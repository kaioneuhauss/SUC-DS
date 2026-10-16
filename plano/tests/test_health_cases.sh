#!/bin/bash
# Exercita discovery sem Longhorn, instalacao sem volumes e API/RBAC indisponivel.
set -Eeuo pipefail
ROOT=$(cd -- "$(dirname -- "$0")/.." && pwd)
source "$ROOT/scripts/health.sh"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
LH_NAMESPACE=longhorn-system
CASE=absent
k() {
  case "$CASE:$*" in
    absent:'get --raw /apis') echo '{"groups":[]}' ;;
    empty:'get --raw /apis') echo '{"groups":[{"name":"longhorn.io"}]}' ;;
    empty:'get volumes.longhorn.io -A -o json') echo '{"items":[]}' ;;
    denied:*) return 1 ;;
    *) echo 'Unexpected test call' >&2; return 1 ;;
  esac
}
longhorn_health && [[ $LH_ACTIVE == false ]]
CASE=empty
longhorn_health && [[ $LH_ACTIVE == false ]]
CASE=denied
if longhorn_health; then echo 'Falha: API negada interpretada como saudavel' >&2; exit 1; fi
echo 'PASS: Longhorn ausente, sem volumes e API negada'
