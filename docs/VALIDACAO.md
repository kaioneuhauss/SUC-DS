# Validação e alterações

## Estado observado em 16/10/2026

- Cluster Rancher `mpba-teste`, ID `c-m-n4dl4ksn`; cinco nós Ready.
- Micro 6.2 confirmado no `/etc/os-release` do host. Os campos de compatibilidade anunciam SLES 16.0 conforme as release notes SUSE.
- RKE2 v1.35.6+rke2r1; SUC v0.19.1 já instalado por Helm/Rancher, mas com Deployment escalado para zero; Longhorn v1.11.2.
- Volume `pvc-0129e97d-c00d-40e5-8b01-4ebd578d084d`, PVC `istio-system/prometheus-comunidade-server`, tinha uma única réplica no worker-mpba1. Com a autorização do laboratório, foi aumentado para duas; reconstrução concluída e estado healthy confirmado. A política de drain protetora foi preservada.
- PVC RabbitMQ já tinha duas réplicas. Nenhum PV local foi encontrado neste inventário.
- Monitoramento usa emptyDir; o usuário autorizou descartar esse histórico temporário apenas no lab.
- Snapshot Btrfs pendente encontrado no worker-mpba1; o fluxo preserva esse snapshot e não cria uma transação por cima sem ativá-lo.

## Diferenças em relação aos arquivos originais

| Original | Problema / alteração |
|---|---|
| `server-plan.yaml` + `agent-plan.yaml` | Rodadas e imagens divergentes; concorrência por Plan não cria uma fila global. Substituídos por manifesto de Plan único, concorrência 1, nomes explícitos e ConfigMap de trava. |
| `os-upgrade-secret.yaml` | Scripts embutidos foram separados em arquivos testáveis e empacotados em Secret data por render-secret.py, mantendo fontes legíveis em scripts/. Identificação de Micro 6.2 corrigida. |
| `prepare.sh` / `wait-servers.sh` | Espera entre Plans removida. A serialização e as verificações ficam no fluxo único; não dependem de hashes iguais entre Plans diferentes. |
| `storage-guard.jq` | Não bloqueia falsamente sockets CSI/infraestrutura auditada; preserva bloqueio de PVC local, hostPath de aplicação e CSI desconhecido. emptyDir é uma decisão explícita. |
| `upgrade.sh` | Evoluiu para `run.sh`: registra falhas de drain, espera boot real, faz uncordon antes de esperar rebuild e só termina após estabilidade. |
| `host-worker.sh` | Estado persistente e flock mantidos; adicionados snapshot etcd, tratamento de snapshot já pendente, mensagem explícita sem reboot, erros persistentes e perfil SLES. |
| `plano-prod-so.yaml` | Exemplo tradicional preservado conceitualmente em `examples/sles/plano-prod-so.yaml`, utilizando os mesmos scripts e proteções; zypper direto jamais é usado no Micro. |
| `fleet.yaml` | YAML puro consumido pelo Fleet; GitRepo restrito ao MPBA. Label de adesão nos nós controla elegibilidade. |
| `suc/suc-prod-so.yaml` | Controller antigo 0.11 e kubectl 1.25 não devem ser instalados sobre o SUC gerenciado. Originais arquivados fora do caminho ativo do Fleet. |

## Verificações concluídas

- Sintaxe Bash de todos os scripts.
- Chart anterior retirado do caminho ativo; YAMLs separados validados e Secret comparado com os arquivos fonte.
- `kubectl apply --dry-run=server` dos recursos no MPBA (validação da API; não significa execução).
- 18 testes locais de storage e worker: sem alterações, falha de update, snapshot novo aguardando reboot, snapshot pendente permitido/proibido, PVC local, PVC não resolvido, Longhorn, emptyDir autorizado/bloqueado, hostPath e CSI inline.
- 3 cenários adicionais: Longhorn ausente, instalado sem volumes e API/RBAC indisponível. Ausência permite prosseguir; indisponibilidade bloqueia.
- Storage guard executado contra inventário real dos pods/PVC/PV do MPBA e perfil autorizado; nenhum falso bloqueio restante.

## Execução real — rodadas mpba-update-03 e mpba-update-04 concluídas

Controller Rancher existente reativado com uma réplica; nenhum controller adicional instalado. Por escolha expressa do usuário, SUC permanece ativo e o Plan de system-agent permanece em espera nos cinco nós pelo label documentado `disabled`. Labels anteriores foram salvos.

