"""Drain BE commands after a successful promotion invokes this Lambda.

Manual invocation: {"maxMessages": 100, "maxRuntimeSeconds": 840}.
Schema 3 dispatches typed business commands; schema 2 retains legacy SQL replay.
The caller owns promotion readiness. No SQS event-source mapping is required.
The caller must inspect status: blocked retains the failed FIFO head and stops;
message_limit/runtime_limit mean another invocation may be needed to finish.
db_write_replay_receipts.sql must already be applied on the replicated database.
"""

import base64
import json
import os
import re
import time
import uuid
from decimal import Decimal

from db_write_business_commands import CommandExecutor, ReplayBlocked, validate_envelope


_sqs = None
_ssm = None
_database_credentials = None

_TRANSIENT_MYSQL_CODES = frozenset({1040, 1053, 1205, 1213, 1290, 2002, 2003, 2006, 2013, 2055, 9001})
_BUSINESS_CONFLICT_CODES = frozenset({
    "USER_NOT_FOUND", "ONBOARDING_REQUIRED", "ACCOUNT_NOT_FOUND", "FORBIDDEN_ACCOUNT",
    "DUPLICATE_ACCOUNT_NAME", "LEGACY_ACCOUNT_USER_ORDER_NOT_ALLOWED",
    "COMPETITION_NOT_IN_PROGRESS", "INVALID_START_DATE", "INVALID_COMPETITION_PERIOD",
    "ORDER_WINDOW_CLOSED", "ORDER_NOT_FOUND", "ORDER_NOT_PENDING",
    "INSUFFICIENT_CASH", "INSUFFICIENT_HOLDINGS",
})
_RECONCILIATION_CODES = frozenset({
    "RECONCILIATION_REQUIRED", "CANCELLED_ORDER_STATE_INCONSISTENT",
    "AMBIGUOUS_STOCK_CODE", "STOCK_MASTER_RESOLUTION_REQUIRED", "MARKET_EXECUTION_REQUIRED",
})


def _aws_clients():
    global _sqs, _ssm
    if _sqs is None or _ssm is None:
        import boto3

        if _sqs is None:
            _sqs = boto3.client("sqs")
        if _ssm is None:
            _ssm = boto3.client("ssm")
    return _sqs, _ssm


def _database_auth():
    global _database_credentials
    if _database_credentials is None:
        _, ssm = _aws_clients()
        user = ssm.get_parameter(
            Name=os.environ["DB_WRITE_REPLAY_MYSQL_USER_PARAMETER"],
            WithDecryption=True,
        )["Parameter"]["Value"]
        password = ssm.get_parameter(
            Name=os.environ["DB_WRITE_REPLAY_MYSQL_PASSWORD_PARAMETER"],
            WithDecryption=True,
        )["Parameter"]["Value"]
        if not user or not password:
            raise ValueError("The ProxySQL database credentials are empty")
        _database_credentials = (user, password)
    return _database_credentials


def _decode_value(serialized):
    if not isinstance(serialized, dict) or "type" not in serialized:
        raise ValueError("A JDBC bind value is malformed")

    value = serialized.get("value")
    value_type = serialized["type"]
    if value_type == "null":
        return None
    if value_type == "byte[]":
        return base64.b64decode(value or "", validate=True)
    if value_type in ("java.math.BigDecimal",):
        return Decimal(str(value))
    if value_type in ("java.math.BigInteger", "java.lang.Integer", "java.lang.Long",
                      "java.lang.Short", "java.lang.Byte"):
        return int(value)
    if value_type in ("java.lang.Float", "java.lang.Double"):
        return float(value)
    if value_type == "java.lang.Boolean":
        if isinstance(value, bool):
            return value
        normalized = str(value).lower()
        if normalized not in ("true", "false"):
            raise ValueError("A JDBC boolean bind value is malformed")
        return normalized == "true"

    # MySQL can parse the ISO representations emitted by the BE for date/time,
    # UUID, enum, and string values. Other JSON scalar values remain bindable.
    if value is None or isinstance(value, (str, int, float, bool)):
        return value
    raise ValueError(f"Unsupported JDBC bind value type: {value_type}")


