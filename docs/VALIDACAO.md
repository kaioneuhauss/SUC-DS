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

## Execução real — rodada mpba-update-03 concluída

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
| mpba-update-03 | master-mbpa1 | Snapshot etcd salvo; snapshot SO 300 ativado e reboot verificado. Conclusão automática 21:28:41 UTC. |
| mpba-update-03 | master-mpba2 | Snapshot etcd salvo; snapshot SO 306 ativado e reboot verificado. Conclusão automática 21:34:38 UTC. |
| mpba-update-03 | worker-mpba2 | transactional-update executado, sem alterações nem reboot. Conclusão 21:38:24 UTC. |
| mpba-update-03 | worker-mpba1 | transactional-update executado, sem alterações nem reboot. Conclusão 21:43:30 UTC. |
| mpba-update-03 | master-mpba3 | Snapshot etcd salvo; snapshot SO 303 ativado e reboot verificado. Conclusão automática 21:47:57 UTC. |

Comando real do host: `transactional-update --non-interactive --drop-if-no-change up`. Não houve pacotes novos disponíveis no primeiro worker; não foram fabricadas atualizações por downgrade/reinstalação.

PDBs respeitados: o Longhorn bloqueou temporariamente a eviction do Instance Manager e a liberou após a movimentação segura das cargas. Não foram usados force, disable-eviction, remoção de PDB ou de finalizers. Em uma reconstrução foi observado progresso de 72%; a fila aguardou todas as réplicas RW e 60 segundos de saúde estável.

Testes locais: 18 de segurança/worker/storage, três cenários Longhorn e cinco de saúde/RKE2. YAMLs validados e Secret conferido contra os fontes. O perfil SLES tradicional não foi executado em host SLES tradicional. Os casos sem Longhorn foram testados com respostas de API simuladas; o cluster real possui Longhorn.

Fleet 0.15.4 configurado via GitRepo fleet-default/suc-os-mpba, branch main, caminho plano, destino único mpba-teste. Publicação feita pela sessão autenticada do GitHub no navegador, pois o terminal não tinha credencial de push. Todos os 16 arquivos ativos foram comparados com a árvore remota. Após corrigir o Secret data, GitRepo atingiu Ready 1/1 e o release existente foi adotado sem recriação. A rodada mpba-update-04 foi explicitamente autorizada e publicada no commit 1f704091d832da95841f608526ae7c6290612d71; a transferência dos registros antigos de gestão ainda está sendo concluída antes do disparo.

O Plan mpba-update-03 ficou Complete=True em 21:48:29 UTC, sem trava residual e com os cinco nós Ready/uncordoned. Snapshot etcd local foi criado antes de cada master. Prometheus readiness e RabbitMQ ping responderam após a migração dos workers. Esses testes não equivalem à validação funcional completa das aplicações ou a uma certificação de integridade de todos os dados.
