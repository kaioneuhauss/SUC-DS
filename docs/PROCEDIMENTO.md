# Procedimento: manutenção do SO com SUC e manifests separados

## 1. Escopo e pré-requisitos

O destino verificado é `mpba-teste`, Rancher `c-m-n4dl4ksn`, com cinco nós: `master-mbpa1` (esta é a grafia real), `master-mpba2`, `master-mpba3`, `worker-mpba1`, `worker-mpba2`. RKE2 `v1.35.6+rke2r1`, SUC `v0.19.1`, Longhorn `v1.11.2`.

Micro 6.2 pode apresentar `ID=sles` e `VERSION_ID=16.0`. A identificação do produto usa `VARIANT_ID=transactional`, `SUSE_SUPPORT_PRODUCT=SUSE Linux Micro` e `SUSE_SUPPORT_PRODUCT_VERSION=6.2`; não se deve escolher `zypper` direto pelo campo OS-IMAGE do Kubernetes.

Este procedimento faz atualização de pacotes dentro da versão instalada. Não executa `dup`, `migration`, atualização de RKE2 nem troca de repositórios. Verifique registro/subscrição e alcance aos repositórios SUSE. Tenha backup externo restaurável de aplicações e etcd; o snapshot local de etcd criado pelo script não substitui backup externo. Valide a matriz de suporte da sua combinação real de SO, RKE2 e CNI antes de transportar para produção.

Uma única pessoa/automação deve operar a manutenção. Não altere scripts, imagem, parâmetros ou rodada enquanto houver Job em execução: esses campos podem mudar o hash e substituir Jobs. A trava impede avanço silencioso, mas não cancela uma transação que já iniciou no host.

## 2. Arquivos e validação — entrega pelo Fleet

O controller existente continua instalado pelo Helm/Rancher. Não instalamos um segundo controller nem mantemos um chart próprio. Fleet aceita os mesmos YAMLs diretamente.

- `plano/rbac.yaml`: ServiceAccount e permissões do Job.
- `plano/os-upgrade-secret.yaml`: scripts e política de storage, sem credenciais; usa `data` em base64 para compatibilidade com server-side apply. Os fontes legíveis estão em scripts/.
- `plano/os-upgrade-plan.yaml`: um Plan para masters e workers.
- `plano/fleet.yaml`: namespace de destino para Fleet.
- `plano/scripts/`: fonte legível dos scripts; `render-secret.py` sincroniza o Secret.

Na raiz do repositório:

```bash
export KUBECONFIG=/home/kaio/.kube/istio-mpba.yaml
kubectl config current-context
kubectl get nodes -o wide
kubectl -n cattle-system get deploy system-upgrade-controller
kubectl get plans.upgrade.cattle.io -A
python3 plano/render-secret.py
bash plano/tests/verify.sh
kubectl apply --dry-run=server -f plano/rbac.yaml -f plano/os-upgrade-secret.yaml -f plano/os-upgrade-plan.yaml
```

Os cinco nomes em `nodeSelector` limitam o escopo. Além disso, cada nó precisa do label `suc-os.cattle.io/enabled=true`. A ausência desse label impede novas execuções nesse nó, mas não interrompe um Job já iniciado.

## 3. Preparar os hosts

Revise o Plan: `ACTION=prepare-host`, `MANAGE_AUTOMATIC=true` e uma `spec.version` exclusiva para a preparação. Revise os nomes e `EXPECTED_NODES`. Em `scripts/policy.json`, o MPBA permite descarte de emptyDir por autorização expressa do dono do lab. Outros ambientes devem usar false por padrão.

```bash
git add plano
# Revise git diff --cached antes de publicar.
git commit -m "Prepara hosts para manutencao serial do SO"
git push origin main
# Somente na primeira instalacao: criar o GitRepo no Rancher management.
kubectl --context rancher apply -f examples/fleet-gitrepo.yaml
kubectl label nodes master-mbpa1 master-mpba2 master-mpba3 worker-mpba1 worker-mpba2 suc-os.cattle.io/enabled=true --overwrite
```

O controller deve ter uma réplica disponível. Neste lab estava com zero e havia um upgrade de system-agent pendente. Os labels originais foram guardados; `plan.upgrade.cattle.io/system-agent-upgrader=disabled` foi aplicado aos cinco nós antes de ativar o controller. Por escolha do usuário, o estado final mantém SUC ativo e esse outro Plan em espera. Não remova o label disabled sem revisar e autorizar a atualização do agente. Não ative controllers pausados sem inventariar todos os seus Plans.

