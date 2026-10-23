# Atualização do SO pelo Fleet e SUC

Fluxo semelhante à manutenção manual: **verificar nós → drain → atualizar o SO → reboot se solicitado → uncordon e recuperação**. O SUC executa um nó por vez; os workers aguardam os servidores da mesma rodada.

| Diretório | Sistema | Arquivos |
|---|---|---|
| `sle-micro/` | SUSE Linux Micro 6.2 | `fleet.yaml`, `server-plan.yaml`, `agent-plan.yaml`, `os-upgrade-secret.yaml` |
| `opensuse-sles/` | openSUSE Leap / SLES tradicional | `fleet.yaml`, `server-plan.yaml`, `os-upgrade-secret.yaml` |
| `ubuntu/` | Ubuntu 22.04 / 24.04 | `fleet.yaml`, `server-plan.yaml`, `agent-plan.yaml`, `os-upgrade-secret.yaml` |

Não há chart próprio, ConfigMap de trava, anotações de preparação, Jobs auxiliares, lista de nomes de nós ou lista de caminhos hostPath. Não são criados nem apagados snapshots etcd. O Micro continua usando os snapshots de SO necessários ao transactional-update.

## Uso direto

1. Confira que o cluster tem o **System Upgrade Controller**, o CRD `plans.upgrade.cattle.io` e a ServiceAccount `system-upgrade-controller` em `cattle-system`. Criar os Plans não instala o controller.
2. Escolha **somente um diretório**, conforme o SO. No Fleet, configure o GitRepo para esse caminho e para o cluster correto. Não aponte para a raiz nem combine perfis no mesmo cluster.
3. Confira a imagem de ferramentas dos Plans, os seletores de função e `drain.deleteEmptydirData`. Os exemplos deste lab estão em `true`: o drain pode descartar dados temporários em `emptyDir`. Para um ambiente que não autorize essa perda, mude para `false` antes de aplicar; nesse caso, o drain interrompe a atualização se encontrar esses Pods. PVCs não são apagados por essa opção.
4. Publique os arquivos no Git. O primeiro deploy já inicia a rodada definida em `version`.
5. Nas próximas manutenções, altere **somente `version`**, com o mesmo valor nos Plans de servers e agents. Exemplo: `os-20261021-01`. Aguarde uma rodada concluir antes de publicar outra.

`version` é um identificador da execução, não a versão de destino do SO. Os comandos instalam os updates dos repositórios configurados no próprio nó; não fazem migração de release.

O Secret usa `ignoreUpdates: true`: editar seu conteúdo sozinho **não** dispara outra rodada. Publique alterações de script/imagem/parametrização junto com uma nova `version` quando quiser executá-las. Não troque o script durante uma rodada ativa.

## Parâmetros dos Plans

| Parâmetro | Função |
|---|---|
| `concurrency: 1` | Um nó em execução por Plan. A espera dos workers pelos servidores mantém a ordem entre os dois Plans. |
| `exclusive: true` | Evita outro Plan exclusivo simultâneo no mesmo nó; não é uma trava global. |
| `jobActiveDeadlineSecs: 0` | Não mata uma instalação de pacotes por um limite total de Job. Drain e espera de saúde têm limites próprios. |
| `postCompleteDelay: 30s` | Pausa adicional entre os nós. |
| `serviceAccountName` | Usa a conta existente do SUC. Ela precisa das permissões de leitura e drain/uncordon necessárias; não são criados novos RBACs. |
| `nodeSelector` | Descobre servidores por `control-plane`; workers não têm `control-plane` nem `etcd`. Ajuste apenas se a topologia usar outros papéis. |
| `tolerations` | Permite executar nos servidores com taints e em nós cordonados. |
| `cordon` / `drain` | O próprio SUC cria o init container `drain`; o update só inicia depois de seu sucesso. |
| `drain.timeout: 15m` | Tempo máximo de cada tentativa de drain. |
| `drain.ignoreDaemonSets: true` | DaemonSets não são removidos pelo drain. |
| `drain.force: false` | Não força remoção de Pods sem controlador. |
| `drain.deleteEmptydirData: false` | Exige decisão explícita antes de descartar dados temporários de Pods. |
| `drain.disableEviction: false` | Mantém PDBs e o mecanismo de eviction. |
| `secrets.path` | Monta os scripts em `/run/suc-os`. `stringData` permite editá-los como texto. |
| `secrets.ignoreUpdates: true` | Mantém o disparo sob controle de `version`, em vez de disparar por qualquer edição do Secret. |
| `prepare.image` / `upgrade.image` | Imagem de ferramentas com Bash, kubectl e jq; não executa upgrade do Kubernetes. A âncora `&tools` e `*tools` reutilizam a mesma imagem. |
| `SERVER_PLAN` | Somente no agent: nome do Plan de servidores que precisa concluir a mesma versão. |
| `privileged` / `runAsUser: 0` | Permitem executar o gerenciador de pacotes e o reboot no host via `chroot /host`. |

