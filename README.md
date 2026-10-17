# Atualização do SO pelo Fleet

Quatro arquivos de implantação em `plano/`:

| Arquivo | Para que serve |
|---|---|
| `fleet.yaml` | Entrega os YAMLs em cattle-system pelo Fleet. |
| `server-plan.yaml` | Atualiza os três masters, um por vez. Inclui a conta e as permissões compartilhadas após o Plan. |
| `agent-plan.yaml` | Espera os três masters concluírem a mesma rodada e atualiza os dois workers, um por vez. |
| `os-upgrade-secret.yaml` | Contém os scripts compartilhados e a política de volumes. Não contém credenciais. |

O exemplo `examples/sles/plano-prod-so.yaml` é alternativo, para SLES tradicional com zypper. O Fleet do MPBA acompanha somente `plano/`.

## Uso no MPBA

1. Espere os dois Plans da rodada anterior terminarem. Confira os cinco nós Ready.
2. Altere **spec.version nos dois Plans para o mesmo identificador novo**, por exemplo `mpba-update-06`. Mantenha ACTION=update.
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

Fleet Ready significa entrega; Complete=True nos dois Plans significa manutenção concluída. Não edite versão, parâmetros ou Secret durante Jobs ativos. Qualquer mudança de código/configuração deve usar uma nova versão, igual nos dois Plans, no mesmo commit.

**Esta revisão simplificada está publicada pelo Fleet e validada na rodada mpba-update-05.** Ela substituiu o Plan único os-maintenance pelos Plans server/agent. O Fleet removeu o Plan e o Secret antigos, preservou o controller Rancher e confirmou os oito recursos prontos. A próxima rodada deve usar um identificador novo nos dois Plans, por exemplo mpba-update-06.

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
| `upgrade.image` | Imagem fixa por digest. O comando executa nossos scripts, não um upgrade do RKE2. |
| `serviceAccountName` / `securityContext` | Conta com permissões dedicadas e privilégio necessário para operar o host. |
| `secrets` | Monta o código compartilhado em /run/suc-os. |
| `tolerations` | Permitem executar nos masters e em nós cordoned. |
| `PLAN_NAMESPACE` / `LH_NAMESPACE` | Namespace da manutenção e do Longhorn. |
| `exclusive` | Exclusividade no nó; não substitui a espera entre os dois Plans. |
| `upgrade.cattle.io/digest` | Inclui configuração da execução no hash; por isso não se edita durante uma rodada. |

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

Chaves: run.sh (fluxo), common.sh (API/log/trava), wait-servers.sh (ordem dos grupos), health.sh (saúde), host-preflight.sh (SO/ferramentas), host-worker.sh (transação/reboot), storage-guard.jq e policy.json (volumes).

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

A revisão simplificada passou em 26 testes anteriores, nove cenários da espera server/agent, sintaxe Bash e dry-run da API. A rodada mpba-update-05 validou os dois Plans no cluster: três masters primeiro e dois workers depois, com no máximo um container de manutenção ativo e um nó cordoned por vez. Todos executaram transactional-update; não havia pacotes novos e nenhum reiniciou. Ao final, ambos os Plans estavam Complete=True, os cinco nós Ready/sem cordon, sem trava pendente, os dois volumes Longhorn saudáveis com duas réplicas RW e Prometheus/RabbitMQ respondendo. O controller permaneceu ativo e o system-agent-upgrader em espera. Os cenários sem Longhorn e com volumes locais foram validados por testes simulados; o exemplo SLES tradicional não foi executado em host real. Os testes reais das rodadas 03/04 usaram a versão anterior com um Plan; o [relatório permanece no histórico Git](https://github.com/kaioneuhauss/SUC-DS/blob/bba41acf88718051495fdcbab27bd08dc6ade12d/docs/VALIDACAO.md). Não houve novos pacotes nas chamadas de transactional-update anteriores; houve ativação de snapshots pendentes e reboots reais.

Referências: [SUC Plan](https://github.com/rancher/system-upgrade-controller/blob/v0.19.1/doc/plan.md), [SUSE Micro](https://documentation.suse.com/sle-micro/6.2/html/Micro-transactional-updates/index.html), [drain Kubernetes](https://kubernetes.io/docs/tasks/administer-cluster/safely-drain-node/), [Longhorn 1.11.2](https://longhorn.io/docs/1.11.2/maintenance/maintenance/) e [Fleet YAML](https://fleet.rancher.io/explanations/gitrepo-content). Scripts próprios; não representam homologação formal da SUSE.
