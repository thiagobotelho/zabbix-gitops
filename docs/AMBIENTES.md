# Ambientes

Este repositório usa `base/` e `overlays/{desenvolvimento,aceite,producao}`.

- `desenvolvimento`: Zabbix Server/Web/PostgreSQL/Agent2 com recursos reduzidos para CRC.
- `aceite`: use para homologar SSO, datasource Grafana e templates antes da produção.
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
- `grafana/zabbix-datasource`: `username`, `password`, criado/atualizado por `scripts/bootstrap-zabbix.sh`.

Automação preservada:

- `.github/workflows/validate.yml`: agora renderiza todos os Kustomizations e executa `yamllint`.
- `scripts/bootstrap-zabbix.sh`: configura API, SAML, usuário técnico Grafana e monitores HTTP; descobre Routes quando URLs não são informadas no `.env`.
