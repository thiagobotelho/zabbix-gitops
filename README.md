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
oc apply -k overlays/desenvolvimento
```

## Bootstrap de API, SSO e integração Grafana

Após a stack subir, execute o bootstrap idempotente:

```bash
cp .env.example .env
# defina ZABBIX_ADMIN_PASSWORD com a senha administrativa atual do Zabbix
scripts/bootstrap-zabbix.sh
```

O script faz:

- autentica na API do Zabbix sem imprimir credenciais;
- cria/atualiza o usuário técnico `grafana-datasource`;
- cria/atualiza o grupo `Grafana datasource readers` com leitura no host group
  `OpenShift Local`;
- cria o Secret `grafana/zabbix-datasource`, consumido pelo datasource do
  `grafana-gitops`;
- habilita SAML no Zabbix 7.4 apontando para o realm `observability` do
  Keycloak;
- garante usuários locais `zabbix-admin` e `observability-admin` para login
  SAML sem depender de JIT;
- cria hosts e web scenarios HTTP para CRC API, OpenShift GitOps, Keycloak,
  Grafana e o próprio Zabbix.

### Secrets

| Secret | Namespace | Chaves | Consumidor |
|---|---|---|---|
| `zabbix-db` | `zabbix` | `username`, `password`, `database` | PostgreSQL, Zabbix Server e Zabbix Web |
| `zabbix-datasource` | `grafana` | `username`, `password` | Grafana datasource Zabbix |

Criação/rotação do banco:

```bash
oc -n zabbix create secret generic zabbix-db \
  --from-literal=username=zabbix \
  --from-literal=password="${ZABBIX_DB_PASSWORD}" \
  --from-literal=database=zabbix \
  --dry-run=client -o yaml | oc apply -f -
```

Rotação do usuário técnico do Grafana:

```bash
ZABBIX_GRAFANA_PASSWORD="$(openssl rand -base64 36)" scripts/bootstrap-zabbix.sh
```

### SSO via Keycloak

O Zabbix 7.4 suporta SAML para SSO. O script configura:

- IdP Entity ID: `${KEYCLOAK_BASE_URL}/realms/observability`;
- SSO/SLO URL: `${KEYCLOAK_BASE_URL}/realms/observability/protocol/saml`;
- SP Entity ID: `zabbix`;
- ACS: `${ZABBIX_BASE_URL}/index_sso.php?acs`.

O client SAML correspondente é mantido em `keycloak-gitops`.

## Validação

```bash
oc -n zabbix get pods,svc,route
curl -k "$(oc -n zabbix get route zabbix -o jsonpath='https://{.spec.host}')/api_jsonrpc.php"
oc -n grafana get secret zabbix-datasource
```

Para monitoramento Kubernetes completo, use o chart oficial Zabbix Kubernetes
da linha 7.4 e revise RBAC/SCC antes de habilitar coleta em nível de nó.

Referências:

- https://www.zabbix.com/documentation/7.4/en/manual/installation/containers
- https://www.zabbix.com/documentation/7.4/en/manual/web_interface/frontend_sections/users/authentication/saml
- https://www.zabbix.com/documentation/7.4/en/manual/api/reference/user/create
- https://www.zabbix.com/documentation/7.4/en/manual/api/reference/userdirectory/create

## Ambientes e validação

```bash
oc kustomize overlays/desenvolvimento >/tmp/zabbix-dev.yaml
oc kustomize overlays/aceite >/tmp/zabbix-aceite.yaml
oc kustomize overlays/producao >/tmp/zabbix-prod.yaml
oc apply --dry-run=client -k overlays/desenvolvimento
```

O Route não fixa host; OpenShift gera o domínio por cluster. O script de
bootstrap descobre Zabbix, Keycloak, Grafana e Argo CD por Route quando URLs não
são informadas no `.env`. Veja `docs/AMBIENTES.md`.

## Automatizações preservadas e ajustadas

- `.github/workflows/validate.yml` foi preservado e ajustado para renderizar
  todos os Kustomizations.
- `scripts/bootstrap-zabbix.sh` foi preservado e ajustado para não depender de
  `apps-crc.testing`/`api.crc.testing`.
- Adicionados overlays padronizados `desenvolvimento`, `aceite` e `producao`.
