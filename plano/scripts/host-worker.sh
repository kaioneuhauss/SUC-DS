#!/bin/bash
# Executado como unidade do systemd do host, fora do cgroup do Pod.
set -Eeuo pipefail
export LC_ALL=C
STATE=${1:?}
PROFILE=${2:?}
ACTIVATE_PENDING=${3:-false}
[[ $STATE =~ ^/var/lib/suc-os/[a-zA-Z0-9_-]+$ ]]
write_state() { printf '%s\n' "$2" > "$STATE/$1.tmp"; mv "$STATE/$1.tmp" "$STATE/$1"; }
on_exit() {
  local rc=$?
  if (( rc != 0 )) && [[ $(cat "$STATE/phase" 2>/dev/null || true) != reboot-pending ]]; then
    write_state error "exit=$rc linha=${BASH_LINENO[0]}; consultar journalctl -u suc-os-${STATE##*/}.service"
    write_state phase failed
    echo 'ERRO: transacao interrompida. Corrigir causa antes de remover trava; nenhum reboot autorizado por este erro.' >&2
  fi
}
trap on_exit EXIT
trap 'exit 143' TERM
exec 9>/var/lib/suc-os/host-update.lock
flock -n 9
write_state old-boot "$(cat /proc/sys/kernel/random/boot_id)"
write_state phase running
for unit in transactional-update.timer transactional-update.service rebootmgr.service; do
  state=$(systemctl show "$unit" -p ActiveState --value)
  [[ $state == inactive || $state == failed ]]
done
[[ ! -f /run/systemd/shutdown/scheduled ]]
# Snapshot etcd antes da manutencao do SO em cada servidor.
if systemctl is-active --quiet rke2-server; then
  command -v rke2 >/dev/null
  rke2 etcd-snapshot save --name "pre-os-${STATE##*/}"
fi
reboot_required=false
if [[ $PROFILE == micro62 ]]; then
  before=$(btrfs inspect-internal rootid /)
  target=$(btrfs subvolume get-default /); target=${target#ID }; target=${target%% *}
  [[ $before =~ ^[0-9]+$ && $target =~ ^[0-9]+$ ]]
  write_state old-root "$before"
  if [[ $target != "$before" ]]; then
    [[ $ACTIVATE_PENDING == true ]]
    echo "Snapshot pendente $target detectado; ativando depois do drain. Nova transacao fica para a proxima rodada."
    write_state result pending-snapshot-activated
    reboot_required=true
  else
    transactional-update --non-interactive --drop-if-no-change up
    target=$(btrfs subvolume get-default /); target=${target#ID }; target=${target%% *}
    [[ $target =~ ^[0-9]+$ ]]
    if [[ $target == "$before" ]]; then
      echo 'SEM ATUALIZACOES: nenhum snapshot novo; o SO NAO sera reiniciado. O fluxo seguira para o proximo no apos verificar a saude.'
      write_state result no-change-no-reboot
    else
      write_state result updated-and-rebooted
      reboot_required=true
    fi
  fi
  write_state target-root "$target"
else
  # Exemplo SLES tradicional. Nunca executar em raiz transacional/read-only.
  . /etc/os-release
  [[ ${ID:-} == sles && ${VARIANT_ID:-} != transactional ]]
  rpm -qa --qf '%{NAME} %{EPOCHNUM}:%{VERSION}-%{RELEASE} %{ARCH}\n' | sort > "$STATE/rpm-before"
  zypper --non-interactive refresh
  # 102/103 sao codigos informativos documentados; 103 pede repetir o patch.
  patch_rc=103
  for attempt in 1 2 3; do
    patch_rc=0
    zypper --non-interactive patch --with-update || patch_rc=$?
    case "$patch_rc" in 0|102) break ;; 103) echo 'Gerenciador atualizado; repetindo patch.' ;; *) exit "$patch_rc" ;; esac
  done
  [[ $patch_rc != 103 ]]
  rpm -qa --qf '%{NAME} %{EPOCHNUM}:%{VERSION}-%{RELEASE} %{ARCH}\n' | sort > "$STATE/rpm-after"
  if cmp -s "$STATE/rpm-before" "$STATE/rpm-after"; then
    [[ ! -f /run/reboot-needed && $patch_rc != 102 ]] || { echo 'Ha reboot anterior pendente; requer avaliacao.' >&2; exit 1; }
    write_state result no-change-no-reboot
    echo 'SEM ATUALIZACOES: inventario RPM inalterado; SO NAO sera reiniciado.'
  else
    # Reinicio conservador apos alteracoes, para carregar todos os binarios novos.
    write_state result updated-and-rebooted
    reboot_required=true
  fi
fi
if [[ $reboot_required == false ]]; then write_state phase done; exit 0; fi
write_state phase reboot-pending
sync
echo 'Update preparado. Solicitando reboot completo; Job verificara boot ID e saude.'
systemctl reboot || { write_state phase failed; exit 1; }
# Durante shutdown o systemd encerra esta unidade. Nao transformar isso em falha.
trap - TERM
sleep 300
write_state error 'Reboot nao concluiu em 300 segundos; diagnosticar systemd.'
write_state phase failed
exit 1
