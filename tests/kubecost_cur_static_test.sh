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

require_exact_line() {
  local line=$1
  local file=$2

  if ! grep -Fxq -- "$line" "$file"; then
    printf 'expected exact line %s in %s\n' "$line" "$file" >&2
    exit 1
  fi
}

require_adjacent() {
  local name=$1
  local value=$2
  local file=$3
  local name_pattern="^[[:space:]]*-[[:space:]]*name:[[:space:]]*${name}[[:space:]]*$"
  local value_pattern="^[[:space:]]*value:[[:space:]]*.*\\.Values\\.${value}([[:space:]}|]|$)"
  local adjacent

  adjacent=$(grep -A1 -E "$name_pattern" "$file" || true)
  if ! grep -Eq "$value_pattern" <<<"$adjacent"; then
    printf 'expected name %s adjacent to .Values.%s in %s\n' "$name" "$value" "$file" >&2
    exit 1
  fi
}

require_block_match() {
  local marker=$1
  local pattern=$2
  local file=$3
  local exact=${4:-false}

  if ! awk -v marker="$marker" -v pattern="$pattern" -v exact="$exact" '
    BEGIN {
      found_marker = 0
      found_match = 0
      in_scope = 0
      brace_depth = 0
      bracket_depth = 0
    }
    {
      if (!found_marker && index($0, marker)) {
        found_marker = 1
        in_scope = 1
      }

      if (!in_scope) {
        next
      }

      if (exact == "true") {
        line = $0
        sub(/^[[:space:]]*/, "", line)
        sub(/[[:space:]]*$/, "", line)
        if (line == pattern) {
          found_match = 1
        }
      } else if (index($0, pattern)) {
        found_match = 1
      }

      line = $0
      opens = gsub(/\{/, "", line)
      closes = gsub(/\}/, "", line)
      brace_depth += opens - closes

      line = $0
      opens = gsub(/\[/, "", line)
      closes = gsub(/\]/, "", line)
      bracket_depth += opens - closes

      if (brace_depth == 0 && bracket_depth == 0) {
        in_scope = 0
      }
    }
    END {
      exit !(found_marker && found_match && !in_scope)
    }
  ' "$file"; then
    printf 'expected %s in block %s in %s\n' "$pattern" "$marker" "$file" >&2
    exit 1
  fi
}

require_branch_match() {
  local branch=$1
  local pattern=$2
  local file=$3

  if ! awk -v branch="$branch" -v pattern="$pattern" '
    BEGIN {
      found_branch = 0
      found_match = 0
      in_branch = 0
    }
    {
      if (!found_branch && index($0, branch)) {
        found_branch = 1
        in_branch = 1
        next
      }

      if (!in_branch) {
        next
      }

      if (index($0, pattern)) {
        found_match = 1
      }

      if ($0 ~ /^[[:space:]]*\{\{[[:space:]]*end[[:space:]]*\}\}/) {
        in_branch = 0
      }
    }
    END {
      exit !(found_branch && found_match && !in_branch)
    }
  ' "$file"; then
    printf 'expected %s in branch %s in %s\n' "$pattern" "$branch" "$file" >&2
    exit 1
  fi
}

for variable in \
  'variable "kubecost_athena_database" {' \
  'variable "kubecost_athena_table" {' \
  'variable "kubecost_athena_query_results_bucket" {' \
  'variable "kubecost_cur_source_bucket" {' \
  'variable "kubecost_athena_workgroup" {'; do
  require_exact_line "$variable" variables.tf
done

require_match 'data\.aws_caller_identity\.current\.account_id' argocd.tf
require_match 'var\.aws_region' argocd.tf
require_match 'kubecost_athena_policy_statements' locals.tf
require_match 'module "kubecost_pod_identity"' pod-identity.tf

policy_block='kubecost_athena_policy_statements = ['
for bucket in kubecost_cur_source_bucket kubecost_athena_query_results_bucket; do
  require_block_match "$policy_block" "var.${bucket}" locals.tf
done

for action in \
  'athena:*' \
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
  require_block_match "$policy_block" "$action" locals.tf
done

pod_identity_block='module "kubecost_pod_identity" {'
for setting in \
  'attach_custom_policy = true' \
  'namespace = "kubecost"' \
  'service_account = "kubecost-aws"'; do
  require_block_match "$pod_identity_block" "$setting" pod-identity.tf
done
require_block_match \
  "$pod_identity_block" \
  'policy_statements    = local.kubecost_athena_policy_statements' \
  pod-identity.tf \
  true

require_match '^[[:space:]]*kubecostAthenaAccountId[[:space:]]*=[[:space:]]*data\.aws_caller_identity\.current\.account_id[[:space:]]*$' argocd.tf
require_match '^[[:space:]]*kubecostAthenaDatabase[[:space:]]*=[[:space:]]*var\.kubecost_athena_database[[:space:]]*$' argocd.tf
require_match '^[[:space:]]*kubecostAthenaTable[[:space:]]*=[[:space:]]*var\.kubecost_athena_table[[:space:]]*$' argocd.tf
require_match '^[[:space:]]*kubecostAthenaQueryResultsBucket[[:space:]]*=[[:space:]]*var\.kubecost_athena_query_results_bucket[[:space:]]*$' argocd.tf
require_match '^[[:space:]]*kubecostAthenaWorkgroup[[:space:]]*=[[:space:]]*var\.kubecost_athena_workgroup[[:space:]]*$' argocd.tf

for parameter in \
  kubecostAthenaAccountId \
  kubecostAthenaDatabase \
  kubecostAthenaTable \
  kubecostAthenaQueryResultsBucket \
  kubecostAthenaWorkgroup; do
  require_adjacent "$parameter" "$parameter" charts/argocd-root-application/templates/application.yaml
done

kubecost_branch='{{ else if eq $app.name "kubecost" }}'
for setting in cloudIntegrationJSON cloudCost: kubecost-aws; do
  require_branch_match "$kubecost_branch" "$setting" gitops/root/templates/applications.yaml
done

require_match 'serviceAccountName: kubecost-aws' gitops/apps/kubecost/values.yaml