def _parameters_from_operations(operations):
    parameters = {}
    for operation in operations:
        if not isinstance(operation, dict):
            raise ValueError("A JDBC bind operation is malformed")
        method = operation.get("method", "")
        arguments = operation.get("args", [])
        if not isinstance(method, str) or not method.startswith("set"):
            raise ValueError("A JDBC bind operation has an unsupported method")
        if not isinstance(arguments, list) or len(arguments) < 1:
            raise ValueError("A JDBC bind operation has no parameter index")

        index = _decode_value(arguments[0])
        if isinstance(index, bool) or not isinstance(index, int) or index < 1:
            raise ValueError("A JDBC bind operation has an invalid parameter index")
        if method == "setNull":
            value = None
        elif len(arguments) >= 2:
            value = _decode_value(arguments[1])
        else:
            raise ValueError("A JDBC bind operation has no parameter value")
        parameters[index] = value

    if not parameters:
        return ()
    highest_index = max(parameters)
    if set(parameters) != set(range(1, highest_index + 1)):
        raise ValueError("JDBC bind parameter indexes are not contiguous")
    return tuple(parameters[index] for index in range(1, highest_index + 1))


def _prepare_sql(sql, has_parameters):
    """Translate JDBC question marks to PyMySQL placeholders outside SQL literals."""
    output = []
    placeholders = 0
    index = 0
    mode = "normal"
    while index < len(sql):
        char = sql[index]
        next_char = sql[index + 1] if index + 1 < len(sql) else ""

        if mode == "normal":
            if char == "'":
                mode = "single"
                output.append(char)
            elif char == '"':
                mode = "double"
                output.append(char)
            elif char == "`":
                mode = "backtick"
                output.append(char)
            elif char == "#":
                mode = "line"
                output.append(char)
            elif char == "-" and next_char == "-" and (
                index + 2 == len(sql) or sql[index + 2].isspace()
            ):
                mode = "line"
                output.extend((char, next_char))
                index += 1
            elif char == "/" and next_char == "*":
                mode = "block"
                output.extend((char, next_char))
                index += 1
            elif char == "?":
                output.append("%s")
                placeholders += 1
            elif char == "%" and has_parameters:
                output.append("%%")
            else:
                output.append(char)
        elif mode == "line":
            output.append(char)
            if char == "\n":
                mode = "normal"
        elif mode == "block":
            output.append(char)
            if char == "*" and next_char == "/":
                output.append(next_char)
                index += 1
                mode = "normal"
        else:
            quote = {"single": "'", "double": '"', "backtick": "`"}[mode]
            if char == "\\" and mode != "backtick" and next_char:
                output.extend((char, next_char))
                index += 1
            elif char == quote and next_char == quote:
                output.extend((char, next_char))
                index += 1
            else:
                if char == quote:
                    mode = "normal"
                if char == "%" and has_parameters:
                    output.append("%%")
                else:
                    output.append(char)
        index += 1
    return "".join(output), placeholders


def _execute_statement(cursor, statement):
    if not isinstance(statement, dict) or not isinstance(statement.get("sql"), str):
        raise ValueError("A queued SQL statement is malformed")
    sql = statement["sql"]
    parameter_sets = statement.get("parameterSets") or [[]]
    if not isinstance(parameter_sets, list) or not parameter_sets:
        raise ValueError("A queued SQL statement has no parameter sets")

    for operations in parameter_sets:
        if not isinstance(operations, list):
            raise ValueError("A JDBC parameter set is malformed")
        parameters = _parameters_from_operations(operations)
        prepared_sql, placeholder_count = _prepare_sql(sql, bool(parameters))
        if placeholder_count != len(parameters):
            raise ValueError("JDBC bind count does not match SQL placeholders")
        if parameters:
            cursor.execute(prepared_sql, parameters)
        else:
            cursor.execute(prepared_sql)
        # CALL may produce result sets; consume them before issuing the next statement.
        while cursor.nextset():
            if cursor.description:
                cursor.fetchall()


