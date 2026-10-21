#!/usr/bin/env bash
set -euo pipefail

command -v kubectl >/dev/null
command -v python3 >/dev/null
command -v terraform >/dev/null

: "${AIRFLOW_DB_PASSWORD:?set AIRFLOW_DB_PASSWORD before running this script}"

namespace=airflow
db_address="$(terraform output -raw airflow_db_address)"
encoded_password="$(AIRFLOW_DB_PASSWORD="$AIRFLOW_DB_PASSWORD" python3 -c 'import os; from urllib.parse import quote; print(quote(os.environ["AIRFLOW_DB_PASSWORD"], safe=""))')"
db_connection="postgresql://airflow:${encoded_password}@${db_address}:5432/airflow?sslmode=require"

create_secret() {
  local name=$1
  local key=$2
  local value=$3

  kubectl -n "$namespace" get secret "$name" >/dev/null 2>&1 || \
    kubectl create secret generic "$name" -n "$namespace" \
      --from-literal="$key=$value" \
      --dry-run=client -o yaml | kubectl apply -f - >/dev/null
}

create_secret airflow-fernet-key fernet-key "$(python3 -c 'import base64; import secrets; print(base64.urlsafe_b64encode(secrets.token_bytes(32)).decode())')"
create_secret airflow-jwt-secret jwt-secret "$(python3 -c 'import secrets; print(secrets.token_urlsafe(96))')"
create_secret airflow-api-secret-key api-secret-key "$(python3 -c 'import secrets; print(secrets.token_urlsafe(32))')"
create_secret airflow-admin-credentials admin-password "$(python3 -c 'import secrets; print(secrets.token_urlsafe(32))')"

kubectl create secret generic airflow-db-credentials -n "$namespace" \
  --from-literal="connection=$db_connection" \
  --dry-run=client -o yaml | kubectl apply -f - >/dev/null
