#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

load_env_file() {
  local env_file="$1"
  local line key value

  while IFS= read -r line || [[ -n "${line}" ]]; do
    line="${line%$'\r'}"
    line="${line#"${line%%[![:space:]]*}"}"
    line="${line%"${line##*[![:space:]]}"}"

    [[ -z "${line}" || "${line}" == \#* ]] && continue

    if [[ "${line}" == export[[:space:]]* ]]; then
      line="${line#export}"
      line="${line#"${line%%[![:space:]]*}"}"
    fi

    if [[ ! "${line}" =~ ^[A-Za-z_][A-Za-z0-9_]*= ]]; then
      echo "[WARN] Linha ignorada em ${env_file}: formato inválido para .env" >&2
      continue
    fi

    key="${line%%=*}"
    value="${line#*=}"
    value="${value#"${value%%[![:space:]]*}"}"
    value="${value%"${value##*[![:space:]]}"}"

    if [[ "${value}" =~ ^\"(.*)\"$ ]]; then
      value="${BASH_REMATCH[1]}"
    elif [[ "${value}" =~ ^\'(.*)\'$ ]]; then
      value="${BASH_REMATCH[1]}"
    fi

    export "${key}=${value}"
  done < "${env_file}"
}

if [[ -f "${ROOT_DIR}/.env" ]]; then
  load_env_file "${ROOT_DIR}/.env"
fi

OC_BIN="${OC_BIN:-oc}"
if ! command -v "${OC_BIN}" >/dev/null 2>&1 && [[ "${OC_BIN}" == "oc" && -x "${HOME}/.local/bin/oc" ]]; then
  OC_BIN="${HOME}/.local/bin/oc"
fi

ZABBIX_NAMESPACE="${ZABBIX_NAMESPACE:-zabbix}"
ZABBIX_ROUTE_NAME="${ZABBIX_ROUTE_NAME:-zabbix}"
ZABBIX_ADMIN_USER="${ZABBIX_ADMIN_USER:-Admin}"
ZABBIX_ADMIN_PASSWORD="${ZABBIX_ADMIN_PASSWORD:-}"
ZABBIX_BASE_URL="${ZABBIX_BASE_URL:-}"

GRAFANA_NAMESPACE="${GRAFANA_NAMESPACE:-grafana}"
ZABBIX_GRAFANA_SECRET="${ZABBIX_GRAFANA_SECRET:-zabbix-datasource}"
ZABBIX_GRAFANA_USER="${ZABBIX_GRAFANA_USER:-grafana-datasource}"
ZABBIX_GRAFANA_PASSWORD="${ZABBIX_GRAFANA_PASSWORD:-}"
ZABBIX_MANAGE_GRAFANA_DATASOURCE="${ZABBIX_MANAGE_GRAFANA_DATASOURCE:-true}"
ZABBIX_GRAFANA_USER_GROUP="${ZABBIX_GRAFANA_USER_GROUP:-Grafana datasource readers}"
ZABBIX_GRAFANA_READ_HOST_GROUPS="${ZABBIX_GRAFANA_READ_HOST_GROUPS:-}"

ZABBIX_ENABLE_SAML="${ZABBIX_ENABLE_SAML:-true}"
ZABBIX_ENABLE_SAML_JIT="${ZABBIX_ENABLE_SAML_JIT:-true}"
ZABBIX_ENABLE_SAML_SCIM="${ZABBIX_ENABLE_SAML_SCIM:-true}"
ZABBIX_MANAGE_SAML_IDP_CERT="${ZABBIX_MANAGE_SAML_IDP_CERT:-true}"
ZABBIX_SAML_IDP_CONFIGMAP="${ZABBIX_SAML_IDP_CONFIGMAP:-zabbix-saml-idp}"
ZABBIX_SAML_IDP_CERT_KEY="${ZABBIX_SAML_IDP_CERT_KEY:-idp.crt}"
ZABBIX_RESTART_WEB_ON_IDP_CERT_CHANGE="${ZABBIX_RESTART_WEB_ON_IDP_CERT_CHANGE:-true}"
ZABBIX_SAML_ENTITY_ID="${ZABBIX_SAML_ENTITY_ID:-zabbix}"
ZABBIX_SAML_LOGIN_ATTRIBUTE="${ZABBIX_SAML_LOGIN_ATTRIBUTE:-username}"
ZABBIX_SAML_GROUP_ATTRIBUTE="${ZABBIX_SAML_GROUP_ATTRIBUTE:-groups}"
ZABBIX_SAML_FIRST_NAME_ATTRIBUTE="${ZABBIX_SAML_FIRST_NAME_ATTRIBUTE:-firstName}"
ZABBIX_SAML_LAST_NAME_ATTRIBUTE="${ZABBIX_SAML_LAST_NAME_ATTRIBUTE:-lastName}"
ZABBIX_DISABLED_USER_GROUP="${ZABBIX_DISABLED_USER_GROUP:-Disabled provisioned users}"

KEYCLOAK_NAMESPACE="${KEYCLOAK_NAMESPACE:-keycloak-dev}"
KEYCLOAK_ROUTE_NAME="${KEYCLOAK_ROUTE_NAME:-keycloak}"
KEYCLOAK_BASE_URL="${KEYCLOAK_BASE_URL:-}"
KEYCLOAK_REALM="${KEYCLOAK_REALM:-observability}"

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

render_keycloak_saml_idp_cert() {
  local descriptor cert
  descriptor="$(curl -ksS --fail "${KEYCLOAK_BASE_URL%/}/realms/${KEYCLOAK_REALM}/protocol/saml/descriptor")"
  cert="$(printf '%s' "${descriptor}" \
    | tr -d '\n\r\t ' \
    | sed -n 's#.*<ds:X509Certificate>\([^<]*\)</ds:X509Certificate>.*#\1#p' \
    | head -n 1)"

  if [[ -z "${cert}" ]]; then
    cert="$(printf '%s' "${descriptor}" \
      | tr -d '\n\r\t ' \
      | sed -n 's#.*<X509Certificate>\([^<]*\)</X509Certificate>.*#\1#p' \
      | head -n 1)"
  fi

  if [[ -z "${cert}" ]]; then
    echo "[ERROR] Não foi possível extrair o certificado SAML do metadata do Keycloak." >&2
    exit 1
  fi

  {
    printf '%s\n' '-----BEGIN CERTIFICATE-----'
    printf '%s' "${cert}" | fold -w 64
    printf '\n%s\n' '-----END CERTIFICATE-----'
  }
}

ensure_saml_idp_configmap() {
  local tmp cert_current cert_next

  if [[ "${ZABBIX_MANAGE_SAML_IDP_CERT}" != "true" ]]; then
    return 0
  fi

  if [[ -z "${KEYCLOAK_BASE_URL}" ]]; then
    echo "[WARN] KEYCLOAK_BASE_URL ausente; ConfigMap ${ZABBIX_NAMESPACE}/${ZABBIX_SAML_IDP_CONFIGMAP} não será atualizado." >&2
    return 0
  fi

  tmp="$(mktemp)"
  render_keycloak_saml_idp_cert > "${tmp}"
  cert_next="$(cat "${tmp}")"
  cert_current="$("${OC_BIN}" -n "${ZABBIX_NAMESPACE}" get configmap "${ZABBIX_SAML_IDP_CONFIGMAP}" -o json 2>/dev/null \
    | jq -r --arg key "${ZABBIX_SAML_IDP_CERT_KEY}" '.data[$key] // ""' || true)"

  if [[ "${cert_current}" == "${cert_next}" ]]; then
    rm -f "${tmp}"
    return 0
  fi

  "${OC_BIN}" -n "${ZABBIX_NAMESPACE}" create configmap "${ZABBIX_SAML_IDP_CONFIGMAP}" \
    "--from-file=${ZABBIX_SAML_IDP_CERT_KEY}=${tmp}" \
    --dry-run=client -o yaml | "${OC_BIN}" apply -f - >/dev/null
  rm -f "${tmp}"

  if [[ "${ZABBIX_RESTART_WEB_ON_IDP_CERT_CHANGE}" == "true" ]]; then
    "${OC_BIN}" -n "${ZABBIX_NAMESPACE}" rollout restart deployment/zabbix-web >/dev/null 2>&1 || true
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

ensure_saml_idp_configmap

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

role_id_by_name() {
  local name="$1"
  zbx_result role.get "$(jq -n --arg name "${name}" '{output:["roleid","name"],filter:{name:$name}}')" | jq -r '.[0].roleid // empty'
}

user_group_id_by_name() {
  local name="$1"
  zbx_result usergroup.get "$(jq -n --arg name "${name}" '{output:["usrgrpid","name"],filter:{name:$name}}')" | jq -r '.[0].usrgrpid // empty'
}

host_group_id_by_name() {
  local name="$1"
  zbx_result hostgroup.get "$(jq -n --arg name "${name}" '{output:["groupid","name"],filter:{name:$name}}')" | jq -r '.[0].groupid // empty'
}

ensure_user_group() {
  local name="$1"
  local usrgrpid
  usrgrpid="$(user_group_id_by_name "${name}")"
  if [[ -z "${usrgrpid}" ]]; then
    zbx_result usergroup.create "$(jq -n --arg name "${name}" '{name:$name}')" >/dev/null
    usrgrpid="$(user_group_id_by_name "${name}")"
  fi
  printf '%s' "${usrgrpid}"
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

ensure_user_group_read_rights() {
  local usrgrpid="$1"
  local group_names="$2"
  local name groupid rights

  rights="[]"
  while IFS= read -r name; do
    [[ -z "${name}" ]] && continue
    groupid="$(host_group_id_by_name "${name}")"
    if [[ -z "${groupid}" ]]; then
      echo "[WARN] Host group '${name}' não existe; permissão do datasource não será aplicada para ele." >&2
      continue
    fi
    rights="$(printf '%s' "${rights}" | jq --arg id "${groupid}" '. + [{id:$id, permission:2}]')"
  done < <(printf '%s' "${group_names}" | tr ',' '\n' | sed '/^[[:space:]]*$/d' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')

  if [[ "$(printf '%s' "${rights}" | jq 'length')" != "0" ]]; then
    zbx_result usergroup.update "$(jq -n --arg id "${usrgrpid}" --argjson rights "${rights}" '{usrgrpid:$id, hostgroup_rights:$rights}')" >/dev/null
  fi
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

  if [[ -z "${roleid}" || -z "${usrgrpid}" ]]; then
    echo "[ERROR] Role ou grupo Zabbix ausente para criar/atualizar usuário ${username}." >&2
    exit 1
  fi

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

ensure_grafana_datasource_identity() {
  local grafana_usrgrp_id grafana_role_id

  grafana_usrgrp_id="$(ensure_user_group "${ZABBIX_GRAFANA_USER_GROUP}")"
  ensure_user_group_read_rights "${grafana_usrgrp_id}" "${ZABBIX_GRAFANA_READ_HOST_GROUPS}"
  grafana_role_id="$(role_id_by_name "User role")"

  if [[ -n "${ZABBIX_GRAFANA_PASSWORD}" && "${#ZABBIX_GRAFANA_PASSWORD}" -lt 8 ]]; then
    echo "[WARN] ZABBIX_GRAFANA_PASSWORD ignorado: o Zabbix exige no mínimo 8 caracteres." >&2
    ZABBIX_GRAFANA_PASSWORD=""
  fi

  if [[ -z "${ZABBIX_GRAFANA_PASSWORD}" ]]; then
    ZABBIX_GRAFANA_PASSWORD="$(existing_secret_key password)"
  fi

  if [[ -n "${ZABBIX_GRAFANA_PASSWORD}" && "${#ZABBIX_GRAFANA_PASSWORD}" -lt 8 ]]; then
    echo "[WARN] Senha existente em ${GRAFANA_NAMESPACE}/${ZABBIX_GRAFANA_SECRET} ignorada: o Zabbix exige no mínimo 8 caracteres." >&2
    ZABBIX_GRAFANA_PASSWORD=""
  fi

  ZABBIX_GRAFANA_PASSWORD="${ZABBIX_GRAFANA_PASSWORD:-$(openssl rand -base64 36 | tr -d '\n')}"
  ensure_user "${ZABBIX_GRAFANA_USER}" "Grafana" "Datasource" "${grafana_role_id}" "${grafana_usrgrp_id}" "${ZABBIX_GRAFANA_PASSWORD}"

  "${OC_BIN}" create namespace "${GRAFANA_NAMESPACE}" --dry-run=client -o yaml | "${OC_BIN}" apply -f - >/dev/null
  "${OC_BIN}" -n "${GRAFANA_NAMESPACE}" create secret generic "${ZABBIX_GRAFANA_SECRET}" \
    --from-literal=username="${ZABBIX_GRAFANA_USER}" \
    --from-literal=password="${ZABBIX_GRAFANA_PASSWORD}" \
    --dry-run=client -o yaml | "${OC_BIN}" apply -f - >/dev/null
}

ensure_saml() {
  local directory_id admin_group admin_role reader_group reader_role disabled_group provision_groups jit_enabled scim_enabled

  directory_id="$(zbx_result userdirectory.get "$(jq -n '{output:"extend",filter:{idp_type:"2"}}')" | jq -r '.[0].userdirectoryid // empty')"
  admin_group="$(user_group_id_by_name "Zabbix administrators")"
  admin_role="$(role_id_by_name "Super admin role")"
  reader_group="$(ensure_user_group "${ZABBIX_GRAFANA_USER_GROUP}")"
  reader_role="$(role_id_by_name "User role")"
  disabled_group="$(ensure_disabled_user_group "${ZABBIX_DISABLED_USER_GROUP}")"

  if [[ -z "${admin_group}" || -z "${admin_role}" || -z "${reader_role}" ]]; then
    echo "[ERROR] Roles/grupos padrão do Zabbix não foram encontrados. Verifique a instalação antes de configurar SAML." >&2
    exit 1
  fi

  provision_groups="$(jq -n \
    --arg admin_group "${admin_group}" \
    --arg admin_role "${admin_role}" \
    --arg reader_group "${reader_group}" \
    --arg reader_role "${reader_role}" \
    '[
      {name:"zabbix-super-admins", roleid:$admin_role, user_groups:[{usrgrpid:$admin_group}]},
      {name:"zabbix-admins", roleid:$admin_role, user_groups:[{usrgrpid:$admin_group}]},
      {name:"zabbix-users", roleid:$reader_role, user_groups:[{usrgrpid:$reader_group}]},
      {name:"zabbix-guests", roleid:$reader_role, user_groups:[{usrgrpid:$reader_group}]}
    ]')"

  if [[ "${ZABBIX_ENABLE_SAML_JIT}" == "true" ]]; then
    jit_enabled="1"
  else
    jit_enabled="0"
  fi

  if [[ "${ZABBIX_ENABLE_SAML_SCIM}" == "true" ]]; then
    scim_enabled="1"
  else
    scim_enabled="0"
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
    --arg scim_enabled "${scim_enabled}" \
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
      scim_status:$scim_enabled,
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
}

if [[ "${ZABBIX_ENABLE_SAML}" == "true" ]]; then
  if [[ -z "${KEYCLOAK_BASE_URL}" ]]; then
    echo "[ERROR] Defina KEYCLOAK_BASE_URL ou exponha a Route ${KEYCLOAK_NAMESPACE}/${KEYCLOAK_ROUTE_NAME} para habilitar SAML." >&2
    exit 1
  fi
  ensure_saml
  echo "[OK] SAML do Zabbix reconciliado com Keycloak."
else
  echo "[INFO] SAML não alterado porque ZABBIX_ENABLE_SAML=false."
fi

if [[ "${ZABBIX_MANAGE_GRAFANA_DATASOURCE}" == "true" ]]; then
  ensure_grafana_datasource_identity
  echo "[OK] Secret ${GRAFANA_NAMESPACE}/${ZABBIX_GRAFANA_SECRET} reconciliado para o Grafana."
fi

echo "[OK] Bootstrap Zabbix concluído sem provisionar hosts ou templates."
echo "[INFO] Credenciais sensíveis não foram exibidas."