def _connect_database(dictionary=False):
    import pymysql

    username, password = _database_auth()
    options = dict(
        host=os.environ["DB_WRITE_REPLAY_PROXYSQL_HOST"],
        port=int(os.environ.get("DB_WRITE_REPLAY_PROXYSQL_PORT", "6033")),
        user=username,
        password=password,
        database=os.environ.get("DB_WRITE_REPLAY_DATABASE", "stockspoon"),
        connect_timeout=5,
        read_timeout=30,
        write_timeout=30,
        autocommit=False,
        charset="utf8mb4",
        init_command="SET time_zone = '+00:00'",
    )
    if dictionary:
        options["cursorclass"] = pymysql.cursors.DictCursor
    return pymysql.connect(**options)


def _rollback(connection):
    try:
        connection.rollback()
    except Exception as error:
        print(json.dumps({"event": "db_write_replay_rollback_unconfirmed", "errorType": type(error).__name__,
                          "errorCode": _safe_error_code(error)}))


def _close(connection):
    try:
        connection.close()
    except Exception:
        # A close error must not hide a confirmed commit or the original failure.
        pass


def _execute_transaction(envelope):
    if isinstance(envelope, dict) and type(envelope.get("schemaVersion")) is int and envelope["schemaVersion"] == 3:
        return _execute_business_command(envelope)
    return _execute_sql_transaction(envelope)


def _execute_business_command(envelope):
    # Validate safety and command routing before even opening a database connection.
    command = validate_envelope(envelope)
    import pymysql

    connection = _connect_database(dictionary=True)
    try:
        connection.begin()
        with connection.cursor() as cursor:
            try:
                # Retain the existing requestId receipt. Full client-key idempotency
                # and reconciliation of the original BE commit are separate work.
                cursor.execute("INSERT INTO db_write_replay_receipts (request_id,transaction_id) VALUES (%s,%s)",
                               (command.request_id, command.transaction_id))
            except pymysql.err.IntegrityError as error:
                if error.args and error.args[0] == 1062:
                    _rollback(connection)
                    return "duplicate"
                raise
            result = CommandExecutor(cursor).execute(command)
            if result.outcome not in ("applied", "already_satisfied"):
                raise RuntimeError("Unexpected business command outcome")
        connection.commit()
        print(json.dumps({"event": "db_write_business_command_committed", "requestId": command.request_id,
                          "commandType": command.kind, "result": result.identifiers, "outcome": result.outcome}))
        return result.outcome
    except Exception:
        _rollback(connection)
        raise
    finally:
        _close(connection)


def _execute_sql_transaction(envelope):
    if not isinstance(envelope, dict) or envelope.get("schemaVersion") != 2:
        raise ValueError("Unsupported DB write replay message schema")
    if envelope.get("operation") != "SQL_TRANSACTION":
        raise ValueError("Unsupported DB write replay operation")
    request_id = envelope.get("requestId")
    try:
        request_id = str(uuid.UUID(request_id))
    except (ValueError, TypeError, AttributeError) as error:
        raise ValueError("The queued transaction has an invalid requestId") from error
    statements = envelope.get("statements")
    if not isinstance(statements, list) or not statements:
        raise ValueError("The queued transaction has no SQL statements")

    import pymysql

    connection = _connect_database()
    try:
        connection.begin()
        try:
            with connection.cursor() as cursor:
                cursor.execute(
                    "INSERT INTO db_write_replay_receipts "
                    "(request_id, transaction_id) VALUES (%s, %s)",
                    (request_id, str(envelope.get("transactionId", ""))[:64]),
                )
        except pymysql.err.IntegrityError as error:
            if error.args and error.args[0] == 1062:
                _rollback(connection)
                return "duplicate"
            raise
        with connection.cursor() as cursor:
            for statement in statements:
                _execute_statement(cursor, statement)
        connection.commit()
        return "applied"
    except Exception:
        _rollback(connection)
        raise
    finally:
        _close(connection)


def _positive_int(event, key, default, maximum):
    value = event.get(key, default) if isinstance(event, dict) else default
    if type(value) is not int:
        raise ValueError(f"{key} must be an integer")
    if value < 1 or value > maximum:
        raise ValueError(f"{key} must be between 1 and {maximum}")
    return value


