"""DB_WRITE_BUSINESS_COMMAND_V1, matching BE PR #209 (48ad1c0).

Each command runs inside the caller's MySQL transaction, including its receipt.
Captured JDBC statements are diagnostic evidence and are never executed here.
LIMIT orders are restored as PENDING; the BE's subscription refresh finds them.
Market execution and external stock-master discovery require their own adapters;
those messages remain queued rather than being acknowledged as partially applied.
"""

from dataclasses import dataclass
from datetime import date, datetime, time, timedelta, timezone
from decimal import Decimal
import json
import math
import re
import uuid
from zoneinfo import ZoneInfo


SEOUL = ZoneInfo("Asia/Seoul")
MAX_LONG = 9_223_372_036_854_775_807
COMMAND_TYPES = frozenset({
    "ACCOUNT_CREATE", "ACCOUNT_RENAME", "WATCHLIST_ADD", "WATCHLIST_REMOVE",
    "ORDER_CREATE", "ORDER_CANCEL", "COMPETITION_CREATE",
})


class ReplayBlocked(ValueError):
    """A safe, machine-readable reason to leave the FIFO head in SQS."""

    def __init__(self, code):
        self.code = code
        super().__init__(code)


def require(condition, code):
    if not condition:
        raise ReplayBlocked(code)


def positive_long(value, code="INVALID_IDENTIFIER"):
    require(type(value) is int and 0 < value <= MAX_LONG, code)
    return value


def java_length(value):
    return len(value.encode("utf-16-le", errors="surrogatepass")) // 2


def blank(value):
    return not value or all(ch.isspace() and ch not in "\u00a0\u2007\u202f" for ch in value)


def java_trim(value):
    return value.strip("".join(chr(number) for number in range(33)))


def text(value, maximum, code, optional=False):
    if value is None and optional:
        return None
    require(isinstance(value, str) and not blank(value) and java_length(value) <= maximum, code)
    return value


def capital(payload):
    value = positive_long(payload.get("initial_capital"), "INVALID_INITIAL_CAPITAL")
    require(1_000_000 <= value <= 100_000_000, "INVALID_INITIAL_CAPITAL")
    return value


def stock_code(value, numeric=False):
    require(isinstance(value, str) and re.fullmatch(r"[0-9]{6}" if numeric else r"[0-9A-Z]{6}", value),
            "INVALID_STOCK_CODE")
    return value


def local_date(value):
    require(isinstance(value, str) and re.fullmatch(r"\d{4}-\d{2}-\d{2}", value), "INVALID_DATE")
    try:
        return date.fromisoformat(value)
    except ValueError as error:
        raise ReplayBlocked("INVALID_DATE") from error


def market_open(now):
    return now.weekday() < 5 and time(9) <= now.time().replace(tzinfo=None) < time(15, 30)


@dataclass(frozen=True)
class CommandResult:
    identifiers: dict
    outcome: str = "applied"


@dataclass(frozen=True)
class BusinessCommand:
    request_id: str
    transaction_id: str
    kind: str
    user_id: int
    source: str
    target: dict
    payload: dict


