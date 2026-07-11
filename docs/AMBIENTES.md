# Ambientes

Este repositório usa `base/` e `overlays/{desenvolvimento,aceite,producao}`.

- `desenvolvimento`: Zabbix Server/Web/PostgreSQL/Agent2 com recursos reduzidos para CRC.
- `aceite`: use para homologar SSO, datasource Grafana e integração Keycloak.
- `producao`: recomenda-se banco externo, backup, HA, sizing e housekeeping formal.

Validação:

```bash
oc kustomize overlays/desenvolvimento >/tmp/zabbix-dev.yaml
oc kustomize overlays/aceite >/tmp/zabbix-aceite.yaml
oc kustomize overlays/producao >/tmp/zabbix-prod.yaml
oc apply --dry-run=client -k overlays/desenvolvimento
```

Secrets obrigatórios:

- `zabbix/zabbix-db`: `username`, `password`, `database`.
- `grafana/zabbix-datasource`: `username`, `password`, criado/atualizado por
  `scripts/bootstrap-zabbix.sh` quando `ZABBIX_MANAGE_GRAFANA_DATASOURCE=true`.

ConfigMaps:

- `zabbix/zabbix-saml-idp`: chave `idp.crt`, criada/atualizada pelo bootstrap a
  partir do metadata SAML do Keycloak.

Bootstrap:

- `ZABBIX_ENABLE_SAML=true` habilita SAML via Keycloak.
- `ZABBIX_ENABLE_SAML_JIT=true` ativa JIT provisioning.
- `ZABBIX_ENABLE_SAML_SCIM=true` deixa SCIM habilitado no diretório SAML.
- `ZABBIX_DISABLED_USER_GROUP` define o grupo desabilitado usado em
  `disabled_usrgrpid`.
- `ZABBIX_MANAGE_GRAFANA_DATASOURCE=true` cria/atualiza o usuário técnico e o
  Secret do datasource Grafana.
- `ZABBIX_GRAFANA_READ_HOST_GROUPS` pode listar host groups já existentes,
  separados por vírgula, para conceder leitura ao datasource.

O bootstrap não cria hosts, templates, web scenarios ou macros Kubernetes.
Monitoramento via Zabbix deve ser modelado separadamente conforme a necessidade
do ambiente.