def _safe_error_code(error):
    if isinstance(error, ReplayBlocked):
        return error.code
    arguments = getattr(error, "args", ())
    # Exception strings can contain SQL and bindings. MySQL numeric codes are safe.
    if arguments and type(arguments[0]) is int:
        return arguments[0]
    response = getattr(error, "response", None)
    if isinstance(response, dict):
        details = response.get("Error")
        code = details.get("Code") if isinstance(details, dict) else None
        if isinstance(code, str) and re.fullmatch(r"[A-Za-z0-9_.-]{1,64}", code):
            return code
    return None


def _classify_failure(error, stage):
    """Classify for operators; queue retention and FIFO stopping remain unchanged."""
    code = _safe_error_code(error)
    if stage == "sqs_delete":
        category = "SQS_ERROR"
        response = getattr(error, "response", {})
        metadata = response.get("ResponseMetadata", {}) if isinstance(response, dict) else {}
        status = metadata.get("HTTPStatusCode") if isinstance(metadata, dict) else None
        retryable = (isinstance(error, (ConnectionError, TimeoutError))
                     or code in {"Throttling", "ThrottlingException", "RequestThrottled", "RequestTimeout"}
                     or type(status) is int and (status == 429 or 500 <= status <= 599))
    elif isinstance(error, ReplayBlocked):
        category = ("RECONCILIATION_REQUIRED" if code in _RECONCILIATION_CODES
                    else "BUSINESS_CONFLICT" if code in _BUSINESS_CONFLICT_CODES
                    else "INVALID_COMMAND")
        retryable = False
    elif isinstance(error, ValueError):
        category, retryable = "INVALID_COMMAND", False
    elif stage == "command_execution" and (
            code in _TRANSIENT_MYSQL_CODES or isinstance(error, (ConnectionError, TimeoutError))):
        category, retryable = "TRANSIENT_DB_ERROR", True
    elif stage == "command_execution" and type(code) is int:
        category, retryable = "DATABASE_ERROR", False
    else:
        category, retryable = "SYSTEM_ERROR", False
    return {"failureCategory": category, "retryable": retryable}


def _drain_result(status, processed, applied, duplicates, already_satisfied, **details):
    result = {"status": status, "processed": processed, "applied": applied,
              "duplicates": duplicates, "alreadySatisfied": already_satisfied, **details}
    # Embedded Metric Format uses the existing CloudWatch Logs permission.
    # A handled business block must be observable even when Lambda Errors is zero.
    metrics = {"Processed": processed, "Applied": applied, "Duplicates": duplicates,
               "AlreadySatisfied": already_satisfied, "Blocked": int(status == "blocked")}
    print(json.dumps({
        "event": "db_write_replay_summary", **result,
        "FunctionName": os.environ.get("AWS_LAMBDA_FUNCTION_NAME", "db-write-replay-forwarder"),
        "FailureCategory": details.get("failureCategory", "NONE"), **metrics,
        "_aws": {"Timestamp": int(time.time() * 1000), "CloudWatchMetrics": [{
            "Namespace": "Stockspoon/DBWriteReplay",
            "Dimensions": [["FunctionName", "FailureCategory"]],
            "Metrics": [{"Name": name, "Unit": "Count"} for name in metrics],
        }]},
    }))
    return result


