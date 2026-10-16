# Procedimento: manutenção do SO com SUC e Helm

## 1. Escopo e pré-requisitos

O destino verificado é `mpba-teste`, Rancher `c-m-n4dl4ksn`, com cinco nós: `master-mbpa1` (esta é a grafia real), `master-mpba2`, `master-mpba3`, `worker-mpba1`, `worker-mpba2`. RKE2 `v1.35.6+rke2r1`, SUC `v0.19.1`, Longhorn `v1.11.2`.

Micro 6.2 pode apresentar `ID=sles` e `VERSION_ID=16.0`. A identificação do produto usa `VARIANT_ID=transactional`, `SUSE_SUPPORT_PRODUCT=SUSE Linux Micro` e `SUSE_SUPPORT_PRODUCT_VERSION=6.2`; não se deve escolher `zypper` direto pelo campo OS-IMAGE do Kubernetes.

Este procedimento faz atualização de pacotes dentro da versão instalada. Não executa `dup`, `migration`, atualização de RKE2 nem troca de repositórios. Verifique registro/subscrição e alcance aos repositórios SUSE. Tenha backup externo restaurável de aplicações e etcd; o snapshot local de etcd criado pelo script não substitui backup externo. Valide a matriz de suporte da sua combinação real de SO, RKE2 e CNI antes de transportar para produção.

Uma única pessoa/automação deve operar a manutenção. Não altere scripts, imagem, parâmetros ou rodada enquanto houver Job em execução: esses campos podem mudar o hash e substituir Jobs. A trava impede avanço silencioso, mas não cancela uma transação que já iniciou no host.

## 2. Conferir o destino e os arquivos

Na raiz do repositório:

```bash
export KUBECONFIG=/home/kaio/.kube/istio-mpba.yaml
kubectl config current-context
kubectl get nodes -o wide
kubectl -n cattle-system get deploy system-upgrade-controller
kubectl -n suc-os-system get deploy suc-os-controller
kubectl get plans.upgrade.cattle.io -A
helm lint ./plano -f ./plano/values-mpba.yaml
python3 ./plano/tests/test_safety.py
bash ./plano/tests/test_health_cases.sh
helm template suc-os-mpba ./plano -n suc-os-system -f ./plano/values-mpba.yaml --set enabled=true > /tmp/suc-os-rendered.yaml
kubectl apply --dry-run=server -f /tmp/suc-os-rendered.yaml
```

O perfil MPBA contém os cinco nomes explícitos, sem inclusão automática de novos nós. O RBAC dedicado evita `cluster-admin` para a conta do Job. Ainda assim, atualizar o SO exige Job privilegiado com montagem do host: essa é a arquitetura do SUC e deve ficar restrita a operadores de infraestrutura.

## 3. Preparar os hosts

No MPBA o controller gerenciado estava pausado. O perfil revisado inclui `controller.enabled: true` em namespace separado, `suc-os-system`. A implantação exige aprovação de Jobs privilegiados e do controller persistente. Criar e rotular o namespace é um pré-requisito:

```bash
kubectl apply -f examples/namespace.yaml
```

Se optar por reutilizar um controller existente ativo em outro ambiente, configure `controller.enabled=false` e instale o Plan no namespace observado por ele. Nunca habilite dois controllers distintos para observar o mesmo namespace.

```bash
helm upgrade --install suc-os-mpba ./plano -n suc-os-system \
  -f ./plano/values-mpba.yaml --set enabled=true \
  --set action=prepare-host --set-string round=mpba-prepare-20261016
```

A preparação valida SO, ferramentas, espaço e systemd; registra o estado anterior dos serviços em `/var/lib/suc-os/automatic-units-before.txt`; desativa o timer antes de verificar se há transação ativa; não interrompe uma transação em execução; desativa rebootmgr quando a transação estiver inativa; bloqueia se existir shutdown agendado. Não faz update nem reboot. Cada nó recebe a anotação `suc-os.cattle.io/automatic-updates=disabled` ao concluir.

