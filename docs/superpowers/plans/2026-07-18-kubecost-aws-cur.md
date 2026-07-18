# Kubecost AWS CUR Integration Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Configure Kubecost 3.2.1 to reconcile AWS costs from the existing same-account CUR/Athena integration using EKS Pod Identity.

**Architecture:** Terraform will accept the existing Athena/CUR identifiers, derive the AWS account and region, and create a dedicated IAM role associated with the `kubecost-aws` service account. Terraform will pass the non-secret metadata through the intermediate Argo CD root Application into the GitOps app-of-apps, which will render Kubecost's `cloudCost.cloudIntegrationJSON`.

**Tech Stack:** Terraform, AWS EKS Pod Identity, AWS Athena, AWS Glue, Amazon S3, Helm, Argo CD, Kubecost 3.2.1, Bash static tests.

---

## File Map

- Modify `variables.tf`: declare the existing Athena/CUR identifiers as root Terraform inputs.
- Modify `locals.tf`: build the scoped IAM policy statements for Athena, Glue, CUR S3, and Athena result S3 access.
- Modify `pod-identity.tf`: create and associate the dedicated Kubecost EKS Pod Identity role.
- Modify `argocd.tf`: pass the derived account ID and Terraform inputs to the intermediate Argo CD root Application chart.
- Modify `charts/argocd-root-application/values.yaml`: document deterministic sample defaults for the new chart values.
- Modify `charts/argocd-root-application/templates/application.yaml`: forward the new values as Helm parameters to `gitops/root`.
- Modify `gitops/root/values.yaml`: document the values consumed by the root app-of-apps chart.
- Modify `gitops/root/templates/applications.yaml`: render the Kubecost service account and Athena cloud integration JSON.
- Modify `gitops/apps/kubecost/values.yaml`: set the dedicated Kubecost service account defaults.
- Add `tests/kubecost_cur_static_test.sh`: regression checks for wiring, IAM, Pod Identity, and Helm configuration.

## Task 1: Add Failing Regression Checks

**Files:**
- Create: `tests/kubecost_cur_static_test.sh`

- [ ] **Step 1: Add the static test with the expected implementation contract**

Create an executable Bash test with these checks:

```bash
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
```

- [ ] **Step 2: Run the new test before implementation**

Run:

```bash
rtk bash tests/kubecost_cur_static_test.sh
```

Expected: FAIL because the new variables, policy, module, and GitOps wiring do not exist yet.

- [ ] **Step 3: Make the test executable**

Run:

```bash
chmod +x tests/kubecost_cur_static_test.sh
```

## Task 2: Add Terraform Inputs and IAM Policy Data

**Files:**
- Modify: `variables.tf` after `default_node_capacity_type`.
- Modify: `locals.tf` after `airflow_ebs_cleanup_policy_statements`.

- [ ] **Step 1: Add the CUR/Athena variables**

Add these variables to `variables.tf`. Bucket variables are plain bucket names,
not `s3://` URLs, because the IAM locals need ARNs and the Helm rendering adds
the `s3://` prefix only to the Athena result location.

```hcl
variable "kubecost_athena_database" {
  description = "Existing Glue/Athena database containing the AWS CUR table."
  type        = string
}

variable "kubecost_athena_table" {
  description = "Existing Glue/Athena table containing the AWS CUR data."
  type        = string
}

variable "kubecost_athena_query_results_bucket" {
  description = "Existing S3 bucket used for Athena query results."
  type        = string
}

variable "kubecost_cur_source_bucket" {
  description = "Existing S3 bucket containing the AWS CUR objects."
  type        = string
}

variable "kubecost_athena_workgroup" {
  description = "Athena workgroup used for Kubecost CUR queries."
  type        = string
  default     = "Primary"
}
```

- [ ] **Step 2: Add the scoped policy statement locals**

Add this local block to `locals.tf`. Athena API resources remain `*` because
Athena query APIs and workgroup discovery do not provide a single portable
resource scope; S3 and Glue resources remain tied to the configured database,
table, and buckets.

