# Atualização do SO pelo Fleet

O uso normal é **alterar `version` e publicar no Git**. O Fleet entrega os YAMLs; o SUC atualiza um nó por vez e só libera o próximo depois da recuperação do cluster.

| Diretório | Sistema / cluster | Arquivos para operar |
|---|---|---|
| `sle-micro/` | **SLE Micro 6.2**, MPBA | `fleet.yaml`, `server-plan.yaml`, `agent-plan.yaml`, `os-upgrade-secret.yaml` |
| `opensuse-sles/` | **openSUSE Leap / SLES tradicional**, Rancher | `fleet.yaml`, `server-plan.yaml`, `os-upgrade-secret.yaml` |

O exemplo tradicional anterior foi consolidado em `opensuse-sles/`: ficam apenas os dois diretórios de SO.

Cada diretório é independente e tem seu próprio Secret. Configure o GitRepo com **apenas o caminho e o cluster correspondentes**; não aponte para a raiz do repositório nem aplique os dois perfis no mesmo cluster. O GitRepo do MPBA acompanha `sle-micro/`. O nome interno do bundle foi preservado para evitar recriar recursos durante a mudança de pasta. Não há chart próprio, gerador ou instalação de Python.

Função dos arquivos:

| Arquivo | Função |
|---|---|
| `fleet.yaml` | Namespace e nome do release usado internamente pelo Fleet. |
| `server-plan.yaml` | Seleciona Linux com label control-plane e atualiza um server por vez. |
| `agent-plan.yaml` | Seleciona Linux sem control-plane/etcd; espera os servers da mesma rodada. |
| `os-upgrade-secret.yaml` | Scripts e política em texto legível (`stringData`), sem credenciais. |

Todos os Plans reutilizam a ServiceAccount `cattle-system/system-upgrade-controller`, já existente. Este projeto não cria Roles, bindings ou outra conta. No MPBA e no Rancher, essa conta já tem cluster-admin; os Jobs recebem essas permissões amplas. O SUC, a conta e as permissões são pré-requisitos para outro cluster.

## Passo a passo: SLE Micro 6.2

1. No Rancher, confirme os nós Ready, os dois Plans anteriores Complete=True e ausência de manutenção em andamento. O Fleet Ready confirma a entrega dos arquivos, não o término do update.
2. Abra `sle-micro/server-plan.yaml` e altere somente `spec.version`, por exemplo:
   ```yaml
   version: sles-20261019-01
   ```
3. Coloque **exatamente o mesmo valor novo** em `sle-micro/agent-plan.yaml`. Use um identificador que nunca foi executado. `sles-20261019-01` é apenas um nome de rodada: não instala uma release específica do SO e não atualiza Kubernetes.
4. Publique os dois arquivos juntos no `main` acompanhado pelo GitRepo `fleet-default/suc-os-mpba`. Pela interface do GitHub, edite ambos na mesma branch e integre o PR depois das duas alterações. Não faça dois commits separados diretamente em main durante uma rodada.
5. No Rancher, abra os Pods do namespace `cattle-system`. Leia **prepare** para acompanhar espera/validações e depois **upgrade** para drain, atualização e resultado.
6. Aguarde ambos os Plans Complete=True, nós Ready/sem cordon e ausência da trava `suc-os-maintenance-gate`. Só então inicie outra rodada.

Não é necessário editar scripts, conhecer Bash ou usar Python para esse procedimento. O `transactional-update --non-interactive --drop-if-no-change up` procura as atualizações disponíveis nos repositórios configurados no host. Sem alterações, informa que **não reiniciará** e libera o próximo nó após validar a saúde. O drain ainda pode mover workloads mesmo quando não há pacotes novos.

## Passo a passo: openSUSE Leap / SLES

1. No cluster Rancher, confirme os três nós Ready, aplicações saudáveis e nenhuma manutenção em andamento.
2. Abra `opensuse-sles/server-plan.yaml`. Depois da preparação inicial, `ACTION` permanece em `update` e `PROFILE` em `zypper`.
3. Altere **somente `version`**, por exemplo `opensuse-20261019-01`, e publique no `main`. Só há um Plan neste perfil, pois o cluster Rancher tem apenas servidores.
4. O GitRepo `fleet-local/suc-os-rancher` acompanha `opensuse-sles/` na branch `lab-rancher` deste lab e seleciona exclusivamente o cluster `local`. O Plan de SO chama-se `os-maintenance-zypper`; o Plan `server-plan` já existente para atualizar Kubernetes é outro recurso.
5. Acompanhe `prepare` e `upgrade` em `cattle-system`. Aguarde o Plan Complete=True, todos os nós Ready/sem cordon e ausência da trava antes de outra rodada.

