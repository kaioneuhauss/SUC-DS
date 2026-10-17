# AtualizaÃ§Ã£o do SO pelo Fleet

Quatro arquivos de implantaÃ§Ã£o em `plano/`:

| Arquivo | Para que serve |
|---|---|
| `fleet.yaml` | Entrega os YAMLs em cattle-system pelo Fleet. |
| `server-plan.yaml` | Atualiza os trÃªs masters, um por vez. Inclui a conta e as permissÃµes compartilhadas apÃ³s o Plan. |
| `agent-plan.yaml` | Espera os trÃªs masters concluÃ­rem a mesma rodada e atualiza os dois workers, um por vez. |
| `os-upgrade-secret.yaml` | ContÃ©m os scripts compartilhados e a polÃ­tica de volumes. NÃ£o contÃ©m credenciais. |

O exemplo `examples/sles/plano-prod-so.yaml` Ã© alternativo, para SLES tradicional com zypper. O Fleet do MPBA acompanha somente `plano/`.

## Uso no MPBA

1. Espere os dois Plans da rodada anterior terminarem. Confira os cinco nÃ³s Ready.
2. Altere **spec.version nos dois Plans para o mesmo identificador novo**, por exemplo `mpba-update-05`. Mantenha ACTION=update.
3. Publique os quatro YAMLs no mesmo commit da branch main. O GitRepo `fleet-default/suc-os-mpba` entrega os arquivos.
4. Acompanhe os Jobs em cattle-system. Masters primeiro; workers depois. Um Job de worker pode aparecer em Init enquanto espera: ainda nÃ£o executa drain nem update.
5. A rodada acaba quando os dois Plans estÃ£o Complete=True, os cinco nÃ³s estÃ£o Ready/sem cordon e a trava nÃ£o existe mais.

```bash
export KUBECONFIG=/home/kaio/.kube/istio-mpba.yaml
kubectl -n cattle-system get plans
kubectl -n cattle-system get jobs,pods -l upgrade.cattle.io/controller -o wide
kubectl -n cattle-system logs -l upgrade.cattle.io/plan=os-maintenance-server --all-containers --prefix --tail=80
kubectl -n cattle-system logs -l upgrade.cattle.io/plan=os-maintenance-agent --all-containers --prefix --tail=80
kubectl get nodes
kubectl -n cattle-system get cm suc-os-maintenance-gate --ignore-not-found
```

Fleet Ready significa entrega; Complete=True nos dois Plans significa manutenÃ§Ã£o concluÃ­da. NÃ£o edite versÃ£o, parÃ¢metros ou Secret durante Jobs ativos. Qualquer mudanÃ§a de cÃ³digo/configuraÃ§Ã£o deve usar uma nova versÃ£o, igual nos dois Plans, no mesmo commit.

**Esta revisÃ£o simplificada ainda nÃ£o foi publicada nem executada no cluster.** Ela substitui o antigo Plan Ãºnico os-maintenance. PublicÃ¡-la cria dois Plans novos e pode iniciar a rodada 05; faÃ§a a migraÃ§Ã£o somente apÃ³s o Plan antigo terminar e sem Jobs ativos. O Secret novo tem outro nome para nÃ£o disparar o Plan antigo durante a transiÃ§Ã£o. O Fleet deve remover o Plan/Secret antigos e preservar o controller Rancher.

## O que normalmente alterar

| ParÃ¢metro | FunÃ§Ã£o |
|---|---|
| `spec.version` nos dois Plans | Identificador da rodada. Ã‰ o Ãºnico ajuste habitual. |
| `nodeSelector` | Destinos de cada grupo; exige suc-os.cattle.io/enabled=true. |
| `EXPECTED_NODES` | Todos os cinco nÃ³s esperados; nÃ£o apenas o grupo atual. |
| `SERVER_PLAN` / `SERVER_NODES` | Plan e nomes dos trÃªs masters que os workers devem esperar. |
| `concurrency: 1` | Um nÃ³ por vez em cada grupo; a espera entre grupos e a trava compartilhada mantÃªm a fila serial. |
| `PEER_PLAN` | Identifica o outro Plan desta manutenÃ§Ã£o. Seu Job pode estar apenas aguardando; outros Plans ativos bloqueiam. |
| `PROFILE` | micro62 para SUSE Linux Micro; sles somente no exemplo de SLES tradicional. |
| `ACTION` | update no uso normal; prepare-host prepara os agendamentos uma Ãºnica vez. |
| `MANAGE_AUTOMATIC` | Autoriza desativar timer/rebootmgr na preparaÃ§Ã£o; transactional-update continua disponÃ­vel. |
| `ACTIVATE_PENDING` | Permite ativar um snapshot jÃ¡ pendente antes de tentar outra transaÃ§Ã£o. |
| `HEALTH_TIMEOUT` / `STABLE_SECONDS` | AtÃ© 1800 s para recuperar; exige 60 s contÃ­nuos de saÃºde. |
| `DRAIN_TIMEOUT` / `HOST_TIMEOUT` | AtÃ© 30 min para drain e 7200 s para a operaÃ§Ã£o no host. |
| `WAIT_TIMEOUT` | AtÃ© 43200 s aguardando todos os masters, antes da manutenÃ§Ã£o do worker. |
| `jobActiveDeadlineSecs` | Limite total do Job: 18000 s nos masters; 86400 s nos workers, incluindo a espera pelos masters. |
| `postCompleteDelay: 30s` | Intervalo adicional apÃ³s cada sucesso. |
| `upgrade.image` | Imagem fixa por digest. O comando executa nossos scripts, nÃ£o um upgrade do RKE2. |
| `serviceAccountName` / `securityContext` | Conta com permissÃµes dedicadas e privilÃ©gio necessÃ¡rio para operar o host. |
| `secrets` | Monta o cÃ³digo compartilhado em /run/suc-os. |
| `tolerations` | Permitem executar nos masters e em nÃ³s cordoned. |
| `PLAN_NAMESPACE` / `LH_NAMESPACE` | Namespace da manutenÃ§Ã£o e do Longhorn. |
| `exclusive` | Exclusividade no nÃ³; nÃ£o substitui a espera entre os dois Plans. |
| `upgrade.cattle.io/digest` | Inclui configuraÃ§Ã£o da execuÃ§Ã£o no hash; por isso nÃ£o se edita durante uma rodada. |

