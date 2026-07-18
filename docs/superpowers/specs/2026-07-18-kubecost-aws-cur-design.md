# Kubecost AWS CUR Integration

## Goal

Enable the Kubecost 3.2.1 deployment to reconcile AWS costs from the existing
Cost and Usage Report (CUR) through Athena. The CUR, Athena, EKS cluster, and
IAM resources are in the same AWS account.

## Scope

The change covers:

- Terraform inputs for the existing Athena database, CUR table, Athena query
  results bucket, CUR source bucket, and optional Athena workgroup.
- Automatic AWS account ID discovery through
  `data.aws_caller_identity.current.account_id`.
- Reuse of `var.aws_region` for Athena.
- A dedicated EKS Pod Identity role for Kubecost.
- IAM permissions for Athena, Glue metadata, CUR S3 reads, and Athena query
  result reads/writes.
- Argo CD values that configure Kubecost cloud-cost with an AWS Athena
  integration and the dedicated service account.

The change does not create or modify the CUR, Athena database/table, S3
buckets, or payer-account roles. It does not add static AWS credentials.

## Architecture

Terraform creates a Kubecost-specific Pod Identity role and associates it with
the `kubecost-aws` service account in the `kubecost` namespace. The Kubecost
chart uses that service account for its cloud-cost workload.

The root Argo CD Application receives the integration metadata from Terraform
and renders the Kubecost child Application values. The generated Kubecost
configuration identifies the Athena query-results bucket, region, database,
table, workgroup, and current AWS account. The CUR source bucket is used only
to scope the IAM read policy because Athena reads the CUR through the existing
Glue/Athena table.

The existing `eks-pod-identity-agent` addon supplies the runtime credential
mechanism. The existing NAT path supplies outbound access to AWS APIs from the
private nodes. No Tailscale-specific access is required for Athena or S3.

## Configuration

Add these root Terraform variables:

- `kubecost_athena_database` (required)
- `kubecost_athena_table` (required)
- `kubecost_athena_query_results_bucket` (required)
- `kubecost_cur_source_bucket` (required)
- `kubecost_athena_workgroup` (default `Primary`)

The values are passed to the root Argo CD Helm release. The account ID and
region are derived rather than duplicated as inputs.

The Kubecost cloud integration uses the chart's `cloudCost` configuration:

- `cloudCost.serviceAccountName = kubecost-aws`
- `cloudCost.cloudIntegrationJSON` with an AWS Athena entry
- Athena `bucket = s3://<query-results-bucket>`
- Athena `region = var.aws_region`
- Athena `database`, `table`, and `workgroup` from variables
- Athena `account = data.aws_caller_identity.current.account_id`

## IAM

The dedicated role grants the Kubecost cloud-cost workload access to:

- Athena query execution and result APIs.
- Glue database, table, partition, and function metadata APIs.
- Read/list access to the CUR source bucket.
- Read/list/write query result access to the Athena results bucket.

The policy should scope S3 resources to the two configured buckets. If either
bucket uses a customer-managed KMS key, the implementation must also grant
the required KMS decrypt/data-key permissions and rely on the key policy to
authorize the Kubecost role.

## Testing

Static regression checks will assert that:

- The required variables and account/region wiring exist.
- A dedicated Kubecost Pod Identity module and service-account association
  exist.
- IAM statements reference both configured buckets and required Athena/Glue
  actions.
- The root Application passes the Kubecost Athena configuration.
- The Kubecost chart selects the dedicated service account.

Validation will run Terraform formatting, Terraform validation, existing
static tests, and Helm rendering with representative sample values. Runtime
verification after apply will query the Kubecost cloud-cost logs and confirm
that the Athena integration reports reconciled AWS costs.
