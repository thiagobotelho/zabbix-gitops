#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [[ -f "${ROOT_DIR}/.env" ]]; then
  # shellcheck disable=SC1091
  set -a; source "${ROOT_DIR}/.env"; set +a
fi

OC_BIN="${OC_BIN:-oc}"
ZABBIX_NAMESPACE="${ZABBIX_NAMESPACE:-zabbix}"
ZABBIX_ROUTE_NAME="${ZABBIX_ROUTE_NAME:-zabbix}"
ZABBIX_ADMIN_USER="${ZABBIX_ADMIN_USER:-Admin}"
ZABBIX_ADMIN_PASSWORD="${ZABBIX_ADMIN_PASSWORD:-}"
GRAFANA_NAMESPACE="${GRAFANA_NAMESPACE:-grafana}"
ZABBIX_GRAFANA_SECRET="${ZABBIX_GRAFANA_SECRET:-zabbix-datasource}"
ZABBIX_GRAFANA_USER="${ZABBIX_GRAFANA_USER:-grafana-datasource}"
ZABBIX_GRAFANA_PASSWORD="${ZABBIX_GRAFANA_PASSWORD:-}"
ZABBIX_ENABLE_SAML="${ZABBIX_ENABLE_SAML:-true}"
ZABBIX_ENABLE_SAML_JIT="${ZABBIX_ENABLE_SAML_JIT:-true}"
KEYCLOAK_NAMESPACE="${KEYCLOAK_NAMESPACE:-keycloak-dev}"
KEYCLOAK_ROUTE_NAME="${KEYCLOAK_ROUTE_NAME:-keycloak}"
KEYCLOAK_BASE_URL="${KEYCLOAK_BASE_URL:-}"
KEYCLOAK_REALM="${KEYCLOAK_REALM:-observability}"
ZABBIX_SAML_ENTITY_ID="${ZABBIX_SAML_ENTITY_ID:-zabbix}"
ZABBIX_SAML_LOGIN_ATTRIBUTE="${ZABBIX_SAML_LOGIN_ATTRIBUTE:-username}"
ZABBIX_SAML_GROUP_ATTRIBUTE="${ZABBIX_SAML_GROUP_ATTRIBUTE:-groups}"
ZABBIX_SAML_FIRST_NAME_ATTRIBUTE="${ZABBIX_SAML_FIRST_NAME_ATTRIBUTE:-firstName}"
ZABBIX_SAML_LAST_NAME_ATTRIBUTE="${ZABBIX_SAML_LAST_NAME_ATTRIBUTE:-lastName}"
ZABBIX_DISABLED_USER_GROUP="${ZABBIX_DISABLED_USER_GROUP:-Disabled provisioned users}"
ZABBIX_BASE_URL="${ZABBIX_BASE_URL:-}"
ZABBIX_PROVISION_MONITORING="${ZABBIX_PROVISION_MONITORING:-true}"
ZABBIX_PROVISION_AGENT="${ZABBIX_PROVISION_AGENT:-true}"
ZABBIX_PROVISION_KUBERNETES_TEMPLATES="${ZABBIX_PROVISION_KUBERNETES_TEMPLATES:-true}"
ZABBIX_IMPORT_KUBERNETES_TEMPLATES="${ZABBIX_IMPORT_KUBERNETES_TEMPLATES:-true}"
ZABBIX_KUBERNETES_TEMPLATE_RELEASE="${ZABBIX_KUBERNETES_TEMPLATE_RELEASE:-7.4}"
ZABBIX_PROVISION_COMPONENT_TEMPLATES="${ZABBIX_PROVISION_COMPONENT_TEMPLATES:-true}"
ZABBIX_AGENT_HOST="${ZABBIX_AGENT_HOST:-openshift-local}"
ZABBIX_AGENT_VISIBLE_NAME="${ZABBIX_AGENT_VISIBLE_NAME:-OpenShift Local - Zabbix Agent2}"
ZABBIX_AGENT_DNS="${ZABBIX_AGENT_DNS:-zabbix-agent2}"
ZABBIX_AGENT_PORT="${ZABBIX_AGENT_PORT:-10050}"
ZABBIX_AGENT_TEMPLATE="${ZABBIX_AGENT_TEMPLATE:-Linux by Zabbix agent}"
ZABBIX_DEFAULT_AGENT_HOST="${ZABBIX_DEFAULT_AGENT_HOST:-Zabbix server}"
ZABBIX_COMPONENT_TEMPLATE_GROUP="${ZABBIX_COMPONENT_TEMPLATE_GROUP:-Templates/Observability}"
ZABBIX_KUBERNETES_MONITOR_SECRET="${ZABBIX_KUBERNETES_MONITOR_SECRET:-zabbix-kubernetes-monitor-token}"
ZABBIX_KUBERNETES_API_URL="${ZABBIX_KUBERNETES_API_URL:-}"
ZABBIX_KUBERNETES_NODES_TEMPLATE="${ZABBIX_KUBERNETES_NODES_TEMPLATE:-Kubernetes nodes by HTTP}"
ZABBIX_KUBERNETES_CLUSTER_TEMPLATE="${ZABBIX_KUBERNETES_CLUSTER_TEMPLATE:-Kubernetes cluster state by HTTP}"
ZABBIX_KUBERNETES_API_TEMPLATE="${ZABBIX_KUBERNETES_API_TEMPLATE:-Kubernetes API server by HTTP}"
ZABBIX_KUBERNETES_KUBELET_TEMPLATE="${ZABBIX_KUBERNETES_KUBELET_TEMPLATE:-Kubernetes Kubelet by HTTP}"
ZABBIX_KUBERNETES_CONTROLLER_TEMPLATE="${ZABBIX_KUBERNETES_CONTROLLER_TEMPLATE:-Kubernetes Controller manager by HTTP}"
ZABBIX_KUBERNETES_SCHEDULER_TEMPLATE="${ZABBIX_KUBERNETES_SCHEDULER_TEMPLATE:-Kubernetes Scheduler by HTTP}"
ZABBIX_KUBERNETES_NODES_ENDPOINT_NAME="${ZABBIX_KUBERNETES_NODES_ENDPOINT_NAME:-zabbix-agent2}"
ZABBIX_KUBE_NODE_MATCHES="${ZABBIX_KUBE_NODE_MATCHES:-.*}"
ZABBIX_KUBE_NAMESPACE_MATCHES="${ZABBIX_KUBE_NAMESPACE_MATCHES:-^(default|kube-.+|openshift-.+|argocd|openshift-gitops|grafana|zabbix|keycloak.*|tempo|loki|pyroscope|observability.*)$}"
ARGOCD_NAMESPACE="${ARGOCD_NAMESPACE:-openshift-gitops}"
ARGOCD_ROUTE_NAME="${ARGOCD_ROUTE_NAME:-openshift-gitops-server}"
GRAFANA_ROUTE_NAME="${GRAFANA_ROUTE_NAME:-grafana-route}"
PYROSCOPE_READY_URL="${PYROSCOPE_READY_URL:-http://pyroscope.pyroscope.svc:4040/ready}"
PROMETHEUS_APPS_READY_URL="${PROMETHEUS_APPS_READY_URL:-http://apps-monitoring-prometheus.observability-apps.svc:9090/-/ready}"

require() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "[ERROR] Comando obrigatório não encontrado: $1" >&2
    exit 1
  }
}

require "${OC_BIN}"
require curl
require jq
require openssl
require base64

if [[ -z "${ZABBIX_ADMIN_PASSWORD}" ]]; then
  echo "[ERROR] Defina ZABBIX_ADMIN_PASSWORD no .env ou no ambiente antes de executar o bootstrap." >&2
  exit 1
fi

route_url() {
  local namespace="$1"
  local route="$2"
  local host
  host="$("${OC_BIN}" -n "${namespace}" get route "${route}" -o jsonpath='{.spec.host}' 2>/dev/null || true)"
  if [[ -n "${host}" ]]; then
    printf 'https://%s' "${host}"
  fi
}

if [[ -z "${KEYCLOAK_BASE_URL}" ]]; then
  KEYCLOAK_BASE_URL="$(route_url "${KEYCLOAK_NAMESPACE}" "${KEYCLOAK_ROUTE_NAME}")"
fi

if [[ -z "${ZABBIX_BASE_URL}" ]]; then
  ZABBIX_BASE_URL="$(route_url "${ZABBIX_NAMESPACE}" "${ZABBIX_ROUTE_NAME}")"
fi

if [[ -z "${ZABBIX_API_URL:-}" ]]; then
  if [[ -z "${ZABBIX_BASE_URL}" ]]; then
    echo "[ERROR] Defina ZABBIX_API_URL/ZABBIX_BASE_URL ou exponha a Route ${ZABBIX_NAMESPACE}/${ZABBIX_ROUTE_NAME}." >&2
    exit 1
  fi
  ZABBIX_API_URL="${ZABBIX_BASE_URL}/api_jsonrpc.php"
fi

json_escape() {
  jq -Rn --arg value "$1" '$value'
}

zbx_call() {
  local method="$1"
  local params="$2"
  local id="${3:-1}"
  curl -ksS \
    -H 'Content-Type: application/json-rpc' \
    -H "Authorization: Bearer ${ZABBIX_TOKEN}" \
    -d "{\"jsonrpc\":\"2.0\",\"method\":\"${method}\",\"params\":${params},\"id\":${id}}" \
    "${ZABBIX_API_URL}"
}

zbx_result() {
  local method="$1"
  local params="$2"
  local response
  response="$(zbx_call "${method}" "${params}")"
  if printf '%s' "${response}" | jq -e '.error' >/dev/null; then
    printf '%s\n' "${response}" | jq -r '.error | "[ERROR] Zabbix API: \(.message) - \(.data // "")"' >&2
    exit 1
  fi
  printf '%s' "${response}" | jq '.result'
}

zbx_payload_result() {
  local payload_file="$1"
  local response
  response="$(curl -ksS \
    -H 'Content-Type: application/json-rpc' \
    -H "Authorization: Bearer ${ZABBIX_TOKEN}" \
    -d @"${payload_file}" \
    "${ZABBIX_API_URL}")"
  if printf '%s' "${response}" | jq -e '.error' >/dev/null; then
    printf '%s\n' "${response}" | jq -r '.error | "[ERROR] Zabbix API: \(.message) - \(.data // "")"' >&2
    exit 1
  fi
  printf '%s' "${response}" | jq '.result'
}

login_response="$(curl -ksS \
  -H 'Content-Type: application/json-rpc' \
  -d "$(jq -n \
    --arg user "${ZABBIX_ADMIN_USER}" \
    --arg pass "${ZABBIX_ADMIN_PASSWORD}" \
    '{jsonrpc:"2.0",method:"user.login",params:{username:$user,password:$pass},id:1}')" \
  "${ZABBIX_API_URL}")"

ZABBIX_TOKEN="$(printf '%s' "${login_response}" | jq -r '.result // empty')"
if [[ -z "${ZABBIX_TOKEN}" ]]; then
  echo "[ERROR] Não foi possível autenticar no Zabbix API. Defina ZABBIX_ADMIN_PASSWORD no .env." >&2
  exit 1
fi

existing_secret_key() {
  local key="$1"
  "${OC_BIN}" -n "${GRAFANA_NAMESPACE}" get secret "${ZABBIX_GRAFANA_SECRET}" \
    -o "jsonpath={.data.${key}}" 2>/dev/null | base64 -d 2>/dev/null || true
}

ensure_host_group() {
  local name="$1"
  local groupid
  groupid="$(zbx_result hostgroup.get "$(jq -n --arg name "${name}" '{output:["groupid","name"],filter:{name:$name}}')" | jq -r '.[0].groupid // empty')"
  if [[ -z "${groupid}" ]]; then
    groupid="$(zbx_result hostgroup.create "$(jq -n --arg name "${name}" '{name:$name}')" | jq -r '.groupids[0]')"
  fi
  printf '%s' "${groupid}"
}

role_id_by_name() {
  local name="$1"
  zbx_result role.get "$(jq -n --arg name "${name}" '{output:["roleid","name"],filter:{name:$name}}')" | jq -r '.[0].roleid // empty'
}

