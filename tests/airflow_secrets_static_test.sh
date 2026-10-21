#!/usr/bin/env bash
set -euo pipefail

script="scripts/create-airflow-secrets.sh"

for expected in \
  'command -v kubectl' \
  'command -v python3' \
  'AIRFLOW_DB_PASSWORD' \
  'terraform output -raw airflow_db_address' \
  'airflow-fernet-key' \
  'airflow-jwt-secret' \
  'airflow-api-secret-key' \
  'airflow-admin-credentials' \
  'airflow-db-credentials' \
  'sslmode=require' \
  'kubectl create secret generic' \
  'dry-run=client' \
  'kubectl apply -f -'; do
  if ! grep -Fq "$expected" "$script"; then
    printf 'expected %s in %s\n' "$expected" "$script" >&2
    exit 1
  fi
done

if ! grep -Fq 'get secret "$name"' "$script"; then
  printf 'expected an existing-secret guard for generated Airflow secrets\n' >&2
  exit 1
fi

if grep -Eq 'echo .*AIRFLOW_DB_PASSWORD|echo .*connection|printf .*connection' "$script"; then
  printf 'expected the secret script not to print credential values\n' >&2
  exit 1
fi

printf 'native Airflow secret contract is present\n'
