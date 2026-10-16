#!/usr/bin/env python3
"""Gera YAML legivel do Secret. --check verifica sincronizacao sem escrever."""
from pathlib import Path
import sys
root = Path(__file__).resolve().parent
out = 'apiVersion: v1\nkind: Secret\nmetadata:\n  name: os-maintenance-scripts\n  namespace: cattle-system\ntype: Opaque\nstringData:\n'
for path in sorted((root / 'scripts').iterdir()):
    if path.is_file():
        out += f'  {path.name}: |\n'
        out += ''.join('    ' + line + '\n' for line in path.read_text().splitlines())
target = root / 'os-upgrade-secret.yaml'
if '--check' in sys.argv:
    if target.read_text() != out:
        sys.exit('Secret desatualizado: execute python3 plano/render-secret.py')
    print('Secret sincronizado com scripts: PASS')
else:
    target.write_text(out)
