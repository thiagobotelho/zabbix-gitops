# zabbix-gitops

Stack Zabbix 7.4 para laboratório OpenShift Local: servidor, frontend,
PostgreSQL 16 e Agent 2. O overlay `desenvolvimento` usa réplicas únicas e
recursos reduzidos; não é um desenho de alta disponibilidade.


## Arquitetura

```mermaid
flowchart LR
    Web[Zabbix Web/API] --> Server[Zabbix Server]
    Server --> DB[(PostgreSQL)]
    Server -->|passive checks :10050| AgentSvc[Service zabbix-agent2]
    Agent[Zabbix Agent2] -->|active checks :10051| Server
    AgentSvc --> Agent
    Grafana[Grafana datasource] --> Web
    Keycloak[Keycloak SAML] --> Web
    Server -->|HTTP agent + token SA| KubeAPI[OpenShift/Kubernetes API]
    Server -->|HTTP agent| Obs[Argo CD / Keycloak / Grafana / Pyroscope]
```

O Zabbix complementa a observabilidade com monitoramento sintético/API, hosts,
triggers e integração com Grafana. O SSO usa SAML via Keycloak.

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
- habilita JIT provisioning SAML, usando atributos `username`, `firstName`,
  `lastName` e `groups`;
- mapeia grupos Keycloak para grupos/roles Zabbix;
- garante usuários locais `zabbix-admin` e `observability-admin` como fallback;
- cria/atualiza hosts Agent2 usando o Service `zabbix-agent2:10050`, evitando
  checks passivos contra `127.0.0.1`;
- cria hosts e web scenarios HTTP para CRC API, OpenShift GitOps, Keycloak,
  Grafana e o próprio Zabbix;
- cria/vincula templates HTTP funcionais para OpenShift API, Argo CD, Keycloak,
  Grafana, Zabbix Web, Prometheus Apps e Pyroscope;
- importa/atualiza os templates oficiais Kubernetes 7.4 do Zabbix e cria hosts
  que os reutilizam.

### Secrets

| Secret | Namespace | Chaves | Consumidor |
|---|---|---|---|
| `zabbix-db` | `zabbix` | `username`, `password`, `database` | PostgreSQL, Zabbix Server e Zabbix Web |
| `zabbix-kubernetes-monitor-token` | `zabbix` | `token`, `ca.crt`, `namespace` | Zabbix API bootstrap e templates Kubernetes oficiais |
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

### JIT provisioning

O bootstrap configura JIT com os mappers SAML provisionados pelo
`keycloak-gitops`:

| Atributo SAML | Variável | Uso no Zabbix |
|---|---|---|
| `username` | `ZABBIX_SAML_LOGIN_ATTRIBUTE` | login/alias do usuário |
| `firstName` | `ZABBIX_SAML_FIRST_NAME_ATTRIBUTE` | nome |
| `lastName` | `ZABBIX_SAML_LAST_NAME_ATTRIBUTE` | sobrenome |
| `groups` | `ZABBIX_SAML_GROUP_ATTRIBUTE` | mapeamento de grupos |

Mapeamentos criados:

| Grupo Keycloak | Grupo Zabbix | Role |
|---|---|---|
| `/observability/zabbix-super-admins` | `Zabbix administrators` | `Super admin role` |
| `/observability/zabbix-admins` | `Zabbix administrators` | `Super admin role` |
| `/observability/zabbix-users` | `Grafana datasource readers` | `User role` |
| `/observability/zabbix-guests` | `Grafana datasource readers` | `User role` |

O grupo `Disabled provisioned users` é criado com `users_status=disabled` e
configurado em `disabled_usrgrpid`, permitindo desabilitar usuários
deprovisionados pelo IdP.

### Zabbix Agent2

O Agent2 roda em pod separado do Zabbix Server. Em Kubernetes, `127.0.0.1` só
apontaria para o próprio pod do Server; por isso checks passivos devem usar o
Service `zabbix-agent2` na porta `10050`. O bootstrap cria/atualiza os hosts
`openshift-local` e `Zabbix server` para essa interface DNS.

