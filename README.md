# Atualização do SO pelo Fleet

O uso normal é **alterar `version` e publicar no Git**. O Fleet entrega os YAMLs; o SUC atualiza um nó por vez e só libera o próximo depois da recuperação do cluster.

| Diretório | Sistema / cluster | Arquivos para operar |
|---|---|---|
| `sle-micro/` | **SLE Micro 6.2**, cluster downstream | `fleet.yaml`, `server-plan.yaml`, `agent-plan.yaml`, `os-upgrade-secret.yaml` |
| `opensuse-sles/` | **openSUSE Leap / SLES tradicional**, Rancher | `fleet.yaml`, `server-plan.yaml`, `os-upgrade-secret.yaml` |
| `ubuntu/` | **Ubuntu Server 22.04 / 24.04 LTS**, cluster RKE2 | `fleet.yaml`, `server-plan.yaml`, `agent-plan.yaml`, `os-upgrade-secret.yaml` |

São três diretórios independentes, um por família de SO. O mesmo perfil `ubuntu/` atende 22.04 e 24.04; não é necessário duplicá-lo por versão.

Cada diretório é independente e tem seu próprio Secret. Configure o GitRepo com **apenas o caminho e o cluster correspondentes**; não aponte para a raiz do repositório nem aplique mais de um perfil no mesmo cluster. O GitRepo do cluster SLE Micro deve acompanhar `sle-micro/`. Os identificadores do bundle e do release usam o nome genérico `suc-os-sle-micro`. Não há chart próprio, gerador ou instalação de Python.

**Instalações existentes:** se o bundle ou o release já usa outro nome, planeje a migração antes de publicar estes identificadores genéricos. A troca de nomes não é uma alteração apenas visual e pode recriar recursos no Fleet. Comentários dentro de `stringData` também fazem parte do conteúdo do Secret e sua alteração pode disparar uma nova execução do SUC.

Função dos arquivos:

| Arquivo | Função |
|---|---|
| `fleet.yaml` | Namespace e nome do release usado internamente pelo Fleet. |
| `server-plan.yaml` | Seleciona Linux com label control-plane e atualiza um server por vez. |
| `agent-plan.yaml` | Seleciona Linux sem control-plane/etcd; espera os servers da mesma rodada. |
| `os-upgrade-secret.yaml` | Scripts e política em texto legível (`stringData`), sem credenciais. |

Todos os Plans reutilizam a ServiceAccount `cattle-system/system-upgrade-controller`, já existente. Este projeto não cria Roles, bindings ou outra conta. Os Jobs herdam as permissões dessa conta; confira o RBAC existente, inclusive eventual cluster-admin. O SUC, a conta e as permissões são pré-requisitos para outro cluster.

## Snapshots etcd sob controle do operador

Os três perfis **não criam snapshots etcd automaticamente** durante o update do SO. O comando `rke2 etcd-snapshot save` foi retirado dos scripts. A criação do backup fica sob controle do operador, antes da manutenção quando necessário; os snapshots etcd existentes são preservados.