Se houver transação ativa, a fila para. Aguarde seu término, confira snapshot pendente e a seção de recuperação antes de repetir. Os serviços permanecem desativados enquanto o SUC for responsável pelas atualizações. Não haverá atualização automática futura apenas por instalar este chart: uma nova rodada precisa ser disparada explicitamente.

`helm --wait` confirma a instalação dos recursos, mas não comprova a conclusão do Plan. Acompanhe a condição Complete e os resultados nos nós:

```bash
kubectl -n suc-os-system get plan os-maintenance -o yaml
kubectl -n suc-os-system get jobs -l upgrade.cattle.io/plan=os-maintenance
kubectl -n suc-os-system logs -l upgrade.cattle.io/plan=os-maintenance --all-containers --prefix --tail=100
kubectl get nodes -o custom-columns=NAME:.metadata.name,PREPARADO:.metadata.annotations.suc-os\\.cattle\\.io/automatic-updates
```

## 4. Executar a rodada

Somente após todos os hosts preparados:

```bash
helm upgrade suc-os-mpba ./plano -n suc-os-system \
  -f ./plano/values-mpba.yaml --set enabled=true \
  --set action=update --set-string round=mpba-update-01
```

A sequência por nó é: adquirir trava; verificar versão/ferramentas; confirmar preparação de todos; esperar saúde estável; conferir conflitos e redundância; cordon; inventariar volumes; executar drain com eviction e PDB; iniciar unidade do systemd do host; atualizar ou ativar snapshot pendente; verificar reboot e snapshot; uncordon; esperar API, leases, workloads e Longhorn recuperados; liberar a trava e concluir Job. O SUC só então seleciona o próximo nó.

A ordem entre nomes é definida pelo SUC; não se promete masters primeiro. O requisito garantido por este chart é uma fila única para ambos os papéis. `exclusive` isoladamente não é uma trava global: no SUC inspecionado ele usa antiafinidade por hostname. A serialização vem do Plan único e da trava persistente.

Quando não há snapshot novo, o log diz `SEM ATUALIZACOES ... SO NAO sera reiniciado`. A etapa de drain pode ter ocorrido, mas não há reboot desnecessário. Um snapshot já pendente é uma atualização ainda não ativada: se a política permitir, a rodada faz seu reboot e deixa uma nova transação para a próxima rodada.

## 5. Validar e executar outra rodada

```bash
kubectl -n suc-os-system get plan os-maintenance -o yaml
kubectl get nodes -o wide
kubectl get nodes -o json | jq '.items[] | {node:.metadata.name,boot:.status.nodeInfo.bootID,round:.metadata.annotations["suc-os.cattle.io/last-round"],result:.metadata.annotations["suc-os.cattle.io/last-result"]}'
kubectl -n suc-os-system get cm suc-os-maintenance-gate --ignore-not-found
```

Complete deve ser True para a rodada e hash atuais; todos os destinos devem ter a anotação correspondente; todos devem estar Ready e sem cordon; a trava deve estar ausente. Compare boot IDs e logs: resultado `no-change-no-reboot` exige boot ID inalterado; `updated-and-rebooted` ou `pending-snapshot-activated` exige mudança de boot ID. A verificação interna também compara o root Btrfs ativo ao alvo.

Após conclusão, altere apenas o identificador da rodada:

```bash
helm upgrade suc-os-mpba ./plano -n suc-os-system \
  -f ./plano/values-mpba.yaml --set enabled=true \
  --set action=update --set-string round=mpba-update-02
```

Não force reinstalação/downgrade de pacotes para fabricar updates. A segunda rodada pode legitimamente não encontrar novidades. Para comprovar instalação real, é preciso haver pacotes elegíveis nos repositórios; caso contrário, comprova-se o caminho sem alterações.

## 6. Longhorn, volumes locais e ausência de Longhorn

Sem grupo `longhorn.io` na API ou com lista de volumes vazia, os testes de réplicas são dispensados. Erro de discovery, API ou RBAC bloqueia; não é interpretado como ausência. Nós, leases, aplicações e volumes locais continuam verificados.