A imagem do init container `drain` é definida na configuração do **controller** (`SYSTEM_UPGRADE_JOB_KUBECTL_IMAGE`); ela não é a imagem de ferramentas do Plan. Ambas precisam fornecer kubectl compatível com a API do cluster.

## Scripts dentro do Secret

São quatro blocos pequenos, dentro de um único YAML:

- `common.sh`: logs coloridos, consulta dos nós pelo IP interno da API e recuperação do Longhorn quando instalado. Falhas transitórias da API são repetidas até o limite de saúde; falha persistente interrompe. Ausência de Longhorn é normal.
- `prepare.sh`: nos workers, espera o Plan de servidores; depois verifica nós `Ready`, pressão e cordon dos outros nós. O cordon do próprio nó não bloqueia a retomada. Não escreve objetos Kubernetes.
- `upgrade.sh`: só é iniciado após o drain nativo. Executa o script do SO no host, faz uncordon e espera a recuperação antes de concluir o Job.
- `host-update.sh`: identifica o SO, executa seu gerenciador de pacotes e reinicia apenas quando necessário. Um pequeno registro em `/var/lib/suc-os-simple/HASH/` permite retomar após reboot sem instalar tudo novamente; não é uma trava e não precisa ser excluído para operar uma nova versão.

Os limites opcionais de `common.sh` são `HEALTH_TIMEOUT=900` (15 minutos), `STABLE_SECONDS=30` (saúde contínua), `POLL_SECONDS=10` e `LOG_COLOR=true`. O worker espera servidores por até `SERVER_WAIT_TIMEOUT=43200` (12 horas). São variáveis de ambiente do container correspondente; normalmente não precisam mudar.

| Perfil | Atualização | Pedido de reboot |
|---|---|---|
| Micro | `transactional-update --non-interactive --drop-if-no-change up` | Uma nova raiz Btrfs precisa ser ativada. Sem alteração, não reinicia. Se já houver snapshot pendente, ativa-o primeiro e informa que uma nova consulta de pacotes fica para outra rodada. |
| openSUSE/SLES | `zypper --non-interactive refresh` e `zypper --non-interactive update` | Retorno 102 do Zypper/`needs-rebooting`. Outros erros interrompem; não é feita busca por palavras como `kernel` na saída. |
| Ubuntu | `apt-get update` e `apt-get --assume-yes --with-new-pkgs --no-remove upgrade` | `/run/reboot-required`. Preserva arquivos locais de configuração e não permite remoção automática de pacotes. |

No Ubuntu, `needrestart` apenas lista serviços que precisam de restart; não reinicia o RKE2 no meio do `apt`. Se o Ubuntu não pedir reboot, planeje o restart dos serviços listados em uma manutenção separada.

Um pedido de reboot que já estava pendente também é atendido depois do drain. Durante o reboot, o Pod pode terminar e o Job criar outro: o registro local confirma a mudança do boot antes de concluir. Com drain nativo, uma nova tentativa de Pod passa novamente por `prepare` e `drain`; não repete a instalação já registrada.

## Saber se a rodada terminou

O Deployment `system-upgrade-controller` normalmente continua em execução depois da manutenção. Para saber se **o update do SO** ainda está em andamento, consulte os Plans e os Jobs:

