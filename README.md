# SUC: manutenção serial do sistema operacional

Chart Helm em `plano/`, utilizando SUC dedicado ao namespace `suc-os-system` no perfil MPBA. Um único Plan atende masters e workers, com concorrência 1 e trava persistente. O SUC gerenciado pelo Rancher estava pausado e é preservado. O chart não atualiza RKE2 nem migra a versão do sistema operacional.

- [Procedimento e parâmetros](docs/PROCEDIMENTO.md)
- [Alterações e limites de validação](docs/VALIDACAO.md)
- [Perfil MPBA/Micro 6.2](plano/values-mpba.yaml)
- [Exemplo SLES tradicional](examples/sles/values.yaml), substituto do antigo `plano-prod-so.yaml`
- [GitRepo Fleet restrito ao MPBA](examples/fleet-gitrepo.yaml)

O padrão é `enabled: false`. A exclusão de `emptyDir` só é liberada no perfil MPBA por autorização específica para este laboratório. Backups e alta disponibilidade das aplicações continuam necessários.