Com volumes Longhorn, exige-se a política `block-if-contains-last-replica`, scheduling bloqueado em nó cordoned, volumes saudáveis, engines sem réplicas WO/ERR e réplicas válidas em outro nó antes do drain. A fila espera recuperação completa após uncordon, pois esperar rebuild com o nó ainda cordoned pode causar bloqueio circular. PDBs do Longhorn continuam sendo respeitados.

PVC local, hostPath de aplicação, CSI inline e volumes efêmeros desconhecidos bloqueiam. Socket CSI e diretórios próprios da infraestrutura podem ser permitidos por uma lista de namespace, service account, ownerKind e caminhos exatos. A exceção não desativa PDB nem transforma um PVC local em remoto.

O padrão bloqueia `emptyDir`. O perfil MPBA permite sua exclusão apenas porque o dono do laboratório aceitou perder o histórico temporário. Essa política não deve ser copiada automaticamente para produção. Cache e dados de aplicação podem usar o mesmo tipo de volume; `emptyDir` não significa automaticamente descartável.

Bloqueios também ocorrem por indisponibilidade, PDB, autenticação, capacidade, erro de repositório ou reboot incompleto. Não é correto limitar a parada apenas a corrupção comprovada: estas condições precisam ser resolvidas antes da manutenção segura.

## 7. Parâmetros do Helm/YAML

| Parâmetro | Função / padrão |
|---|---|
| `controller.enabled` | Instala o controller dedicado quando true; bloqueado pelo template em cattle-system. |
| `controller.image` | Imagem SUC 0.19.1, alinhada à CRD existente. |
| `controller.replicas` | 2 réplicas em nós diferentes, com eleição de líder. |
| `enabled` | false não cria Plan; true permite execução imediata pelo SUC. |
| `planName` | Nome do Plan, conta, Secret e RBAC; não renomear durante manutenção. |
| `round` | Identificador da campanha. Mudar após conclusão dispara novo hash. Não é versão do RKE2. |
| `profile` | `micro62`: transactional-update; `sles`: zypper em SLES tradicional RW. |
| `action` | `prepare-host` configura agendamentos; `update` executa a manutenção. |
| `image` | Toolbox fixada compatível com Kubernetes. Entry point sobrescrito: não executa upgrade do RKE2. |
| `nodeNames` | Lista explícita dos hostnames elegíveis. Vazia bloqueia ativação. |
| `longhornNamespace` | Namespace dos volumes Longhorn quando existentes. |
| `healthTimeoutSeconds` | 1800 s máximos para recuperar saúde em cada espera. |
| `stableSeconds` | 60 s consecutivos saudáveis; uma falha zera a contagem. |
| `drainTimeout` | 30m máximos para eviction; timeout para a fila. Ajustar após medir PDB/rebuild real. |
| `hostTimeoutSeconds` | 7200 s máximos para unidade de update; impede transação pendurada indefinidamente. |
| `jobActiveDeadlineSeconds` | 18000 s para o Job, incluindo esperas, drain, update e validação. |
| `postCompleteDelay` | 30s adicionais entre sucesso do Job e seleção do próximo nó. Não substitui testes de saúde. |
| `allowEmptyDirDeletion` | false por padrão; true autoriza perda desses dados no drain. |
| `activatePendingSnapshot` | false bloqueia snapshot previamente pendente; true ativa após drain, sem criar outro sobre ele. |
| `manageAutomaticUpdates` | Autoriza a etapa prepare-host a desativar timer/rebootmgr. |
| `remoteCSIDrivers` | Lista de drivers remotos revisados além de Longhorn e NFS. Não usar para aprovar CSI local. |
| `hostPathAllowlist` | Exceções auditadas com namespace, service account, ownerKind e caminhos exatos. |
| `spec.concurrency: 1` | No máximo um destino do Plan sendo processado. |
| `spec.exclusive: true` | Evita Job exclusivo concorrente no mesmo nó. |
| `upgrade.cattle.io/digest` | Inclui ambiente/imagem no hash; Secret também participa. Editar scripts pode redisparar manutenção. |
| `serviceAccountName` | Conta dedicada, sem vínculo cluster-admin. |
| `secrets[].path` | `/run/suc-os`, scripts montados pelo SUC. O Secret contém código, não credenciais. |
| `tolerations: Exists` | Permite Job em masters/etcd e nós cordoned; o preflight continua exigindo saúde. |
| `privileged`, `runAsUser: 0` | Necessários para operar o SO hospedeiro; restringir quem pode modificar o chart/Secret/Plan. |
| `cordon/drain` ausentes do Plan | O script opera ambos e valida recuperação antes do Job concluir, incluindo registro persistente de erros. |

