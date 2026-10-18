"""Manually drains queued JDBC transactions through the ProxySQL writer endpoint."""

import base64
import json
import os
import time
import uuid
from decimal import Decimal


_sqs = None
_ssm = None
_database_credentials = None


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


def _execute_transaction(envelope):
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

    username, password = _database_auth()
    connection = pymysql.connect(
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
    )
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
            connection.rollback()
            if error.args and error.args[0] == 1062:
                return "duplicate"
            raise
        try:
            with connection.cursor() as cursor:
                for statement in statements:
                    _execute_statement(cursor, statement)
            connection.commit()
            return "applied"
        except Exception:
            connection.rollback()
            raise
    except Exception:
        connection.rollback()
        raise
    finally:
        connection.close()


def _positive_int(event, key, default, maximum):
    value = event.get(key, default) if isinstance(event, dict) else default
    if isinstance(value, bool):
        raise ValueError(f"{key} must be an integer")
    try:
        value = int(value)
    except (TypeError, ValueError) as error:
        raise ValueError(f"{key} must be an integer") from error
    if value < 1 or value > maximum:
        raise ValueError(f"{key} must be between 1 and {maximum}")
    return value


def _safe_error_code(error):
    arguments = getattr(error, "args", ())
    return arguments[0] if arguments and isinstance(arguments[0], (str, int)) else None


def handler(event, context):
    """Drain messages only when explicitly invoked; there is no SQS event mapping."""
    max_messages = _positive_int(event, "maxMessages", 100, 1000)
    max_runtime_seconds = _positive_int(event, "maxRuntimeSeconds", 840, 840)
    sqs, _ = _aws_clients()
    queue_url = os.environ["DB_WRITE_REPLAY_QUEUE_URL"]
    started_at = time.monotonic()
    processed = 0
    applied = 0
    duplicates = 0

    while processed < max_messages:
        remaining_ms = context.get_remaining_time_in_millis()
        elapsed = time.monotonic() - started_at
        if remaining_ms <= 15_000 or elapsed >= max_runtime_seconds:
            return {
                "status": "runtime_limit",
                "processed": processed,
                "applied": applied,
                "duplicates": duplicates,
            }

        response = sqs.receive_message(
            QueueUrl=queue_url,
            MaxNumberOfMessages=1,
            WaitTimeSeconds=0,
            VisibilityTimeout=900,
            MessageSystemAttributeNames=["ApproximateReceiveCount"],
        )
        messages = response.get("Messages", [])
        if not messages:
            return {
                "status": "queue_empty",
                "processed": processed,
                "applied": applied,
                "duplicates": duplicates,
            }

        message = messages[0]
        message_id = message.get("MessageId", "unknown")
        request_id = "unknown"
        try:
            envelope = json.loads(message["Body"])
            request_id = str(envelope.get("requestId", "unknown"))[:64]
            result = _execute_transaction(envelope)
            sqs.delete_message(
                QueueUrl=queue_url,
                ReceiptHandle=message["ReceiptHandle"],
            )
            processed += 1
            if result == "duplicate":
                duplicates += 1
            else:
                applied += 1
            print(json.dumps({
                "event": "db_write_replay_completed",
                "requestId": request_id,
                "sqsMessageId": message_id,
                "result": result,
                "processed": processed,
            }))
        except Exception as error:
            # SQL text and bind values can contain user data. Log only safe identifiers
            # and exception codes; leave the message queued and stop at this FIFO head.
            released_for_retry = False
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
            }))
            return {
                "status": "blocked",
                "processed": processed,
                "applied": applied,
                "duplicates": duplicates,
                "requestId": request_id,
                "messageId": message_id,
                "errorType": type(error).__name__,
                "errorCode": _safe_error_code(error),
                "releasedForRetry": released_for_retry,
            }

    return {
        "status": "message_limit",
        "processed": processed,
        "applied": applied,
        "duplicates": duplicates,
    }