```bash
kubectl -n cattle-system get plans
kubectl -n cattle-system get jobs -l 'upgrade.cattle.io/plan in (os-maintenance-server,os-maintenance-agent,os-maintenance-zypper)'
kubectl get nodes
```

Em Ubuntu e SLE Micro, aguarde `COMPLETE=True` nos Plans `os-maintenance-server` e `os-maintenance-agent`. Em openSUSE/SLES, confira apenas `os-maintenance-zypper`. `COMPLETE=False` com Job ativo indica que a rodada continua; `COMPLETE=False` sem Job ativo exige conferir o Plan e os eventos, pois ela pode estar bloqueada. Durante a manutenção, o nó pode aparecer como `Ready,SchedulingDisabled`; ao final, confira que voltou a `Ready` sem cordon. Jobs concluídos podem permanecer visíveis até a limpeza automática configurada no controller (900 segundos no lab); isso não significa que ainda estejam atualizando. A condição `COMPLETE=True` não comprova que todas as aplicações voltaram a ficar prontas.

Para acompanhar mudanças em tempo real, acrescente `-w` ao comando `kubectl get plans`.

## Acompanhar e tratar uma falha

```bash
kubectl -n cattle-system get pods -l upgrade.cattle.io/plan -o wide
kubectl -n cattle-system logs NOME_DO_POD -c prepare
kubectl -n cattle-system logs NOME_DO_POD -c drain
kubectl -n cattle-system logs NOME_DO_POD -c upgrade -f
```

Se o `drain` falhar, **o gerenciador de pacotes não é iniciado**. O nó permanece cordonado. Leia o Pod/PDB apontado pelo kubectl e corrija a causa, como falta de capacidade, Pod em encerramento, réplica Longhorn indisponível ou emptyDir sem autorização de descarte:

```bash
kubectl get pods -A --field-selector spec.nodeName=NOME_DO_NO -o wide
kubectl get pdb -A
kubectl -n NAMESPACE_DO_POD describe pod NOME_DO_POD
kubectl -n cattle-system describe job NOME_DO_JOB
```

O Kubernetes/SUC pode repetir o **mesmo nó**, conforme o backoff configurado no controller. Ele não marca esse nó concluído em uma falha. Corrija o motivo antes de retomar; não exclua PDBs/finalizers nem use `--disable-eviction` para contornar storage. Se o Job ainda estiver tentando, acompanhe a próxima tentativa. Se já falhou definitivamente, após corrigir a causa e confirmar que não há instalação/reboot ativo, exclua somente o Job daquele nó e solicite reconciliação do Plan correspondente com os comandos abaixo. A anotação apenas desperta o controller: não é uma trava nem um requisito de preparação. Não é necessário remover ConfigMap ou executar uma nova rodada em todos os nós.

```bash
kubectl -n cattle-system delete job NOME_DO_JOB --wait=true
kubectl -n cattle-system annotate plan NOME_DO_PLAN \
  suc-os.cattle.io/reconcile="$(date -u +%Y%m%dT%H%M%SZ)" --overwrite
```

Se decidir cancelar a manutenção antes do update, encerre a tentativa antes de executar `kubectl uncordon NOME_DO_NO`. Não faça uncordon durante instalação/reboot.

## Volumes e limites do procedimento

O drain nativo é a fonte da decisão de evacuação, como num procedimento manual. O Longhorn precisa estar configurado com sua política de drain e PDBs; no lab foi conferido `node-drain-policy=block-if-contains-last-replica`. **Não há lista própria de hostPath:** `/var/lib/longhorn/metadata` não recebe tratamento especial nem produz o erro da implementação anterior.

`kubectl drain` não é um validador universal de dados: um PVC local/hostPath de aplicação pode ser evicto e ficar Pending em outro nó; isso não prova portabilidade nem garante proteção contra corrupção. Dados locais persistentes exigem a estratégia da aplicação/storage, assim como na manutenção manual. `emptyDir` só é descartado com a opção explícita do Plan. Nenhum comando deste procedimento apaga PVCs.