def validate_envelope(envelope):
    require(isinstance(envelope, dict), "INVALID_ENVELOPE")
    require(type(envelope.get("schemaVersion")) is int and envelope["schemaVersion"] == 3,
            "UNSUPPORTED_SCHEMA")
    require(envelope.get("operation") == "BUSINESS_COMMAND"
            and envelope.get("consumerContract") == "DB_WRITE_BUSINESS_COMMAND_V1", "UNSUPPORTED_CONTRACT")
    try:
        request_id = str(uuid.UUID(envelope["requestId"]))
    except (ValueError, TypeError, AttributeError, KeyError) as error:
        raise ReplayBlocked("INVALID_REQUEST_ID") from error
    transaction_id = envelope.get("transactionId")
    require(isinstance(transaction_id, str) and 0 < len(transaction_id) <= 64, "INVALID_TRANSACTION_ID")
    for key in ("idempotencyKey", "payloadHash"):
        value = envelope.get(key)
        require(isinstance(value, str) and re.fullmatch(r"[0-9a-f]{64}", value), "INVALID_COMMAND_DIGEST")
    require(envelope.get("idempotencyKeySource") in ("CLIENT", "REQUEST"), "INVALID_KEY_SOURCE")
    require(envelope.get("requiresBusinessValidation") is True
            and envelope.get("capturedStatementsArePartial") is True, "INVALID_COMMAND_CONTRACT")
    require(isinstance(envelope.get("capturedStatements"), list), "INVALID_SQL_EVIDENCE")
    safety = envelope.get("replaySafety")
    policy = envelope.get("replayPolicy")
    if safety == "UNCONFIRMED_OR_PARTIAL" or policy == "RECONCILIATION_REQUIRED":
        raise ReplayBlocked("RECONCILIATION_REQUIRED")
    require(safety in ("NO_DML_OBSERVED", "CONFIRMED_ROLLBACK") and policy == "REEXECUTE_COMMAND",
            "INVALID_REPLAY_POLICY")
    require(safety != "NO_DML_OBSERVED" or not envelope["capturedStatements"], "RECONCILIATION_REQUIRED")
    transactions = envelope.get("sourceTransactions")
    require(isinstance(transactions, list), "INVALID_SOURCE_TRANSACTIONS")
    mutation_seen = False
    for transaction in transactions:
        require(isinstance(transaction, dict), "INVALID_SOURCE_TRANSACTIONS")
        require(type(transaction.get("dmlObserved")) is bool
                and type(transaction.get("completionObserved")) is bool
                and type(transaction.get("rollbackConfirmed")) is bool
                and transaction.get("outcome") in ("UNKNOWN", "COMMITTED", "ROLLED_BACK"),
                "INVALID_SOURCE_TRANSACTIONS")
        require(transaction["completionObserved"], "RECONCILIATION_REQUIRED")
        if transaction["dmlObserved"]:
            mutation_seen = True
            require(safety == "CONFIRMED_ROLLBACK" and transaction["outcome"] == "ROLLED_BACK"
                    and transaction["rollbackConfirmed"], "RECONCILIATION_REQUIRED")
    require(safety != "CONFIRMED_ROLLBACK" or mutation_seen, "INVALID_REPLAY_POLICY")
    command = envelope.get("businessCommand")
    require(isinstance(command, dict), "INVALID_BUSINESS_COMMAND")
    kind = command.get("type")
    require(isinstance(kind, str) and kind in COMMAND_TYPES, "UNSUPPORTED_COMMAND")
    actor = command.get("actor")
    require(isinstance(actor, dict), "INVALID_ACTOR")
    user_id = positive_long(actor.get("userId"), "INVALID_ACTOR")
    source = actor.get("source")
    require(source in ("USER", "AI"), "INVALID_ACTOR")
    target, payload = command.get("target"), command.get("payload")
    require(isinstance(target, dict) and isinstance(payload, dict), "INVALID_COMMAND_INPUT")
    expected_target = {
        "ACCOUNT_RENAME": {"accountId"}, "WATCHLIST_REMOVE": {"stockCode"},
        "ORDER_CREATE": {"accountId"}, "ORDER_CANCEL": {"accountId", "orderId"},
    }.get(kind, set())
    require(set(target) == expected_target, "INVALID_COMMAND_TARGET")
    for key in ("accountId", "orderId"):
        if key in target:
            positive_long(target[key])
    return BusinessCommand(request_id, transaction_id, kind, user_id, source, target, payload)