Nos clusters em que o Rancher oferece essa ação, use **Cluster Management → cluster → Snapshots → Snapshot Now** e aguarde a conclusão antes de publicar a rodada. No cluster local/importado sem essa opção, use o procedimento de backup próprio desse cluster. [Snapshots manuais no Rancher](https://ranchermanager.docs.rancher.com/v2.14/how-to-guides/new-user-guides/backup-restore-and-disaster-recovery/back-up-rancher-launched-kubernetes-clusters).

Esta alteração é apenas no procedimento de SO: os agendamentos de snapshots configurados no Rancher/RKE2 continuam independentes. Os snapshots Btrfs usados pelo `transactional-update` no SLE Micro também continuam, pois são parte do mecanismo de atualização do SO, distintos do backup etcd. `--drop-if-no-change` descarta somente o snapshot da transação sem alterações e preserva o comportamento de não reiniciar nesse caso. [Funcionamento do transactional-update no Micro 6.2](https://documentation.suse.com/sle-micro/6.2/html/Micro-transactional-updates/index.html).

## Passo a passo: SLE Micro 6.2

1. No Rancher, confirme os nós Ready, os dois Plans anteriores Complete=True e ausência de manutenção em andamento. O Fleet Ready confirma a entrega dos arquivos, não o término do update.
2. Abra `sle-micro/server-plan.yaml` e altere somente `spec.version`, por exemplo:
   ```yaml
   version: sles-20261019-01
   ```
3. Coloque **exatamente o mesmo valor novo** em `sle-micro/agent-plan.yaml`. Use um identificador que nunca foi executado. `sles-20261019-01` é apenas um nome de rodada: não instala uma release específica do SO e não atualiza Kubernetes.
4. Publique os dois arquivos juntos na branch `main` acompanhada pelo GitRepo configurado para o cluster SLE Micro. Pela interface do GitHub, edite ambos na mesma branch e integre o PR depois das duas alterações. Não faça dois commits separados diretamente em main durante uma rodada.
5. No Rancher, abra os Pods do namespace `cattle-system`. Leia **prepare** para acompanhar espera/validações e depois **upgrade** para drain, atualização e resultado.
6. Aguarde ambos os Plans Complete=True, nós Ready/sem cordon e ausência da trava `suc-os-maintenance-gate`. Só então inicie outra rodada.

Não é necessário editar scripts, conhecer Bash ou usar Python para esse procedimento. O `transactional-update --non-interactive --drop-if-no-change up` procura as atualizações disponíveis nos repositórios configurados no host. Sem alterações, informa que **não reiniciará** e libera o próximo nó após validar a saúde. O drain ainda pode mover workloads mesmo quando não há pacotes novos.

## Passo a passo: openSUSE Leap / SLES

1. No cluster Rancher, confirme todos os nós Ready, aplicações saudáveis e nenhuma manutenção em andamento.
2. Abra `opensuse-sles/server-plan.yaml`. Depois da preparação inicial, `ACTION` permanece em `update` e `PROFILE` em `zypper`.
3. Altere **somente `version`**, por exemplo `opensuse-20261019-01`, na branch acompanhada pelo GitRepo. Este perfil fornece um Plan para clusters compostos somente de servidores.
4. Configure o GitRepo para acompanhar somente `opensuse-sles/` e selecionar exclusivamente o cluster desejado. O Plan de SO chama-se `os-maintenance-zypper`; ele é separado de Plans usados para atualizar Kubernetes.
5. Acompanhe `prepare` e `upgrade` em `cattle-system`. Aguarde o Plan Complete=True, todos os nós Ready/sem cordon e ausência da trava antes de outra rodada.

A versão principal exige todas as aplicações saudáveis. Uma exceção temporária deve ser avaliada pelo operador e mantida fora deste procedimento padrão.

O comando é `zypper --non-interactive patch --with-update --with-interactive`: aplica patches e atualiza os pacotes sem patch correspondente. O retorno 103 indica atualização do próprio gerenciador; o script repete a operação, no máximo três vezes. O retorno 102 indica necessidade de reboot. Falhas de repositório, dependências ou scripts RPM interrompem o procedimento. Não há troca de release, `dist-upgrade`, aceitação forçada de licenças ou desativação de GPG.

O inventário RPM é comparado antes/depois. **Atualizar pacotes não provoca reboot por si só:** o reinício ocorre apenas se `zypper patch` ou `zypper needs-rebooting` retornar **102**. Com pacotes alterados e sem pedido de reboot, registra `updated-no-reboot` e valida o cluster sem reiniciar o nó. Sem alteração e sem reboot pendente, registra `no-change-no-reboot`. Serviços do host podem precisar de reinício conforme os patches; use `zypper ps -s` para avaliar processos que ainda usam arquivos antigos. Um reboot pendente anterior sem atualização nesta rodada exige avaliação, em vez de ser ignorado. Esse perfil aceita SLES e openSUSE **Leap** com raiz gravável; rejeita Micro transacional e Tumbleweed.

## Passo a passo: Ubuntu Server 22.04 e 24.04

Este perfil atualiza pacotes **dentro da release instalada**. Não migra de Ubuntu 22.04 para 24.04, não muda repositórios e não instala/atualiza RKE2 por conta própria. Exige RKE2, SUC e a ServiceAccount existente, assim como os outros perfis. A seleção automática atende clusters Ubuntu; não é um exemplo para misturar perfis de SO no mesmo cluster.

1. Confira backup manual, saúde, capacidade, repositórios e a tag RKE2 dos dois Plans. Os nós precisam de `apt-get`, `dpkg`, `needrestart`, `update-notifier-common` e `fuser` (pacote `psmisc`), além das ferramentas básicas verificadas pelo script. A checagem bloqueia se faltar alguma ferramenta, houver dpkg incompleto, processo usando locks, reboot anterior pendente ou pouco espaço. Não apaga locks nem tenta reparar pacotes automaticamente.
2. No Fleet, configure o GitRepo para **somente `ubuntu/`**, a branch desejada e o cluster Ubuntu correspondente. Não selecione a raiz do repositório. Mantenha os dois Plans com a mesma `version`.
3. A primeira versão já vem com **`ACTION: prepare-host`** e `version: ubuntu-prepare-20261019-01`. Publique para preparar os agendamentos; essa fase não instala atualizações nem reinicia. Ela desativa `apt-daily.timer` e `apt-daily-upgrade.timer` e grava `/etc/apt/apt.conf.d/99-suc-os-periodic`, com `APT::Periodic::Enable "0"` e `Unattended-Upgrade::Automatic-Reboot "false"`. O APT manual/SUC continua funcionando. Uma transação automática já ativa bloqueia e deve terminar normalmente.
4. Aguarde os dois Plans concluírem. Nos dois arquivos, mude **`ACTION` para `update`** e use a mesma nova `version`, por exemplo `ubuntu-20261020-01`. Mantenha `PROFILE: ubuntu`. Publique os dois juntos.
5. Acompanhe `prepare` e `upgrade` no Rancher. O fluxo é: saúde → trava → drain → APT → reboot **somente se solicitado** → validação → próximo nó. Sem pedido de reboot, verifica a recuperação sem reiniciar.
6. Nas rodadas seguintes, altere apenas **`version` nos dois Plans**. Aguarde ambos Complete=True, nós Ready/sem cordon e trava ausente antes de outra rodada. `Fleet Ready` confirma entrega, não conclusão da manutenção.

No Ubuntu, `allowEmptyDirDeletion` começa em **false**: o descarte autorizado para os outros labs não vale automaticamente neste cluster. Se o drain bloquear por `emptyDir`, avalie os dados indicados antes de autorizar uma exceção. Longhorn continua opcional; volumes locais e backends não revisados bloqueiam.

| Comando / parâmetro Ubuntu | Função |
|---|---|
| `apt-get -o APT::Update::Error-Mode=any update` | Atualiza os índices; falha de repositório, inclusive transitória, interrompe o fluxo. |
| `apt-get check` e `dpkg --audit` | Verificam dependências e instalações incompletas; não executam recuperação automática. |
| `upgrade --with-new-pkgs --no-remove` | Atualiza pacotes, permitindo novas dependências, sem remover pacotes. Mantém holds e políticas de phased updates. |
| `--assume-yes` / `DEBIAN_FRONTEND=noninteractive` | Execução sem perguntas. Erros continuam bloqueando a manutenção. |
| `--force-confold` / `UCF_FORCE_CONFFOLD=1` | Preservam configurações locais em conflitos; revisar depois arquivos `.dpkg-dist`/equivalentes. Não desativam assinaturas ou validação de dependências. |
| `DPkg::Lock::Timeout=60` | Aguarda até 60 s por lock nas operações de pacotes. Não remove locks nem encerra quem os mantém. |
| `NEEDRESTART_MODE=a` / `needrestart -r a` | Tratam reinícios de serviços dentro da manutenção do nó. Reinício de serviço é diferente de reboot do SO. |
| `/run/reboot-required` | Indicação usada para reiniciar o Ubuntu após alteração de pacotes; o helper de `update-notifier-common` é obrigatório. Os pacotes indicados em `.pkgs` aparecem no log, quando disponíveis. |

O script compara o inventário dpkg antes/depois. Sem alterações: `no-change-no-reboot`. Com alterações e sem solicitação de reboot: `updated-no-reboot`. Com alterações e `/run/reboot-required`: `updated-and-rebooted`, confirmado pelo boot ID. Um reboot já pendente antes da rodada bloqueia para avaliação; não é atribuído à atualização atual. A saída APT informa pacotes retidos; nenhuma alteração de inventário não significa que todo pacote existente no repositório possa ser instalado.

A preparação dos agendamentos permanece aplicada após uma falha. O estado inicial está em `/var/lib/suc-os/automatic-units-before.txt`; se já havia o drop-in gerenciado, sua cópia fica em `apt-periodic-before.conf`. Para voltar ao agendamento anterior, termine a manutenção, restaure/remova somente esse drop-in conforme o estado inicial e reative os timers que estavam habilitados. Não deixe APT automático concorrendo com outra rodada SUC.

[APT Ubuntu 22.04](https://manpages.ubuntu.com/manpages/jammy/man8/apt-get.8.html), [APT Ubuntu 24.04](https://manpages.ubuntu.com/manpages/noble/man8/apt-get.8.html), [dpkg](https://manpages.ubuntu.com/manpages/noble/man1/dpkg.1.html) e [atualizações automáticas no Ubuntu](https://ubuntu.com/server/docs/how-to/software/automatic-updates/).

## Quando cada perfil reinicia

| Perfil | Condição de reboot |
|---|---|
| SLE Micro 6.2 | Nova raiz transacional preparada ou snapshot anteriormente pendente autorizado. A ativação dessa raiz exige reboot. |
| openSUSE Leap / SLES | Pacotes alterados e indicação 102 de `patch` ou `needs-rebooting`. |
| Ubuntu 22.04 / 24.04 | Pacotes alterados e `/run/reboot-required`. |

Sem alterações, nenhum perfil solicita reboot. Falha interrompe a sequência e mantém a trava; não desfaz pacotes já instalados. Os perfis tradicionais podem reiniciar serviços durante a instalação sem reiniciar o SO.

## Imagem: quando alterar

A imagem está por tag, sem `@sha256`. Para RKE2 `v1.35.6+rke2r1`, usamos:

```yaml
image: &maintenance_image registry.rancher.com/rancher/rke2-upgrade:v1.35.6-rke2r1
```

`&maintenance_image` dá um nome a esse valor; `image: *maintenance_image` no upgrade reutiliza a mesma imagem. Assim, há **uma tag para editar em cada Plan**. Quando atualizar o RKE2 pelo Rancher, revise a tag correspondente nos dois arquivos, confirme que ela existe no registry e publique com uma nova `version`, numa janela de manutenção. Não use `latest`.

Essa é a imagem de ferramentas de upgrade do RKE2, não a imagem do kube-apiserver. O `command` dos Plans executa nossos scripts de SO em vez do upgrade do RKE2. O script verifica a compatibilidade do kubectl com a API (no máximo uma versão minor de diferença), além das ferramentas necessárias. A correspondência de tag deve ser revista após cada upgrade do cluster; não é uma garantia para toda versão futura. Sem digest, o conteúdo depende da tag publicada no registry.

No laboratório SLE Micro 6.2, o sistema anuncia `SUSE Linux Enterprise Server 16.0` em `PRETTY_NAME` por compatibilidade. O perfil exige também `VARIANT_ID=transactional`, `SUSE_SUPPORT_PRODUCT=SUSE Linux Micro` e versão do produto `6.2` (ou o ID Micro equivalente). Por isso uma linha do host pode mostrar SLES 16.0 enquanto a ação identifica corretamente SLE Micro 6.2. O perfil tradicional rejeita esse host transacional.

## Seleção e descoberta dos nós

Não há nomes de hosts nos Plans. O Kubernetes fornece os nomes e labels pela API:

- Server: Linux com `node-role.kubernetes.io/control-plane`.
- Worker: Linux sem `node-role.kubernetes.io/control-plane` e sem `node-role.kubernetes.io/etcd`.
- A saúde considera todos os nós encontrados, inclusive os do outro grupo. A lista fica fixa durante o Job e é gravada na trava para sobreviver a reboot. Se a lista mudar durante esse Job, o avanço bloqueia.

O exemplo destina-se ao cluster Linux com control-plane e etcd juntos. Um nó somente etcd bloqueia para revisão da ordem; não é tratado como worker. A descoberta não identifica um nó removido da API antes de a rodada começar: confira a topologia esperada no Rancher antes de publicar.

Um nó Linux novo passa a ser selecionado automaticamente. Antes de incluí-lo em uma rodada de update, ele precisa da preparação dos agendamentos descrita abaixo. Não é necessário atualizar uma lista de nomes.

## O que acontece em cada etapa

1. **prepare:** descobre os nós; nos workers, espera todos os servers na mesma version/hash. Confere API, Ready, ausência de pressão/cordon, heartbeats recentes, workloads e Longhorn quando presente. Exige 60 segundos contínuos de saúde. Não altera o host.
2. **upgrade / trava:** reserva a manutenção global para um nó, confere SO, espaço, ferramentas e compatibilidade do cliente, repete a saúde e bloqueia outros Jobs de manutenção conflitantes.
3. **upgrade / drain:** faz cordon, verifica volumes e evacua workloads respeitando PDBs. Não usa force nem remove finalizers. O drain está no script para não ser repetido automaticamente após reboot.
4. **upgrade / SO:** informa que o backup etcd fica sob controle do operador e executa a transação no systemd do host. A saída aparece no log do container e fica persistida no host. Sem alterações, não há reboot.
5. **upgrade / validação:** quando houve reboot, confere boot ID e, no Micro, o snapshot ativo. Espera RKE2 ativo, faz uncordon, aguarda recuperação dos workloads/volumes por 60 segundos e só então libera a trava.

Os logs agrupam o fluxo em **Etapa 1 de 6 até Etapa 6 de 6**: azul em negrito para etapas/informações, verde para sucesso, amarelo para espera/atenção e vermelho em negrito para erro/interrupção. As cores usam ANSI; os rótulos continuam informativos sem cor. Para um exportador sem ANSI, use LOG_COLOR=false ou NO_COLOR=1 no container. O nó e a rodada aparecem no início; o container é selecionado no Rancher, sem repetir um prefixo longo em cada linha. Na espera, o resumo muda quando há progresso; sem mudança, há apenas um lembrete a cada dois minutos.

```text
Etapa 1 de 6 — Preparar a atualização
[AGUARDANDO] Servidores concluídos: 1 de 3. Em atualização: server-02.
Faltam: server-01, server-02.

Etapa 6 de 6 — Concluir a manutenção deste nó
[CONCLUIDO] Não havia atualizações disponíveis. Este nó não foi reiniciado. O cluster está saudável; o próximo nó já pode começar.
```

Em falha, `[ERRO]` identifica etapa e motivo, `[INTERROMPIDO]` informa que aquele Pod não executará novas etapas, e `[COMO CORRIGIR]` orienta o diagnóstico. Falha fatal no prepare tenta registrar a mesma trava global em failed, sem sobrescrever uma manutenção existente. O upgrade preserva a trava em failed. O SUC pode recriar o Pod, mas uma trava em failed impede que essa repetição pule a falha. Se a API estiver indisponível, o log informa que não foi possível confirmar a gravação da trava; confira seu estado. Uma trava já existente em updating/verifying, com o mesmo nó e hash, permite retomar a transação persistida após reboot. Um worker também interrompe a espera se encontrar a trava em failed.

**Interromper o procedimento não é desfazer pacotes já instalados nem matar uma transação ativa.** Se o systemd ainda estiver executando a transação, o log avisa para verificar seu resultado antes de qualquer recuperação. Isso evita interromper escrita de pacotes à força.

`Init:0/1` significa que o prepare está em execução. Seus logs mostram o motivo, os servers pendentes, o progresso e o tempo restante. No reboot, o pod original pode ficar Unknown/Failed e outro pod do **mesmo Job** retoma a validação; isso não repete a transação. O TTL configurado no controller limpa Jobs concluídos e seus pods. Não apague pods ativos apenas para limpar a tela.

## Parâmetros dos YAMLs

| Parâmetro | Função |
|---|---|
| `version` | Identificador único da rodada; único ajuste habitual, igual nos dois Plans do Micro; apenas um Plan no Rancher. |
| `concurrency: 1` | Um nó por vez dentro de cada Plan. Espera dos servers + trava global impedem manutenção simultânea entre grupos. |
| `exclusive: true` | Exclusividade por nó; não é uma trava global entre Plans. |
| `jobActiveDeadlineSecs` | Limite total do Job: 18000 s nos servers; 86400 s nos workers, incluindo a espera inicial. |
| `postCompleteDelay: 30s` | Intervalo adicional depois de cada sucesso. |
| `serviceAccountName` | Conta existente usada para consultar e operar a API. |
| `nodeSelector` / `tolerations` | Escolhem os papéis Linux e permitem execução em masters com taints e retomada após cordon. |
| `prepare` / `upgrade` | Container inicial de validação e container que executa a manutenção. |
| `image` / `command` / `args` | Imagem de ferramentas, interpretador Bash e script a executar. |
| `securityContext` | Root e privilégio para o container upgrade operar o host montado em /host pelo SUC. |
| `secrets` | Monta o código compartilhado em /run/suc-os. |
| `ACTION` | `update` na rotina; `prepare-host` somente para preparar os agendamentos. |
| `PROFILE` | `micro62`, `zypper` ou `ubuntu`, conforme o diretório. O script verifica o SO real antes de operar o host. |
| `SERVER_PLAN` | Nome do Plan dos servers que o prepare do worker deve esperar. |
| `PEER_PLAN` | Plan parceiro permitido; outros Jobs SUC ativos bloqueiam. |
| `upgrade.cattle.io/digest` | Acrescenta imagem/envs/prepare ao cálculo de execução. Version, conta e conteúdo do Secret já entram no hash padrão. |
| `name` no `sle-micro/fleet.yaml` | Define o identificador genérico do bundle: `suc-os-sle-micro`. Não muda o caminho usado no GitRepo. |
| `defaultNamespace` / `helm.releaseName` | Namespace e identificação interna do release Fleet; não exigem Chart.yaml ou values. |

A mudança da `version` dispara uma execução mesmo mantendo imagem e Secret iguais. **Mudanças de scripts, imagem, conta ou parâmetros também podem disparar execução.** Publique-as com uma nova version, igual nos dois Plans, somente depois de concluir a rodada anterior.

## Scripts legíveis no Secret

`stringData` contém texto normal; a conversão interna em `data`/base64 é feita pelo Kubernetes. Base64 não é criptografia. O Secret foi mantido porque o SUC monta scripts por esse mecanismo; não há credenciais nele. Não precisa extrair, decodificar ou regenerar nada para editar.

| Chave | O que faz |
|---|---|
| `prepare.sh` | Organiza verificações iniciais e reconhece retomada após reboot. |
| `run.sh` | Organiza a manutenção e acompanha o processo do host. |
| `common.sh` | Logs, API, descoberta de nós, trava e valores padrão. |
| `wait-servers.sh` | Espera a conclusão da mesma rodada em todos os servers. |
| `health.sh` | Valida nós, heartbeats, workloads e Longhorn opcional. |
| `host-preflight.sh` | Confere SO, ferramentas, systemd e pelo menos 2 GiB livres em / e /var. Ubuntu exige também 200 MiB em /boot e 50 MiB em /boot/efi quando forem partições separadas. |
| `host-worker.sh` | Executa somente o gerenciador do SO daquele diretório; persiste resultado e reinicia apenas quando necessário. |
| `storage-guard.jq` / `policy.json` | Verificam os volumes e as exceções autorizadas. |

Em Bash, `#` inicia comentário, `source` carrega funções de outro script e `${VAR:-padrao}` usa o padrão quando a variável não foi definida. `set -Eeuo pipefail` faz o fluxo parar em falhas/variáveis obrigatórias ausentes; `trap` registra a interrupção. Não é necessário mudar essas instruções no uso normal.

Os padrões avançados estão comentados no começo de `common.sh`:

| Variável | Padrão e função |
|---|---|
| `PLAN_NAMESPACE` | Descoberto pela credencial projetada da ServiceAccount. |
| `LH_NAMESPACE` | `longhorn-system`; ajuste apenas se o Longhorn estiver em outro namespace. |
| `HEALTH_TIMEOUT` / `STABLE_SECONDS` | Até 1800 s esperando saúde; exige 60 s contínuos saudáveis. |
| `DRAIN_TIMEOUT` / `HOST_TIMEOUT` | 30 min para drain e 7200 s de espera pela transação, com margem de 600 s no acompanhamento. Timeout bloqueia a fila; não mata o APT/Zypper/transactional-update. |
| `WAIT_TIMEOUT` | Até 43200 s aguardando os servers. |
| `ACTIVATE_PENDING` | Apenas Micro, `true`: ativa snapshot pendente após drain; uma nova transação fica para a próxima rodada. |
| `MANAGE_AUTOMATIC` | `true`, usado apenas em prepare-host para verificar/desativar os agendamentos de update/reboot existentes. |

`NODE`, `PLAN`, `HASH` e a version são fornecidos pelo SUC ao Job. `EXPECTED_NODES` e `SERVER_NODES` vêm da descoberta na API; não são parâmetros para preencher. `STATE` guarda o resultado em `/var/lib/suc-os/HASH` no host. A trava `suc-os-maintenance-gate` não expira automaticamente: uma falha não autoriza o próximo nó.

## Preparação inicial e volumes

A preparação dos agendamentos é obrigatória antes do primeiro update. O comando `transactional-update` continua funcionando normalmente quando chamado pelo procedimento.

Para preparar outro cluster/nós novos: confira primeiro SO, registro/repositórios SUSE, backup, imagem, conta e política de volumes. Use `ACTION: prepare-host` nos Plans do perfil selecionado, com uma nova version (igual nos dois Plans do Micro), publique e espere todos concluírem. Nos perfis SUSE, isso verifica/desativa `transactional-update.timer`, `os-update.timer` e `rebootmgr.service`, quando existem, sem executar update ou reboot. No Ubuntu, use a preparação APT descrita no passo a passo próprio. Depois volte ACTION para update com outra version. Não execute preparação enquanto outro update estiver ativo. Os novos nós precisam também da revisão de outros Plans/agendamentos conflitantes.

Longhorn é opcional. Sem API/volumes Longhorn, a validação segue com PDBs e proteção dos demais volumes. Erro de consulta/permissão bloqueia; não é interpretado como ausência. Com Longhorn, exige saúde/redundância e protege a última réplica; espera reconstruções antes de avançar.

PVC local, hostPath de aplicação e CSI não revisado bloqueiam antes do drain. Isso exige avaliar o backend e o workload, não apagar volume/finalizer. Em `policy.json`, `allowEmptyDirDeletion: true` foi autorizado para os dados temporários dos laboratórios SLE Micro e Rancher, incluindo filas de telemetria do Rancher; use false sem essa autorização. `hostPathAllowlist` contém exceções específicas de infraestrutura (no Rancher, diretórios de certificados do controller SUC, identificados por namespace/ServiceAccount/owner/path); `remoteCSIDrivers` aceita apenas backends remotos previamente revisados. PDBs, falha de saúde, espaço, repositório ou compatibilidade também podem bloquear: o bloqueio não significa necessariamente corrupção de dados.

### DNS e dependências

Valide resolução de nomes e disponibilidade dos serviços usados pelo cluster antes da manutenção. Falhas de DNS ou aplicações indisponíveis bloqueiam o avanço. Ajustes de infraestrutura devem seguir o ambiente de destino; este procedimento não fornece IPs ou domínios internos como padrão.

## Diagnóstico opcional por terminal

A rotina pode ser acompanhada no Rancher. Para quem preferir terminal, usando o kubeconfig do cluster de destino:

```bash
kubectl -n cattle-system get plans
kubectl -n cattle-system get pods -l upgrade.cattle.io/plan -o wide
kubectl get nodes
kubectl -n cattle-system get cm suc-os-maintenance-gate --ignore-not-found
# Substitua NOME_DO_POD pelo nome mostrado acima.
kubectl -n cattle-system logs NOME_DO_POD -c prepare -f
kubectl -n cattle-system logs NOME_DO_POD -c upgrade -f
```

Em erro, leia a mensagem `[ERRO]`/`[ACAO NECESSARIA]`, a trava e, no host envolvido, `journalctl -u suc-os-HASH.service` e `/var/lib/suc-os/HASH/operation.log`. Corrija a causa; confirme que não há transação/reboot ativo e que o nó/volumes estão recuperados antes de qualquer liberação manual. Não apague a trava para pular uma falha. Snapshot local etcd não substitui backup externo.

## Revisão do código e limites de segurança

A serialização, a trava persistente, os PDBs, a proteção dos volumes e a confirmação de saúde são necessárias para este procedimento. `concurrency: 1` sozinho não coordena dois Plans, e `exclusive` protege a execução por nó; por isso a trava global foi mantida. O drain dentro do script permite reconhecer retomada sem repetir uma transação depois do reboot.

Na revisão de 19/10/2026, foram removidos os executores de outros sistemas de cada Secret: o Micro contém transactional-update; o tradicional, Zypper; Ubuntu, APT. Os YAMLs seguem independentes, sem chart, gerador ou runtime adicional. Parte do código de segurança é repetida intencionalmente para permitir instalar cada diretório sozinho; mudanças nessa parte precisam ser verificadas nos três perfis.

Também foram corrigidos dois pontos: `TimeoutStartSec=infinity` impede que o limite de uma unidade oneshot mate a transação de pacotes; o Pod continua com timeout e mantém a fila bloqueada para diagnóstico. E tipos de volume inline não reconhecidos passaram a bloquear, em vez de serem aceitos pelo caso padrão. [Semântica de timeout do systemd](https://www.freedesktop.org/software/systemd/man/latest/systemd.service.html#TimeoutStartSec=).

Isso é um procedimento próprio, não uma certificação de compatibilidade de qualquer SO/kernel/pacote com RKE2. A conta existente permanece com as permissões que já possui; revise esse acesso antes de usar em outro cluster. `allowEmptyDirDeletion: true` dos perfis SUSE é uma autorização de lab, não um padrão recomendado para outros clusters. Os limites de tempo e espaço são mínimos operacionais e precisam comportar o tamanho real do ambiente.

## Validação e limites

- Revisão de 19/10/2026: 25 testes locais com comandos simulados, além da leitura de 11 YAMLs e verificação de sintaxe de 21 scripts Bash. Cobrem Ubuntu 22.04/24.04 com e sem pedido de reboot, falhas APT/dpkg, Zypper, Micro, storage, saúde e retomada.
- Não houve atualização real de nós Ubuntu nesta revisão. A primeira execução precisa ser validada no cluster Ubuntu selecionado.
- Testes reais anteriores em SLE Micro e openSUSE não homologam automaticamente as alterações atuais nem todas as versões de SLES.
- Os testes de desenvolvimento ficam fora dos diretórios entregues pelo Fleet; não são necessários para operar os Plans.

Referências: [SUC 0.19.1](https://github.com/rancher/system-upgrade-controller/blob/v0.19.1/doc/plan.md), [RKE2 upgrades](https://docs.rke2.io/upgrades/automated), [SUSE Micro 6.2](https://documentation.suse.com/sle-micro/6.2/html/Micro-transactional-updates/index.html), [drain Kubernetes](https://kubernetes.io/docs/tasks/administer-cluster/safely-drain-node/), [Secrets/stringData](https://kubernetes.io/docs/concepts/configuration/secret/), [Longhorn 1.11.2](https://longhorn.io/docs/1.11.2/maintenance/maintenance/) , [Zypper Leap 16.0](https://manpages.opensuse.org/Leap-16.0/zypper/zypper.8.en.html) e [Fleet YAML](https://fleet.rancher.io/explanations/gitrepo-content). Scripts próprios, sem homologação formal da SUSE.