No MPBA esta preparação já foi executada nos cinco hosts. Para o uso normal, mantenha `ACTION=update`; não é necessário repetir a preparação a cada rodada.

A preparação registra o estado dos serviços em `/var/lib/suc-os/automatic-units-before.txt`, desativa `transactional-update.timer`, confirma que nenhuma transação está ativa e desativa `rebootmgr.service`. O executável `transactional-update` continua disponível. Não faz update nem reboot e não interrompe transação em andamento. Falhas param a fila; a anotação `suc-os.cattle.io/automatic-updates=disabled` identifica os nós preparados.

```bash
kubectl -n cattle-system get plan os-maintenance -o yaml
kubectl -n cattle-system get jobs -l upgrade.cattle.io/plan=os-maintenance
kubectl -n cattle-system logs -l upgrade.cattle.io/plan=os-maintenance --all-containers --prefix --tail=100
kubectl get nodes -o json | jq '.items[] | {node:.metadata.name,prepared:.metadata.annotations["suc-os.cattle.io/automatic-updates"]}'
```

## 4. Executar a rodada

Após todos os hosts preparados e o Plan completo, edite `plano/os-upgrade-plan.yaml`: troque o valor de `ACTION` para `update` e `spec.version` para um identificador novo, por exemplo `mpba-update-05` para a próxima rodada após os testes deste lab. Mantenha os demais campos, revise o diff e publique:

```bash
git diff -- plano/os-upgrade-plan.yaml
git add plano/os-upgrade-plan.yaml
git commit -m "Inicia rodada de atualizacao do SO"
git push origin main
kubectl --context rancher -n fleet-default get gitrepo suc-os-mpba
```

Fleet detecta o commit e aplica o Plan. Também é possível editar e fazer commit pela interface do GitHub. Depois de Fleet assumir, não aplique mudanças manuais concorrentes no downstream.

A sequência por nó é: adquirir trava; verificar versão/ferramentas; confirmar preparação de todos; esperar saúde estável; conferir conflitos e redundância; cordon; inventariar volumes; executar drain com eviction e PDB; iniciar unidade do systemd do host; atualizar ou ativar snapshot pendente; verificar reboot e snapshot; uncordon; esperar API, leases, workloads e Longhorn recuperados; liberar a trava e concluir Job. O SUC só então seleciona o próximo nó.

A ordem entre nomes é definida pelo SUC; não se promete masters primeiro. O requisito garantido pelo Plan é uma fila única para ambos os papéis. `exclusive` isoladamente não é uma trava global: no SUC inspecionado ele usa antiafinidade por hostname. A serialização vem do Plan único e da trava persistente.

Quando não há snapshot novo, o log diz `SEM ATUALIZACOES ... SO NAO sera reiniciado`. A etapa de drain pode ter ocorrido, mas não há reboot desnecessário. Um snapshot já pendente é uma atualização ainda não ativada: se a política permitir, a rodada faz seu reboot e deixa uma nova transação para a próxima rodada.

## 5. Validar e executar outra rodada

```bash
kubectl -n cattle-system get plan os-maintenance -o yaml
kubectl get nodes -o wide
kubectl get nodes -o json | jq '.items[] | {node:.metadata.name,boot:.status.nodeInfo.bootID,round:.metadata.annotations["suc-os.cattle.io/last-round"],result:.metadata.annotations["suc-os.cattle.io/last-result"]}'
kubectl -n cattle-system get cm suc-os-maintenance-gate --ignore-not-found
```

Complete deve ser True para a rodada e hash atuais; todos os destinos devem ter a anotação correspondente; todos devem estar Ready e sem cordon; a trava deve estar ausente. Compare boot IDs e logs: resultado `no-change-no-reboot` exige boot ID inalterado; `updated-and-rebooted` ou `pending-snapshot-activated` exige mudança de boot ID. A verificação interna também compara o root Btrfs ativo ao alvo.

Após conclusão, altere apenas `spec.version` para um identificador novo, mantendo `ACTION=update`, e publique por commit/push ou pela interface do GitHub. Fleet iniciará a próxima rodada. Não edite o Secret ou o Plan enquanto houver manutenção ativa.