Preparação concluída em todos os nós em 16/10/2026, entre 20:53:50 e 20:56:40 UTC: timer/rebootmgr desativados. O comando transactional-update continua disponível.

Defeitos encontrados e corrigidos nos testes reais:

1. kubectl tentava localhost:8080: configuração explícita da API interna, CA e tokenFile rotativo do próprio ServiceAccount.
2. Expressão jq dos leases tinha precedência ambígua: cálculo corrigido e testado com lease recente, expirado e nó ausente.
3. Job retomava antes do RKE2 terminar sua inicialização: espera limitada a 600 segundos antes de falhar. Testados retorno durante a espera e timeout.
4. RKE2 instalado em /opt/rke2/bin nos masters: PATH corrigido e binário verificado antes do drain. A tentativa anterior falhou antes de alterar o SO; após diagnóstico, master recuperado e nova rodada iniciada.
5. Adoção pelo Fleet: Secret convertido de stringData para data, sem mudar bytes, por compatibilidade com server-side apply. Geradores/scripts permanecem separados e testáveis.

O primeiro piloto parou por esses problemas; nenhum outro nó avançou. Depois do terceiro diagnóstico, a verificação do mesmo nó/hash foi retomada manualmente, sem novo update/reboot. Esse piloto não é classificado como execução totalmente autônoma.

| Rodada | Destino | Resultado comprovado |
|---|---|---|
| mpba-update-01 | worker-mpba1 | Snapshot pendente ativado: root Btrfs 300 → 303, snapshot 13. Boot ID 05e14946-8630-43dc-af16-2696b060888f → b8a01ce9-097a-481e-9af5-305294848a80. RKE2 ativo, timers continuam desativados e Longhorn recuperado. Conclusão 21:05:41 UTC, após intervenção descrita acima. |
| mpba-update-02 | worker-mpba1 | transactional-update 5.0.9 executado de fato entre 21:07:35–21:07:39 UTC. Retornou nothing to update, criou e descartou snapshot vazio 14, preservou root 303 e o boot ID. Concluiu no-change-no-reboot às 21:10:56 UTC após reconstrução Longhorn, sem intervenção. |
| mpba-update-02 | worker-mpba2 | Snapshot pendente ativado automaticamente, boot 62346c3c-dfd0-4e1e-b9c9-fcf823039840 → d037649b-7beb-46f9-8d51-647fe45e12f9. Conclusão 21:17:14 UTC. |
| mpba-update-03 | master-mbpa1 | Snapshot etcd salvo; root Btrfs 300 ativado e reboot verificado. Conclusão automática 21:28:41 UTC. |
| mpba-update-03 | master-mpba2 | Snapshot etcd salvo; root Btrfs 306 ativado e reboot verificado. Conclusão automática 21:34:38 UTC. |
| mpba-update-03 | worker-mpba2 | transactional-update executado, sem alterações nem reboot. Conclusão 21:38:24 UTC. |
| mpba-update-03 | worker-mpba1 | transactional-update executado, sem alterações nem reboot. Conclusão 21:43:30 UTC. |
| mpba-update-03 | master-mpba3 | Snapshot etcd salvo; root Btrfs 303 ativado e reboot verificado. Conclusão automática 21:47:57 UTC. |

Comando real do host: `transactional-update --non-interactive --drop-if-no-change up`. Nas chamadas realizadas, o comando retornou nothing to update; não foram fabricadas atualizações por downgrade/reinstalação. Os reboots reais anteriores ativaram snapshots já pendentes. Portanto, comprovamos ativação de snapshots, recuperação após reboot e o caminho sem alterações; não a instalação de um novo pacote disponibilizado durante estes testes.

PDBs respeitados: o Longhorn bloqueou temporariamente a eviction do Instance Manager e a liberou após a movimentação segura das cargas. Não foram usados force, disable-eviction, remoção de PDB ou de finalizers. Em uma reconstrução foi observado progresso de 72%; a fila aguardou todas as réplicas RW e 60 segundos de saúde estável.

Testes locais: 18 de segurança/worker/storage, três cenários Longhorn e cinco de saúde/RKE2. YAMLs validados e Secret conferido contra os fontes. O perfil SLES tradicional não foi executado em host SLES tradicional. Os casos sem Longhorn foram testados com respostas de API simuladas; o cluster real possui Longhorn.

