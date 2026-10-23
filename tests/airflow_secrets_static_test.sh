#!/usr/bin/env bash
set -euo pipefail

assert_contains() {
  local file=$1
  local text=$2
  if ! grep -Fq -- "$text" "$file"; then
    printf 'expected %s in %s\n' "$text" "$file" >&2
    exit 1
  fi
}

for expected in \
  'source  = "hashicorp/kubernetes"' \
  'source  = "hashicorp/random"' \
  'provider "kubernetes"' \
  'resource "random_id" "airflow_fernet"' \
  'resource "random_password" "airflow_jwt"' \
  'resource "random_password" "airflow_api"' \
  'resource "random_password" "airflow_admin"' \
  'resource "kubernetes_namespace_v1" "airflow"' \
  'resource "kubernetes_secret_v1" "airflow_fernet"' \
  'resource "kubernetes_secret_v1" "airflow_jwt"' \
  'resource "kubernetes_secret_v1" "airflow_api"' \
  'resource "kubernetes_secret_v1" "airflow_admin"' \
  'resource "kubernetes_secret_v1" "airflow_db"' \
  'output "airflow_admin_password"' \
  'output "argocd_admin_password"'; do
  if [[ "$expected" == source* ]]; then
    assert_contains versions.tf "$expected"
  elif [[ "$expected" == provider* ]]; then
    assert_contains providers.tf "$expected"
  elif [[ "$expected" == output* ]]; then
    assert_contains outputs.tf "$expected"
  else
    assert_contains airflow-secrets.tf "$expected"
  fi
done

assert_contains argocd.tf 'depends_on = ['
for dependency in \
  'kubernetes_secret_v1.airflow_fernet' \
  'kubernetes_secret_v1.airflow_jwt' \
  'kubernetes_secret_v1.airflow_api' \
  'kubernetes_secret_v1.airflow_admin' \
  'kubernetes_secret_v1.airflow_db'; do
  assert_contains argocd.tf "$dependency"
done

assert_contains airflow-secrets.tf 'depends_on = [helm_release.argocd]'

if test -e scripts/create-airflow-secrets.sh; then
  printf 'expected the local Airflow secret script to be removed\n' >&2
  exit 1
fi

printf 'Terraform Airflow secret contract is present\n'