## 8. Scripts, variáveis e estado

| Arquivo / parâmetro | Responsabilidade |
|---|---|
| `run.sh` | Orquestra o ciclo completo; somente ele libera próximo nó. |
| `common.sh` | Logs UTC, API com timeout, host chroot, trava e parada em erro. |
| `health.sh` | API readyz, Ready/pressão, leases com menos de 120 s, workloads e Longhorn condicional. |
| `storage-guard.jq` | Resolve PVC/PV e imprime bloqueadores com namespace/pod/volume. |
| `host-preflight.sh` | Identifica o SO real, confirma binários, systemd e pelo menos 2 GiB livres em root/var. Este mínimo não é dimensionamento para qualquer update. |
| `host-worker.sh` | Unidade independente do container, flock local, snapshot etcd, update, estado persistente e reboot. |
| `SYSTEM_UPGRADE_NODE_NAME` | Nome do nó, injetado pelo SUC. |
| `SYSTEM_UPGRADE_PLAN_NAME` | Plan atual; usado para excluir sua própria manutenção das verificações de conflito. |
| `SYSTEM_UPGRADE_PLAN_LATEST_HASH` | Identifica o estado persistente desta execução; não usar um hash antigo para marcar sucesso. |
| `SYSTEM_UPGRADE_PLAN_LATEST_VERSION` | Identificador legível da rodada nos logs. |
| `PLAN_NAMESPACE` / `NS` | Namespace da trava e Plan. |
| `PROFILE`, `ACTION`, `EXPECTED_NODES` | Perfil, etapa e lista de destinos vindos do Helm. |
| `HEALTH_TIMEOUT`, `STABLE_SECONDS` | Limite e intervalo contínuo de saúde. |
| `DRAIN_TIMEOUT`, `HOST_TIMEOUT` | Limites do drain e unidade do host. |
| `ACTIVATE_PENDING`, `MANAGE_AUTOMATIC` | Autorizações de comportamento definidas no perfil. |
| `STATE` / `LOCAL_STATE` | `/var/lib/suc-os/<hash>` no host e seu acesso por `/host`. Persistem após reboot. |
| `suc-os-maintenance-gate` | ConfigMap com nó/hash/fase. Não tem expiração automática; erro não pode abrir a fila por tempo. |
| `phase` | running, reboot-pending, done ou failed no host. Na trava: preflight, draining, updating, verifying, failed. |
| `old-boot`, `old-root`, `target-root` | Provas de boot anterior e snapshot esperado; retorno do comando reboot não conta como sucesso. |
| `result` | no-change-no-reboot, updated-and-rebooted ou pending-snapshot-activated. |
| `error`, `job-error` | Diagnóstico persistente da unidade/Job. |
| `flock -n` | Impede dois workers locais simultâneos; não substitui a trava do cluster. |
| `set -Eeuo pipefail` | Interrompe falhas, variáveis ausentes e erros em pipelines. |
| `--non-interactive --drop-if-no-change up` | Atualiza pacotes do Micro, descartando snapshot sem mudanças. |
| `zypper patch --with-update` | Exemplo SLES: aplica patches e updates em uma operação; 102/103 são tratados explicitamente. |

## 9. Diagnóstico e retomada

```bash
kubectl -n suc-os-system get cm suc-os-maintenance-gate -o yaml
kubectl -n suc-os-system get jobs,pods -l upgrade.cattle.io/plan=os-maintenance -o wide
kubectl -n suc-os-system logs POD -c upgrade --timestamps
kubectl get pdb -A
kubectl get events -A --sort-by=.lastTimestamp
```

No nó envolvido, usando o hash real mostrado na trava:

