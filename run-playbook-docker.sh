#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")"

if [[ $# -eq 0 ]]; then
  echo "Usage: ./run-playbook-docker.sh [ansible-playbook args]"
  echo "Example: ./run-playbook-docker.sh -i inventory/hosts.yml -u ubuntu --become --ask-vault-pass site.yml"
  exit 1
fi

docker compose -f docker-compose.runner.yml run --rm ansible "$@"
