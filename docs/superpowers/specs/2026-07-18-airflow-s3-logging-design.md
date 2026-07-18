# Airflow S3 Remote Logging Design

## Goal

Configure Airflow to write task logs to an existing S3 bucket, using the fixed
prefix `airflow/logs`, while reusing the existing `airflow_task_pod_identity`
role and avoiding static AWS credentials.

## Current Context

- Airflow is deployed by the GitOps Helm wrapper at `gitops/apps/airflow`.
- The chart uses `KubernetesExecutor`.
- The `airflow-task` service account already has an EKS Pod Identity association
  through the Terraform `airflow_task_pod_identity` module.
- The bucket is external to this Terraform configuration and must be supplied
  as a Terraform variable.
- The current Airflow values do not enable remote logging.

## Architecture

Add an `airflow_logs_bucket` Terraform input. Terraform derives the bucket ARN
and adds an S3 policy to the existing Airflow task role. The policy is scoped to
the log prefix:

- `s3:ListBucket` on the bucket, restricted to `airflow/logs` and its children.
- `s3:GetObject` and `s3:PutObject` on
  `arn:aws:s3:::<bucket>/airflow/logs/*`.

The existing role remains the source of AWS credentials through EKS Pod
Identity. No access key, secret key, or AWS connection secret is added to
Kubernetes.

The same role must be associated with the Airflow component service accounts
that read or write task logs. Existing component service accounts and their
Kubernetes RBAC remain unchanged; the Pod Identity associations only extend
their AWS permissions.

## Airflow Configuration

The Airflow Helm values configure the S3 task handler:

```yaml
config:
  logging:
    remote_logging: "True"
    remote_base_log_folder: "s3://<airflow_logs_bucket>/airflow/logs"
    remote_log_conn_id: aws_default
```

`aws_default` uses the AWS credential provider chain, which resolves the EKS
Pod Identity credentials inside the Airflow pods. The Amazon provider required
by the S3 task handler must be present in the Airflow image or installed by the
chart's supported package configuration.

The existing local log persistence setting remains disabled. Local logs can
still be used as a temporary buffer while a task runs, but completed logs are
uploaded to S3 and fetched by the Airflow UI from the remote location.

## Data Flow

1. A KubernetesExecutor task pod runs with the `airflow-task` service account.
2. Airflow obtains temporary AWS credentials through EKS Pod Identity.
3. The task log handler writes to `s3://<bucket>/airflow/logs/...`.
4. Airflow web and API components use the same role permissions to read the
   remote log from S3.
5. No object outside the configured prefix is accessible through this policy.

## Validation

- Run `terraform fmt -check` and `terraform validate`.
- Render the Airflow chart and verify the three logging settings and the
  configured S3 path.
- Verify the generated IAM policy contains only the bucket listing and object
  permissions required for `airflow/logs`.
- Run a small DAG task and confirm an object is created below
  `airflow/logs/`.
- Open the task log in the Airflow UI after completion and confirm it is read
  from S3.
- Confirm an S3 operation outside the prefix is denied.

## Alternatives Rejected

Using an Airflow connection with static AWS credentials was rejected because it
duplicates secrets and bypasses the existing EKS Pod Identity integration.

Creating a new logging-only IAM role was rejected for this change because the
approved design reuses the existing Airflow task role. Its policy remains
restricted to the required S3 prefix.