Fleet 0.15.4 configurado via GitRepo fleet-default/suc-os-mpba, branch main, caminho plano, destino único mpba-teste. Publicação feita pela sessão autenticada do GitHub no navegador, pois o terminal não tinha credencial de push. Todos os 16 arquivos ativos foram comparados com a árvore remota. Após corrigir o Secret data, GitRepo atingiu Ready 1/1 e o release existente foi adotado sem recriação. A rodada mpba-update-04 foi explicitamente autorizada e publicada no commit 1f704091d832da95841f608526ae7c6290612d71; houve um conflito de propriedade em spec.version herdado dos testes com kubectl. Foi resolvido uma única vez por server-side apply no Plan com field-manager=fleetagent e force-conflicts; o dry-run confirmou que somente version mudaria. Não houve edição manual de managedFields dos sete recursos. Após ressincronizar o mesmo conteúdo, Fleet voltou a Ready 1/1 e a rodada começou às 22:12:41 UTC. A rodada ficou Complete=True em 2026-10-16T22:32:25Z. Os Jobs avançaram automaticamente, sem intervenção após o início.

O Plan mpba-update-03 ficou Complete=True em 21:48:29 UTC, sem trava residual e com os cinco nós Ready/uncordoned. Snapshot etcd local foi criado antes de cada master. Prometheus readiness e RabbitMQ ping responderam após a migração dos workers. Esses testes não equivalem à validação funcional completa das aplicações ou a uma certificação de integridade de todos os dados.

## Resultado final da rodada 04 pelo Fleet

`transactional-update --non-interactive --drop-if-no-change up` foi executado nos cinco hosts. Todos retornaram `nothing to update`, descartaram o snapshot vazio e concluíram `no-change-no-reboot`; os cinco boot IDs permaneceram iguais aos do início desta rodada. Snapshot etcd foi salvo antes da operação em cada master.

| Nó | Conclusão UTC em 16/10/2026 | Resultado | Boot ID preservado |
|---|---|---|---|
| master-mbpa1 | 22:15:22 | no-change-no-reboot | 1ca3c162-f1b8-470e-b04c-6c02e46814dd |
| master-mpba3 | 22:19:40 | no-change-no-reboot | ad07201f-1a64-4bca-88de-02808776cf89 |
| master-mpba2 | 22:22:43 | no-change-no-reboot | e55160b8-3ef0-44b0-a541-47384f879404 |
| worker-mpba1 | 22:26:18 | no-change-no-reboot | b8a01ce9-097a-481e-9af5-305294848a80 |
| worker-mpba2 | 22:31:52 | no-change-no-reboot | d037649b-7beb-46f9-8d51-647fe45e12f9 |

Conferência final às 22:32:54 UTC (19:32:54 em Brasília):

- Plan `mpba-update-04`: Complete=True, hash `bb1cab1356b54a98d1a3c824925879a90fc1741df4c6ccee7ac06f4b` concluído nos cinco nós.
- Cinco nós Ready, sem pressão e sem cordon; trava `suc-os-maintenance-gate` ausente.
- Fleet Ready 1/1; Rancher mostra App Bundle Active, 1/1 bundles e 7/7 recursos prontos.
- SUC ativo com uma réplica; system-agent-upgrader continua disabled nos cinco nós.
- Dois volumes Longhorn healthy, quatro réplicas RW, duas em cada volume. Nenhum PDB/finalizer removido nem eviction forçada.
- Na rodada 04 os workers passaram por reconstrução de réplicas; a fila esperou a recuperação e 60 segundos de estabilidade. O segundo worker aguardou também a liberação do PDB do Instance Manager durante o drain.
- Deployments, StatefulSets e DaemonSets com a quantidade esperada de réplicas prontas.
- Endpoint `istio-system/prometheus-comunidade-server:80/proxy/-/ready`: `Prometheus Server is Ready.`
- `kubectl -n dr-test exec rabbitmq-0 -- rabbitmq-diagnostics -q ping`: `Ping succeeded`.
- Amostragem dos Jobs e estado dos nós durante as rodadas 03 e 04: no máximo um Job de manutenção ativo por vez.

As rodadas 03 e 04 são as duas rodadas completas da validação. Os pilotos 01 e 02 e as correções estão registrados acima; não foram contabilizados como duas rodadas completas bem-sucedidas. O exemplo SLES tradicional, a ausência de Longhorn e os bloqueios de volumes locais mantêm os limites de validação já descritos.

Para o uso normal, a próxima identificação disponível é `mpba-update-05`. Alterar somente `spec.version` pelo Git e acompanhar o Fleet/Plan. A preparação dos hosts não precisa ser repetida a cada rodada.
