#!/usr/bin/env bash
set -euo pipefail

require_match() {
  local pattern=$1
  local file=$2

  if ! grep -Eq "$pattern" "$file"; then
    printf 'expected %s in %s\n' "$pattern" "$file" >&2
    exit 1
  fi
}

require_fixed_match() {
  local pattern=$1
  local file=$2

  if ! grep -Fq -- "$pattern" "$file"; then
    printf 'expected %s in %s\n' "$pattern" "$file" >&2
    exit 1
  fi
}

require_adjacent() {
  local name=$1
  local value=$2
  local file=$3
  local name_pattern="^[[:space:]]*-[[:space:]]*name:[[:space:]]*${name}[[:space:]]*$"
  local value_pattern="^[[:space:]]*value:[[:space:]]*.*\\.Values\\.${value}([[:space:]}|]|$)"

  if ! grep -A1 -E "$name_pattern" "$file" | grep -Eq "$value_pattern"; then
    printf 'expected name %s adjacent to .Values.%s in %s\n' "$name" "$value" "$file" >&2
    exit 1
  fi
}

for variable in \
  'variable "kubecost_athena_database"' \
  'variable "kubecost_athena_table"' \
  'variable "kubecost_athena_query_results_bucket"' \
  'variable "kubecost_cur_source_bucket"' \
  'variable "kubecost_athena_workgroup"'; do
  require_fixed_match "$variable" variables.tf
done

require_match 'data\.aws_caller_identity\.current\.account_id' argocd.tf
require_match 'var\.aws_region' argocd.tf
require_match 'kubecost_athena_policy_statements' locals.tf
require_match 'module "kubecost_pod_identity"' pod-identity.tf
require_match 'service_account = "kubecost-aws"' pod-identity.tf

for bucket in kubecost_cur_source_bucket kubecost_athena_query_results_bucket; do
  require_match "var\\.${bucket}" locals.tf
done

for action in \
  'athena:\*' \
  'glue:GetDatabase' \
  'glue:GetTable' \
  'glue:GetPartition' \
  'glue:GetUserDefinedFunction' \
  'glue:BatchGetPartition' \
  's3:GetBucketLocation' \
  's3:ListBucket' \
  's3:GetObject' \
  's3:GetObjectVersion' \
  's3:ListBucketMultipartUploads' \
  's3:AbortMultipartUpload' \
  's3:ListMultipartUploadParts' \
  's3:PutObject'; do
  require_match "$action" locals.tf
done

require_match 'attach_custom_policy[[:space:]]*=[[:space:]]*true' pod-identity.tf
require_match 'policy_statements[[:space:]]*=[[:space:]]*local\.kubecost_athena_policy_statements' pod-identity.tf
require_match 'namespace[[:space:]]*=[[:space:]]*"kubecost"' pod-identity.tf

require_match '^[[:space:]]*kubecostAthenaAccountId[[:space:]]*=[[:space:]]*data\.aws_caller_identity\.current\.account_id' argocd.tf
require_match '^[[:space:]]*kubecostAthenaDatabase[[:space:]]*=[[:space:]]*var\.kubecost_athena_database' argocd.tf
require_match '^[[:space:]]*kubecostAthenaTable[[:space:]]*=[[:space:]]*var\.kubecost_athena_table' argocd.tf
require_match '^[[:space:]]*kubecostAthenaQueryResultsBucket[[:space:]]*=[[:space:]]*var\.kubecost_athena_query_results_bucket' argocd.tf
require_match '^[[:space:]]*kubecostAthenaWorkgroup[[:space:]]*=[[:space:]]*var\.kubecost_athena_workgroup' argocd.tf

for parameter in \
  kubecostAthenaAccountId \
  kubecostAthenaDatabase \
  kubecostAthenaTable \
  kubecostAthenaQueryResultsBucket \
  kubecostAthenaWorkgroup; do
  require_adjacent "$parameter" "$parameter" charts/argocd-root-application/templates/application.yaml
done

require_match 'cloudIntegrationJSON' gitops/root/templates/applications.yaml
require_match 'kubecost-aws' gitops/root/templates/applications.yaml
require_match 'cloudCost:' gitops/root/templates/applications.yaml
require_match 'serviceAccountName: kubecost-aws' gitops/apps/kubecost/values.yaml
