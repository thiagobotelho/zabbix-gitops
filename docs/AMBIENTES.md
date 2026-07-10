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
- `zabbix/zabbix-kubernetes-monitor-token`: token de ServiceAccount criado por
  `base/kubernetes-monitor-rbac.yaml` para os templates Kubernetes por HTTP.
- `grafana/zabbix-datasource`: `username`, `password`, criado/atualizado por `scripts/bootstrap-zabbix.sh`.

Bootstrap:

- `ZABBIX_ENABLE_SAML_JIT=true` ativa JIT SAML via Keycloak.
- `ZABBIX_DISABLED_USER_GROUP` define o grupo desabilitado usado em
  `disabled_usrgrpid`.
- `ZABBIX_AGENT_DNS=zabbix-agent2` e `ZABBIX_AGENT_PORT=10050` definem a
  interface dos hosts Agent2.
- O Service `zabbix-agent2` substitui o uso incorreto de `127.0.0.1:10050`
  quando Server e Agent rodam em pods diferentes.
- `ZABBIX_PROVISION_KUBERNETES_TEMPLATES=true` importa e vincula hosts aos
  templates oficiais `Kubernetes nodes by HTTP`,
  `Kubernetes cluster state by HTTP`, `Kubernetes API server by HTTP`,
  `Kubernetes Kubelet by HTTP`, `Kubernetes Controller manager by HTTP` e
  `Kubernetes Scheduler by HTTP`.
- `ZABBIX_IMPORT_KUBERNETES_TEMPLATES=false` desativa o download/import dos YAMLs
  oficiais e apenas reutiliza templates já existentes.
- `ZABBIX_PROVISION_COMPONENT_TEMPLATES=true` cria templates HTTP funcionais
  para OpenShift API, Argo CD, Keycloak, Grafana, Zabbix Web, Prometheus Apps e
  Pyroscope.
- `ZABBIX_KUBE_NAMESPACE_MATCHES` limita descoberta LLD no CRC. Amplie com
  cuidado em clusters maiores.
