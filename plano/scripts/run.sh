#!/bin/bash
set -Eeuo pipefail
SCRIPT_DIR=$(cd -- "$(dirname -- "$0")" && pwd)
source "$SCRIPT_DIR/common.sh"
source "$SCRIPT_DIR/health.sh"
TMP=$(mktemp -d)
# Mantido no pod para diagnostico; nao contem credenciais.
for t in bash jq kubectl chroot; do command -v "$t" >/dev/null || fail "Ferramenta $t ausente na imagem."; done
claim_gate
log "Inicio action=$ACTION profile=$PROFILE hash=$HASH"
host /bin/bash -s -- "$PROFILE" < "$SCRIPT_DIR/host-preflight.sh" || fail 'SO/ferramentas/espaco/systemd nao atendem ao perfil; revisar preflight.'
k version -o json | jq -e '(.clientVersion.minor | capture("(?<n>[0-9]+)").n|tonumber) as $c | (.serverVersion.minor|capture("(?<n>[0-9]+)").n|tonumber) as $s | .clientVersion.major==.serverVersion.major and (($c-$s)|fabs)<=1' >/dev/null || fail 'Imagem kubectl fora da politica de version skew.'

if [[ $ACTION == prepare-host ]]; then
  [[ $MANAGE_AUTOMATIC == true ]] || fail 'Ative manageAutomaticUpdates para transferir os agendamentos ao SUC, apos revisao.'
  host /bin/bash -s <<'HOST'
set -Eeuo pipefail
mkdir -p /var/lib/suc-os
systemctl show transactional-update.timer transactional-update.service rebootmgr.service -p Id -p ActiveState -p UnitFileState > /var/lib/suc-os/automatic-units-before.txt
# Nao interromper transacao em andamento. Primeiro impedir a proxima ativacao.
if [[ $(systemctl show transactional-update.timer -p LoadState --value) != not-found ]]; then systemctl disable --now transactional-update.timer; fi
state=$(systemctl show transactional-update.service -p ActiveState --value)
[[ $state == inactive || $state == failed ]]
if [[ $(systemctl show rebootmgr.service -p LoadState --value) != not-found ]]; then systemctl disable --now rebootmgr.service; fi
[[ ! -f /run/systemd/shutdown/scheduled ]]
HOST
  k annotate node "$NODE" suc-os.cattle.io/automatic-updates=disabled --overwrite
  release_gate
  log 'Preparacao concluida. Timers desativados; nenhum update ou reboot executado.'
  exit 0
fi
[[ $ACTION == update ]] || fail "Acao desconhecida: $ACTION"
k get nodes -o json | jq -e --arg expected "$EXPECTED_NODES" '.items as $nodes | all(($expected|split(","))[]; . as $n | any($nodes[]; .metadata.name==$n and .metadata.annotations["suc-os.cattle.io/automatic-updates"]=="disabled"))' >/dev/null || fail 'Execute prepare-host em TODOS os destinos antes da atualizacao.'

