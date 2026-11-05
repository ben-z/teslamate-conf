#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
docker compose --env-file .env.example config --quiet
bash -n deploy/*.sh deploy/bootstrap/bootstrap.sh scripts/*.sh
python3 -m unittest discover -s tests -v
git diff --check