user_group_id_by_name() {
  local name="$1"
  zbx_result usergroup.get "$(jq -n --arg name "${name}" '{output:["usrgrpid","name"],filter:{name:$name}}')" | jq -r '.[0].usrgrpid // empty'
}

ensure_disabled_user_group() {
  local name="$1"
  local usrgrpid
  usrgrpid="$(user_group_id_by_name "${name}")"
  if [[ -z "${usrgrpid}" ]]; then
    zbx_result usergroup.create "$(jq -n --arg name "${name}" '{name:$name, users_status:1}')" >/dev/null
    usrgrpid="$(user_group_id_by_name "${name}")"
  else
    zbx_result usergroup.update "$(jq -n --arg id "${usrgrpid}" '{usrgrpid:$id, users_status:1}')" >/dev/null
  fi
  printf '%s' "${usrgrpid}"
}

ensure_user_group_with_read_rights() {
  local name="$1"
  local host_group_id="$2"
  local usrgrpid
  local rights
  rights="$(jq -n --arg id "${host_group_id}" '[{id:$id, permission:2}]')"
  usrgrpid="$(user_group_id_by_name "${name}")"
  if [[ -z "${usrgrpid}" ]]; then
    zbx_result usergroup.create "$(jq -n --arg name "${name}" --argjson rights "${rights}" '{name:$name, hostgroup_rights:$rights}')" >/dev/null
    usrgrpid="$(user_group_id_by_name "${name}")"
  else
    zbx_result usergroup.update "$(jq -n --arg id "${usrgrpid}" --argjson rights "${rights}" '{usrgrpid:$id, hostgroup_rights:$rights}')" >/dev/null
  fi
  printf '%s' "${usrgrpid}"
}

ensure_user() {
  local username="$1"
  local first_name="$2"
  local last_name="$3"
  local roleid="$4"
  local usrgrpid="$5"
  local password="${6:-}"
  local userid
  local params

  userid="$(zbx_result user.get "$(jq -n --arg username "${username}" '{output:["userid","username"],filter:{username:$username}}')" | jq -r '.[0].userid // empty')"
  params="$(jq -n \
    --arg username "${username}" \
    --arg first_name "${first_name}" \
    --arg last_name "${last_name}" \
    --arg roleid "${roleid}" \
    --arg usrgrpid "${usrgrpid}" \
    --arg userid "${userid}" \
    --arg password "${password}" \
    '{username:$username,name:$first_name,surname:$last_name,roleid:$roleid,usrgrps:[{usrgrpid:$usrgrpid}]}
     + (if $userid != "" then {userid:$userid} else {} end)
     + (if $password != "" then {passwd:$password} else {} end)')"

  if [[ -z "${userid}" ]]; then
    zbx_result user.create "${params}" >/dev/null
  else
    zbx_result user.update "${params}" >/dev/null
  fi
}

template_id_by_name() {
  local name="$1"
  local templateid
  templateid="$(zbx_result template.get "$(jq -n --arg name "${name}" '{output:["templateid","host","name"],filter:{host:$name}}')" | jq -r '.[0].templateid // empty')"
  if [[ -z "${templateid}" ]]; then
    templateid="$(zbx_result template.get "$(jq -n --arg name "${name}" '{output:["templateid","host","name"],filter:{name:$name}}')" | jq -r '.[0].templateid // empty')"
  fi
  printf '%s' "${templateid}"
}

ensure_template_group() {
  local name="$1"
  local groupid
  groupid="$(zbx_result templategroup.get "$(jq -n --arg name "${name}" '{output:["groupid","name"],filter:{name:$name}}')" | jq -r '.[0].groupid // empty')"
  if [[ -z "${groupid}" ]]; then
    groupid="$(zbx_result templategroup.create "$(jq -n --arg name "${name}" '{name:$name}')" | jq -r '.groupids[0]')"
  fi
  printf '%s' "${groupid}"
}

ensure_template() {
  local template_name="$1"
  local groupid="$2"
  local templateid
  templateid="$(template_id_by_name "${template_name}")"
  if [[ -z "${templateid}" ]]; then
    templateid="$(zbx_result template.create "$(jq -n \
      --arg host "${template_name}" \
      --arg name "${template_name}" \
      --arg groupid "${groupid}" \
      '{host:$host,name:$name,groups:[{groupid:$groupid}]}')" | jq -r '.templateids[0]')"
  fi
  printf '%s' "${templateid}"
}

ensure_template_item_http() {
  local templateid="$1"
  local name="$2"
  local key="$3"
  local url="$4"
  local expected_codes="$5"
  local component="$6"
  local itemid params

  itemid="$(zbx_result item.get "$(jq -n --arg templateid "${templateid}" --arg key "${key}" '{output:["itemid","key_"],hostids:[$templateid],filter:{key_:$key}}')" | jq -r '.[0].itemid // empty')"
  params="$(jq -n \
    --arg itemid "${itemid}" \
    --arg templateid "${templateid}" \
    --arg name "${name}" \
    --arg key "${key}" \
    --arg url "${url}" \
    --arg codes "${expected_codes}" \
    --arg component "${component}" \
    '{name:$name,
      key_:$key,
      type:"19",
      value_type:"4",
      delay:"1m",
      history:"7d",
      timeout:"10s",
      url:$url,
      status_codes:$codes,
      tags:[{tag:"component",value:$component},{tag:"source",value:"zabbix-http-agent"}]}
     + (if $itemid != "" then {itemid:$itemid} else {hostid:$templateid} end)')"

  if [[ -z "${itemid}" ]]; then
    zbx_result item.create "${params}" >/dev/null
  else
    zbx_result item.update "${params}" >/dev/null
  fi
}

