#!/bin/bash
set -Eeuo pipefail
source "$(dirname "$0")/../scripts/health.sh"
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
NODE=node1 EXPECTED_NODES=node1 LH_NAMESPACE=longhorn-system
renew=$(date -u +%FT%TZ)
k() {
  case "$*" in
    'get --raw /readyz') echo ok ;;
    'get nodes -o json') echo '{"items":[{"metadata":{"name":"node1"},"spec":{},"status":{"conditions":[{"type":"Ready","status":"True"}]}}]}' ;;
    '-n kube-node-lease get leases -o json') jq -nc --arg time "$renew" '{items:[{metadata:{name:"node1"},spec:{renewTime:$time}}]}' ;;
    'get --raw /apis') echo '{"groups":[]}' ;;
    'get deployment,statefulset,daemonset -A -o json') echo '{"items":[]}' ;;
    *) echo "Consulta inesperada: $*" >&2; return 1 ;;
  esac
}
health_once false || { echo 'Lease recente deveria permitir saude' >&2; exit 1; }
renew=2020-01-01T00:00:00Z
if health_once false; then echo 'Lease obsoleto deveria bloquear' >&2; exit 1; fi
renew=$(date -u +%FT%TZ); EXPECTED_NODES=node1,node2
if health_once false; then echo 'No ausente deveria bloquear' >&2; exit 1; fi
echo 'PASS: saude completa com lease recente, obsoleto e no ausente'

# O RKE2 pode estar activating quando o Pod ja retomou apos reboot.
calls=0
host() { calls=$((calls+1)); (( calls >= 3 )); }
sleep() { SECONDS=$((SECONDS+10)); }
log() { :; }
fail() { echo "$*" >&2; exit 1; }
wait_rke2
[[ $calls == 3 ]]
host() { return 1; }
sleep() { SECONDS=$((SECONDS+601)); }
if (wait_rke2) 2>/dev/null; then echo 'RKE2 permanentemente inativo deveria bloquear' >&2; exit 1; fi
echo 'PASS: RKE2 activating recupera; RKE2 inativo atinge timeout e bloqueia'
