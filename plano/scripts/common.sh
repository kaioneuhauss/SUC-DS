#!/bin/bash
set -Eeuo pipefail
export LC_ALL=C
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
NODE=${SYSTEM_UPGRADE_NODE_NAME:?}
HASH=${SYSTEM_UPGRADE_PLAN_LATEST_HASH:?}
PLAN=${SYSTEM_UPGRADE_PLAN_NAME:?}
NS=${PLAN_NAMESPACE:?}
[[ $HASH =~ ^[a-zA-Z0-9_-]+$ && $NODE =~ ^[a-zA-Z0-9.-]+$ ]]
STATE=/var/lib/suc-os/$HASH
LOCAL_STATE=/host$STATE
GATE=suc-os-maintenance-gate
OWNED=false
FORCE_FAILURE=false
k() { kubectl --request-timeout=30s "$@"; }
host() { chroot /host "$@"; }
log() { printf '%s node=%s round=%s %s\n' "$(date -u +%FT%TZ)" "$NODE" "$SYSTEM_UPGRADE_PLAN_LATEST_VERSION" "$*"; }
gate_phase() {
  k -n "$NS" patch cm "$GATE" --type=merge -p "$(jq -nc --arg phase "$1" '{data:{phase:$phase}}')" >/dev/null
}
fail() {
  FORCE_FAILURE=true
  log "ERRO: $*"
  log "REMEDIACAO: consulte logs do Job, ConfigMap $NS/$GATE e journalctl -u suc-os-$HASH.service no host. Corrija a causa antes de liberar a trava; nao force drain/uncordon."
  exit 1
}
on_exit() {
  local rc=$?
  if (( rc != 0 )); then
    if [[ $FORCE_FAILURE != true && -f $LOCAL_STATE/phase && $(cat "$LOCAL_STATE/phase") == reboot-pending ]]; then
      log "Container encerrado durante reboot esperado (exit=$rc); trava preservada para retomada."
      return
    fi
    log "INTERROMPIDO exit=$rc linha=${BASH_LINENO[0]} comando=${BASH_COMMAND}"
    if [[ $OWNED == true ]]; then
      gate_phase failed || true
      [[ ! -d $LOCAL_STATE ]] || printf 'Falha do Job; consultar logs e unidade suc-os-%s.service\n' "$HASH" > "$LOCAL_STATE/job-error"
    fi
    log "REMEDIACAO: preservar a trava $NS/$GATE; diagnosticar antes de nova rodada."
  fi
}
trap on_exit EXIT
claim_gate() {
  if k -n "$NS" create cm "$GATE" --from-literal="node=$NODE" --from-literal="hash=$HASH" --from-literal=phase=preflight >/dev/null 2>&1; then
    OWNED=true
    return
  fi
  local current
  current=$(k -n "$NS" get cm "$GATE" -o json) || fail 'Nao foi possivel obter a trava; verificar API/RBAC.'
  jq -e --arg n "$NODE" --arg h "$HASH" '.data.node == $n and .data.hash == $h and (.data.phase == "updating" or .data.phase == "verifying")' <<<"$current" >/dev/null ||
    fail "Trava existente: $(jq -c .data <<<"$current"). Uma falha ou outra manutencao exige diagnostico."
  OWNED=true
  [[ -f $LOCAL_STATE/phase ]] || fail 'Trava de retomada sem estado persistente do host.'
}
release_gate() {
  local current
  current=$(k -n "$NS" get cm "$GATE" -o json)
  jq -e --arg n "$NODE" --arg h "$HASH" '.data.node == $n and .data.hash == $h' <<<"$current" >/dev/null
  k -n "$NS" delete cm "$GATE" --wait=true >/dev/null
  OWNED=false
}
