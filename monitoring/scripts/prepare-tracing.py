#!/usr/bin/env python3
"""Read live ECS tasks and render image-build/deployment inputs; never deploy."""

import argparse
import copy
import hashlib
import json
from pathlib import Path
import re
import shlex
import subprocess


ROOT = Path(__file__).resolve().parents[2]
SERVICES = {"backend": "backend", "backend-collector": "backend", "market-http": "market-http"}
READ_ONLY = {
    "taskDefinitionArn", "revision", "status", "requiresAttributes", "compatibilities",
    "registeredAt", "registeredBy", "deregisteredAt",
}


def aws_json(profile, region, *args):
    return json.loads(subprocess.check_output(
        ["aws", "--profile", profile, "--region", region, *args, "--output", "json"], text=True,
    ))


def running_image(image, digests):
    if not re.fullmatch(r"public\.ecr\.aws/[a-z0-9]+/[a-z0-9._/-]+(?::[A-Za-z0-9_.-]+|@sha256:[0-9a-f]{64})?", image):
        raise ValueError("Expected an existing public ECR application image")
    digests = set(digests)
    if len(digests) != 1 or not re.fullmatch(r"sha256:[0-9a-f]{64}", next(iter(digests))):
        raise ValueError("All running tasks must have the same resolved image digest")
    repository = image.split("@")[0].split(":")[0]
    return repository + "@" + next(iter(digests))


def instrumented_task(snapshot, service, environment, image):
    original = snapshot["taskDefinition"]
    if not original["family"].endswith("-" + service):
        raise ValueError("Task family does not match the selected service")
    task = {key: copy.deepcopy(value) for key, value in original.items() if key not in READ_ONLY}
    if snapshot.get("tags"):
        task["tags"] = copy.deepcopy(snapshot["tags"])
    matches = [item for item in task["containerDefinitions"] if item["name"] == SERVICES[service]]
    if len(matches) != 1:
        raise ValueError("Expected exactly one matching application container")
    container = matches[0]
    env = {item["name"]: item["value"] for item in container.get("environment", [])}
    if environment.get("OTEL_SERVICE_NAME") != service:
        raise ValueError("Terraform OTLP environment does not match the service")
    if environment.get("OTEL_TRACES_EXPORTER") != "otlp" or any(
        environment.get(name) != "none" for name in ["OTEL_METRICS_EXPORTER", "OTEL_LOGS_EXPORTER"]
    ):
        raise ValueError("Tempo receives traces only; disable OTLP metrics and logs")
    # Explicit ECS entrypoints would override the instrumentation in the image.
    if container.get("entryPoint"):
        raise ValueError("Review the custom container entrypoint before instrumenting")
    if service == "market-http" and container.get("command") != ["market-http"]:
        raise ValueError("Review the custom Python entrypoint/command before instrumenting")
    env.update(environment)
    if service != "market-http":
        if "-javaagent:" in env.get("JAVA_TOOL_OPTIONS", ""):
            raise ValueError("An existing Java agent requires manual review")
    container["image"] = image
    container["environment"] = [{"name": key, "value": value} for key, value in sorted(env.items())]
    return task