Não force reinstalação/downgrade de pacotes para fabricar updates. A segunda rodada pode legitimamente não encontrar novidades. Para comprovar instalação real, é preciso haver pacotes elegíveis nos repositórios; caso contrário, comprova-se o caminho sem alterações.

## 6. Longhorn, volumes locais e ausência de Longhorn

Sem grupo `longhorn.io` na API ou com lista de volumes vazia, os testes de réplicas são dispensados. Erro de discovery, API ou RBAC bloqueia; não é interpretado como ausência. Nós, leases, aplicações e volumes locais continuam verificados.

Com volumes Longhorn, exige-se a política `block-if-contains-last-replica`, scheduling bloqueado em nó cordoned, volumes saudáveis, engines sem réplicas WO/ERR e réplicas válidas em outro nó antes do drain. A fila espera recuperação completa após uncordon, pois esperar rebuild com o nó ainda cordoned pode causar bloqueio circular. PDBs do Longhorn continuam sendo respeitados.

PVC local, hostPath de aplicação, CSI inline e volumes efêmeros desconhecidos bloqueiam. Socket CSI e diretórios próprios da infraestrutura podem ser permitidos por uma lista de namespace, service account, ownerKind e caminhos exatos. A exceção não desativa PDB nem transforma um PVC local em remoto.

O padrão bloqueia `emptyDir`. O perfil MPBA permite sua exclusão apenas porque o dono do laboratório aceitou perder o histórico temporário. Essa política não deve ser copiada automaticamente para produção. Cache e dados de aplicação podem usar o mesmo tipo de volume; `emptyDir` não significa automaticamente descartável.

Bloqueios também ocorrem por indisponibilidade, PDB, autenticação, capacidade, erro de repositório ou reboot incompleto. Não é correto limitar a parada apenas a corrupção comprovada: estas condições precisam ser resolvidas antes da manutenção segura.

## 7. Parâmetros do Plan e da política

| Campo | Função |
|---|---|
| `metadata.name/namespace` | `os-maintenance` em `cattle-system`, observado pelo SUC existente. |
| `spec.version` | Identificador da rodada; alterá-lo dispara nova execução. Não é versão do RKE2. |
| `spec.concurrency: 1` | Um nó por vez no conjunto de masters e workers deste Plan. |
| `spec.exclusive: true` | Evita outro Job exclusivo no mesmo nó; não é serialização global entre Plans. |
| `nodeSelector` | Linux, hostnames explícitos e label de adesão. Não inclui novos nós automaticamente. |
| `jobActiveDeadlineSecs: 18000` | Prazo total de cinco horas por Job. Falha não autoriza o próximo nó. |
| `postCompleteDelay: 30s` | Intervalo adicional após sucesso; não substitui saúde estável. |
| `serviceAccountName` | Conta dedicada; RBAC limita consultas e alterações Kubernetes. |
| `upgrade.image` | Imagem fixada por digest, com bash/jq/kubectl compatível com Kubernetes 1.35. |
| `command/args` | Executam nosso script; não executam o entrypoint de upgrade do RKE2. |
| `privileged/runAsUser` | Privilégio necessário para operar o host; limitar acesso de escrita ao Plan/Secret. |
| `secrets[].name/path` | Monta código em `/run/suc-os`. Mudanças no Secret alteram o hash do Plan. |
| `upgrade.cattle.io/digest` | Inclui ambiente/imagem no hash, além de versão/Secret. |
| `tolerations: Exists` | Permite o Job nos masters/etcd e no nó cordoned. |
| `ACTION` | `prepare-host` transfere agendamentos; `update` executa manutenção. |
| `PROFILE` | `micro62` usa transactional-update; `sles` usa zypper em raiz tradicional RW. |
| `PLAN_NAMESPACE` | Namespace da trava, igual ao do Plan. |
| `EXPECTED_NODES` | Lista separada por vírgulas dos nós que devem existir e estar preparados. |
| `LH_NAMESPACE` | Namespace Longhorn, somente utilizado quando existem volumes Longhorn. |
| `HEALTH_TIMEOUT: 1800` | Tempo máximo de cada espera de recuperação, em segundos. |
| `STABLE_SECONDS: 60` | Tempo contínuo saudável antes de avançar. Uma falha reinicia a contagem. |
| `DRAIN_TIMEOUT: 30m` | Limite da eviction respeitando PDB e término normal dos pods. |
| `HOST_TIMEOUT: 7200` | Prazo máximo da unidade systemd de atualização, em segundos. |
| `ACTIVATE_PENDING` | true permite ativar snapshot já pendente, sem sobrescrevê-lo; false bloqueia. |
| `MANAGE_AUTOMATIC` | true autoriza desativar timer/rebootmgr na preparação. Não desabilita o comando de update. |
| `allowEmptyDirDeletion` em `scripts/policy.json` | true permite perda dos dados emptyDir; autorizado exclusivamente para este lab. |
| `remoteCSIDrivers` na política | Drivers remotos adicionais revisados. Não deve liberar CSI local. |
| `hostPathAllowlist` na política | Exceções exatas de namespace, ServiceAccount, ownerKind e caminhos de infraestrutura. |
| `cordon/drain` ausentes do YAML | O script executa ambos e verifica recuperação antes de concluir o Job. |