ensure_template_trigger_nodata() {
  local templateid="$1"
  local template_name="$2"
  local key="$3"
  local description="$4"
  local component="$5"
  local triggerid expression params

  triggerid="$(zbx_result trigger.get "$(jq -n --arg templateid "${templateid}" --arg description "${description}" '{output:["triggerid","description"],hostids:[$templateid],filter:{description:$description}}')" | jq -r '.[0].triggerid // empty')"
  expression="nodata(/${template_name}/${key},5m)=1"
  params="$(jq -n \
    --arg triggerid "${triggerid}" \
    --arg description "${description}" \
    --arg expression "${expression}" \
    --arg component "${component}" \
    '{description:$description,
      expression:$expression,
      priority:"3",
      tags:[{tag:"component",value:$component},{tag:"source",value:"zabbix-http-agent"}]}
     + (if $triggerid != "" then {triggerid:$triggerid} else {} end)')"

  if [[ -z "${triggerid}" ]]; then
    zbx_result trigger.create "${params}" >/dev/null
  else
    zbx_result trigger.update "${params}" >/dev/null
  fi
}

ensure_component_template() {
  local template_name="$1"
  local item_name="$2"
  local key="$3"
  local component="$4"
  local template_group_id templateid

  template_group_id="$(ensure_template_group "${ZABBIX_COMPONENT_TEMPLATE_GROUP}")"
  templateid="$(ensure_template "${template_name}" "${template_group_id}")"
  ensure_template_item_http "${templateid}" "${item_name}" "${key}" '{$HEALTH.URL}' "200-399" "${component}"
  ensure_template_trigger_nodata "${templateid}" "${template_name}" "${key}" "${template_name}: health endpoint sem dados por 5m" "${component}"
  printf '%s' "${templateid}"
}

ensure_host_macros() {
  local hostid="$1"
  local macros_json="$2"
  local encoded macro value type hostmacroid params

  while IFS= read -r encoded; do
    [[ -z "${encoded}" ]] && continue
    macro="$(printf '%s' "${encoded}" | base64 -d | jq -r '.macro')"
    value="$(printf '%s' "${encoded}" | base64 -d | jq -r '.value // ""')"
    type="$(printf '%s' "${encoded}" | base64 -d | jq -r '.type // ""')"
    hostmacroid="$(zbx_result usermacro.get "$(jq -n --arg hostid "${hostid}" --arg macro "${macro}" '{output:["hostmacroid","macro"],hostids:[$hostid],filter:{macro:$macro}}')" | jq -r '.[0].hostmacroid // empty')"
    if [[ -z "${hostmacroid}" ]]; then
      params="$(jq -n \
        --arg hostid "${hostid}" \
        --arg macro "${macro}" \
        --arg value "${value}" \
        --arg type "${type}" \
        '{hostid:$hostid,macro:$macro,value:$value}
         + (if $type != "" then {type:$type} else {} end)')"
    else
      params="$(jq -n \
        --arg hostmacroid "${hostmacroid}" \
        --arg value "${value}" \
        --arg type "${type}" \
        '{hostmacroid:$hostmacroid,value:$value}
         + (if $type != "" then {type:$type} else {} end)')"
    fi

    if [[ -z "${hostmacroid}" ]]; then
      zbx_result usermacro.create "${params}" >/dev/null
    else
      zbx_result usermacro.update "${params}" >/dev/null
    fi
  done < <(printf '%s' "${macros_json}" | jq -r '.[] | @base64')
}

ensure_host_with_templates_and_macros() {
  local host="$1"
  local visible="$2"
  local component="$3"
  local host_group_id="$4"
  local macros_json="$5"
  shift 5

  local template_name templateid desired_templates
  desired_templates="[]"
  for template_name in "$@"; do
    templateid="$(template_id_by_name "${template_name}")"
    if [[ -z "${templateid}" ]]; then
      echo "[WARN] Template '${template_name}' não encontrado; host ${host} não receberá esse vínculo." >&2
      continue
    fi
    desired_templates="$(printf '%s' "${desired_templates}" | jq --arg templateid "${templateid}" '. + [{templateid:$templateid}]')"
  done

  if [[ "$(printf '%s' "${desired_templates}" | jq 'length')" == "0" ]]; then
    echo "[WARN] Host ${host} ignorado: nenhum template funcional disponível." >&2
    return 0
  fi

  local host_data hostid interfaceid groups templates interface params
  host_data="$(zbx_result host.get "$(jq -n --arg host "${host}" '{output:["hostid"],selectGroups:["groupid"],selectInterfaces:["interfaceid","type","main"],selectParentTemplates:["templateid"],filter:{host:$host}}')")"
  hostid="$(printf '%s' "${host_data}" | jq -r '.[0].hostid // empty')"
  interfaceid="$(printf '%s' "${host_data}" | jq -r '.[0].interfaces[]? | select(.type == "1" and .main == "1") | .interfaceid' | head -n 1)"
  groups="$(printf '%s' "${host_data}" | jq --arg groupid "${host_group_id}" '([.[0].groups[]? | {groupid:.groupid}] + [{groupid:$groupid}]) | unique_by(.groupid)')"
  templates="$(printf '%s' "${host_data}" | jq --argjson desired "${desired_templates}" '([.[0].parentTemplates[]? | {templateid:.templateid}] + $desired) | unique_by(.templateid)')"
  interface="$(jq -n \
    --arg interfaceid "${interfaceid}" \
    '{type:1,main:1,useip:1,ip:"127.0.0.1",dns:"",port:"10050"}
     + (if $interfaceid != "" then {interfaceid:$interfaceid} else {} end)')"

  params="$(jq -n \
    --arg host "${host}" \
    --arg visible "${visible}" \
    --arg hostid "${hostid}" \
    --arg component "${component}" \
    --argjson groups "${groups}" \
    --argjson templates "${templates}" \
    --argjson interface "${interface}" \
    '{host:$host,
      name:$visible,
      groups:$groups,
      templates:$templates,
      interfaces:[$interface],
      tags:[{tag:"domain",value:"openshift-local"},{tag:"component",value:$component},{tag:"provisioned-by",value:"zabbix-gitops"}]}
     + (if $hostid != "" then {hostid:$hostid} else {} end)')"

  if [[ -z "${hostid}" ]]; then
    hostid="$(zbx_result host.create "${params}" | jq -r '.hostids[0]')"
  else
    zbx_result host.update "${params}" >/dev/null
  fi

  ensure_host_macros "${hostid}" "${macros_json}"
}