**Exceção somente do lab:** a branch `lab-rancher` ignora apenas o Deployment `suse-observability/suse-observability-agent-rbac-agent`, pois o backend está desligado por decisão do operador. O `main` não contém essa exceção e exige todas as réplicas prontas. Quando o Observability for recuperado, conclua a rodada e retorne o GitRepo à branch `main`. Não use a branch de lab em produção.

O comando é `zypper --non-interactive patch --with-update --with-interactive`: aplica patches e atualiza os pacotes sem patch correspondente. O retorno 103 indica atualização do próprio gerenciador; o script repete a operação, no máximo três vezes. O retorno 102 indica necessidade de reboot. Falhas de repositório, dependências ou scripts RPM interrompem o procedimento. Não há troca de release, `dist-upgrade`, aceitação forçada de licenças ou desativação de GPG.

O inventário RPM é comparado antes/depois. Se houve alteração, o fluxo faz um reboot conservador para carregar os novos binários. Sem alteração e sem reboot pendente, registra que **não reiniciará**. Um reboot pendente anterior sem atualização nesta rodada exige avaliação, em vez de ser ignorado. Esse perfil aceita SLES e openSUSE **Leap** com raiz gravável; rejeita Micro transacional e Tumbleweed.

## Imagem: quando alterar

A imagem está por tag, sem `@sha256`. Para RKE2 `v1.35.6+rke2r1`, usamos:

```yaml
image: &maintenance_image registry.rancher.com/rancher/rke2-upgrade:v1.35.6-rke2r1
```

`&maintenance_image` dá um nome a esse valor; `image: *maintenance_image` no upgrade reutiliza a mesma imagem. Assim, há **uma tag para editar em cada Plan**. Quando atualizar o RKE2 pelo Rancher, revise a tag correspondente nos dois arquivos, confirme que ela existe no registry e publique com uma nova `version`, numa janela de manutenção. Não use `latest`.

Essa é a imagem de ferramentas de upgrade do RKE2, não a imagem do kube-apiserver. O `command` dos Plans executa nossos scripts de SO em vez do upgrade do RKE2. O script verifica a compatibilidade do kubectl com a API (no máximo uma versão minor de diferença), além das ferramentas necessárias. A correspondência de tag deve ser revista após cada upgrade do cluster; não é uma garantia para toda versão futura. Sem digest, o conteúdo depende da tag publicada no registry.

## Seleção e descoberta dos nós

Não há nomes de hosts nos Plans. O Kubernetes fornece os nomes e labels pela API:

- Server: Linux com `node-role.kubernetes.io/control-plane`.
- Worker: Linux sem `node-role.kubernetes.io/control-plane` e sem `node-role.kubernetes.io/etcd`.
- A saúde considera todos os nós encontrados, inclusive os do outro grupo. A lista fica fixa durante o Job e é gravada na trava para sobreviver a reboot. Se a lista mudar durante esse Job, o avanço bloqueia.

O exemplo destina-se ao cluster Linux com control-plane e etcd juntos, como o MPBA. Um nó somente etcd bloqueia para revisão da ordem; não é tratado como worker. A descoberta não identifica um nó removido da API antes de a rodada começar: confira a topologia esperada no Rancher antes de publicar.

Um nó Linux novo passa a ser selecionado automaticamente. Antes de incluí-lo em uma rodada de update, ele precisa da preparação dos agendamentos descrita abaixo. Não é necessário atualizar uma lista de nomes.

## O que acontece em cada etapa

1. **prepare:** descobre os nós; nos workers, espera todos os servers na mesma version/hash. Confere API, Ready, ausência de pressão/cordon, heartbeats recentes, workloads e Longhorn quando presente. Exige 60 segundos contínuos de saúde. Não altera o host.
2. **upgrade / trava:** reserva a manutenção global para um nó, confere SO, espaço, ferramentas e compatibilidade do cliente, repete a saúde e bloqueia outros Jobs de manutenção conflitantes.
3. **upgrade / drain:** faz cordon, verifica volumes e evacua workloads respeitando PDBs. Não usa force nem remove finalizers. O drain está no script para não ser repetido automaticamente após reboot.
4. **upgrade / SO:** salva snapshot etcd nos servers e executa a transação no systemd do host. A saída aparece no log do container e fica persistida no host. Sem alterações, não há reboot.
5. **upgrade / validação:** quando houve reboot, confere boot ID e, no Micro, o snapshot ativo. Espera RKE2 ativo, faz uncordon, aguarda recuperação dos workloads/volumes por 60 segundos e só então libera a trava.