if [[ ! -f $LOCAL_STATE/phase ]]; then
  wait_health false
  # Bloquear outros Jobs do SUC, inclusive planos gerenciados pelo Rancher.
  k get jobs -A -o json | jq -e --arg p "$PLAN" 'all(.items[] | select(.metadata.labels["upgrade.cattle.io/controller"]!=null); .metadata.labels["upgrade.cattle.io/plan"]==$p or ((.status.active // 0)==0))' >/dev/null || fail 'Ha outro Job do SUC ativo; concluir a outra manutencao primeiro.'
  if [[ $LH_ACTIVE == true ]]; then
  k -n "$LH_NAMESPACE" get settings.longhorn.io node-drain-policy disable-scheduling-on-cordoned-node -o json > "$TMP/settings.json"
  jq -e '([.items[]|select(.metadata.name=="node-drain-policy")|.value][0] == "block-if-contains-last-replica") and ([.items[]|select(.metadata.name=="disable-scheduling-on-cordoned-node")|.value][0]=="true")' "$TMP/settings.json" >/dev/null || fail 'Exige node-drain-policy=block-if-contains-last-replica e disable-scheduling-on-cordoned-node=true.'
  # Exigir redundancia real: nenhuma replica unica pode ser desligada.
  k -n "$LH_NAMESPACE" get replicas.longhorn.io -o json > "$TMP/replicas.json"
  jq -e --slurpfile replicas "$TMP/replicas.json" --arg node "$NODE" '
    all(.items[]; .metadata.name as $v |
      [$replicas[0].items[] | select(.spec.volumeName==$v and (.spec.failedAt // "")=="" and .spec.nodeID!="" and (.spec.healthyAt // "")!="") | .spec.nodeID] | unique |
      (index($node)==null or length>=2))' "$TMP/volumes.json" >/dev/null || fail 'Ultima replica Longhorn neste no; aumentar replicas/reconstruir antes do drain.'
  else
    log 'Longhorn ausente ou sem volumes: sem verificacoes de replicas; protecoes de storage local/PDB permanecem ativas.'
  fi
  mkdir -p "$LOCAL_STATE"
  chmod 700 "$LOCAL_STATE"
  k cordon "$NODE"
  touch "$LOCAL_STATE/cordoned-by-plan"
  gate_phase draining
  k get pods -A --field-selector "spec.nodeName=$NODE" -o json > "$TMP/pods.json"
  k get pvc -A -o json > "$TMP/pvcs.json"
  k get pv -o json > "$TMP/pvs.json"
  jq -r --slurpfile pvcs "$TMP/pvcs.json" --slurpfile pvs "$TMP/pvs.json" --slurpfile policy "$SCRIPT_DIR/policy.json" -f "$SCRIPT_DIR/storage-guard.jq" "$TMP/pods.json" > "$TMP/blockers.txt"
  if [[ -s $TMP/blockers.txt ]]; then cat "$TMP/blockers.txt"; fail 'Storage guard bloqueou. Nenhum pacote foi atualizado; no mantido cordoned.'; fi
  drain_args=(drain "$NODE" --ignore-daemonsets --timeout="$DRAIN_TIMEOUT" --grace-period=-1 --pod-selector='!upgrade.cattle.io/controller')
  if jq -e '.allowEmptyDirDeletion==true' "$SCRIPT_DIR/policy.json" >/dev/null; then
    log 'AVISO: descarte de emptyDir explicitamente autorizado neste perfil.'
    drain_args+=(--delete-emptydir-data)
  fi
  # Nunca usar --force, --disable-eviction ou ignorar pods Terminating.
  k "${drain_args[@]}" || fail 'Drain falhou: inspecionar PDBs, pods Terminating, volumes anexados e ultima replica; nao remover finalizers/PDBs.'
  gate_phase updating
  cp "$SCRIPT_DIR/host-worker.sh" "$LOCAL_STATE/host-worker.sh"
  chmod 700 "$LOCAL_STATE/host-worker.sh"
  # O systemd do host mantem a transacao viva se o container morrer/reiniciar.
  host systemd-run --unit="suc-os-$HASH.service" --property=Type=oneshot --property="TimeoutStartSec=$HOST_TIMEOUT" \
    /bin/bash "$STATE/host-worker.sh" "$STATE" "$PROFILE" "$ACTIVATE_PENDING"
fi

deadline=$((SECONDS+HOST_TIMEOUT+600))
while (( SECONDS < deadline )); do
  phase=$(cat "$LOCAL_STATE/phase" 2>/dev/null || printf starting)
  case "$phase" in
    failed) host journalctl -u "suc-os-$HASH.service" -n 60 --no-pager || true; fail 'Servico do host falhou. Consulte tambem /var/log/transactional-update.log ou /var/log/zypp/history.' ;;
    done|reboot-pending)
      old_boot=$(cat "$LOCAL_STATE/old-boot")
      boot=$(cat /proc/sys/kernel/random/boot_id)
      if [[ $phase == reboot-pending && $boot == "$old_boot" ]]; then log 'Aguardando reboot real; sucesso ainda nao autorizado.'
      else
        if [[ $PROFILE == micro62 ]]; then
          target=$(cat "$LOCAL_STATE/target-root")
          current=$(host btrfs inspect-internal rootid /)
          [[ $current == "$target" ]] || fail "Snapshot ativo $current difere de $target; possivel rollback."
        fi
        host /bin/bash -s -- "$PROFILE" < "$SCRIPT_DIR/host-preflight.sh" || fail 'Verificacao do host apos update falhou.'
        host /bin/bash -c 'if systemctl is-enabled rke2-server.service >/dev/null 2>&1; then systemctl is-active --quiet rke2-server; else systemctl is-active --quiet rke2-agent; fi' || fail 'Servico RKE2 nao recuperou; examinar journalctl -u rke2-server/-agent.'
        gate_phase verifying
        k uncordon "$NODE"
        # Longhorn pode precisar do uncordon para reconstruir replicas neste no.
        wait_health false
        result=$(cat "$LOCAL_STATE/result")
        k annotate node "$NODE" "suc-os.cattle.io/last-result=$result" "suc-os.cattle.io/last-round=$SYSTEM_UPGRADE_PLAN_LATEST_VERSION" --overwrite
        printf 'done\n' > "$LOCAL_STATE/phase"
        host journalctl -u "suc-os-$HASH.service" -n 80 --no-pager || true
        release_gate
        log "SUCESSO resultado=$result boot=$boot. Proximo no liberado."
        exit 0
      fi ;;
    starting|running)
      active=$(host systemctl show "suc-os-$HASH.service" -p ActiveState --value)
      now=$(cat "$LOCAL_STATE/phase" 2>/dev/null || true)
      [[ $active == active || $active == activating || $now == done || $now == reboot-pending ]] || fail "Unidade do host esta $active sem conclusao; investigar journal."
      ;;
    *) fail "Fase inesperada $phase" ;;
  esac
  sleep 10
done
fail 'Timeout aguardando update/reboot; manter trava, investigar host e snapshot.'