kube_token_from_secret() {
  local token_b64
  token_b64="$("${OC_BIN}" -n "${ZABBIX_NAMESPACE}" get secret "${ZABBIX_KUBERNETES_MONITOR_SECRET}" -o jsonpath='{.data.token}' 2>/dev/null || true)"
  if [[ -z "${token_b64}" ]]; then
    return 0
  fi
  printf '%s' "${token_b64}" | base64 -d
}

kubernetes_template_url() {
  local path="$1"
  printf 'https://git.zabbix.com/projects/ZBX/repos/zabbix/raw/templates/app/kubernetes_http/%s?at=release/%s' \
    "${path}" \
    "${ZABBIX_KUBERNETES_TEMPLATE_RELEASE}"
}

import_zabbix_template_from_url() {
  local name="$1"
  local url="$2"
  local tmpdir source_file payload_file

  tmpdir="$(mktemp -d)"
  source_file="${tmpdir}/template.yaml"
  payload_file="${tmpdir}/payload.json"

  if ! curl -fsSL "${url}" -o "${source_file}"; then
    rm -rf "${tmpdir}"
    echo "[WARN] Não foi possível baixar template oficial '${name}' em ${url}; seguindo sem importar." >&2
    return 0
  fi

  jq -n --rawfile source "${source_file}" \
    '{jsonrpc:"2.0",
      method:"configuration.import",
      params:{
        format:"yaml",
        source:$source,
        rules:{
          template_groups:{createMissing:true,updateExisting:true},
          host_groups:{createMissing:true,updateExisting:true},
          templates:{createMissing:true,updateExisting:true},
          templateLinkage:{createMissing:true},
          items:{createMissing:true,updateExisting:true},
          discoveryRules:{createMissing:true,updateExisting:true},
          triggers:{createMissing:true,updateExisting:true},
          graphs:{createMissing:true,updateExisting:true},
          templateDashboards:{createMissing:true,updateExisting:true},
          valueMaps:{createMissing:true,updateExisting:true}
        }},
      id:1}' >"${payload_file}"

  zbx_payload_result "${payload_file}" >/dev/null
  rm -rf "${tmpdir}"
  echo "[OK] Template oficial importado/atualizado: ${name}"
}

import_official_kubernetes_templates() {
  [[ "${ZABBIX_IMPORT_KUBERNETES_TEMPLATES}" == "true" ]] || return 0

  import_zabbix_template_from_url "${ZABBIX_KUBERNETES_NODES_TEMPLATE}" \
    "$(kubernetes_template_url 'kubernetes_nodes_http/template_kubernetes_nodes.yaml')"
  import_zabbix_template_from_url "${ZABBIX_KUBERNETES_CLUSTER_TEMPLATE}" \
    "$(kubernetes_template_url 'kubernetes_state_http/template_kubernetes_state.yaml')"
  import_zabbix_template_from_url "${ZABBIX_KUBERNETES_API_TEMPLATE}" \
    "$(kubernetes_template_url 'kubernetes_api_server_http/template_kubernetes_api_servers.yaml')"
  import_zabbix_template_from_url "${ZABBIX_KUBERNETES_KUBELET_TEMPLATE}" \
    "$(kubernetes_template_url 'kubernetes_kubelet_http/template_kubernetes_kubelet.yaml')"
  import_zabbix_template_from_url "${ZABBIX_KUBERNETES_CONTROLLER_TEMPLATE}" \
    "$(kubernetes_template_url 'kubernetes_controller_manager_http/template_kubernetes_controller_manager.yaml')"
  import_zabbix_template_from_url "${ZABBIX_KUBERNETES_SCHEDULER_TEMPLATE}" \
    "$(kubernetes_template_url 'kubernetes_scheduler_http/template_kubernetes_scheduler.yaml')"
}

ensure_official_kubernetes_hosts() {
  local host_group_id="$1"
  local kube_api_url kube_token macros_json
  kube_api_url="${ZABBIX_KUBERNETES_API_URL:-https://kubernetes.default.svc.cluster.local:443}"
  kube_token="$(kube_token_from_secret)"

  if [[ -z "${kube_token}" ]]; then
    echo "[WARN] Secret ${ZABBIX_NAMESPACE}/${ZABBIX_KUBERNETES_MONITOR_SECRET} sem token disponível; templates Kubernetes oficiais não serão vinculados agora." >&2
    return 0
  fi

  macros_json="$(jq -n \
    --arg api_url "${kube_api_url}" \
    --arg api_metrics_url "${kube_api_url}/metrics" \
    --arg token "${kube_token}" \
    --arg endpoint_name "${ZABBIX_KUBERNETES_NODES_ENDPOINT_NAME}" \
    --arg node_matches "${ZABBIX_KUBE_NODE_MATCHES}" \
    --arg namespace_matches "${ZABBIX_KUBE_NAMESPACE_MATCHES}" \
    '[
      {macro:"{$KUBE.API.URL}",value:$api_url},
      {macro:"{$KUBE.API.SERVER.URL}",value:$api_metrics_url},
      {macro:"{$KUBE.API.TOKEN}",value:$token,type:"1"},
      {macro:"{$KUBE.NODES.ENDPOINT.NAME}",value:$endpoint_name},
      {macro:"{$KUBE.LLD.FILTER.NODE.MATCHES}",value:$node_matches},
      {macro:"{$KUBE.LLD.FILTER.NODE.NOT_MATCHES}",value:"CHANGE_IF_NEEDED"},
      {macro:"{$KUBE.LLD.FILTER.NODE.ROLE.MATCHES}",value:".*"},
      {macro:"{$KUBE.LLD.FILTER.NODE.ROLE.NOT_MATCHES}",value:"CHANGE_IF_NEEDED"},
      {macro:"{$KUBE.LLD.FILTER.POD.NAMESPACE.MATCHES}",value:$namespace_matches},
      {macro:"{$KUBE.LLD.FILTER.POD.NAMESPACE.NOT_MATCHES}",value:"CHANGE_IF_NEEDED"},
      {macro:"{$KUBE.LLD.FILTER.NAMESPACE.MATCHES}",value:$namespace_matches},
      {macro:"{$KUBE.LLD.FILTER.NAMESPACE.NOT_MATCHES}",value:"CHANGE_IF_NEEDED"},
      {macro:"{$KUBE.HTTP.PROXY}",value:""}
    ]')"

  ensure_host_with_templates_and_macros \
    "openshift-local-kubernetes-nodes" \
    "OpenShift Local - Kubernetes Nodes" \
    "kubernetes" \
    "${host_group_id}" \
    "${macros_json}" \
    "${ZABBIX_KUBERNETES_NODES_TEMPLATE}"

  ensure_host_with_templates_and_macros \
    "openshift-local-kubernetes-state" \
    "OpenShift Local - Kubernetes Cluster State" \
    "kubernetes" \
    "${host_group_id}" \
    "${macros_json}" \
    "${ZABBIX_KUBERNETES_CLUSTER_TEMPLATE}"

  ensure_host_with_templates_and_macros \
    "openshift-local-kubernetes-apiserver" \
    "OpenShift Local - Kubernetes API Server" \
    "kubernetes" \
    "${host_group_id}" \
    "${macros_json}" \
    "${ZABBIX_KUBERNETES_API_TEMPLATE}"
}

