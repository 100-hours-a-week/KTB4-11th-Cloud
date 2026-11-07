#!/usr/bin/env bash
set -euo pipefail

dnf install -y jq procps awscli

ACTIVATION_ID=""
SSM_AGENT_PID=""

cleanup() {
  trap - TERM INT

  if [[ -n "$ACTIVATION_ID" ]]; then
    echo "Deleting SSM activation $ACTIVATION_ID"
    aws ssm delete-activation \
      --activation-id "$ACTIVATION_ID" \
      --region "$ECS_TASK_REGION" || echo "Failed to delete SSM activation $ACTIVATION_ID" >&2
  fi

  if [[ -f /var/lib/amazon/ssm/registration ]]; then
    managed_instance_id="$(jq -e -r .ManagedInstanceID /var/lib/amazon/ssm/registration)"
    if [[ -n "$managed_instance_id" && "$managed_instance_id" != "null" ]]; then
      echo "Deregistering SSM managed instance $managed_instance_id"
      aws ssm deregister-managed-instance \
        --instance-id "$managed_instance_id" \
        --region "$ECS_TASK_REGION" || echo "Failed to deregister SSM managed instance $managed_instance_id" >&2
    fi
  fi

  if [[ -n "$SSM_AGENT_PID" ]]; then
    kill -TERM "$SSM_AGENT_PID" 2>/dev/null || true
    wait "$SSM_AGENT_PID" 2>/dev/null || true
  fi
}

if [[ -z "${MANAGED_INSTANCE_ROLE_NAME:-}" ]]; then
  echo "MANAGED_INSTANCE_ROLE_NAME is required" >&2
  exit 1
fi

if [[ -z "${ECS_CONTAINER_METADATA_URI_V4:-}" ]]; then
  echo "ECS task metadata endpoint is missing" >&2
  exit 1
fi

task_metadata="$(curl --fail --silent --show-error --max-time 5 "${ECS_CONTAINER_METADATA_URI_V4}/task")"
ECS_TASK_AVAILABILITY_ZONE="$(jq -e -r .AvailabilityZone <<<"$task_metadata")"
ECS_TASK_ARN="$(jq -e -r .TaskARN <<<"$task_metadata")"

if [[ ! "$ECS_TASK_AVAILABILITY_ZONE" =~ ^(af|ap|ca|cn|eu|me|sa|us|us-gov)-(central|north|(north(east|west))|south|south(east|west)|east|west)-[0-9][a-z]$ ]]; then
  echo "Could not determine AWS region from task Availability Zone" >&2
  exit 1
fi
ECS_TASK_REGION="${ECS_TASK_AVAILABILITY_ZONE%?}"

if [[ ! "$ECS_TASK_ARN" =~ ^arn:(aws|aws-cn|aws-us-gov):ecs:[a-z0-9-]+:[0-9]{12}:task/[a-zA-Z0-9_-]+/[a-zA-Z0-9]+$ ]]; then
  echo "Task ARN has an unexpected format" >&2
  exit 1
fi

CREATE_ACTIVATION_OUTPUT="$(aws ssm create-activation \
  --iam-role "$MANAGED_INSTANCE_ROLE_NAME" \
  --tags \
    "Key=ECS_TASK_AVAILABILITY_ZONE,Value=$ECS_TASK_AVAILABILITY_ZONE" \
    "Key=ECS_TASK_ARN,Value=$ECS_TASK_ARN" \
    "Key=FAULT_INJECTION_SIDECAR,Value=true" \
  --region "$ECS_TASK_REGION")"
ACTIVATION_CODE="$(jq -e -r .ActivationCode <<<"$CREATE_ACTIVATION_OUTPUT")"
ACTIVATION_ID="$(jq -e -r .ActivationId <<<"$CREATE_ACTIVATION_OUTPUT")"
trap cleanup TERM INT

if ! amazon-ssm-agent -register \
  -code "$ACTIVATION_CODE" \
  -id "$ACTIVATION_ID" \
  -region "$ECS_TASK_REGION"; then
  echo "Failed to register the task as an SSM managed instance" >&2
  cleanup
  exit 1
fi

amazon-ssm-agent &
SSM_AGENT_PID=$!
wait "$SSM_AGENT_PID"
