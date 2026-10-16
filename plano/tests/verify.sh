#!/bin/bash
set -Eeuo pipefail
root=$(cd -- "$(dirname -- "$0")/.." && pwd)
for script in "$root"/scripts/*.sh; do bash -n "$script"; done
python3 "$root/tests/test_safety.py"
bash "$root/tests/test_health_cases.sh"
bash "$root/tests/test_cluster_health.sh"
python3 "$root/render-secret.py" --check