Os logs agrupam o fluxo em **Etapa 1 de 6 até Etapa 6 de 6**: azul em negrito para etapas/informações, verde para sucesso, amarelo para espera/atenção e vermelho em negrito para erro/interrupção. As cores usam ANSI; os rótulos continuam informativos sem cor. Para um exportador sem ANSI, use LOG_COLOR=false ou NO_COLOR=1 no container. O nó e a rodada aparecem no início; o container é selecionado no Rancher, sem repetir um prefixo longo em cada linha. Na espera, o resumo muda quando há progresso; sem mudança, há apenas um lembrete a cada dois minutos.

```text
Etapa 1 de 6 — Preparar a atualização
[AGUARDANDO] Servidores concluídos: 1 de 3. Em atualização: master-mpba2.
Faltam: master-mbpa1, master-mpba2.

Etapa 6 de 6 — Concluir a manutenção deste nó
[CONCLUIDO] Não havia atualizações disponíveis. Este nó não foi reiniciado. O cluster está saudável; o próximo nó já pode começar.
```

Em falha, `[ERRO]` identifica etapa e motivo, `[INTERROMPIDO]` informa que aquele Pod não executará novas etapas, e `[COMO CORRIGIR]` orienta o diagnóstico. Falha fatal no prepare tenta registrar a mesma trava global em failed, sem sobrescrever uma manutenção existente. O upgrade preserva a trava em failed. O SUC pode recriar o Pod, mas a trava impede que essa repetição pule a falha. Um worker também interrompe a espera se encontrar a trava em failed.

**Interromper o procedimento não é desfazer pacotes já instalados nem matar uma transação ativa.** Se o systemd ainda estiver executando a transação, o log avisa para verificar seu resultado antes de qualquer recuperação. Isso evita interromper escrita de pacotes à força.

`Init:0/1` significa que o prepare está em execução. Seus logs mostram o motivo, os servers pendentes, o progresso e o tempo restante. No reboot, o pod original pode ficar Unknown/Failed e outro pod do **mesmo Job** retoma a validação; isso não repete a transação. O TTL do controller limpa Jobs concluídos e seus pods (900 segundos no MPBA). Não apague pods ativos apenas para limpar a tela.

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
| `PROFILE` | `micro62` exige SLE Micro 6.2; `zypper` aceita openSUSE Leap/SLES tradicional. O log exibe o nome completo do perfil. |
| `SERVER_PLAN` | Nome do Plan dos servers que o prepare do worker deve esperar. |
| `PEER_PLAN` | Plan parceiro permitido; outros Jobs SUC ativos bloqueiam. |
| `upgrade.cattle.io/digest` | Acrescenta imagem/envs/prepare ao cálculo de execução. Version, conta e conteúdo do Secret já entram no hash padrão. |
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
| `host-preflight.sh` | Confere SO, ferramentas, systemd e pelo menos 2 GiB livres em / e /var. |
| `host-worker.sh` | Executa o update e persiste resultado/estado antes do reboot. |
| `storage-guard.jq` / `policy.json` | Verificam os volumes e as exceções autorizadas. |

Em Bash, `#` inicia comentário, `source` carrega funções de outro script e `${VAR:-padrao}` usa o padrão quando a variável não foi definida. `set -Eeuo pipefail` faz o fluxo parar em falhas/variáveis obrigatórias ausentes; `trap` registra a interrupção. Não é necessário mudar essas instruções no uso normal.

Os padrões avançados estão comentados no começo de `common.sh`:

| Variável | Padrão e função |
|---|---|
| `PLAN_NAMESPACE` | Descoberto pela credencial projetada da ServiceAccount. |
| `LH_NAMESPACE` | `longhorn-system`; ajuste apenas se o Longhorn estiver em outro namespace. |
| `HEALTH_TIMEOUT` / `STABLE_SECONDS` | Até 1800 s esperando saúde; exige 60 s contínuos saudáveis. |
| `DRAIN_TIMEOUT` / `HOST_TIMEOUT` | 30 min para drain e 7200 s para a transação no host. |
| `WAIT_TIMEOUT` | Até 43200 s aguardando os servers. |
| `ACTIVATE_PENDING` | `true`: ativa snapshot Micro pendente após drain; uma nova transação fica para a próxima rodada. |
| `MANAGE_AUTOMATIC` | `true`, usado apenas em prepare-host para verificar/desativar os agendamentos de update/reboot existentes. |