```hcl
  kubecost_athena_policy_statements = [
    {
      sid       = "KubecostAthenaAccess"
      actions   = ["athena:*"]
      resources = ["*"]
    },
    {
      sid = "KubecostGlueRead"
      actions = [
        "glue:GetDatabase*",
        "glue:GetTable*",
        "glue:GetPartition*",
        "glue:GetUserDefinedFunction",
        "glue:BatchGetPartition",
      ]
      resources = [
        "arn:${data.aws_partition.current.partition}:glue:${var.aws_region}:${data.aws_caller_identity.current.account_id}:catalog",
        "arn:${data.aws_partition.current.partition}:glue:${var.aws_region}:${data.aws_caller_identity.current.account_id}:database/${var.kubecost_athena_database}",
        "arn:${data.aws_partition.current.partition}:glue:${var.aws_region}:${data.aws_caller_identity.current.account_id}:table/${var.kubecost_athena_database}/*",
      ]
    },
    {
      sid       = "KubecostCurBucketRead"
      actions   = ["s3:GetBucketLocation", "s3:ListBucket"]
      resources = ["arn:${data.aws_partition.current.partition}:s3:::${var.kubecost_cur_source_bucket}"]
    },
    {
      sid       = "KubecostCurObjectRead"
      actions   = ["s3:GetObject", "s3:GetObjectVersion"]
      resources = ["arn:${data.aws_partition.current.partition}:s3:::${var.kubecost_cur_source_bucket}/*"]
    },
    {
      sid       = "KubecostAthenaResultsBucket"
      actions   = ["s3:GetBucketLocation", "s3:ListBucket", "s3:ListBucketMultipartUploads"]
      resources = ["arn:${data.aws_partition.current.partition}:s3:::${var.kubecost_athena_query_results_bucket}"]
    },
    {
      sid = "KubecostAthenaResultsObjects"
      actions = [
        "s3:AbortMultipartUpload",
        "s3:GetObject",
        "s3:ListMultipartUploadParts",
        "s3:PutObject",
      ]
      resources = ["arn:${data.aws_partition.current.partition}:s3:::${var.kubecost_athena_query_results_bucket}/*"]
    },
  ]
```

- [ ] **Step 3: Run Terraform formatting and the new test**

Run:

```bash
rtk terraform fmt variables.tf locals.tf
rtk bash tests/kubecost_cur_static_test.sh
```

Expected: The formatter succeeds; the test still fails only on the Pod Identity and GitOps checks.

## Task 3: Create the Kubecost EKS Pod Identity

**Files:**
- Modify: `pod-identity.tf` after `external_dns_pod_identity` and before `airflow_task_pod_identity`.

- [ ] **Step 1: Add the dedicated module**

Add this module using the same `terraform-aws-modules/eks-pod-identity/aws` pattern already used in the repository:

```hcl
module "kubecost_pod_identity" {
  source  = "terraform-aws-modules/eks-pod-identity/aws"
  version = "~> 2.0"

  name                 = "${local.name}-kubecost"
  attach_custom_policy = true
  policy_statements    = local.kubecost_athena_policy_statements

  associations = {
    kubecost = {
      cluster_name    = local.name
      namespace       = "kubecost"
      service_account = "kubecost-aws"
    }
  }

  depends_on = [module.eks]
  tags       = local.tags
}
```

- [ ] **Step 2: Run the focused test**

Run:

```bash
rtk bash tests/kubecost_cur_static_test.sh
```

Expected: The test advances to the GitOps configuration checks.

## Task 4: Forward Terraform Values Through the Root Application

**Files:**
- Modify: `argocd.tf` in the `helm_release.argocd_root_application` `values` map.
- Modify: `charts/argocd-root-application/values.yaml` after `airflowLogsBucket`.
- Modify: `charts/argocd-root-application/templates/application.yaml` after the `global.airflowLogsBucket` parameter.

- [ ] **Step 1: Pass derived account and configured metadata from Terraform**

Add these entries to the map in `argocd.tf`:

```hcl
    kubecostAthenaAccountId        = data.aws_caller_identity.current.account_id
    kubecostAthenaDatabase         = var.kubecost_athena_database
    kubecostAthenaTable            = var.kubecost_athena_table
    kubecostAthenaQueryResultsBucket = var.kubecost_athena_query_results_bucket
    kubecostAthenaWorkgroup        = var.kubecost_athena_workgroup
```

- [ ] **Step 2: Add chart defaults for deterministic rendering**

Append these sample values to `charts/argocd-root-application/values.yaml`:

```yaml
kubecostAthenaAccountId: "000000000000"
kubecostAthenaDatabase: athenacurcfn_example
kubecostAthenaTable: cur_example
kubecostAthenaQueryResultsBucket: aws-athena-query-results-example
kubecostAthenaWorkgroup: Primary
```

- [ ] **Step 3: Forward the values into `gitops/root`**

Append these Helm parameters to `charts/argocd-root-application/templates/application.yaml`:

```yaml
        - name: kubecostAthenaAccountId
          value: {{ .Values.kubecostAthenaAccountId | quote }}
        - name: kubecostAthenaDatabase
          value: {{ .Values.kubecostAthenaDatabase | quote }}
        - name: kubecostAthenaTable
          value: {{ .Values.kubecostAthenaTable | quote }}
        - name: kubecostAthenaQueryResultsBucket
          value: {{ .Values.kubecostAthenaQueryResultsBucket | quote }}
        - name: kubecostAthenaWorkgroup
          value: {{ .Values.kubecostAthenaWorkgroup | quote }}
```

- [ ] **Step 4: Run the focused test**

Run:

```bash
rtk bash tests/kubecost_cur_static_test.sh
```

Expected: The test advances to the GitOps child Application checks.

## Task 5: Configure the Kubecost Child Application

**Files:**
- Modify: `gitops/root/values.yaml` after `global.airflowLogsBucket`.
- Modify: `gitops/root/templates/applications.yaml` in the Kubecost branch.
- Modify: `gitops/apps/kubecost/values.yaml`.

- [ ] **Step 1: Add root chart defaults**

Append these values to `gitops/root/values.yaml` so direct chart rendering has the same shape as the Argo CD parameterized render:

```yaml
kubecostAthenaAccountId: "000000000000"
kubecostAthenaDatabase: athenacurcfn_example
kubecostAthenaTable: cur_example
kubecostAthenaQueryResultsBucket: aws-athena-query-results-example
kubecostAthenaWorkgroup: Primary
```

- [ ] **Step 2: Set the Kubecost service account and cloud integration**

Replace the current Kubecost branch in `gitops/root/templates/applications.yaml` with:

```yaml
{{ else if eq $app.name "kubecost" }}
        kubecost:
          global:
            clusterId: {{ $.Values.global.clusterName | quote }}
          serviceAccount:
            create: true
            name: kubecost-aws
          cloudCost:
            serviceAccountName: kubecost-aws
            cloudIntegrationJSON: {{ dict "aws" (dict "athena" (list (dict "bucket" (printf "s3://%s" $.Values.kubecostAthenaQueryResultsBucket) "region" $.Values.global.awsRegion "database" $.Values.kubecostAthenaDatabase "table" $.Values.kubecostAthenaTable "workgroup" $.Values.kubecostAthenaWorkgroup "account" $.Values.kubecostAthenaAccountId))) | toJson | quote }}
{{ end }}
```

This intentionally uses the Athena query-results bucket in the Kubecost
configuration. The CUR source bucket remains an IAM-only input.

- [ ] **Step 3: Set chart-level service account defaults**

Append this to `gitops/apps/kubecost/values.yaml`:

```yaml
  serviceAccount:
    create: true
    name: kubecost-aws
  cloudCost:
    serviceAccountName: kubecost-aws
```

- [ ] **Step 4: Run the focused test**

Run:

```bash
rtk bash tests/kubecost_cur_static_test.sh
```

Expected: PASS.

## Task 6: Render and Validate the Complete Configuration

**Files:**
- Modify: `tests/kubecost_cur_static_test.sh` only if a test assertion needs to match the final rendered structure.