ensure_component_host() {
  local host="$1"
  local visible="$2"
  local component="$3"
  local url="$4"
  local template_name="$5"
  local item_key="$6"
  local host_group_id="$7"
  local templateid macros_json

  if [[ -z "${url}" ]]; then
    echo "[WARN] Template host ${visible} ignorado: URL não encontrada." >&2
    return 0
  fi

  templateid="$(ensure_component_template "${template_name}" "Health endpoint response" "${item_key}" "${component}")"
  if [[ -z "${templateid}" ]]; then
    echo "[WARN] Template '${template_name}' não pôde ser criado." >&2
    return 0
  fi

  macros_json="$(jq -n --arg url "${url}" '[{macro:"{$HEALTH.URL}",value:$url}]')"
  ensure_host_with_templates_and_macros "${host}" "${visible}" "${component}" "${host_group_id}" "${macros_json}" "${template_name}"
}

ensure_component_template_hosts() {
  local host_group_id="$1"
  local openshift_api_url="$2"
  local argocd_url="$3"
  local grafana_url="$4"
  local keycloak_wellknown_url="$5"

  ensure_component_host "openshift-api" "OpenShift API" "openshift-api" "${openshift_api_url}" "Template OpenShift API by HTTP" "openshift.api.health.raw" "${host_group_id}"
  ensure_component_host "openshift-gitops" "OpenShift GitOps" "argocd" "${argocd_url}" "Template Argo CD by HTTP" "argocd.health.raw" "${host_group_id}"
  ensure_component_host "keycloak" "Keycloak" "keycloak" "${keycloak_wellknown_url}" "Template Keycloak by HTTP" "keycloak.health.raw" "${host_group_id}"
  ensure_component_host "grafana" "Grafana" "grafana" "${grafana_url:+${grafana_url}/api/health}" "Template Grafana by HTTP" "grafana.health.raw" "${host_group_id}"
  ensure_component_host "zabbix-web" "Zabbix Web" "zabbix" "${ZABBIX_BASE_URL}" "Template Zabbix Web by HTTP" "zabbix.web.health.raw" "${host_group_id}"
  ensure_component_host "pyroscope" "Pyroscope" "pyroscope" "${PYROSCOPE_READY_URL}" "Template Pyroscope by HTTP" "pyroscope.health.raw" "${host_group_id}"
  ensure_component_host "prometheus-apps" "Prometheus Apps" "prometheus" "${PROMETHEUS_APPS_READY_URL}" "Template Prometheus Apps by HTTP" "prometheus.apps.health.raw" "${host_group_id}"
}

ensure_agent_host() {
  local host="$1"
  local visible="$2"
  local dns="$3"
  local port="$4"
  local host_group_id="$5"
  local template_name="$6"
  local host_data hostid interfaceid templateid interface groups params

  host_data="$(zbx_result host.get "$(jq -n --arg host "${host}" '{output:["hostid"],selectInterfaces:["interfaceid","type","main"],selectGroups:["groupid"],filter:{host:$host}}')")"
  hostid="$(printf '%s' "${host_data}" | jq -r '.[0].hostid // empty')"
  interfaceid="$(printf '%s' "${host_data}" | jq -r '.[0].interfaces[]? | select(.type == "1" and .main == "1") | .interfaceid' | head -n 1)"
  templateid="$(template_id_by_name "${template_name}")"
  groups="$(printf '%s' "${host_data}" | jq --arg groupid "${host_group_id}" '([.[0].groups[]? | {groupid:.groupid}] + [{groupid:$groupid}]) | unique_by(.groupid)')"

  if [[ -z "${templateid}" ]]; then
    echo "[WARN] Template '${template_name}' não encontrado; host ${host} será criado/atualizado sem template." >&2
  fi

  interface="$(jq -n \
    --arg dns "${dns}" \
    --arg port "${port}" \
    --arg interfaceid "${interfaceid}" \
    '{type:1, main:1, useip:0, ip:"", dns:$dns, port:$port}
     + (if $interfaceid != "" then {interfaceid:$interfaceid} else {} end)')"

  params="$(jq -n \
    --arg host "${host}" \
    --arg visible "${visible}" \
    --arg hostid "${hostid}" \
    --arg templateid "${templateid}" \
    --argjson interface "${interface}" \
    --argjson groups "${groups}" \
    '{host:$host,
      name:$visible,
      groups:$groups,
      interfaces:[$interface],
      tags:[{tag:"domain",value:"openshift-local"},{tag:"component",value:"zabbix-agent2"}]}
     + (if $hostid != "" then {hostid:$hostid} else {} end)
     + (if $templateid != "" then {templates:[{templateid:$templateid}]} else {} end)')"

  if [[ -z "${hostid}" ]]; then
    zbx_result host.create "${params}" >/dev/null
  else
    zbx_result host.update "${params}" >/dev/null
  fi
}