`NODE`, `PLAN`, `HASH` e a version são fornecidos pelo SUC ao Job. `EXPECTED_NODES` e `SERVER_NODES` vêm da descoberta na API; não são parâmetros para preencher. `STATE` guarda o resultado em `/var/lib/suc-os/HASH` no host. A trava `suc-os-maintenance-gate` não expira automaticamente: uma falha não autoriza o próximo nó.

## Preparação inicial e volumes

Os cinco nós MPBA já foram preparados: timers automáticos desativados, SUC ativo e system-agent-upgrader mantido em espera, conforme autorizado. `transactional-update` continua funcionando normalmente quando chamado pelo procedimento.

Para preparar outro cluster/nós novos: confira primeiro SO, registro/repositórios SUSE, backup, imagem, conta e política de volumes. Use `ACTION: prepare-host` nos Plans do perfil selecionado, com uma nova version (igual nos dois Plans do Micro), publique e espere todos concluírem. Isso verifica/desativa `transactional-update.timer`, `os-update.timer` e `rebootmgr.service`, quando existem, sem executar update ou reboot. Depois volte ACTION para update com outra version. Não execute preparação enquanto outro update estiver ativo. Os novos nós precisam também da revisão de outros Plans/agendamentos conflitantes.

Longhorn é opcional. Sem API/volumes Longhorn, a validação segue com PDBs e proteção dos demais volumes. Erro de consulta/permissão bloqueia; não é interpretado como ausência. Com Longhorn, exige saúde/redundância e protege a última réplica; espera reconstruções antes de avançar.

PVC local, hostPath de aplicação e CSI não revisado bloqueiam antes do drain. Isso exige avaliar o backend e o workload, não apagar volume/finalizer. Em `policy.json`, `allowEmptyDirDeletion: true` foi autorizado para os dados temporários dos labs MPBA e Rancher, incluindo filas de telemetria do Rancher; use false sem essa autorização. `hostPathAllowlist` contém exceções específicas de infraestrutura (no Rancher, diretórios de certificados do controller SUC, identificados por namespace/ServiceAccount/owner/path); `remoteCSIDrivers` aceita apenas backends remotos previamente revisados. PDBs, falha de saúde, espaço, repositório ou compatibilidade também podem bloquear: o bloqueio não significa necessariamente corrupção de dados.

## Diagnóstico opcional por terminal

A rotina pode ser acompanhada no Rancher. Para quem preferir terminal, usando o kubeconfig do MPBA:

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

## Validação e limites

- MPBA: a rodada `mpba-update-06` instalou atualizações e reiniciou os cinco nós, passando ao kernel `6.12.0-160000.39-default`.
- MPBA: a rodada `mpba-update-07` executou o transactional-update nos cinco nós, sem pacotes novos e sem reboot. Plans concluídos, nós Ready, Longhorn saudável e aplicações respondendo.
- As rodadas seguintes verificam logs coloridos, disparo apenas por version e a apresentação final dos perfis. Os resultados definitivos ficam registrados após a conclusão.
- openSUSE Leap 16.0: perfil entregue pelo Fleet ao Rancher, sem Longhorn/PVs. A execução real e o resultado serão registrados após o teste.
- SLES tradicional: o caminho zypper foi validado em testes locais, mas não há um host SLES tradicional neste lab para teste real. Isso não equivale a homologação de todas as versões SLES.
- 58 testes locais cobrem descoberta, ordem, trava, cores, falhas, storage e retornos do Zypper; fixtures adicionais cobrem ausência de Longhorn, acesso negado à API, heartbeats e retomada. Não há testes artificiais dentro do diretório entregue pelo Fleet.

Referências: [SUC 0.19.1](https://github.com/rancher/system-upgrade-controller/blob/v0.19.1/doc/plan.md), [RKE2 upgrades](https://docs.rke2.io/upgrades/automated), [SUSE Micro 6.2](https://documentation.suse.com/sle-micro/6.2/html/Micro-transactional-updates/index.html), [drain Kubernetes](https://kubernetes.io/docs/tasks/administer-cluster/safely-drain-node/), [Secrets/stringData](https://kubernetes.io/docs/concepts/configuration/secret/), [Longhorn 1.11.2](https://longhorn.io/docs/1.11.2/maintenance/maintenance/) , [Zypper Leap 16.0](https://manpages.opensuse.org/Leap-16.0/zypper/zypper.8.en.html) e [Fleet YAML](https://fleet.rancher.io/explanations/gitrepo-content). Scripts próprios, sem homologação formal da SUSE.
