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
| `server-plan.yaml` + `agent-plan.yaml` | Rodadas e imagens divergentes; concorrência por Plan não cria uma fila global. Substituídos por template de Plan único, concorrência 1, nomes explícitos e ConfigMap de trava. |
| `os-upgrade-secret.yaml` | Scripts embutidos foram separados em arquivos testáveis e empacotados em Secret por Helm. Identificação de Micro 6.2 corrigida. |
| `prepare.sh` / `wait-servers.sh` | Espera entre Plans removida. A serialização e as verificações ficam no fluxo único; não dependem de hashes iguais entre Plans diferentes. |
| `storage-guard.jq` | Não bloqueia falsamente sockets CSI/infraestrutura auditada; preserva bloqueio de PVC local, hostPath de aplicação e CSI desconhecido. emptyDir é uma decisão explícita. |
| `upgrade.sh` | Evoluiu para `run.sh`: registra falhas de drain, espera boot real, faz uncordon antes de esperar rebuild e só termina após estabilidade. |
| `host-worker.sh` | Estado persistente e flock mantidos; adicionados snapshot etcd, tratamento de snapshot já pendente, mensagem explícita sem reboot, erros persistentes e perfil SLES. |
| `plano-prod-so.yaml` | Exemplo tradicional preservado conceitualmente em `examples/sles/values.yaml`, utilizando o mesmo Helm e guardrails; zypper direto jamais é usado no Micro. |
| `fleet.yaml` | Chart Helm e release explícitos; GitRepo de exemplo restrito ao MPBA. Ativação fica explícita. |
| `suc/suc-prod-so.yaml` | Controller antigo 0.11 e kubectl 1.25 não devem ser instalados sobre o SUC gerenciado. Originais arquivados fora do caminho ativo do Fleet. |

## Verificações concluídas

- Sintaxe Bash de todos os scripts.
- `helm lint` e renderização com os valores MPBA.
- `kubectl apply --dry-run=server` dos recursos no MPBA (validação da API; não significa execução).
- 16 testes locais de storage e worker: sem alterações, falha de update, snapshot novo aguardando reboot, snapshot pendente permitido/proibido, PVC local, PVC não resolvido, Longhorn, emptyDir autorizado/bloqueado, hostPath e CSI inline.
- 3 cenários adicionais: Longhorn ausente, instalado sem volumes e API/RBAC indisponível. Ausência permite prosseguir; indisponibilidade bloqueia.
- Storage guard executado contra inventário real dos pods/PVC/PV do MPBA e perfil autorizado; nenhum falso bloqueio restante.

## Execução real

Pendente: implantação do controller dedicado, preparação dos hosts, duas rodadas e integração Fleet. O release inicial em cattle-system foi instalado por Helm, mas não criou Jobs porque o SUC gerenciado está com zero réplicas. A revisão automática solicitou autorização explícita para a desativação persistente dos timers e para os Jobs privilegiados de manutenção. Nenhum update/reboot foi executado até esta versão do relatório. A alteração de duas réplicas Longhorn foi executada e validada separadamente.

O perfil SLES tradicional ainda não foi executado em um host SLES tradicional. Testes simulados não certificam reboot, aplicação, filesystem, restauração ou suporte formal. A execução real precisa ser registrada abaixo antes de declarar a validação completa.