class CommandExecutor:
    def __init__(self, cursor, now=None):
        self.cursor = cursor
        self.now = (now or datetime.now(timezone.utc)).astimezone(SEOUL)
        # Hibernate stores Instant timestamps in UTC; MySQL DATETIME has no timezone.
        self.timestamp = self.now.astimezone(timezone.utc).replace(tzinfo=None)

    def execute(self, command):
        result = {
            "ACCOUNT_CREATE": self.account_create, "ACCOUNT_RENAME": self.account_rename,
            "WATCHLIST_ADD": self.watchlist_add, "WATCHLIST_REMOVE": self.watchlist_remove,
            "ORDER_CREATE": self.order_create, "ORDER_CANCEL": self.order_cancel,
            "COMPETITION_CREATE": self.competition_create,
        }[command.kind](command)
        return result if isinstance(result, CommandResult) else CommandResult(result)

    def one(self, sql, values=()):
        self.cursor.execute(sql, values)
        return self.cursor.fetchone()

    def user(self, user_id, onboarding=False):
        user = self.one("SELECT user_id, CAST(onboarding_completed AS UNSIGNED) AS onboarding_completed "
                        "FROM users WHERE user_id=%s FOR UPDATE", (user_id,))
        require(user is not None, "USER_NOT_FOUND")
        require(not onboarding or user["onboarding_completed"] == 1, "ONBOARDING_REQUIRED")
        return user

    def name_taken(self, user_id, name, except_id=None):
        return self.one("SELECT account_id FROM accounts WHERE user_id=%s AND LOWER(name)=LOWER(%s) "
                        "AND (%s IS NULL OR account_id<>%s) LIMIT 1", (user_id, name, except_id, except_id)) is not None

    def account_name(self, value):
        text(value, MAX_LONG, "INVALID_ACCOUNT_NAME")
        name = java_trim(value)
        require(java_length(name) <= 20, "INVALID_ACCOUNT_NAME")
        return name

    def insert_account(self, user_id, name, amount, ai=False):
        self.cursor.execute(
            "INSERT INTO accounts (user_id,name,initial_capital,cash_balance,is_ai_managed,is_active,created_at,updated_at) "
            "VALUES (%s,%s,%s,%s,%s,1,%s,%s)",
            (user_id, name, amount, amount, int(ai), self.timestamp, self.timestamp))
        return self.cursor.lastrowid

    def account_create(self, command):
        amount = capital(command.payload)
        raw_name = command.payload.get("account_name")
        require(raw_name is None or isinstance(raw_name, str) and java_length(raw_name) <= 20,
                "INVALID_ACCOUNT_NAME")
        self.user(command.user_id, onboarding=True)
        if raw_name is None or blank(raw_name):
            number = 1
            while self.name_taken(command.user_id, f"기본 계좌 {number}"):
                number += 1
            name = f"기본 계좌 {number}"
        else:
            name = self.account_name(raw_name)
        require(not self.name_taken(command.user_id, name), "DUPLICATE_ACCOUNT_NAME")
        return {"accountId": self.insert_account(command.user_id, name, amount)}

    def account_rename(self, command):
        name = self.account_name(command.payload.get("account_name"))
        self.user(command.user_id)
        account_id = command.target["accountId"]
        account = self.one("SELECT account_id,name FROM accounts WHERE account_id=%s AND user_id=%s "
                           "AND is_active=1 FOR UPDATE", (account_id, command.user_id))
        require(account is not None, "ACCOUNT_NOT_FOUND")
        if account["name"] != name:
            require(not self.name_taken(command.user_id, name, account_id), "DUPLICATE_ACCOUNT_NAME")
            self.cursor.execute("UPDATE accounts SET name=%s,updated_at=%s WHERE account_id=%s",
                                (name, self.timestamp, account_id))
        return {"accountId": account_id}

    def matching_stock(self, code):
        self.cursor.execute("SELECT stock_id FROM stocks WHERE stock_code=%s LIMIT 2", (code,))
        matches = self.cursor.fetchall()
        require(len(matches) <= 1, "AMBIGUOUS_STOCK_CODE")
        # Never synthesize a stock name/market, or ACK an unresolved watchlist add.
        require(bool(matches), "STOCK_MASTER_RESOLUTION_REQUIRED")
        return matches[0]["stock_id"]

    def watchlist_add(self, command):
        code = stock_code(command.payload.get("stock_code"))
        self.user(command.user_id)
        stock_id = self.matching_stock(code)
        existing = self.one("SELECT user_id FROM watchlist_stocks WHERE user_id=%s AND stock_id=%s",
                            (command.user_id, stock_id))
        if existing is None:
            self.cursor.execute("INSERT INTO watchlist_stocks (user_id,stock_id,created_at) VALUES (%s,%s,%s)",
                                (command.user_id, stock_id, self.timestamp))
        return {"stockId": stock_id}

    def watchlist_remove(self, command):
        code = stock_code(command.target["stockCode"])
        self.user(command.user_id)
        self.cursor.execute("DELETE w FROM watchlist_stocks w JOIN stocks s ON s.stock_id=w.stock_id "
                            "WHERE w.user_id=%s AND s.stock_code=%s", (command.user_id, code))
        return {}

    def competition_create(self, command):
        payload = command.payload
        name = java_trim(text(payload.get("competition_name"), 20, "INVALID_COMPETITION_NAME"))
        amount = capital(payload)
        require(payload.get("competition_type") == "user_vs_ai", "INVALID_COMPETITION_TYPE")
        require(type(payload.get("ai_participant_count")) is int and payload["ai_participant_count"] == 1,
                "INVALID_AI_PARTICIPANT_COUNT")
        start, end = local_date(payload.get("start_date")), local_date(payload.get("end_date"))
        require(start == self.now.date(), "INVALID_START_DATE")
        require((end - start).days >= 3, "INVALID_COMPETITION_PERIOD")
        self.user(command.user_id, onboarding=True)
        require(not self.name_taken(command.user_id, name), "DUPLICATE_ACCOUNT_NAME")
        started = market_open(self.now)
        self.cursor.execute(
            "INSERT INTO competitions (user_id,competition_name,competition_type,initial_capital,ai_participant_count,"
            "start_date,end_date,state,started_at,created_at,updated_at) "
            "VALUES (%s,%s,'USER_VS_AI',%s,1,%s,%s,%s,%s,%s,%s)",
            (command.user_id, name, amount, start, end, "IN_PROGRESS" if started else "READY",
             self.timestamp if started else None, self.timestamp, self.timestamp))
        competition_id = self.cursor.lastrowid
        user_account = self.insert_account(command.user_id, name, amount)
        base = "AI-" + base36(competition_id)
        ai_name, suffix = base, 1
        while self.name_taken(command.user_id, ai_name):
            ending = "-" + str(suffix)
            ai_name = base[:min(len(base), 20 - len(ending))] + ending
            suffix += 1
        ai_account = self.insert_account(command.user_id, ai_name, amount, ai=True)
        for account_id in (user_account, ai_account):
            self.cursor.execute("INSERT INTO competition_participants (competition_id,account_id) VALUES (%s,%s)",
                                (competition_id, account_id))
        return {"competitionId": competition_id, "userAccountId": user_account, "aiAccountId": ai_account}

    def locked_account(self, command, check_source=False):
        account = self.one("SELECT account_id,user_id,cash_balance,created_at,"
                           "CAST(is_active AS UNSIGNED) AS is_active,CAST(is_ai_managed AS UNSIGNED) AS is_ai_managed "
                           "FROM accounts WHERE account_id=%s FOR UPDATE", (command.target["accountId"],))
        require(account is not None and account["is_active"] == 1, "ACCOUNT_NOT_FOUND")
        require(account["user_id"] == command.user_id, "FORBIDDEN_ACCOUNT")
        if check_source:
            valid = (account["is_ai_managed"] == 1) == (command.source == "AI")
            if not valid and command.source == "USER" and account["is_ai_managed"] == 1:
                created = account["created_at"]
                if isinstance(created, datetime) and created.replace(tzinfo=timezone.utc) < datetime(2026, 10, 20, 13, tzinfo=timezone.utc):
                    raise ReplayBlocked("LEGACY_ACCOUNT_USER_ORDER_NOT_ALLOWED")
            require(valid, "FORBIDDEN_ACCOUNT")
        competition = self.one("SELECT c.state,c.start_date,c.end_date FROM competitions c "
                               "JOIN competition_participants p ON p.competition_id=c.competition_id "
                               "WHERE p.account_id=%s", (account["account_id"],))
        if competition is not None:
            end = competition["end_date"]
            while end.weekday() >= 5:
                end -= timedelta(days=1)
            require(competition["state"] == "IN_PROGRESS" and competition["start_date"] <= self.now.date()
                    and self.now < datetime.combine(end, time(15, 30), SEOUL), "COMPETITION_NOT_IN_PROGRESS")
        return account

    def order_create(self, command):
        payload = command.payload
        kind = payload.get("order_type")
        require(isinstance(kind, str) and kind.lower() in ("limit", "market"), "INVALID_ORDER_TYPE")
        if kind.lower() == "market":
            raise ReplayBlocked("ORDER_WINDOW_CLOSED" if not market_open(self.now) else "MARKET_EXECUTION_REQUIRED")
        side = payload.get("order_side")
        require(isinstance(side, str) and side.upper() in ("BUY", "SELL"), "INVALID_ORDER_SIDE")
        side = side.upper()
        code = stock_code(payload.get("stock_code"), numeric=True)
        quantity = positive_long(payload.get("quantity"), "INVALID_QUANTITY")
        price = positive_long(payload.get("limit_price"), "INVALID_LIMIT_PRICE")
        tick = next(tick for ceiling, tick in ((2_000, 1), (5_000, 5), (20_000, 10), (50_000, 50),
                                             (200_000, 100), (500_000, 500), (MAX_LONG + 1, 1_000)) if price < ceiling)
        require(price % tick == 0, "INVALID_PRICE_TICK")
        report = validate_report(payload, command.source, side)
        account = self.locked_account(command, check_source=True)
        account_id = account["account_id"]
        reserved = quantity * price if side == "BUY" else 0
        require(reserved <= MAX_LONG, "ORDER_AMOUNT_OVERFLOW")
        if side == "BUY":
            row = self.one("SELECT COALESCE(SUM(reserved_cash),0) AS amount FROM trade_orders "
                           "WHERE account_id=%s AND status='PENDING'", (account_id,))
            require(account["cash_balance"] - row["amount"] >= reserved, "INSUFFICIENT_CASH")
        else:
            held = self.one("SELECT quantity FROM holdings WHERE account_id=%s AND stock_code=%s",
                            (account_id, code))
            pending = self.one("SELECT COALESCE(SUM(quantity),0) AS quantity FROM trade_orders "
                               "WHERE account_id=%s AND stock_code=%s AND side='SELL' AND status='PENDING'", (account_id, code))
            require((held["quantity"] if held else 0) - pending["quantity"] >= quantity, "INSUFFICIENT_HOLDINGS")
        self.cursor.execute(
            "INSERT INTO trade_orders (account_id,stock_code,side,order_type,status,order_source,quantity,"
            "limit_price,reserved_cash,created_at) VALUES (%s,%s,%s,'LIMIT','PENDING',%s,%s,%s,%s,%s)",
            (account_id, code, side, command.source, quantity, price, reserved, self.timestamp))
        order_id = self.cursor.lastrowid
        if command.source == "AI":
            self.cursor.execute("INSERT INTO ai_order_reports (order_id,reason,stock_name,holding_weight_limit_percent,"
                                "is_lower_triggered) VALUES (%s,%s,%s,%s,%s)",
                                (order_id, report["reason"], report["stock_name"],
                                 report["holding_weight_limit_percent"], report["is_lower_triggered"]))
            report_id = self.cursor.lastrowid
            for index, item in enumerate(report["reasoning"]):
                self.cursor.execute("INSERT INTO ai_report_reasoning (report_id,reasoning_index,label,body) VALUES (%s,%s,%s,%s)",
                                    (report_id, index, item["label"], item["body"]))
        return {"orderId": order_id}

    def order_cancel(self, command):
        require(command.payload.get("status") == "cancelled", "INVALID_ORDER_STATUS")
        self.locked_account(command)
        order = self.one("SELECT order_id,status,reserved_cash,created_at,cancelled_at FROM trade_orders WHERE order_id=%s AND account_id=%s FOR UPDATE",
                         (command.target["orderId"], command.target["accountId"]))
        if (order is not None and order["status"] == "CANCELLED"
                and order["reserved_cash"] == 0 and order["cancelled_at"] is not None):
            # Ownership and both row locks have already been checked. Record this
            # request's receipt without changing the original cancellation time.
            return CommandResult({"orderId": order["order_id"], "accountId": command.target["accountId"],
                                  "previousStatus": "CANCELLED", "orderStatus": "CANCELLED",
                                  "cancelledAt": str(order["cancelled_at"]), "mutationApplied": False},
                                 "already_satisfied")
        if order is None or order["status"] != "PENDING":
            # Conflicting or inconsistent state remains queued for investigation.
            print(json.dumps({
                "event": "db_write_replay_order_cancel_validation_failed",
                "requestId": command.request_id,
                "commandType": command.kind,
                "phase": "order_cancel_state_validation",
                "accountId": command.target["accountId"],
                "orderId": command.target["orderId"],
                "orderExists": order is not None,
                "observedOrderStatus": order["status"] if order is not None else None,
                "expectedOrderStatus": "PENDING",
                "orderCreatedAt": order.get("created_at") if order is not None else None,
                "orderCancelledAt": order.get("cancelled_at") if order is not None else None,
                "reservedCashReleased": order["reserved_cash"] == 0 if order is not None else None,
            }, default=str))
        require(order is not None, "ORDER_NOT_FOUND")
        require(order["status"] != "CANCELLED", "CANCELLED_ORDER_STATE_INCONSISTENT")
        require(order["status"] == "PENDING", "ORDER_NOT_PENDING")
        self.cursor.execute("UPDATE trade_orders SET status='CANCELLED',reserved_cash=0,cancelled_at=%s WHERE order_id=%s",
                            (self.timestamp, order["order_id"]))
        return {"orderId": order["order_id"], "accountId": command.target["accountId"],
                "previousStatus": "PENDING", "orderStatus": "CANCELLED",
                "cancelledAt": str(self.timestamp), "mutationApplied": True}


