# Atualização do SO pelo Fleet

Quatro arquivos de implantação em `plano/`:

| Arquivo | Para que serve |
|---|---|
| `fleet.yaml` | Entrega os YAMLs em cattle-system pelo Fleet. |
| `server-plan.yaml` | Atualiza os três masters, um por vez, usando a conta existente do SUC. |
| `agent-plan.yaml` | Espera os três masters concluírem a mesma rodada e atualiza os dois workers, um por vez. |
| `os-upgrade-secret.yaml` | Contém os scripts compartilhados e a política de volumes. Não contém credenciais. |

O exemplo `examples/sles/plano-prod-so.yaml` é alternativo, para SLES tradicional com zypper. O Fleet do MPBA acompanha somente `plano/`.

**Pré-requisito:** o SUC e a ServiceAccount `cattle-system/system-upgrade-controller` já devem existir. Os dois Plans e o exemplo SLES reutilizam essa conta. No MPBA, ela já está vinculada ao ClusterRole `cluster-admin` pelo ClusterRoleBinding `system-upgrade-controller`; este projeto não cria nem altera essa vinculação. Em outro cluster, confirme as permissões antes de aplicar. A reutilização simplifica os objetos, mas concede aos Jobs as mesmas permissões amplas da conta do controller. O bundle passa a conter somente dois Plans e um Secret; `fleet.yaml` é a configuração de entrega.

## Uso no MPBA

1. Espere os dois Plans da rodada anterior terminarem. Confira os cinco nós Ready.
2. Altere **spec.version nos dois Plans para o mesmo identificador novo**, por exemplo `mpba-update-08`. Mantenha ACTION=update.
3. Publique os quatro YAMLs no mesmo commit da branch main. O GitRepo `fleet-default/suc-os-mpba` entrega os arquivos.
4. Acompanhe os Jobs em cattle-system. Masters primeiro; workers depois. Um Job de worker pode aparecer em Init enquanto espera: ainda não executa drain nem update.
5. A rodada acaba quando os dois Plans estão Complete=True, os cinco nós estão Ready/sem cordon e a trava não existe mais.

```bash
export KUBECONFIG=/home/kaio/.kube/istio-mpba.yaml
kubectl -n cattle-system get plans
kubectl -n cattle-system get plans os-maintenance-server os-maintenance-agent \
  -o custom-columns=NAME:.metadata.name,VERSION:.status.latestVersion,CONDITIONS:.status.conditions
kubectl -n cattle-system get jobs,pods -l upgrade.cattle.io/controller -o wide
kubectl -n cattle-system logs -l upgrade.cattle.io/plan=os-maintenance-server --all-containers --prefix --tail=80
kubectl -n cattle-system logs -l upgrade.cattle.io/plan=os-maintenance-agent --all-containers --prefix --tail=80
kubectl get nodes
kubectl -n cattle-system get cm suc-os-maintenance-gate --ignore-not-found
```

Fleet Ready significa entrega; Complete=True nos dois Plans significa manutenção concluída. Não edite versão, parâmetros ou Secret durante Jobs ativos. Ao alterar código/configuração para uma nova execução, use uma nova versão, igual nos dois Plans, no mesmo commit. A troca de `serviceAccountName` também altera o hash do SUC e pode iniciar outra execução mesmo sem mudar `spec.version`; publique esta migração somente na próxima janela de manutenção autorizada, junto da nova versão nos dois Plans.

A reutilização da conta existente foi publicada na rodada `mpba-update-06`. O Fleet entrega três recursos (dois Plans e um Secret), e os cinco objetos de RBAC/ServiceAccount dedicados foram removidos. A revisão `mpba-update-07` acrescenta o prepare nos dois grupos e logs detalhados, mantendo essa estrutura.

## Como acompanhar cada etapa

1. **prepare:** primeiro aguarda os masters, se for um worker; depois verifica API, todos os nós esperados, Ready/pressão, heartbeats recentes, workloads e Longhorn quando existente. Exige 60 segundos contínuos de saúde. Não altera o host.
2. **upgrade / DRAIN:** adquire a trava global, repete as verificações, faz cordon, verifica volumes e executa drain respeitando PDBs. O drain fica dentro do script para não ser repetido pelo SUC após o reboot.
3. **upgrade / SO:** registra o backup etcd nos masters e a execução do transactional-update. A transação roda no systemd do host e seu progresso aparece também no log do container. Sem alterações, registra explicitamente que não reiniciará.
4. **upgrade / VALIDAÇÃO:** se houve reboot, confere boot ID e snapshot; espera RKE2 ativo, libera o agendamento, espera workloads/volumes saudáveis por 60 segundos e só então libera o próximo nó.