- [ ] **Step 1: Check shell syntax and run all static tests**

Run:

```bash
rtk bash -n tests/kubecost_cur_static_test.sh
rtk bash -n tests/platform_static_test.sh
rtk bash -n tests/bootstrap_static_test.sh
rtk bash tests/kubecost_cur_static_test.sh
rtk bash tests/platform_static_test.sh
rtk bash tests/bootstrap_static_test.sh
```

Expected: all commands exit successfully.

- [ ] **Step 2: Validate Terraform**

Run:

```bash
rtk terraform fmt -check *.tf
rtk terraform validate
```

Expected: formatting is clean and Terraform reports `Success! The configuration is valid.`

- [ ] **Step 3: Render the intermediate root Application**

Run:

```bash
rtk helm template argocd-root-application charts/argocd-root-application \
  --set-string repoURL=https://github.com/VictorCoutinho86/tailscale-eks-example.git \
  --set-string targetRevision=master \
  --set-string clusterName=tailscale-eks-example \
  --set-string awsRegion=us-east-1 \
  --set-string vpcId=vpc-00000000000000000 \
  --set-string domain=example.com \
  --set-string certificateArn=arn:aws:acm:us-east-1:000000000000:certificate/00000000-0000-0000-0000-000000000000 \
  --set-string karpenterQueueName=tailscale-eks-example \
  --set-string karpenterNodeRoleName=tailscale-eks-example-karpenter \
  --set-string sparkWorkloadNamespace=spark-jobs \
  --set-string airflowLogsBucket=example-airflow-logs \
  --set-string kubecostAthenaAccountId=000000000000 \
  --set-string kubecostAthenaDatabase=athenacurcfn_example \
  --set-string kubecostAthenaTable=cur_example \
  --set-string kubecostAthenaQueryResultsBucket=aws-athena-query-results-example \
  --set-string kubecostAthenaWorkgroup=Primary
```

Expected: the generated root Application includes Helm parameters for all five Kubecost values.

- [ ] **Step 4: Render the GitOps root chart and inspect the child Application**

Run:

```bash
rtk helm template platform-root gitops/root \
  --set-string global.clusterName=tailscale-eks-example \
  --set-string global.awsRegion=us-east-1 \
  --set-string kubecostAthenaAccountId=000000000000 \
  --set-string kubecostAthenaDatabase=athenacurcfn_example \
  --set-string kubecostAthenaTable=cur_example \
  --set-string kubecostAthenaQueryResultsBucket=aws-athena-query-results-example \
  --set-string kubecostAthenaWorkgroup=Primary | rg -A12 'name: kubecost$'
```

Expected: the Kubecost Application contains `serviceAccountName: kubecost-aws`, an AWS Athena JSON configuration, the sample database/table/workgroup/account, and `s3://aws-athena-query-results-example`.

- [ ] **Step 5: Render the Kubecost wrapper chart**

Run:

```bash
rtk helm template kubecost gitops/apps/kubecost \
  --set-string kubecost.global.clusterId=tailscale-eks-example \
  --set-string kubecost.serviceAccount.name=kubecost-aws \
  --set-string kubecost.cloudCost.serviceAccountName=kubecost-aws | rg -A4 'kind: ServiceAccount|name: kubecost-aws'
```

Expected: the chart renders the `kubecost-aws` service account and the cloud-cost workload references it.

## Task 7: Commit the Implementation

- [ ] **Step 1: Inspect the final diff**

Run:

```bash
rtk git status --short
rtk git diff --check
rtk git diff --stat
```

Expected: only the planned Terraform, Helm/GitOps, and test files are modified.

- [ ] **Step 2: Commit the implementation**

Run:

```bash
rtk git add variables.tf locals.tf pod-identity.tf argocd.tf \
  charts/argocd-root-application/values.yaml \
  charts/argocd-root-application/templates/application.yaml \
  gitops/root/values.yaml gitops/root/templates/applications.yaml \
  gitops/apps/kubecost/values.yaml tests/kubecost_cur_static_test.sh
rtk git commit -m "feat: connect kubecost to aws cur"
```
