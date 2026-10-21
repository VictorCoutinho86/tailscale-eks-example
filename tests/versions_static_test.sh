#!/usr/bin/env bash
set -euo pipefail

assert_contains() {
  local file=$1
  local expected=$2
  if ! grep -Fq "$expected" "$file"; then
    printf 'expected %s in %s\n' "$expected" "$file" >&2
    exit 1
  fi
}

assert_contains versions.tf 'required_version = ">= 1.11.0"'
assert_contains variables.tf 'default     = "1.37"'
assert_contains argocd.tf 'version          = "10.10.5"'
assert_contains gitops/apps/aws-load-balancer-controller/Chart.yaml 'version: 3.6.1'
assert_contains gitops/apps/aws-load-balancer-controller/Chart.lock 'version: 3.6.1'
assert_contains gitops/apps/external-dns/Chart.yaml 'version: 1.23.0'
assert_contains gitops/apps/external-dns/Chart.lock 'version: 1.23.0'
assert_contains gitops/apps/argocd/Chart.yaml 'version: 10.10.5'
assert_contains gitops/apps/argocd/Chart.lock 'version: 10.10.5'
assert_contains gitops/apps/karpenter/Chart.yaml 'version: 1.15.0'
assert_contains gitops/apps/airflow/values.yaml 'defaultAirflowTag: "3.3.2"'
assert_contains gitops/apps/airflow/values.yaml 'airflowVersion: "3.3.2"'
assert_contains gitops/apps/spark-operator/Chart.yaml 'version: 2.5.2'
assert_contains gitops/apps/spark-operator/Chart.lock 'version: 2.5.2'
assert_contains gitops/apps/kubecost/Chart.yaml 'version: 3.3.1'
assert_contains gitops/apps/kubecost/Chart.lock 'version: 3.3.1'

printf 'retained service version pins are present\n'