ensure_saml() {
  local directory_id admin_group admin_role reader_group reader_role disabled_group provision_groups jit_enabled
  directory_id="$(zbx_result userdirectory.get "$(jq -n '{output:"extend",filter:{idp_type:"2"}}')" | jq -r '.[0].userdirectoryid // empty')"
  admin_group="$(user_group_id_by_name "Zabbix administrators")"
  admin_role="$(role_id_by_name "Super admin role")"
  reader_group="$(user_group_id_by_name "Grafana datasource readers")"
  reader_role="$(role_id_by_name "User role")"
  disabled_group="$(ensure_disabled_user_group "${ZABBIX_DISABLED_USER_GROUP}")"
  provision_groups="$(jq -n \
    --arg admin_group "${admin_group}" \
    --arg admin_role "${admin_role}" \
    --arg reader_group "${reader_group}" \
    --arg reader_role "${reader_role}" \
    '[
      {name:"/observability/zabbix-super-admins", roleid:$admin_role, user_groups:[{usrgrpid:$admin_group}]},
      {name:"/observability/zabbix-admins", roleid:$admin_role, user_groups:[{usrgrpid:$admin_group}]},
      {name:"/observability/zabbix-users", roleid:$reader_role, user_groups:[{usrgrpid:$reader_group}]},
      {name:"/observability/zabbix-guests", roleid:$reader_role, user_groups:[{usrgrpid:$reader_group}]}
    ]')"
  if [[ "${ZABBIX_ENABLE_SAML_JIT}" == "true" ]]; then
    jit_enabled="1"
  else
    jit_enabled="0"
  fi

  local params
  params="$(jq -n \
    --arg id "${directory_id}" \
    --arg keycloak "${KEYCLOAK_BASE_URL}" \
    --arg realm "${KEYCLOAK_REALM}" \
    --arg entity "${ZABBIX_SAML_ENTITY_ID}" \
    --arg login_attr "${ZABBIX_SAML_LOGIN_ATTRIBUTE}" \
    --arg group_attr "${ZABBIX_SAML_GROUP_ATTRIBUTE}" \
    --arg first_name_attr "${ZABBIX_SAML_FIRST_NAME_ATTRIBUTE}" \
    --arg last_name_attr "${ZABBIX_SAML_LAST_NAME_ATTRIBUTE}" \
    --arg jit_enabled "${jit_enabled}" \
    --argjson provision_groups "${provision_groups}" \
    '{idp_type:"2",
      name:"Keycloak SAML",
      idp_entityid:($keycloak + "/realms/" + $realm),
      sp_entityid:$entity,
      username_attribute:$login_attr,
      sso_url:($keycloak + "/realms/" + $realm + "/protocol/saml"),
      slo_url:($keycloak + "/realms/" + $realm + "/protocol/saml"),
      nameid_format:"urn:oasis:names:tc:SAML:1.1:nameid-format:emailAddress",
      encrypt_nameid:"0",
      encrypt_assertions:"0",
      sign_authn_requests:"0",
      sign_logout_requests:"0",
      sign_logout_responses:"0",
      sign_messages:"0",
      sign_assertions:"1",
      scim_status:"0",
      provision_status:$jit_enabled,
      group_name:$group_attr,
      user_username:$first_name_attr,
      user_lastname:$last_name_attr,
      provision_groups:$provision_groups,
      provision_media:[]}
     + (if $id != "" then {userdirectoryid:$id} else {} end)')"

  if [[ -z "${directory_id}" ]]; then
    zbx_result userdirectory.create "${params}" >/dev/null
  else
    zbx_result userdirectory.update "${params}" >/dev/null
  fi

  zbx_result authentication.update "$(jq -n --arg jit "${jit_enabled}" --arg disabled "${disabled_group}" '{saml_auth_enabled:"1", saml_jit_status:$jit, disabled_usrgrpid:$disabled}')" >/dev/null

  local generated_password
  generated_password="$(openssl rand -base64 36 | tr -d '\n')"
  ensure_user "zabbix-admin" "Zabbix" "Admin" "${admin_role}" "${admin_group}" "${generated_password}"
  generated_password="$(openssl rand -base64 36 | tr -d '\n')"
  ensure_user "observability-admin" "Observability" "Admin" "${admin_role}" "${admin_group}" "${generated_password}"
}

ensure_http_monitor() {
  local host="$1"
  local visible="$2"
  local component="$3"
  local url="$4"
  local expected_codes="${5:-200}"
  local host_group_id="$6"
  local hostid

  hostid="$(zbx_result host.get "$(jq -n --arg host "${host}" '{output:["hostid"],filter:{host:$host}}')" | jq -r '.[0].hostid // empty')"
  local host_params
  host_params="$(jq -n \
    --arg host "${host}" \
    --arg visible "${visible}" \
    --arg groupid "${host_group_id}" \
    --arg component "${component}" \
    --arg hostid "${hostid}" \
    '{host:$host,name:$visible,groups:[{groupid:$groupid}],tags:[{tag:"domain",value:"openshift-local"},{tag:"component",value:$component}]}
     + (if $hostid != "" then {hostid:$hostid} else {} end)')"

  if [[ -z "${hostid}" ]]; then
    hostid="$(zbx_result host.create "${host_params}" | jq -r '.hostids[0]')"
  else
    zbx_result host.update "${host_params}" >/dev/null
  fi

  local scenario_name="Availability - ${visible}"
  local httptestid
  httptestid="$(zbx_result httptest.get "$(jq -n --arg hostid "${hostid}" --arg name "${scenario_name}" '{output:["httptestid"],hostids:$hostid,filter:{name:$name}}')" | jq -r '.[0].httptestid // empty')"

  local http_params
  if [[ -z "${httptestid}" ]]; then
    http_params="$(jq -n \
      --arg hostid "${hostid}" \
      --arg name "${scenario_name}" \
      --arg url "${url}" \
      --arg codes "${expected_codes}" \
      --arg component "${component}" \
      '{name:$name,hostid:$hostid,delay:"1m",steps:[{name:"GET",url:$url,status_codes:$codes,no:1}],tags:[{tag:"component",value:$component}]}')"
    zbx_result httptest.create "${http_params}" >/dev/null
  else
    http_params="$(jq -n \
      --arg httptestid "${httptestid}" \
      --arg name "${scenario_name}" \
      --arg url "${url}" \
      --arg codes "${expected_codes}" \
      --arg component "${component}" \
      '{httptestid:$httptestid,name:$name,delay:"1m",steps:[{name:"GET",url:$url,status_codes:$codes,no:1}],tags:[{tag:"component",value:$component}]}')"
    zbx_result httptest.update "${http_params}" >/dev/null
  fi
}