def write_json(path, value):
    path.write_text(json.dumps(value, indent=2) + "\n")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--plan", type=Path, required=True, help="Saved ECS plan containing the new OTLP outputs")
    parser.add_argument("--directory", type=Path, required=True)
    parser.add_argument("--profile", default="stockspoon")
    parser.add_argument("--region", default="ap-northeast-2")
    parser.add_argument("--cluster", default="stockspoon-v2-prod-cluster")
    parser.add_argument("--prefix", default="stockspoon-v2-prod")
    args = parser.parse_args()
    destination = args.directory.resolve()
    # Never overwrite an earlier rollback snapshot or deployment input.
    if destination.exists():
        raise ValueError("Choose a new preparation directory")
    plan = json.loads(subprocess.check_output(
        ["terraform", f"-chdir={ROOT / 'ecs'}", "show", "-json", str(args.plan.resolve())], text=True,
    ))
    environments = plan["planned_values"]["outputs"]["telemetry_application_environments"]["value"]
    names = [args.prefix + "-" + service for service in SERVICES]
    response = aws_json(args.profile, args.region, "ecs", "describe-services", "--cluster", args.cluster, "--services", *names)
    if response.get("failures") or len(response["services"]) != len(names):
        raise ValueError("Some application services could not be read")
    services = {item["serviceName"]: item for item in response["services"]}
    prepared = {}
    for service, container_name in SERVICES.items():
        live = services[args.prefix + "-" + service]
        if (live["runningCount"] < 1 or live["runningCount"] != live["desiredCount"] or live["pendingCount"]
                or len(live["deployments"]) != 1 or live["deployments"][0].get("rolloutState") != "COMPLETED"):
            raise ValueError(f"{service} is not stable; wait before preparing a deployment")
        snapshot = aws_json(args.profile, args.region, "ecs", "describe-task-definition", "--task-definition", live["taskDefinition"], "--include", "TAGS")
        tasks = aws_json(args.profile, args.region, "ecs", "list-tasks", "--cluster", args.cluster, "--service-name", live["serviceName"], "--desired-status", "RUNNING")["taskArns"]
        if not tasks:
            raise ValueError(f"No running tasks for {service}")
        details = aws_json(args.profile, args.region, "ecs", "describe-tasks", "--cluster", args.cluster, "--tasks", *tasks)
        if details.get("failures") or len(details["tasks"]) != live["runningCount"] or any(
            task["taskDefinitionArn"] != live["taskDefinition"] for task in details["tasks"]
        ):
            raise ValueError(f"{service} changed while reading its running tasks; retry")
        container = next(item for item in snapshot["taskDefinition"]["containerDefinitions"] if item["name"] == container_name)
        source = running_image(container["image"], [
            item.get("imageDigest", "") for task in details["tasks"]
            for item in task["containers"] if item["name"] == container_name
        ])
        recipe = "python" if service == "market-http" else "java"
        files = [ROOT / "monitoring/instrumentation" / (recipe + ".Dockerfile")]
        if recipe == "python":
            files.append(ROOT / "monitoring/instrumentation/python-requirements.txt")
        fingerprint = hashlib.sha256(source.encode() + b"".join(path.read_bytes() for path in files)).hexdigest()[:16]
        image = source.split("@")[0] + ":tempo-" + fingerprint
        environment = {item["name"]: item["value"] for item in environments[service]}
        prepared[service] = {
            "service": live["serviceName"], "previous_task_definition": live["taskDefinition"],
            "source_image": source, "image": image, "recipe": recipe,
            "task": instrumented_task(snapshot, service, environment, image), "original": snapshot,
        }
    destination.mkdir(parents=True, mode=0o700)
    command = lambda parts: shlex.join(str(part) for part in parts)
    aws = ["aws", "--profile", args.profile, "--region", args.region]
    build = ["#!/bin/bash", "set -euo pipefail", "cd " + shlex.quote(str(destination)),
             command(["aws", "--profile", args.profile, "--region", "us-east-1", "ecr-public", "get-login-password"]) + " | docker login --username AWS --password-stdin public.ecr.aws"]
    deploy = ["#!/bin/bash", "set -euo pipefail", "cd " + shlex.quote(str(destination))]
    rollback = deploy.copy()
    # Verify both CD-managed services before making the first change.
    for service in ["market-http", "backend"]:
        item = prepared[service]
        check = command(aws + ["ecs", "describe-services", "--cluster", args.cluster, "--services", item["service"], "--query", "services[0].taskDefinition", "--output", "text"])
        deploy.append(f'[[ "$({check})" == {shlex.quote(item["previous_task_definition"])} ]] || {{ echo "{service} changed; prepare again" >&2; exit 1; }}')
    for service, item in prepared.items():
        write_json(destination / (service + ".task.json"), item["task"])
        write_json(destination / (service + ".original.json"), item["original"])
        build.append(command(["docker", "buildx", "build", "--platform", "linux/amd64", "--provenance=false", "--build-arg", "APPLICATION_IMAGE=" + item["source_image"], "--file", ROOT / "monitoring/instrumentation" / (item["recipe"] + ".Dockerfile"), "--tag", item["image"], "--push", ROOT / "monitoring/instrumentation"]))
    for service in ["market-http", "backend"]:
        item = prepared[service]
        register = command(aws + ["ecs", "register-task-definition", "--cli-input-json", "file://" + str(destination / (service + ".task.json")), "--query", "taskDefinition.taskDefinitionArn", "--output", "text"])
        deploy.extend([
            f'tracing_revision=$({register})',
            command(aws + ["ecs", "update-service", "--cluster", args.cluster, "--service", item["service"], "--task-definition"]) + ' "$tracing_revision" --query service.taskDefinition --output text',
            command(aws + ["ecs", "wait", "services-stable", "--cluster", args.cluster, "--services", item["service"]]),
            "[[ \"$(" + command(aws + ["ecs", "describe-services", "--cluster", args.cluster, "--services", item["service"], "--query", "services[0].taskDefinition", "--output", "text"]) + ')" == "$tracing_revision" ]] || { echo "Deployment rolled back" >&2; exit 1; }',
        ])
        rollback.append(command(aws + ["ecs", "update-service", "--cluster", args.cluster, "--service", item["service"], "--task-definition", item["previous_task_definition"], "--query", "service.taskDefinition", "--output", "text"]))
    for filename, lines in [("build-images.sh", build), ("deploy-apps.sh", deploy), ("rollback-apps.sh", rollback)]:
        path = destination / filename
        path.write_text("\n".join(lines) + "\n")
        path.chmod(0o700)
        subprocess.run(["bash", "-n", str(path)], check=True)
    write_json(destination / "collector-image.tfvars.json", {"backend_collector_instrumented_image": prepared["backend-collector"]["image"]})
    write_json(destination / "manifest.json", {service: {key: value for key, value in item.items() if key not in {"task", "original"}} for service, item in prepared.items()})
    print(f"Prepared {len(prepared)} images and deployment inputs in {destination}. Nothing built, pushed or deployed.")


if __name__ == "__main__":
    main()
