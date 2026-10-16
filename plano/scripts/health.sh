#!/bin/bash
# Funcoes carregadas por run.sh; todas as falhas de consulta bloqueiam o avanco.
health_once() {
  local allow_cordon=${1:-false}
  k get --raw /readyz > "$TMP/readyz" || return 1
  [[ $(cat "$TMP/readyz") == ok ]] || return 1
  k get nodes -o json > "$TMP/nodes.json" || return 1
  jq -e --arg node "$NODE" --arg expected "$EXPECTED_NODES" --argjson allow "$allow_cordon" '
    ($expected | split(",")) as $names |
    ([$names[] as $n | any(.items[]; .metadata.name == $n)] | all) and
    all(.items[]; any(.status.conditions[]?; .type=="Ready" and .status=="True") and
      all(.status.conditions[]?; if (.type=="MemoryPressure" or .type=="DiskPressure" or .type=="PIDPressure") then .status=="False" else true end) and
      ((.metadata.name==$node and $allow) or .spec.unschedulable!=true))' "$TMP/nodes.json" >/dev/null || return 1
  k -n kube-node-lease get leases -o json > "$TMP/leases.json" || return 1
  jq -e --arg expected "$EXPECTED_NODES" --argjson now "$(date +%s)" '
    .items as $leases | all(($expected|split(","))[]; . as $n |
      any($leases[];
      (.spec.renewTime | sub("\\.[0-9]+Z$";"Z") | fromdateiso8601) as $t |
      (.metadata.name==$n and ($now-$t) < 120 and ($now-$t) > -120)))' "$TMP/leases.json" >/dev/null || return 1
  longhorn_health || return 1
  k get deployment,statefulset,daemonset -A -o json > "$TMP/workloads.json" || return 1
  jq -e 'all(.items[];
    (.status.observedGeneration // 0) >= .metadata.generation and
    if .kind=="DaemonSet" then (.status.numberReady // 0) >= (.status.desiredNumberScheduled // 0)
    else (.status.readyReplicas // 0) >= (.spec.replicas // 1) end)' "$TMP/workloads.json" >/dev/null || return 1
}
wait_health() {
  local allow_cordon=${1:-false} deadline=$((SECONDS+HEALTH_TIMEOUT)) since=0
  while (( SECONDS < deadline )); do
    if health_once "$allow_cordon"; then
      (( since != 0 )) || since=$SECONDS
      if (( SECONDS-since >= STABLE_SECONDS )); then log 'API, leases, nos, workloads e Longhorn estaveis.'; return 0; fi
    else
      since=0
      log 'Aguardando recuperacao: nos/leases, API, workloads e replicas Longhorn RW.'
      [[ ! -s $TMP/volumes.json ]] || jq -r '.items[] | [.metadata.name,.status.state,.status.robustness] | @tsv' "$TMP/volumes.json"
      [[ ! -s $TMP/workloads.json ]] || jq -r '.items[] | select((.status.readyReplicas // .status.numberReady // 0) < (.spec.replicas // .status.desiredNumberScheduled // 1)) | [.kind,.metadata.namespace,.metadata.name] | @tsv' "$TMP/workloads.json"
    fi
    sleep 10
  done
  fail 'Timeout de saude; corrigir nos, PDB/capacidade/workloads ou reconstrucoes Longhorn antes de continuar.'
}

longhorn_health() {
  LH_ACTIVE=false
  # Discovery bem-sucedida sem o grupo = ausente. Erro de API/RBAC = bloqueio.
  k get --raw /apis > "$TMP/apis.json" || return 1
  jq -e '.groups | type=="array"' "$TMP/apis.json" >/dev/null || return 1
  if ! jq -e 'any(.groups[]; .name=="longhorn.io")' "$TMP/apis.json" >/dev/null; then
    printf '{"items":[]}\n' > "$TMP/volumes.json"
    return 0
  fi
  k get volumes.longhorn.io -A -o json > "$TMP/volumes.json" || return 1
  if jq -e '.items|length==0' "$TMP/volumes.json" >/dev/null; then return 0; fi
  LH_ACTIVE=true
  jq -e --arg ns "$LH_NAMESPACE" 'all(.items[]; .metadata.namespace==$ns)' "$TMP/volumes.json" >/dev/null || return 1
  k -n "$LH_NAMESPACE" get nodes.longhorn.io -o json > "$TMP/lh-nodes.json" || return 1
  k -n "$LH_NAMESPACE" get engines.longhorn.io -o json > "$TMP/engines.json" || return 1
  jq -e 'all(.items[]; .metadata.deletionTimestamp==null and
    ((.status.state=="attached" and .status.robustness=="healthy") or
    (.status.state=="detached" and (.status.robustness=="healthy" or .status.robustness=="unknown"))))' "$TMP/volumes.json" >/dev/null || return 1
  jq -e '(.items|length)>0 and all(.items[]; any(.status.conditions[]?; .type=="Ready" and .status=="True"))' "$TMP/lh-nodes.json" >/dev/null || return 1
  jq -e 'all(.items[]; all((.status.replicaModeMap // {})[]; .=="RW"))' "$TMP/engines.json" >/dev/null || return 1
  return 0
}

# Kubelet pode aceitar Pods antes de a unidade Type=notify do RKE2 ficar active.
wait_rke2() {
  local deadline=$((SECONDS+600))
  until host /bin/bash -c 'if systemctl is-enabled rke2-server.service >/dev/null 2>&1; then systemctl is-active --quiet rke2-server; else systemctl is-active --quiet rke2-agent; fi'; do
    (( SECONDS < deadline )) || fail 'RKE2 nao ficou ativo em 600s; examinar journalctl -u rke2-server/-agent.'
    log 'Aguardando inicializacao do servico RKE2; fila permanece bloqueada.'
    sleep 10
  done
}