`Init:0/1` informa que o prepare ainda não concluiu. Leia o log de **prepare** para saber se ele espera os masters ou a saúde do cluster. As mensagens incluem motivo, progresso e tempo restante; erro/timeout é informado e bloqueia o avanço.

Um reboot do host pode deixar o pod anterior como `Unknown`/`Failed`. O Kubernetes cria outro pod do **mesmo Job** para retomar a validação. Isso não significa nova transação do SO. Só considere recuperado após o pod sucessor concluir, o Plan avançar e o nó voltar saudável. Os Jobs concluídos e seus pods são limpos pelo TTL configurado no controller (900 segundos no MPBA); não remova pods em execução apenas para limpar a tela.

```bash
# Identifique NODE, STATUS e Job; não deduza o nó apenas pelo status.
kubectl -n cattle-system get pods -l upgrade.cattle.io/plan -o wide

# Substitua pelo nome completo obtido acima.
pod_suc=NOME_DO_POD
kubectl -n cattle-system get pod "$pod_suc" \
  -o jsonpath='{.spec.nodeName}{" Job="}{.metadata.ownerReferences[0].name}{"\n"}'
kubectl -n cattle-system logs "$pod_suc" -c prepare -f
# Após o prepare terminar, acompanhe o container upgrade.
kubectl -n cattle-system logs "$pod_suc" -c upgrade -f
```

Exemplos do formato das mensagens (ilustrativos):

```text
container=prepare [ESPERA DOS SERVERS] versao=mpba-update-07 concluidos=2/3 em_execucao=master-mpba2 pendentes=master-mpba2
container=prepare [ESPERA] Motivo: workloads ainda sem todas as replicas prontas. Restam 1700s.
[WORKLOAD] Deployment cattle-system/cattle-cluster-agent prontas=1 desejadas=2
container=upgrade [DRAIN] Evacuando workloads com eviction/PDB. Limite=30m.
[HOST] [SO] Executando transactional-update --non-interactive --drop-if-no-change up
container=upgrade [CONCLUIDO] Sem atualizacoes: SO NAO reiniciado. Saude confirmada; proximo no liberado.
```

O host mantém a saída da transação em `/var/lib/suc-os/HASH/operation.log`, além do journal. Após reboot, o pod sucessor reapresenta esse histórico e continua a validação. `systemd-run --no-block` permite acompanhar essa saída enquanto a unidade executa; a conclusão continua dependendo do estado persistido e das verificações, nunca apenas do envio do comando.

## O que normalmente alterar

