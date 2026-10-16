#!/bin/bash
set -Eeuo pipefail
export LC_ALL=C
# RKE2 em raiz imutavel instala os binarios em /opt/rke2/bin.
export PATH="$PATH:/opt/rke2/bin"
profile=${1:?}
. /etc/os-release
if [[ $profile == micro62 ]]; then
  # Micro 6.2 pode anunciar SLES 16.0 nos campos de compatibilidade.
  [[ ${VARIANT_ID:-} == transactional && ${SUSE_SUPPORT_PRODUCT:-} == 'SUSE Linux Micro' && ${SUSE_SUPPORT_PRODUCT_VERSION:-} == 6.2 ]] ||
    [[ ( ${ID:-} == sl-micro || ${ID:-} == sle-micro ) && ${VERSION_ID:-} == 6.2 ]]
  for t in transactional-update btrfs; do command -v "$t"; done
else
  [[ ${ID:-} == sles && ${VARIANT_ID:-} != transactional ]]
  [[ $(findmnt -no OPTIONS /) == *rw* ]]
  for t in zypper rpm; do command -v "$t"; done
fi
for t in systemd-run systemctl flock findmnt; do command -v "$t"; done
systemctl show --property=Version --value
# Disco: nao iniciar atualizacao com menos de 2 GiB livres no root/var.
for p in / /var; do
  available=$(df -Pk "$p" | awk 'NR==2 {print $4}')
  (( available >= 2097152 ))
done

if systemctl is-active --quiet rke2-server; then
  command -v rke2 >/dev/null || { echo "ERRO: rke2 ausente em PATH; conferir /opt/rke2/bin ou instalacao do servidor antes do drain." >&2; exit 1; }
fi
