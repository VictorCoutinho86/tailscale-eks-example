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

for variable in \
  'variable "kubecost_athena_database"' \
  'variable "kubecost_athena_table"' \
  'variable "kubecost_athena_query_results_bucket"' \
  'variable "kubecost_cur_source_bucket"' \
  'variable "kubecost_athena_workgroup"'; do
  require_match "$variable" variables.tf
done

require_match 'data\.aws_caller_identity\.current\.account_id' argocd.tf
require_match 'var\.aws_region' argocd.tf
require_match 'kubecost_athena_policy_statements' locals.tf
require_match 'module "kubecost_pod_identity"' pod-identity.tf
require_match 'service_account = "kubecost-aws"' pod-identity.tf
require_match 'athena:\*' locals.tf
require_match 'glue:GetDatabase' locals.tf
require_match 'glue:GetTable' locals.tf
require_match 's3:GetObject' locals.tf
require_match 's3:PutObject' locals.tf
require_match 'kubecostAthenaDatabase' argocd.tf
require_match 'kubecostAthenaQueryResultsBucket' charts/argocd-root-application/templates/application.yaml
require_match 'kubecostAthenaDatabase' charts/argocd-root-application/templates/application.yaml
require_match 'cloudIntegrationJSON' gitops/root/templates/applications.yaml
require_match 'kubecost-aws' gitops/root/templates/applications.yaml
require_match 'cloudCost:' gitops/root/templates/applications.yaml
require_match 'serviceAccountName: kubecost-aws' gitops/apps/kubecost/values.yaml
