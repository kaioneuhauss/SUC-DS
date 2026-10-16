# Verifica cada volume dos pods ativos do no APOS cordon. Falha com recurso e causa.
def infra: (.metadata.annotations["kubernetes.io/config.mirror"] != null) or
  any(.metadata.ownerReferences[]?; .kind == "DaemonSet");
def approved_host($p; $v): any($policy[0].hostPathAllowlist[]?;
  .namespace == $p.metadata.namespace and .serviceAccount == $p.spec.serviceAccountName and
  (.ownerKind as $kind | any($p.metadata.ownerReferences[]?; .kind == $kind)) and
  (.paths | index($v.hostPath.path)) != null);
def remote($pv): ($pv.spec.local == null and $pv.spec.hostPath == null) and
  ($pv.spec.csi.driver == "driver.longhorn.io" or $pv.spec.nfs != null or
   (($pv.spec.csi.driver // "") as $d | $d != "" and ($policy[0].remoteCSIDrivers | index($d)) != null));
.items[] | select(.status.phase != "Succeeded" and .status.phase != "Failed") |
select(.metadata.labels["upgrade.cattle.io/controller"] == null) | . as $pod |
.spec.volumes[]? | . as $v |
"\($pod.metadata.namespace)/\($pod.metadata.name) volume=\(.name)" as $where |
if .persistentVolumeClaim then
  ([$pvcs[0].items[] | select(.metadata.namespace == $pod.metadata.namespace and .metadata.name == $v.persistentVolumeClaim.claimName)][0]) as $pvc |
  ([$pvs[0].items[] | select(.metadata.name == $pvc.spec.volumeName)][0]) as $pv |
  if $pvc == null or $pv == null then "\($where): PVC/PV nao resolvido; corrigir o binding antes de repetir"
  elif remote($pv) then empty
  else "\($where): PV \($pv.metadata.name) local/hostPath/backend nao revisado; migrar ou definir procedimento da aplicacao" end
elif .hostPath and (($pod | infra) | not) and (approved_host($pod; $v) | not) then
  "\($where): hostPath \(.hostPath.path) nao revisado; comprovar finalidade antes de incluir excecao"
elif .emptyDir != null and (($pod | infra) | not) and ($policy[0].allowEmptyDirDeletion != true) then
  "\($where): emptyDir perderia dados; migrar para PVC ou autorizar explicitamente o descarte"
elif .ephemeral or .csi then "\($where): CSI inline/efemero exige revisao"
else empty end