A verificação final exige nós saudáveis e Longhorn recuperado quando instalado. Ela não exige todas as aplicações do cluster prontas nem interfere em serviços externos desligados. Coordene a janela com updates/reboots automáticos do SO, upgrades de Kubernetes/Rancher e backups: este fluxo não cria Jobs para desativar serviços de outros nós. No lab, os agendamentos automáticos já estavam desativados pelo procedimento anterior.

## Migrar da versão anterior

1. Aguarde qualquer instalação/reboot ativo terminar. Encerre as tentativas antigas de OS que falharam antes de atualizar o Secret; um Pod antigo continua executando o script que carregou.
2. Substitua os Plans e o Secret deste perfil pelo Fleet, com uma nova `version` comum aos dois Plans. Não remova os Plans de Kubernetes/Rancher.
3. O código novo não consulta nem cria `suc-os-maintenance-gate`. Depois de encerrar os Jobs antigos, esse ConfigMap antigo pode ser excluído uma única vez. Os Jobs `suc-os-schedules-*` concluídos também não são mais utilizados. Não apague arquivos de estado do host durante uma transação antiga.
4. Se a falha antiga deixou o nó cordonado antes do update, a nova preparação aceita o cordon do próprio nó e executa o drain normalmente; não é necessário liberar o agendamento para contornar a validação.

## Base e validação

A estrutura foi comparada com o [exemplo do Matheus Nagata](https://github.com/matheusnagata/fleet/blob/main/os-upgrade-sles/server-plan.yaml). Foram adotados o drain nativo e o fluxo direto. Diferenças: falhas de API não passam silenciosamente, o reboot usa a indicação do SO, os workers esperam os servidores e o descarte de emptyDir/remoção forçada não são habilitados por padrão.

Referências: [ordem prepare/drain/upgrade no SUC](https://github.com/rancher/system-upgrade-controller/blob/v0.19.1/pkg/upgrade/job/job.go), [drain do Kubernetes](https://kubernetes.io/docs/tasks/administer-cluster/safely-drain-node/), [manutenção de nós com Longhorn](https://longhorn.io/docs/1.11.2/maintenance/maintenance/).

Validação em 20/10/2026, usando SUC v0.19.1 e RKE2 v1.35.6:

- **SUSE Linux Micro 6.2:** cinco nós concluíram a rodada pelo Fleet, servidores antes dos workers, sem sobreposição de atualizações no cluster. O drain dos workers aguardou os PDBs do Longhorn; após uncordon, o script aguardou a recuperação dos volumes antes de concluir.
- **openSUSE Leap 16:** três servidores concluíram a rodada pelo Fleet, sem Longhorn. O código tratou a ausência do CRD normalmente.
- **Sem updates disponíveis:** transactional-update e Zypper executaram consultas reais, sem novos pacotes. Nenhum dos oito nós reiniciou; os identificadores de boot permaneceram iguais.
- **Falha por emptyDir:** o drain nativo interrompeu a tentativa, e o container upgrade não iniciou. Depois da autorização de descarte apenas no lab, a tentativa seguinte aceitou o próprio nó já cordonado e concluiu.
- **Falha por PDB:** um Pod temporário com PDB bloqueando eviction fez o drain repetir as tentativas até o timeout de 20s configurado somente no teste. O container upgrade permaneceu sem iniciar. Os recursos do teste foram removidos e o nó liberado.
- **Sem trava própria:** nenhum ConfigMap suc-os-maintenance-gate foi criado durante as rodadas. A criação de Jobs suc-os-schedules também foi removida.
- **Validação local:** sintaxe dos YAMLs e scripts, dry-run na API e cenários simulados de falha de API, cordon, saúde, Longhorn ausente/degradado, falha do gerenciador de pacotes e reboot/retomada dos três perfis.

Os Plans atuais deste lab usam `deleteEmptydirData: true`; revise esse valor antes de copiar para outro cluster. Em 23/10/2026, uma rodada Ubuntu real instalou pacotes e reiniciou masters, revelando uma falha transitória de DNS no `prepare` após reboot. Os três perfis agora usam o IP interno da API e aguardam sua recuperação; a correção passou na validação local, mas uma nova rodada completa com o código corrigido ainda depende da execução manual. Esses testes não comprovam todos os ambientes de cliente.
