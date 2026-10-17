"""Restore the migration listener rule to V1; never promote traffic to V2."""
import json
import os


def emit(action, **fields):
    print(json.dumps({"action": action, **fields}, default=str))


def reconcile(event, config, elb, ssm, cloudwatch):
    # EventBridge permissions restrict callers; also validate the event payload.
    if event.get("account") != config["account"] or event.get("region") != config["region"]:
        raise ValueError("Unexpected event account or region")
    alarm_event = event.get("source") == "aws.cloudwatch"
    schedule_event = (
        event.get("source") == "aws.events"
        and event.get("detail-type") == "Scheduled Event"
        and event.get("resources") == [config["schedule_arn"]]
    )
    if alarm_event:
        detail = event.get("detail", {})
        alarm_name = detail.get("alarmName")
        expected_arn = f'arn:aws:cloudwatch:{config["region"]}:{config["account"]}:alarm:{alarm_name}'
        if (event.get("detail-type") != "CloudWatch Alarm State Change"
                or alarm_name not in config["alarms"]
                or event.get("resources") != [expected_arn]
                or detail.get("state", {}).get("value") != "ALARM"):
            raise ValueError("Unexpected alarm event")
    elif not schedule_event:
        raise ValueError("Unexpected event source")

    latch = ssm.get_parameter(Name=config["parameter"])["Parameter"]["Value"]
    if latch not in {"disarmed", "armed", "tripped"}:
        raise ValueError("Invalid rollback latch; operator intervention required")
    if latch == "disarmed":
        emit("rollback_disarmed", event_id=event.get("id"))
        return {"status": "disarmed"}

    # Recheck alarms: delayed ALARM events must not roll back a recovered service.
    alarms = cloudwatch.describe_alarms(AlarmNames=config["alarms"])["MetricAlarms"]
    if {a["AlarmName"] for a in alarms} != set(config["alarms"]):
        raise RuntimeError("Rollback alarms missing")
    active = [a["AlarmName"] for a in alarms if a["StateValue"] == "ALARM"]
    if latch == "armed" and not active:
        return {"status": "healthy"}

    rule = elb.describe_rules(RuleArns=[config["rule_arn"]])["Rules"][0]
    actions = rule["Actions"]
    if len(actions) != 1 or actions[0]["Type"] != "forward":
        raise RuntimeError("Unexpected listener action; refusing to overwrite")
    groups = actions[0].get("ForwardConfig", {}).get("TargetGroups", [])
    if len(groups) != 2 or {g["TargetGroupArn"] for g in groups} != {config["v1"], config["v2"]}:
        raise RuntimeError("Unexpected target groups; refusing to overwrite")
    weights = {g["TargetGroupArn"]: g.get("Weight", 1) for g in groups}
    if weights == {config["v1"]: 100, config["v2"]: 0}:
        return {"status": "already_v1", "latch": latch}

    targets = elb.describe_target_health(TargetGroupArn=config["v1"])["TargetHealthDescriptions"]
    if not any(t["TargetHealth"]["State"] == "healthy" for t in targets):
        emit("rollback_blocked", reason="V1 has no healthy target", alarms=active)
        raise RuntimeError("V1 has no healthy target")

    # Persist first: a failed ModifyRule can be retried and a fresh Terraform plan
    # also respects the latch. A plan saved before this write must be discarded.
    if latch != "tripped":
        ssm.put_parameter(Name=config["parameter"], Value="tripped", Type="String", Overwrite=True)
    emit("rollback_started", alarms=active, previous_weights=weights, event_id=event.get("id"))
    elb.modify_rule(RuleArn=config["rule_arn"], Actions=[{
        "Type": "forward",
        "ForwardConfig": {
            "TargetGroups": [
                {"TargetGroupArn": config["v1"], "Weight": 100},
                {"TargetGroupArn": config["v2"], "Weight": 0},
            ],
            "TargetGroupStickinessConfig": {"Enabled": False},
        },
    }])
    result = elb.describe_rules(RuleArns=[config["rule_arn"]])["Rules"][0]
    actual = {g["TargetGroupArn"]: g["Weight"] for g in result["Actions"][0]["ForwardConfig"]["TargetGroups"]}
    if actual != {config["v1"]: 100, config["v2"]: 0}:
        raise RuntimeError("Listener weights not yet confirmed; retry required")
    emit("rollback_completed", alarms=active, weights=actual, event_id=event.get("id"))
    return {"status": "rolled_back", "alarms": active}


def handler(event, context):
    import boto3

    config = {
        "account": os.environ["ACCOUNT_ID"],
        "region": os.environ["AWS_REGION"],
        "rule_arn": os.environ["RULE_ARN"],
        "v1": os.environ["V1_TARGET_GROUP_ARN"],
        "v2": os.environ["V2_TARGET_GROUP_ARN"],
        "parameter": os.environ["LATCH_PARAMETER"],
        "alarms": json.loads(os.environ["ALARM_NAMES"]),
        "schedule_arn": os.environ["SCHEDULE_ARN"],
    }
    return reconcile(event, config, boto3.client("elbv2"), boto3.client("ssm"), boto3.client("cloudwatch"))
