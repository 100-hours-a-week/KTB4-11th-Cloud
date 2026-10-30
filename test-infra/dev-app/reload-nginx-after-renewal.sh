#!/usr/bin/env bash
set -Eeuo pipefail

docker exec stockspoon-v2-dev-nginx nginx -t
docker exec stockspoon-v2-dev-nginx nginx -s reload