```bash
sudo journalctl -u suc-os-HASH.service --no-pager
sudo cat /var/lib/suc-os/HASH/phase
sudo cat /var/lib/suc-os/HASH/error
sudo cat /var/log/transactional-update.log
sudo btrfs inspect-internal rootid /
sudo btrfs subvolume get-default /
```

Não apagar a trava, Job, finalizers, PDBs ou snapshots apenas para “destravar”. Primeiro confirmar que a unidade do host está inativa, não há update/reboot em curso e diagnosticar a causa. Após correção: conferir SO, snapshot, boot, storage e aplicações; restaurar schedulability somente se seguro; guardar evidências; remover manualmente a trava; iniciar uma nova rodada com identificador novo. O estado antigo permanece para auditoria. Se a causa foi snapshot pendente, a política deve ser revisada explicitamente. Se foi rollback, investigar o motivo do boot no snapshot antigo antes de repetir.

Para desistir da automação, aguarde o fim de qualquer transação. Desative o Plan no Git/Helm. Restaure timer/rebootmgr conforme `automatic-units-before.txt`, nó a nó e em janela aprovada; reativar timers pode preparar snapshots/reboots de imediato. Não automatizamos essa restauração após uma falha porque ela poderia reiniciar nós em paralelo.

## 10. Fleet e segundo exemplo

O `GitRepo` de exemplo usa exclusivamente `paths: [plano]` e seleciona o label de `mpba-teste`. Não aponte Fleet à raiz, aos exemplos ou ao antigo diretório `suc/`. O Rancher já gerencia um SUC, mas ele estava com zero réplicas. Para preservar seus Plans de system-agent pendentes, o perfil MPBA usa um SUC 0.19.1 dedicado em `suc-os-system`. Os watches de Plans/Jobs/Secrets são restritos a esse namespace, conforme o código da versão. Há permissões de cluster para consultar/atualizar Nodes e registrar a CRD de Plan; não se deve criar Plan nessa instância para outros propósitos sem revisão.

O Fleet usa Helm e o mesmo release `suc-os-mpba`, no namespace `suc-os-system`. A ativação está no `plano/fleet.yaml`: alterar `helm.values.enabled`, `action` e `round` conscientemente. Não mantenha Helm manual e Fleet reconciliando configurações diferentes ao mesmo tempo. Na entrega, o estado salvo deve corresponder à última rodada validada para evitar execução acidental adicional.

Para SLES tradicional, use o mesmo chart com `-f examples/sles/values.yaml`, revise `nodeNames`, imagem e versões, e siga as mesmas etapas. O exemplo original foi melhorado com tratamento de erros, detecção por inventário RPM, logs, limites e proteção de storage. Esse perfil não pode ser validado em hosts Micro e fica identificado separadamente no relatório.

## 11. Referências oficiais consultadas

- [SUSE Micro 6.2: identificação do produto](https://documentation.suse.com/releasenotes/sle-micro/6.2/index.html).
- [SUSE Micro 6.2: transactional-update, snapshots e timers](https://documentation.suse.com/sle-micro/6.2/html/Micro-transactional-updates/index.html).
- [SUC: API de Plan](https://github.com/rancher/system-upgrade-controller/blob/v0.19.1/doc/plan.md) e [implementação de Jobs 0.19.1](https://github.com/rancher/system-upgrade-controller/blob/v0.19.1/pkg/upgrade/job/job.go).
- [Kubernetes: drain seguro e PDB](https://kubernetes.io/docs/tasks/administer-cluster/safely-drain-node/).
- [Kubernetes: volumes e emptyDir](https://kubernetes.io/docs/concepts/storage/volumes/).
- [Kubernetes: version skew do kubectl](https://kubernetes.io/releases/version-skew-policy/).
- [Longhorn 1.11.2: manutenção de nós e políticas de drain](https://longhorn.io/docs/1.11.2/maintenance/maintenance/).
- [SUSE: gerenciamento com Zypper](https://documentation.suse.com/en-us/sles/15-SP6/single-html/SLES-administration/index.html).

Estes são scripts próprios apoiados nos mecanismos documentados. Não representam certificação/homologação formal da SUSE, nem eliminam a necessidade de validação das aplicações e restauração dos backups.