ensure_http_monitor_if_url() {
  local host="$1"
  local visible="$2"
  local component="$3"
  local url="$4"
  local expected_codes="$5"
  local host_group_id="$6"

  if [[ -z "${url}" ]]; then
    echo "[WARN] Monitor ${visible} ignorado: URL não encontrada. Defina variável no .env se necessário." >&2
    return 0
  fi

  ensure_http_monitor "${host}" "${visible}" "${component}" "${url}" "${expected_codes}" "${host_group_id}"
}

monitor_group_id="$(ensure_host_group "OpenShift Local")"
grafana_usrgrp_id="$(ensure_user_group_with_read_rights "Grafana datasource readers" "${monitor_group_id}")"
grafana_role_id="$(role_id_by_name "User role")"
disabled_usrgrp_id="$(ensure_disabled_user_group "${ZABBIX_DISABLED_USER_GROUP}")"

ZABBIX_GRAFANA_PASSWORD="${ZABBIX_GRAFANA_PASSWORD:-$(existing_secret_key password)}"
ZABBIX_GRAFANA_PASSWORD="${ZABBIX_GRAFANA_PASSWORD:-$(openssl rand -base64 36 | tr -d '\n')}"
ensure_user "${ZABBIX_GRAFANA_USER}" "Grafana" "Datasource" "${grafana_role_id}" "${grafana_usrgrp_id}" "${ZABBIX_GRAFANA_PASSWORD}"

"${OC_BIN}" create namespace "${GRAFANA_NAMESPACE}" --dry-run=client -o yaml | "${OC_BIN}" apply -f - >/dev/null
"${OC_BIN}" -n "${GRAFANA_NAMESPACE}" create secret generic "${ZABBIX_GRAFANA_SECRET}" \
  --from-literal=username="${ZABBIX_GRAFANA_USER}" \
  --from-literal=password="${ZABBIX_GRAFANA_PASSWORD}" \
  --dry-run=client -o yaml | "${OC_BIN}" apply -f - >/dev/null

if [[ "${ZABBIX_ENABLE_SAML}" == "true" ]]; then
  if [[ -z "${KEYCLOAK_BASE_URL}" ]]; then
    echo "[ERROR] Defina KEYCLOAK_BASE_URL ou exponha a Route ${KEYCLOAK_NAMESPACE}/${KEYCLOAK_ROUTE_NAME} para habilitar SAML." >&2
    exit 1
  fi
  ensure_saml
fi

if [[ "${ZABBIX_PROVISION_MONITORING}" == "true" || "${ZABBIX_PROVISION_COMPONENT_TEMPLATES}" == "true" ]]; then
  openshift_api_url="${OPENSHIFT_API_READYZ_URL:-$("${OC_BIN}" whoami --show-server 2>/dev/null || true)}"
  if [[ -n "${openshift_api_url}" ]]; then
    openshift_api_url="${openshift_api_url%/}/readyz"
  fi

  argocd_url="${ARGOCD_BASE_URL:-$(route_url "${ARGOCD_NAMESPACE}" "${ARGOCD_ROUTE_NAME}")}"
  grafana_url="${GRAFANA_BASE_URL:-$(route_url "${GRAFANA_NAMESPACE}" "${GRAFANA_ROUTE_NAME}")}"
  keycloak_wellknown_url=""
  if [[ -n "${KEYCLOAK_BASE_URL}" ]]; then
    keycloak_wellknown_url="${KEYCLOAK_BASE_URL}/realms/${KEYCLOAK_REALM}/.well-known/openid-configuration"
  fi

  if [[ "${ZABBIX_PROVISION_MONITORING}" == "true" ]]; then
    ensure_http_monitor_if_url "openshift-api" "OpenShift API" "openshift-api" "${openshift_api_url}" "200" "${monitor_group_id}"
    ensure_http_monitor_if_url "openshift-gitops" "OpenShift GitOps" "argocd" "${argocd_url}" "200-399" "${monitor_group_id}"
    ensure_http_monitor_if_url "keycloak" "Keycloak" "keycloak" "${keycloak_wellknown_url}" "200" "${monitor_group_id}"
    ensure_http_monitor_if_url "grafana" "Grafana" "grafana" "${grafana_url:+${grafana_url}/api/health}" "200" "${monitor_group_id}"
    ensure_http_monitor_if_url "zabbix-web" "Zabbix Web" "zabbix" "${ZABBIX_BASE_URL}" "200-399" "${monitor_group_id}"
  fi

  if [[ "${ZABBIX_PROVISION_COMPONENT_TEMPLATES}" == "true" ]]; then
    ensure_component_template_hosts "${monitor_group_id}" "${openshift_api_url}" "${argocd_url}" "${grafana_url}" "${keycloak_wellknown_url}"
  fi
fi

if [[ "${ZABBIX_PROVISION_KUBERNETES_TEMPLATES}" == "true" ]]; then
  import_official_kubernetes_templates
  ensure_official_kubernetes_hosts "${monitor_group_id}"
fi

if [[ "${ZABBIX_PROVISION_AGENT}" == "true" ]]; then
  ensure_agent_host "${ZABBIX_AGENT_HOST}" "${ZABBIX_AGENT_VISIBLE_NAME}" "${ZABBIX_AGENT_DNS}" "${ZABBIX_AGENT_PORT}" "${monitor_group_id}" "${ZABBIX_AGENT_TEMPLATE}"
  ensure_agent_host "${ZABBIX_DEFAULT_AGENT_HOST}" "Zabbix Server - Agent2" "${ZABBIX_AGENT_DNS}" "${ZABBIX_AGENT_PORT}" "${monitor_group_id}" "${ZABBIX_AGENT_TEMPLATE}"
fi

echo "[OK] Zabbix API bootstrap concluído."
echo "[OK] Secret ${GRAFANA_NAMESPACE}/${ZABBIX_GRAFANA_SECRET} reconciliado para o Grafana."
echo "[INFO] Credenciais sensíveis não foram exibidas."
