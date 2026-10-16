# Manutenção serial do SO com SUC

Manifests separados para o cluster `mpba-teste`, usando o System Upgrade Controller já instalado pelo Rancher. Não é necessário criar um chart próprio nem outro controller.

- `plano/rbac.yaml`: conta e permissões do Job.
- `plano/os-upgrade-secret.yaml`: código e política de storage.
- `plano/os-upgrade-plan.yaml`: fila única para masters e workers, `concurrency: 1`.
- `plano/fleet.yaml`: configuração para Fleet consumir YAML puro.
- `examples/sles/plano-prod-so.yaml`: exemplo para SLES tradicional com zypper.

O perfil Micro usa transactional-update, respeita PDB, bloqueia volumes locais não revisados, verifica Longhorn somente quando há volumes e confirma reboot/snapshot/recuperação antes de liberar o próximo nó. Quando não há mudanças, registra que não reiniciará. Falhas mantêm uma trava para diagnóstico.

Leia [o procedimento e os parâmetros](docs/PROCEDIMENTO.md) e [os resultados reais e limites da validação](docs/VALIDACAO.md) antes de aplicar. O descarte de emptyDir foi autorizado exclusivamente neste lab.

Depois de editar os scripts:

```bash
python3 plano/render-secret.py
bash plano/tests/verify.sh
```

Use somente `plano` como caminho do Fleet. Os originais estão preservados em `examples/legacy` e o chart anterior no histórico Git. Alterar o Secret/Plan pode disparar nova rodada: não faça isso durante um Job ativo.
