# Manutenção serial do SO com SUC

Manifests separados para o cluster `mpba-teste`, usando o System Upgrade Controller já instalado pelo Rancher. Não é necessário criar um chart próprio nem outro controller.

- `plano/rbac.yaml`: conta e permissões do Job.
- `plano/os-upgrade-secret.yaml`: código e política de storage.
- `plano/os-upgrade-plan.yaml`: fila única para masters e workers, `concurrency: 1`.
- `plano/fleet.yaml`: configuração para Fleet consumir YAML puro.
- `examples/sles/plano-prod-so.yaml`: exemplo para SLES tradicional com zypper.

O perfil Micro usa transactional-update, respeita PDB, bloqueia volumes locais não revisados, verifica Longhorn somente quando há volumes e confirma reboot/snapshot/recuperação antes de liberar o próximo nó. Quando não há mudanças, registra que não reiniciará. Falhas mantêm uma trava para diagnóstico.

Leia [o procedimento e os parâmetros](docs/PROCEDIMENTO.md) e [os resultados reais e limites da validação](docs/VALIDACAO.md) antes de aplicar. O descarte de emptyDir foi autorizado exclusivamente neste lab.

## Uso normal no MPBA já preparado

1. Confirme que `os-maintenance` terminou a rodada atual e os cinco nós estão Ready.
2. Edite somente `spec.version` em `plano/os-upgrade-plan.yaml` para um identificador novo (a próxima rodada é `mpba-update-05`), mantendo `ACTION=update`.
3. Faça commit na branch `main` pelo GitHub ou `git push`. Fleet `fleet-default/suc-os-mpba` entrega os YAMLs ao MPBA.
4. Acompanhe os Jobs e logs no namespace `cattle-system`. Fleet Ready confirma a entrega; Plan Complete confirma o fim da manutenção.
5. Em erro, leia a causa e corrija antes de iniciar outra rodada. Não apague a trava para pular o nó.

A preparação dos timers já foi feita. `transactional-update` continua habilitado para execução pelo SUC. O controller fica ativo e o Plan de system-agent permanece em espera nos cinco nós.

Depois de editar os scripts:

```bash
python3 plano/render-secret.py
bash plano/tests/verify.sh
```

Use somente `plano` como caminho do Fleet. Os originais estão preservados em `examples/legacy` e o chart anterior no histórico Git local. Alterar o Secret/Plan pode disparar nova rodada: não faça isso durante um Job ativo.
