# Agent Context

This repository is a private dual-stack Amazon EKS platform accessed through
persistent Tailscale subnet routers. Preserve the two-phase Terraform bootstrap
and the Argo CD app-of-apps delivery path.

## Current architecture

- Root Terraform creates AWS infrastructure only, plus the Argo CD bootstrap
  releases in `argocd.tf`.
- Argo CD manages the platform tree under `gitops/root`.
- EKS is private-only, encrypted with KMS, and Kubernetes version `1.37`.
- Pods and Services use IPv6. Private IPv6 egress uses an egress-only IGW;
  IPv4 and NAT64/DNS64 fallback use the single spot-backed subnet-router ASG.
- The subnet routers advertise the VPC IPv4 and IPv6 CIDRs through Tailscale.
- Argo CD, Airflow and Kubecost use one shared internal dual-stack ALB with ACM
  TLS and ExternalDNS-managed public Route 53 records.
- Terraform state uses S3 native locking (`use_lockfile = true`).
- Airflow metadata uses a private single-AZ PostgreSQL 17 RDS instance:
  `db.t4g.micro`, 20 GiB gp3, dual-stack, encrypted, with no backup or final
  snapshot.

## Decisions to preserve

- Do not add the Tailscale Kubernetes Operator or API server proxy path.
- Do not add root Kubernetes-provider ownership or Helm releases beyond the two
  Argo CD bootstrap releases.
- Use ACM for TLS; Tailscale HTTPS certificates are not part of this design.
- Use Ubuntu 24.04 subnet-router AMIs because tayga is required for NAT64.
- Use packaged tayga plus local Unbound as the NAT64/DNS64 fallback.
- Keep the Argo CD app-of-apps model. The retained child Applications are:
  `base`, `argocd`, `aws-load-balancer-controller`, `external-dns`, `karpenter`,
  `karpenter-resources`, `airflow`, `spark-operator` and `kubecost`.
- All Airflow application credentials are native Kubernetes Secrets created by
  `scripts/create-airflow-secrets.sh`.
- The RDS password uses Terraform `password_wo` and `password_wo_version`; do
  not use a state-backed master password argument.
- Do not add paid backup, monitoring, log aggregation, Secrets Manager, ESO or
  other platform services.

## Root Terraform responsibilities

- Dual-stack VPC across three AZs, private EKS subnets and the internal ALB.
- Private EKS 1.37 cluster with KMS secrets encryption and fixed compatible
  addons: VPC CNI, Pod Identity Agent, CoreDNS, kube-proxy and EBS CSI.
- Karpenter interruption queue and IAM.
- Pod Identity for EBS CSI, AWS Load Balancer Controller, ExternalDNS, Airflow
  tasks, Spark workloads and Kubecost.
- S3 buckets for ALB access logs, Spark events and Airflow application logs.
- Private Airflow RDS, subnet group and security group in `airflow-rds.tf`.
- Route 53 hosted-zone discovery and ACM wildcard certificate.
- Argo CD and the root Application bootstrap, gated by
  `enable_argocd_bootstrap`.

## GitOps responsibilities

- `gitops/base/` contains namespaces, RBAC, StorageClass, ingress, PDB and
  network-policy resources.
- `gitops/apps/` contains wrapper charts for the nine retained Applications.
- Helm dependencies are vendored in each retained wrapper; update only those
  directories.
- The Argo CD bootstrap creates `argocd-secret`; the self-managed chart keeps
  `configs.secret.createSecret: false` to avoid ownership conflicts.
- Airflow points at the `airflow-db-credentials` Secret and the RDS endpoint.

## Required local configuration

`terraform.tfvars` is ignored and may contain sensitive values:

```hcl
aws_profile         = "victor"
route53_domain_name = "example.com"

tailscale_subnet_router_auth_key = "tskey-auth-example"
airflow_db_password              = "local-only-password"

kubecost_athena_database             = "cur_database"
kubecost_athena_table                = "cur_table"
kubecost_athena_query_results_bucket = "athena-query-results-bucket"
kubecost_cur_source_bucket           = "cur-source-bucket"
airflow_logs_bucket                  = "airflow-logs-bucket"

enable_argocd_bootstrap = false
```

Set `AWS_PROFILE=victor` for all AWS and Terraform commands. Do not commit the
tfvars file or the database password.

## Apply flow

```bash
export AWS_PROFILE=victor
terraform init -migrate-state
terraform validate
terraform apply
```

Approve the IPv4 and IPv6 routes shown by Terraform outputs, then set
`enable_argocd_bootstrap = true` and apply again. Configure kubeconfig and run:

```bash
export AIRFLOW_DB_PASSWORD='the same local value used by Terraform'
bash scripts/create-airflow-secrets.sh
kubectl -n argocd get applications
kubectl -n airflow get pods
```

## Important files

- `variables.tf`: inputs including `cluster_version` and RDS password.
- `eks.tf`: EKS cluster and fixed addon versions.
- `airflow-rds.tf`: RDS, subnet group and private security group.
- `argocd.tf`: Argo CD bootstrap and root Application values.
- `pod-identity.tf`: retained workload IAM associations.
- `observability.tf`: ALB and Spark event buckets only.
- `gitops/root/`: Argo CD app-of-apps chart.
- `gitops/base/`: shared Kubernetes resources.
- `gitops/apps/`: retained service chart wrappers.
- `scripts/create-airflow-secrets.sh`: native Airflow Secret setup.
- `docs/architecture_diagram.py`: diagram source.

## Validation commands

```bash
bash -n tests/platform_static_test.sh
bash -n tests/bootstrap_static_test.sh
bash -n tests/versions_static_test.sh
bash -n tests/eks_addons_static_test.sh
bash -n tests/rds_static_test.sh
bash -n tests/airflow_secrets_static_test.sh
bash -n templates/bootstrap.sh.tftpl
bash tests/platform_static_test.sh
bash tests/bootstrap_static_test.sh
terraform fmt -check -recursive *.tf
terraform validate
```

Known risks: RDS has no automated backup or final snapshot; destroying it loses
the database unless it was exported separately. Versioned S3 buckets may need
to be emptied before destroy.
