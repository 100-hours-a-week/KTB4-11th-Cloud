#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
COMPOSE_FILE="$ROOT_DIR/docker-compose.yaml"
ENV_FILE="$ROOT_DIR/.env"
LOCK_FILE="/tmp/stockspoon-v1-deploy.lock"

compose() {
  docker compose \
    --project-directory "$ROOT_DIR" \
    --env-file "$ENV_FILE" \
    -f "$COMPOSE_FILE" \
    "$@"
}

require_runtime_files() {
  test -f "$COMPOSE_FILE" || {
    echo "Missing $COMPOSE_FILE" >&2
    exit 1
  }
  test -f "$ENV_FILE" || {
    echo "Missing $ENV_FILE. Create it from .env.example and set production values." >&2
    exit 1
  }
}

replace_env_value() {
  local key=$1
  local value=$2
  local temporary
  temporary=$(mktemp "${ENV_FILE}.XXXXXX")

  awk -v key="$key" -v value="$value" '
    BEGIN { found = 0 }
    $0 ~ "^" key "=" {
      print key "=" value
      found = 1
      next
    }
    { print }
    END {
      if (!found) {
        print key "=" value
      }
    }
  ' "$ENV_FILE" > "$temporary"

  chmod 600 "$temporary"
  mv "$temporary" "$ENV_FILE"
}

read_env_value() {
  local key=$1
  sed -n "s/^${key}=//p" "$ENV_FILE" | tail -n 1
}

wait_for_service() {
  local service=$1
  local attempts=${2:-60}
  local container_id status

  container_id=$(compose ps -q "$service")
  if [ -z "$container_id" ]; then
    echo "Container for $service was not created." >&2
    return 1
  fi

  for ((attempt = 1; attempt <= attempts; attempt++)); do
    status=$(docker inspect \
      --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' \
      "$container_id")

    case "$status" in
      healthy|running)
        echo "$service is $status."
        return 0
        ;;
      unhealthy|exited|dead)
        echo "$service became $status." >&2
        compose logs --tail=100 "$service" >&2 || true
        return 1
        ;;
    esac

    sleep 5
  done

  echo "Timed out waiting for $service health check." >&2
  compose logs --tail=100 "$service" >&2 || true
  return 1
}

wait_for_stack() {
  local service

  for service in db redis backend frontend nginx; do
    wait_for_service "$service"
  done
}

deploy_image() {
  local service=${1:-}
  local new_tag=${2:-}
  local tag_key old_tag

  case "$service" in
    frontend) tag_key="FE_TAG" ;;
    backend) tag_key="BE_TAG" ;;
    *) echo "Usage: $0 image {frontend|backend} <commit-sha-tag>" >&2; exit 1 ;;
  esac

  if ! [[ "$new_tag" =~ ^[0-9a-f]{7,64}$ ]]; then
    echo "Image tag must be a 7-64 character lowercase commit SHA." >&2
    exit 1
  fi

  old_tag=$(read_env_value "$tag_key")
  if [ -z "$old_tag" ]; then
    echo "$tag_key is missing from $ENV_FILE." >&2
    exit 1
  fi

  if [ "$old_tag" = "$new_tag" ]; then
    echo "$service is already using $new_tag; reconciling the full Compose stack anyway."
  fi

  env "$tag_key=$new_tag" docker compose \
    --project-directory "$ROOT_DIR" \
    --env-file "$ENV_FILE" \
    -f "$COMPOSE_FILE" config --quiet
  env "$tag_key=$new_tag" docker compose \
    --project-directory "$ROOT_DIR" \
    --env-file "$ENV_FILE" \
    -f "$COMPOSE_FILE" pull "$service"

  replace_env_value "$tag_key" "$new_tag"

  # Reconcile the complete Compose application so resource limits and any
  # other docker-compose.yaml changes are applied on every image deployment.
  if compose up -d --remove-orphans && wait_for_stack; then
    echo "$service image deployment completed through the full Compose stack: $old_tag -> $new_tag"
    return 0
  fi

  echo "$service deployment failed; rolling back to $old_tag." >&2
  replace_env_value "$tag_key" "$old_tag"
  compose pull "$service" || true
  compose up -d --remove-orphans || true
  wait_for_stack || true
  return 1
}

deploy_stack() {
  compose config --quiet
  compose pull
  compose up -d --remove-orphans

  wait_for_stack

  compose ps
  echo "Stack deployment completed."
}

main() {
  require_runtime_files

  exec 9>"$LOCK_FILE"
  if ! flock -n 9; then
    echo "Another deployment is already running." >&2
    exit 1
  fi

  case "${1:-}" in
    image) deploy_image "${2:-}" "${3:-}" ;;
    stack) deploy_stack ;;
    *)
      echo "Usage: $0 image {frontend|backend} <commit-sha-tag>" >&2
      echo "       $0 stack" >&2
      exit 1
      ;;
  esac
}

main "$@"