Os hosts MPBA jÃ¡ foram preparados. SUC permanece ativo e o Plan de system-agent deve continuar com label disabled nos cinco nÃ³s. Para outro ambiente, revisar destinos, imagem, registro SUSE, backup e polÃ­tica de volumes antes da primeira preparaÃ§Ã£o.

## ProteÃ§Ãµes mantidas

- API, nÃ³s Ready/sem pressÃ£o, leases recentes e workloads saudÃ¡veis antes de avanÃ§ar.
- Snapshot etcd antes de cada master; snapshot local nÃ£o substitui backup externo.
- Drain com eviction e PDB. Nenhum force, remoÃ§Ã£o de PDB ou de finalizer.
- Longhorn Ã© opcional: sem grupo/volumes na API, nÃ£o exige rÃ©plicas; falha de consulta bloqueia. Com volumes, espera redundÃ¢ncia e rÃ©plicas RW.
- PVC local, hostPath de aplicaÃ§Ã£o e CSI desconhecido bloqueiam. ExceÃ§Ãµes de infraestrutura ficam na polÃ­tica.
- `allowEmptyDirDeletion: true` na polÃ­tica foi autorizado apenas para os dados temporÃ¡rios deste lab; use false em outro ambiente sem essa autorizaÃ§Ã£o.
- Sem novidades, transactional-update descarta o snapshot vazio e registra que nÃ£o haverÃ¡ reboot.
- Reboot sÃ³ Ã© aceito apÃ³s mudanÃ§a real de boot ID e ativaÃ§Ã£o do root Btrfs esperado.
- Erro preserva a trava e os dados em /var/lib/suc-os/HASH. Nenhum prÃ³ximo nÃ³ Ã© autorizado pela passagem do tempo.

Em erro, leia os logs e `kubectl -n cattle-system get cm suc-os-maintenance-gate -o yaml`. No host envolvido, consulte `journalctl -u suc-os-HASH.service` e `/var/lib/suc-os/HASH/error`. Corrija a causa e confirme que nÃ£o hÃ¡ update/reboot ativo antes de recuperar o nÃ³ e liberar a trava; nÃ£o apague a trava para pular uma falha.

## CÃ³digo do Secret

A separaÃ§Ã£o em vÃ¡rios arquivos de desenvolvimento foi retirada. O cÃ³digo fica no prÃ³prio Secret, em `data`/base64, para preservar a compatibilidade com server-side apply do Fleet. Para ler um script, sem aplicar nada:

```bash
kubectl create --dry-run=client -f plano/os-upgrade-secret.yaml -o json |
  jq -r '.data["run.sh"]' | base64 -d
```

Chaves: run.sh (fluxo), common.sh (API/log/trava), wait-servers.sh (ordem dos grupos), health.sh (saÃºde), host-preflight.sh (SO/ferramentas), host-worker.sh (transaÃ§Ã£o/reboot), storage-guard.jq e policy.json (volumes).

Para editar cÃ³digo/polÃ­tica, extraia as chaves para uma pasta temporÃ¡ria vazia, edite e regenere usando o prÃ³prio kubectl; nÃ£o Ã© necessÃ¡rio manter um gerador no projeto:

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

## ValidaÃ§Ã£o e referÃªncias

A revisÃ£o simplificada passou em 26 testes anteriores, nove cenÃ¡rios da nova espera server/agent, sintaxe Bash e dry-run da API. Ainda requer validaÃ§Ã£o real do fluxo com dois Plans. Os testes reais das rodadas 03/04 usaram a versÃ£o anterior com um Plan; o [relatÃ³rio permanece no histÃ³rico Git](https://github.com/kaioneuhauss/SUC-DS/blob/bba41acf88718051495fdcbab27bd08dc6ade12d/docs/VALIDACAO.md). NÃ£o houve novos pacotes nas chamadas de transactional-update anteriores; houve ativaÃ§Ã£o de snapshots pendentes e reboots reais.

ReferÃªncias: [SUC Plan](https://github.com/rancher/system-upgrade-controller/blob/v0.19.1/doc/plan.md), [SUSE Micro](https://documentation.suse.com/sle-micro/6.2/html/Micro-transactional-updates/index.html), [drain Kubernetes](https://kubernetes.io/docs/tasks/administer-cluster/safely-drain-node/), [Longhorn 1.11.2](https://longhorn.io/docs/1.11.2/maintenance/maintenance/) e [Fleet YAML](https://fleet.rancher.io/explanations/gitrepo-content). Scripts prÃ³prios; nÃ£o representam homologaÃ§Ã£o formal da SUSE.