O container Agent2 aceita passivos de `0.0.0.0/0` porque o IP de origem do pod
do Server não é o ClusterIP do Service. A restrição de rede fica na
`NetworkPolicy allow-zabbix-server-to-agent2`, permitindo ingresso somente do
pod `app=zabbix-server`.

## Templates funcionais

O bootstrap trabalha em duas camadas:

1. Templates oficiais Kubernetes do Zabbix, importados automaticamente pelo
   bootstrap a partir da integração oficial:
   `Kubernetes nodes by HTTP`, `Kubernetes cluster state by HTTP` e
   `Kubernetes API server by HTTP`, além dos templates de kubelet,
   controller-manager e scheduler usados por descoberta. Eles coletam estado do
   cluster, nodes e métricas da API usando token de ServiceAccount, não apenas
   web scenarios.
2. Templates locais criados pela API do Zabbix para endpoints críticos:
   `Template OpenShift API by HTTP`, `Template Argo CD by HTTP`,
   `Template Keycloak by HTTP`, `Template Grafana by HTTP`,
   `Template Zabbix Web by HTTP`, `Template Prometheus Apps by HTTP` e
   `Template Pyroscope by HTTP`.

Se `ZABBIX_IMPORT_KUBERNETES_TEMPLATES=false`, o bootstrap não baixa os YAMLs
oficiais e apenas tenta reutilizar templates já existentes. Os hosts oficiais
usam as macros:

| Macro | Valor padrão | Observação |
|---|---|---|
| `{$KUBE.API.URL}` | `https://kubernetes.default.svc.cluster.local:443` | API interna do cluster |
| `{$KUBE.API.SERVER.URL}` | `https://kubernetes.default.svc.cluster.local:443/metrics` | Endpoint `/metrics` do API server |
| `{$KUBE.API.TOKEN}` | Secret `zabbix-kubernetes-monitor-token` | Criada como macro secreta no Zabbix |
| `{$KUBE.NODES.ENDPOINT.NAME}` | `zabbix-agent2` | Endpoint usado pelos templates de nodes |
| `{$KUBE.LLD.FILTER.*}` | filtros do `.env` | Limita descoberta para o CRC/local lab |

Variáveis úteis:

```bash
ZABBIX_PROVISION_KUBERNETES_TEMPLATES=true
ZABBIX_IMPORT_KUBERNETES_TEMPLATES=true
ZABBIX_KUBERNETES_TEMPLATE_RELEASE=7.4
ZABBIX_PROVISION_COMPONENT_TEMPLATES=true
ZABBIX_KUBERNETES_API_URL=https://kubernetes.default.svc.cluster.local:443
ZABBIX_KUBE_NAMESPACE_MATCHES='^(default|openshift-.+|grafana|zabbix|keycloak.*|tempo|loki|pyroscope|observability.*)$'
PYROSCOPE_READY_URL=http://pyroscope.pyroscope.svc:4040/ready
PROMETHEUS_APPS_READY_URL=http://apps-monitoring-prometheus.observability-apps.svc:9090/-/ready
```

## Validação

```bash
oc -n zabbix get pods,svc,route
oc -n zabbix get sa,secret zabbix-kubernetes-monitor zabbix-kubernetes-monitor-token
oc -n zabbix get svc zabbix-agent2
curl -k "$(oc -n zabbix get route zabbix -o jsonpath='https://{.spec.host}')/api_jsonrpc.php"
oc -n grafana get secret zabbix-datasource
```

Para monitoramento Kubernetes completo em produção, revise RBAC, volume de LLD
e filtros antes de ampliar a descoberta para todos os namespaces/nodes.

Referências:

- https://www.zabbix.com/documentation/7.4/en/manual/installation/containers
- https://www.zabbix.com/documentation/7.4/en/manual/web_interface/frontend_sections/users/authentication/saml
- https://www.zabbix.com/documentation/7.4/en/manual/api/reference/user/create
- https://www.zabbix.com/documentation/7.4/en/manual/api/reference/userdirectory/create
- https://www.zabbix.com/integrations/kubernetes

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