| Parâmetro | Função |
|---|---|
| `spec.version` nos dois Plans | Identificador da rodada. É o único ajuste habitual. |
| `nodeSelector` | Destinos de cada grupo; exige suc-os.cattle.io/enabled=true. |
| `EXPECTED_NODES` | Todos os cinco nós esperados; não apenas o grupo atual. |
| `SERVER_PLAN` / `SERVER_NODES` | Plan e nomes dos três masters que os workers devem esperar. |
| `concurrency: 1` | Um nó por vez em cada grupo; a espera entre grupos e a trava compartilhada mantêm a fila serial. |
| `PEER_PLAN` | Identifica o outro Plan desta manutenção. Seu Job pode estar apenas aguardando; outros Plans ativos bloqueiam. |
| `PROFILE` | micro62 para SUSE Linux Micro; sles somente no exemplo de SLES tradicional. |
| `ACTION` | update no uso normal; prepare-host prepara os agendamentos uma única vez. |
| `MANAGE_AUTOMATIC` | Autoriza desativar timer/rebootmgr na preparação; transactional-update continua disponível. |
| `ACTIVATE_PENDING` | Permite ativar um snapshot já pendente antes de tentar outra transação. |
| `HEALTH_TIMEOUT` / `STABLE_SECONDS` | Até 1800 s para recuperar; exige 60 s contínuos de saúde. |
| `DRAIN_TIMEOUT` / `HOST_TIMEOUT` | Até 30 min para drain e 7200 s para a operação no host. |
| `WAIT_TIMEOUT` | Até 43200 s aguardando todos os masters, antes da manutenção do worker. |
| `jobActiveDeadlineSecs` | Limite total do Job: 18000 s nos masters; 86400 s nos workers, incluindo a espera pelos masters. |
| `postCompleteDelay: 30s` | Intervalo adicional após cada sucesso. |
| `prepare` | Container inicial de consulta: espera a ordem dos grupos e valida saúde; não faz drain nem update. |
| `upgrade.image` | Imagem fixa por digest. O comando executa nossos scripts, não um upgrade do RKE2. |
| `serviceAccountName` | Reutiliza `system-upgrade-controller` em cattle-system. A conta e suas permissões são pré-requisitos; não são gerenciadas por estes YAMLs. |
| `securityContext` | Executa como root e com privilégio necessário para operar o host. |
| `secrets` | Monta o código compartilhado em /run/suc-os. |
| `tolerations` | Permitem executar nos masters e em nós cordoned. |
| `PLAN_NAMESPACE` / `LH_NAMESPACE` | Namespace da manutenção e do Longhorn. |
| `exclusive` | Exclusividade no nó; não substitui a espera entre os dois Plans. |
| `upgrade.cattle.io/digest` | Acrescenta os campos listados ao hash. Versão, ServiceAccount e conteúdo dos Secrets já entram no cálculo do SUC; alterações podem disparar outra execução. |

Os hosts MPBA já foram preparados. SUC permanece ativo e o Plan de system-agent deve continuar com label disabled nos cinco nós. Para outro ambiente, revisar destinos, imagem, registro SUSE, backup e política de volumes antes da primeira preparação.

## Proteções mantidas

- API, nós Ready/sem pressão, leases recentes e workloads saudáveis antes de avançar.
- Snapshot etcd antes de cada master; snapshot local não substitui backup externo.
- Drain com eviction e PDB. Nenhum force, remoção de PDB ou de finalizer.
- Longhorn é opcional: sem grupo/volumes na API, não exige réplicas; falha de consulta bloqueia. Com volumes, espera redundância e réplicas RW.
- PVC local, hostPath de aplicação e CSI desconhecido bloqueiam. Exceções de infraestrutura ficam na política.
- `allowEmptyDirDeletion: true` na política foi autorizado apenas para os dados temporários deste lab; use false em outro ambiente sem essa autorização.
- Sem novidades, transactional-update descarta o snapshot vazio e registra que não haverá reboot.
- Reboot só é aceito após mudança real de boot ID e ativação do root Btrfs esperado.
- Erro preserva a trava e os dados em /var/lib/suc-os/HASH. Nenhum próximo nó é autorizado pela passagem do tempo.

Em erro, leia os logs e `kubectl -n cattle-system get cm suc-os-maintenance-gate -o yaml`. No host envolvido, consulte `journalctl -u suc-os-HASH.service` e `/var/lib/suc-os/HASH/error`. Corrija a causa e confirme que não há update/reboot ativo antes de recuperar o nó e liberar a trava; não apague a trava para pular uma falha.

## Código do Secret

A separação em vários arquivos de desenvolvimento foi retirada. O código fica no próprio Secret, em `data`/base64, para preservar a compatibilidade com server-side apply do Fleet. Para ler um script, sem aplicar nada:

```bash
kubectl create --dry-run=client -f plano/os-upgrade-secret.yaml -o json |
  jq -r '.data["run.sh"]' | base64 -d
```

Na política, `allowEmptyDirDeletion` autoriza o descarte de dados temporários; `hostPathAllowlist` exige correspondência de namespace, ServiceAccount, tipo de owner e caminho para cada exceção de infraestrutura; `remoteCSIDrivers` lista drivers remotos revisados além de Longhorn (NFS também é reconhecido). A lista de drivers está vazia por padrão: não adicione um backend sem revisar sua operação durante drain.

Chaves: prepare.sh (verificações iniciais), run.sh (fluxo), common.sh (API/log/trava), wait-servers.sh (ordem dos grupos), health.sh (saúde), host-preflight.sh (SO/ferramentas), host-worker.sh (transação/reboot), storage-guard.jq e policy.json (volumes).

