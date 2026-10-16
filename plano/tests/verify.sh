#!/bin/bash
set -Eeuo pipefail
chart=$(cd -- "$(dirname -- "$0")/.." && pwd)
for script in "$chart"/scripts/*.sh; do bash -n "$script"; done
python3 "$chart/tests/test_safety.py"
bash "$chart/tests/test_health_cases.sh"
helm lint "$chart" --namespace suc-os-system -f "$chart/values-mpba.yaml" --set enabled=true
