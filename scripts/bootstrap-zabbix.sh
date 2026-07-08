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
ZABBIX_ADMIN_PASSWORD="${ZABBIX_ADMIN_PASSWORD:-zabbix}"
GRAFANA_NAMESPACE="${GRAFANA_NAMESPACE:-grafana}"
ZABBIX_GRAFANA_SECRET="${ZABBIX_GRAFANA_SECRET:-zabbix-datasource}"
ZABBIX_GRAFANA_USER="${ZABBIX_GRAFANA_USER:-grafana-datasource}"
ZABBIX_GRAFANA_PASSWORD="${ZABBIX_GRAFANA_PASSWORD:-}"
ZABBIX_ENABLE_SAML="${ZABBIX_ENABLE_SAML:-true}"
KEYCLOAK_BASE_URL="${KEYCLOAK_BASE_URL:-https://keycloak-dev.apps-crc.testing}"
KEYCLOAK_REALM="${KEYCLOAK_REALM:-observability}"
ZABBIX_SAML_ENTITY_ID="${ZABBIX_SAML_ENTITY_ID:-zabbix}"
ZABBIX_BASE_URL="${ZABBIX_BASE_URL:-https://zabbix-zabbix.apps-crc.testing}"
ZABBIX_PROVISION_MONITORING="${ZABBIX_PROVISION_MONITORING:-true}"

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

if [[ -z "${ZABBIX_API_URL:-}" ]]; then
  route_host="$("${OC_BIN}" -n "${ZABBIX_NAMESPACE}" get route "${ZABBIX_ROUTE_NAME}" -o jsonpath='{.spec.host}')"
  ZABBIX_API_URL="https://${route_host}/api_jsonrpc.php"
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
  zbx_result role.get "$(jq -n --arg name "${name}" '{output:["roleid","name"],filter:{name:$name}}')" | jq -r '.[0].roleid'
}

user_group_id_by_name() {
  local name="$1"
  zbx_result usergroup.get "$(jq -n --arg name "${name}" '{output:["usrgrpid","name"],filter:{name:$name}}')" | jq -r '.[0].usrgrpid // empty'
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

ensure_saml() {
  local directory_id
  directory_id="$(zbx_result userdirectory.get "$(jq -n '{output:"extend",filter:{idp_type:"2"}}')" | jq -r '.[0].userdirectoryid // empty')"

  local params
  params="$(jq -n \
    --arg id "${directory_id}" \
    --arg keycloak "${KEYCLOAK_BASE_URL}" \
    --arg realm "${KEYCLOAK_REALM}" \
    --arg entity "${ZABBIX_SAML_ENTITY_ID}" \
    '{idp_type:"2",
      idp_entityid:($keycloak + "/realms/" + $realm),
      sp_entityid:$entity,
      username_attribute:"username",
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
      scim_status:"0"}
     + (if $id != "" then {userdirectoryid:$id} else {} end)')"

  if [[ -z "${directory_id}" ]]; then
    zbx_result userdirectory.create "${params}" >/dev/null
  else
    zbx_result userdirectory.update "${params}" >/dev/null
  fi

  zbx_result authentication.update '{"saml_auth_enabled":"1","saml_jit_status":"0"}' >/dev/null

  local admin_group admin_role generated_password
  admin_group="$(user_group_id_by_name "Zabbix administrators")"
  admin_role="$(role_id_by_name "Super admin role")"
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

monitor_group_id="$(ensure_host_group "OpenShift Local")"
grafana_usrgrp_id="$(ensure_user_group_with_read_rights "Grafana datasource readers" "${monitor_group_id}")"
grafana_role_id="$(role_id_by_name "User role")"

ZABBIX_GRAFANA_PASSWORD="${ZABBIX_GRAFANA_PASSWORD:-$(existing_secret_key password)}"
ZABBIX_GRAFANA_PASSWORD="${ZABBIX_GRAFANA_PASSWORD:-$(openssl rand -base64 36 | tr -d '\n')}"
ensure_user "${ZABBIX_GRAFANA_USER}" "Grafana" "Datasource" "${grafana_role_id}" "${grafana_usrgrp_id}" "${ZABBIX_GRAFANA_PASSWORD}"

"${OC_BIN}" create namespace "${GRAFANA_NAMESPACE}" --dry-run=client -o yaml | "${OC_BIN}" apply -f - >/dev/null
"${OC_BIN}" -n "${GRAFANA_NAMESPACE}" create secret generic "${ZABBIX_GRAFANA_SECRET}" \
  --from-literal=username="${ZABBIX_GRAFANA_USER}" \
  --from-literal=password="${ZABBIX_GRAFANA_PASSWORD}" \
  --dry-run=client -o yaml | "${OC_BIN}" apply -f - >/dev/null

if [[ "${ZABBIX_ENABLE_SAML}" == "true" ]]; then
  ensure_saml
fi

if [[ "${ZABBIX_PROVISION_MONITORING}" == "true" ]]; then
  ensure_http_monitor "crc-api" "CRC API" "openshift-api" "https://api.crc.testing:6443/readyz" "200" "${monitor_group_id}"
  ensure_http_monitor "openshift-gitops" "OpenShift GitOps" "argocd" "https://openshift-gitops-server-openshift-gitops.apps-crc.testing" "200-399" "${monitor_group_id}"
  ensure_http_monitor "keycloak-dev" "Keycloak dev" "keycloak" "https://keycloak-dev.apps-crc.testing/realms/observability/.well-known/openid-configuration" "200" "${monitor_group_id}"
  ensure_http_monitor "grafana" "Grafana" "grafana" "https://grafana-grafana.apps-crc.testing/api/health" "200" "${monitor_group_id}"
  ensure_http_monitor "zabbix-web" "Zabbix Web" "zabbix" "${ZABBIX_BASE_URL}" "200-399" "${monitor_group_id}"
fi

echo "[OK] Zabbix API bootstrap concluído."
echo "[OK] Secret ${GRAFANA_NAMESPACE}/${ZABBIX_GRAFANA_SECRET} reconciliado para o Grafana."
echo "[INFO] Credenciais sensíveis não foram exibidas."