def handler(event, context):
    """Drain messages only when explicitly invoked; there is no SQS event mapping."""
    if event is None:
        event = {}
    if not isinstance(event, dict) or "Records" in event:
        raise ReplayBlocked("MANUAL_INVOCATION_REQUIRED")
    max_messages = _positive_int(event, "maxMessages", 100, 1000)
    max_runtime_seconds = _positive_int(event, "maxRuntimeSeconds", 840, 840)
    wait_seconds = _positive_int(event, "waitTimeSeconds", 2, 20)
    empty_limit = _positive_int(event, "emptyReceivesBeforeStop", 2, 10)
    sqs, _ = _aws_clients()
    queue_url = os.environ["DB_WRITE_REPLAY_QUEUE_URL"]
    started_at = time.monotonic()
    processed = 0
    applied = 0
    duplicates = 0
    already_satisfied = 0
    empty_receives = 0

    while processed < max_messages:
        remaining_ms = context.get_remaining_time_in_millis()
        elapsed = time.monotonic() - started_at
        if remaining_ms <= (wait_seconds + 65) * 1000 or elapsed + wait_seconds + 65 >= max_runtime_seconds:
            return _drain_result("runtime_limit", processed, applied, duplicates, already_satisfied)

        response = sqs.receive_message(
            QueueUrl=queue_url,
            MaxNumberOfMessages=1,
            WaitTimeSeconds=wait_seconds,
            VisibilityTimeout=900,
            MessageSystemAttributeNames=["ApproximateReceiveCount"],
        )
        messages = response.get("Messages", [])
        if not messages:
            # Wait across a brief empty interval for BE requests still finishing
            # their SendMessage call as the switch script invokes this Lambda.
            empty_receives += 1
            if empty_receives < empty_limit:
                continue
            return _drain_result("queue_empty", processed, applied, duplicates, already_satisfied)
        empty_receives = 0

        message = messages[0]
        message_id = message.get("MessageId", "unknown")
        request_id = "unknown"
        stage = "message_validation"
        db_committed = False
        try:
            envelope = json.loads(message["Body"], parse_constant=_invalid_json_number)
            if not isinstance(envelope, dict):
                raise ReplayBlocked("INVALID_ENVELOPE")
            try:
                request_id = str(uuid.UUID(envelope.get("requestId")))
            except (ValueError, TypeError, AttributeError):
                request_id = "invalid"
            stage = "command_execution"
            result = _execute_transaction(envelope)
            if result not in ("applied", "duplicate", "already_satisfied"):
                raise RuntimeError("Unexpected replay outcome")
            db_committed = True
            stage = "sqs_delete"
            sqs.delete_message(
                QueueUrl=queue_url,
                ReceiptHandle=message["ReceiptHandle"],
            )
            processed += 1
            if result == "duplicate":
                duplicates += 1
            elif result == "already_satisfied":
                already_satisfied += 1
            else:
                applied += 1
            print(json.dumps({
                "event": "db_write_replay_completed",
                "requestId": request_id,
                "sqsMessageId": message_id,
                "result": result,
                "operation": envelope.get("operation"),
                "processed": processed,
            }))
        except Exception as error:
            # SQL text and bind values can contain user data. Log only safe identifiers
            # and exception codes; leave the message queued and stop at this FIFO head.
            released_for_retry = False
            failure = _classify_failure(error, stage)
            try:
                sqs.change_message_visibility(
                    QueueUrl=queue_url,
                    ReceiptHandle=message["ReceiptHandle"],
                    VisibilityTimeout=0,
                )
                released_for_retry = True
            except Exception as visibility_error:
                print(json.dumps({
                    "event": "db_write_replay_visibility_reset_failed",
                    "requestId": request_id,
                    "sqsMessageId": message_id,
                    "errorType": type(visibility_error).__name__,
                    "errorCode": _safe_error_code(visibility_error),
                }))
            print(json.dumps({
                "event": "db_write_replay_blocked",
                "requestId": request_id,
                "sqsMessageId": message_id,
                "errorType": type(error).__name__,
                "errorCode": _safe_error_code(error),
                "releasedForRetry": released_for_retry,
                "processed": processed,
                "processingStage": stage,
                "dbCommitConfirmed": db_committed,
                "receiveCount": message.get("Attributes", {}).get("ApproximateReceiveCount"),
                **failure,
            }))
            return _drain_result(
                "blocked", processed, applied, duplicates, already_satisfied,
                requestId=request_id, messageId=message_id,
                errorType=type(error).__name__, errorCode=_safe_error_code(error),
                releasedForRetry=released_for_retry, processingStage=stage,
                dbCommitConfirmed=db_committed, **failure,
            )

    return _drain_result("message_limit", processed, applied, duplicates, already_satisfied)


def _invalid_json_number(_value):
    raise ReplayBlocked("INVALID_JSON_NUMBER")