def validate_report(payload, source, side):
    reason = payload.get("reason")
    require(reason is None or isinstance(reason, str) and java_length(reason) <= 100_000, "INVALID_REPORT_REASON")
    name = text(payload.get("stock_name"), 255, "INVALID_STOCK_NAME", optional=True)
    reasoning = payload.get("reasoning")
    require(reasoning is None or isinstance(reasoning, list), "INVALID_REPORT_REASONING")
    for item in reasoning or []:
        require(isinstance(item, dict), "INVALID_REPORT_REASONING")
        text(item.get("label"), 255, "INVALID_REPORT_REASONING")
        text(item.get("body"), 16_000, "INVALID_REPORT_REASONING")
    limit, lower = payload.get("holding_weight_limit_percent"), payload.get("is_lower_triggered")
    require(lower is None or type(lower) is bool, "INVALID_LOWER_TRIGGERED")
    if source == "AI":
        text(reason, 100_000, "INVALID_REPORT_REASON")
        require(limit is None or type(limit) in (int, float, Decimal) and math.isfinite(limit) and 0 <= limit <= 100,
                "INVALID_HOLDING_WEIGHT_LIMIT")
        require(side != "BUY" or limit is not None, "HOLDING_WEIGHT_LIMIT_REQUIRED")
        require(side != "SELL" or lower is not None, "LOWER_TRIGGERED_REQUIRED")
    return {"reason": reason, "stock_name": name, "reasoning": reasoning or [],
            "holding_weight_limit_percent": limit, "is_lower_triggered": lower}


def base36(value):
    alphabet = "0123456789abcdefghijklmnopqrstuvwxyz"
    result = ""
    while value:
        value, remainder = divmod(value, 36)
        result = alphabet[remainder] + result
    return result or "0"