### Campos do Fleet e RBAC

| Campo/recurso | Função |
|---|---|
| `fleet.yaml.defaultNamespace` | Define o namespace padrão; recursos de cluster continuam permitidos. Não usar `namespace` para forçar ClusterRole a um namespace. |
| `fleet.yaml.helm.releaseName` | Identidade do release interno do Fleet, incluindo bundles de YAML puro. Não instala outro controller. |
| `GitRepo.metadata.namespace: fleet-default` | Namespace de gestão no Rancher; aplicar o GitRepo no contexto de management. |
| `GitRepo.spec.repo/branch` | URL do Git e branch que Fleet acompanhará. Commit local não basta: precisa estar publicado. |
| `GitRepo.spec.paths: [plano]` | Limita os manifests sincronizados; não inclui exemplos antigos ou SLES. |
| `targets[].clusterSelector.matchLabels` | Limita ao cluster com display-name mpba-teste. Confira esse label no Rancher. |
| `ClusterRole` | Leitura de saúde/storage, patch de Nodes para cordon/labels/anotações e criação de eviction. Não permite apagar PVC/PV/PDB ou workloads. |
| `Role` da trava | Permite criar ConfigMap no namespace; get/patch/delete limitados ao nome da trava. |
| `RoleBinding/ClusterRoleBinding` | Vinculam essas permissões somente à conta os-maintenance. |
| `nonResourceURLs` | Autoriza consultas de versão e readyz da API. |

## 8. Scripts, variáveis e estado

| Arquivo / parâmetro | Responsabilidade |
|---|---|
| `run.sh` | Orquestra o ciclo completo; somente ele libera próximo nó. |
| `common.sh` | Logs UTC, API com timeout, host chroot, trava e parada em erro. |
| `health.sh` | API readyz, Ready/pressão, leases com menos de 120 s, workloads e Longhorn condicional; aguarda até 600 s o RKE2 ficar ativo após reboot. |
| `storage-guard.jq` | Resolve PVC/PV e imprime bloqueadores com namespace/pod/volume. |
| `host-preflight.sh` | Identifica o SO real, confirma binários (incluindo RKE2 em /opt/rke2/bin nos masters), systemd e pelo menos 2 GiB livres em root/var. Este mínimo não é dimensionamento para qualquer update. |
| `host-worker.sh` | Unidade independente do container, flock local, snapshot etcd, update, estado persistente e reboot. |
| `SYSTEM_UPGRADE_NODE_NAME` | Nome do nó, injetado pelo SUC. |
| `SYSTEM_UPGRADE_PLAN_NAME` | Plan atual; usado para excluir sua própria manutenção das verificações de conflito. |
| `SYSTEM_UPGRADE_PLAN_LATEST_HASH` | Identifica o estado persistente desta execução; não usar um hash antigo para marcar sucesso. |
| `SYSTEM_UPGRADE_PLAN_LATEST_VERSION` | Identificador legível da rodada nos logs. |
| `PLAN_NAMESPACE` / `NS` | Namespace da trava e Plan. |
| `KUBECONFIG` temporário do Job | Aponta à API interna e aos arquivos CA/token rotativo do próprio ServiceAccount. Não usa credencial administrativa do host. |
| `PROFILE`, `ACTION`, `EXPECTED_NODES` | Perfil, etapa e lista de destinos definidos no Plan. |
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
kubectl -n cattle-system get cm suc-os-maintenance-gate -o yaml
kubectl -n cattle-system get jobs,pods -l upgrade.cattle.io/plan=os-maintenance -o wide
kubectl -n cattle-system logs POD -c upgrade --timestamps
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

