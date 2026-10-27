#!/usr/bin/env python3
"""Validação estrutural offline: não acessa cluster nem executa manifests."""
import json,pathlib,subprocess,yaml,jsonschema
root=pathlib.Path(__file__).resolve().parents[1]
validated=0
validators={}
for entry in root.rglob('kustomization.yaml'):
    docs=yaml.safe_load_all(subprocess.check_output(['kubectl','kustomize',str(entry.parent)],text=True))
    for obj in docs:
        if not obj:continue
        key=obj['apiVersion'].replace('/','__')+'__'+obj['kind']
        schema=root/'tests/crd-schemas'/(key+'.json')
        if schema.exists():
            if key not in validators:
                definition=json.loads(schema.read_text())
                validators[key]=jsonschema.validators.validator_for(definition)(definition)
            validators[key].validate(obj)
            validated+=1
print(f'PASS: {validated} recursos validados contra schemas; admissão/CEL exigem validação no servidor')