Para editar código/política, extraia as chaves para uma pasta temporária vazia, edite e regenere usando o próprio kubectl; não é necessário manter um gerador no projeto:

```bash
suc_fontes=$(mktemp -d)
kubectl create --dry-run=client -f plano/os-upgrade-secret.yaml -o json |
  jq -r '.data | to_entries[] | [.key, .value] | @tsv' |
  while IFS=$'\t' read -r nome conteudo; do
    printf '%s' "$conteudo" | base64 -d > "$suc_fontes/$nome"
  done
# Edite os arquivos em "$suc_fontes" e valide antes de gerar/publicar.
kubectl create secret generic os-maintenance-shared-scripts -n cattle-system \
  --from-file="$suc_fontes" --dry-run=client -o yaml > plano/os-upgrade-secret.yaml
```

## Validação e referências

A rodada **mpba-update-06 concluiu em 18/10/2026** usando `cattle-system/system-upgrade-controller` nos cinco nós. Todos instalaram atualizações do SO e reiniciaram, com mudança real de boot ID e kernel ativo `6.12.0-160000.39-default`. A coleta registrou no máximo um nó cordoned e um container upgrade em execução por vez; os workers só começaram após os três masters. Ao final: dois Plans Complete=True, cinco nós Ready/sem cordon, trava removida, Fleet com 3/3 recursos prontos, volumes Longhorn saudáveis com duas réplicas RW cada, Prometheus Ready e RabbitMQ respondendo. SUC permaneceu ativo, system-agent-upgrader em espera e os cinco objetos de SA/RBAC dedicados estavam removidos. Cada reboot interrompeu o pod original e gerou um pod sucessor do mesmo Job, que concluiu a validação; não houve repetição da transação.

A revisão de prepare/logs passou em 32 testes Python (incluindo nove cenários de ordem entre grupos), verificações Bash de saúde/Longhorn/RKE2, sintaxe dos scripts e dry-run server-side dos dois Plans e Secret. Foram exercitados falha de transação, retomada após reboot, início assíncrono da unidade, ausência de reboot efetivo, snapshot divergente e reprodução incremental dos logs. A execução real desta revisão deve ser confirmada pelos resultados da rodada 07; dry-run não executa manutenção.

A revisão simplificada passou em 26 testes anteriores, nove cenários da espera server/agent, sintaxe Bash e dry-run da API. A rodada mpba-update-05 validou os dois Plans no cluster: três masters primeiro e dois workers depois, com no máximo um container de manutenção ativo e um nó cordoned por vez. Todos executaram transactional-update; não havia pacotes novos e nenhum reiniciou. Ao final, ambos os Plans estavam Complete=True, os cinco nós Ready/sem cordon, sem trava pendente, os dois volumes Longhorn saudáveis com duas réplicas RW e Prometheus/RabbitMQ respondendo. O controller permaneceu ativo e o system-agent-upgrader em espera. Os cenários sem Longhorn e com volumes locais foram validados por testes simulados; o exemplo SLES tradicional não foi executado em host real. Os testes reais das rodadas 03/04 usaram a versão anterior com um Plan; o [relatório permanece no histórico Git](https://github.com/kaioneuhauss/SUC-DS/blob/bba41acf88718051495fdcbab27bd08dc6ade12d/docs/VALIDACAO.md). Não houve novos pacotes nas chamadas de transactional-update anteriores; houve ativação de snapshots pendentes e reboots reais.

Referências: [SUC Plan](https://github.com/rancher/system-upgrade-controller/blob/v0.19.1/doc/plan.md), [SUSE Micro](https://documentation.suse.com/sle-micro/6.2/html/Micro-transactional-updates/index.html), [drain Kubernetes](https://kubernetes.io/docs/tasks/administer-cluster/safely-drain-node/), [Longhorn 1.11.2](https://longhorn.io/docs/1.11.2/maintenance/maintenance/) e [Fleet YAML](https://fleet.rancher.io/explanations/gitrepo-content). [Jobs Kubernetes](https://kubernetes.io/docs/concepts/workloads/controllers/job/) e [systemd-run](https://www.freedesktop.org/software/systemd/man/latest/systemd-run.html). Scripts próprios; não representam homologação formal da SUSE.