Para desistir da automação, aguarde o fim de qualquer transação. Remova o label de adesão dos nós no Kubernetes e mantenha o estado no Git. Restaure timer/rebootmgr conforme `automatic-units-before.txt`, nó a nó e em janela aprovada; reativar timers pode preparar snapshots/reboots de imediato. Não automatizamos essa restauração após uma falha porque ela poderia reiniciar nós em paralelo.

## 10. Fleet e exemplo zypper

O `examples/fleet-gitrepo.yaml` aponta somente para `plano`, com seletor do cluster `mpba-teste`. Fleet pode gerenciar YAML puro; não é necessário criar Chart.yaml, templates ou values. Faça o commit/push dos arquivos antes de criar o GitRepo no contexto de management. Depois que Fleet assumir, mantenha alterações de Plan/Secret no Git para evitar que o reconciliador reverta ajustes manuais.

O Fleet 0.15.4 observado usa Helm internamente também para YAML puro. O campo `helm.releaseName: suc-os-mpba` apenas conserva a identidade do release inicial para sua adoção; não exige chart próprio. A adoção já foi concluída no MPBA. Não execute helm upgrade/rollback/uninstall usando o chart antigo. O controller Rancher tem outro release e deve ser preservado. O estado de GitRepo/BundleDeployment e o resultado do Plan devem ser conferidos separadamente: Ready do Fleet comprova entrega, enquanto Complete do Plan comprova conclusão da manutenção.

Na adoção inicial, um conflito herdado de `kubectl` em `spec.version` foi resolvido uma única vez, transferindo a propriedade desse campo ao `fleetagent` após dry-run. Isso não é uma etapa normal de cada rodada; mudanças futuras devem partir do Git. Não use `force-conflicts` como correção genérica sem examinar o conflito.

O exemplo `examples/sles/plano-prod-so.yaml` reutiliza os scripts/RBAC, mas seleciona `PROFILE=sles`, nomes de exemplo e `ACTIVATE_PENDING=false`. Revise os destinos e aplique esse Plan no lugar do Micro, nunca os dois simultaneamente com o mesmo nome. Em SLES tradicional o worker usa `zypper refresh` e `patch --with-update`, aceita códigos informativos 102/103, compara inventário RPM e registra erros. Não use esse perfil em Micro. O laboratório atual não valida esse ramo em SO tradicional.

## 11. Referências oficiais consultadas

- [SUSE Micro 6.2: identificação do produto](https://documentation.suse.com/releasenotes/sle-micro/6.2/index.html).
- [SUSE Micro 6.2: transactional-update, snapshots e timers](https://documentation.suse.com/sle-micro/6.2/html/Micro-transactional-updates/index.html).
- [SUC: API de Plan](https://github.com/rancher/system-upgrade-controller/blob/v0.19.1/doc/plan.md) e [implementação de Jobs 0.19.1](https://github.com/rancher/system-upgrade-controller/blob/v0.19.1/pkg/upgrade/job/job.go).
- [Kubernetes: drain seguro e PDB](https://kubernetes.io/docs/tasks/administer-cluster/safely-drain-node/).
- [Kubernetes: Secret data e limitação de stringData com server-side apply](https://kubernetes.io/docs/concepts/configuration/secret/).
- [Kubernetes: volumes e emptyDir](https://kubernetes.io/docs/concepts/storage/volumes/).
- [Kubernetes: version skew do kubectl](https://kubernetes.io/releases/version-skew-policy/).
- [Longhorn 1.11.2: manutenção de nós e políticas de drain](https://longhorn.io/docs/1.11.2/maintenance/maintenance/).
- [Fleet: YAML puro](https://fleet.rancher.io/explanations/gitrepo-content) e [campos de fleet.yaml](https://fleet.rancher.io/reference/ref-fleet-yaml).
- [RKE2: caminhos da instalação em raiz imutável](https://docs.rke2.io/install/quickstart).
- [openSUSE/SUSE: códigos de saída do Zypper](https://manpages.opensuse.org/Leap-15.6/zypper/zypper.8.en.html#EXIT_CODES).
- [SUSE: gerenciamento com Zypper](https://documentation.suse.com/en-us/sles/15-SP6/single-html/SLES-administration/index.html).

Estes são scripts próprios apoiados nos mecanismos documentados. Não representam certificação/homologação formal da SUSE, nem eliminam a necessidade de validação das aplicações e restauração dos backups.
