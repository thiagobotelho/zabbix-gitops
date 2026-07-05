# zabbix-gitops

Stack Zabbix 7.4 para laboratório OpenShift Local: servidor, frontend,
PostgreSQL 16 e Agent 2. O overlay `crc` usa réplicas únicas e recursos
reduzidos; não é um desenho de alta disponibilidade.

## Pré-requisito

```bash
oc new-project zabbix
oc -n zabbix create secret generic zabbix-db \
  --from-literal=username=zabbix \
  --from-literal=password="$(openssl rand -base64 32)" \
  --from-literal=database=zabbix
oc apply -k overlays/crc
```

Para monitoramento Kubernetes completo, use o chart oficial Zabbix Kubernetes
da linha 7.4 e revise RBAC/SCC antes de habilitar coleta em nível de nó.

Referência: https://www.zabbix.com/documentation/7.4/en/manual/installation/containers
