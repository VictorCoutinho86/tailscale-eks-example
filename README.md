# Tailscale EKS Platform

Production-grade private Amazon EKS platform accessed through two Tailscale subnet routers in two AZs. The VPC is dual-stack across three AZs, EKS Pods and Services use IPv6, normal IPv6 egress uses an egress-only internet gateway, and IPv4-only egress is translated by the subnet-router layer without AWS NAT Gateway. The third AZ sends IPv4 NAT and NAT64/DNS64 traffic to one fixed router. VPC subnet DNS64 is enabled for workloads, and each Ubuntu 24.04 subnet-router also runs local Unbound as a DNS64 fallback and diagnostic resolver with tayga for NAT64. Infrastructure is created by Terraform. Platform services are reconciled by Argo CD through a GitOps app-of-apps tree. All UIs are exposed through one shared internal dual-stack AWS Application Load Balancer, protected by ACM TLS, with DNS managed by ExternalDNS in Route 53.

## Architecture

![Tailscale EKS platform architecture](docs/architecture.png)

Regenerate the diagram:

```bash
uv run --script docs/architecture_diagram.py
```

The diagram shows three traffic planes: tailnet access to private endpoints through subnet-router routes, IPv6 workload egress through the egress-only internet gateway, and IPv4/NAT64 fallback through the Ubuntu subnet-router ASGs.

## Prerequisites

- Terraform `>= 1.10.0` with S3 backend native locking (bucket created manually)
- AWS credentials (`AWS_PROFILE=victor` or equivalent)
- A public Route 53 hosted zone for `route53_domain_name`
- A reusable Tailscale auth key for the subnet router instances
- Tailscale CLI, AWS CLI, `kubectl`, `kubeseal`, and `htpasswd` on the local machine
- Helm 3 (for chart vendoring: `helm dependency update`)

## Quick Start

### 1. Create local config

```hcl
# terraform.tfvars (gitignored — do not commit)
aws_profile         = "victor"
route53_domain_name = "example.com"
tailscale_subnet_router_auth_key = "tskey-auth-example"

kubecost_athena_database             = "cur_database"
kubecost_athena_table                = "cur_table"
kubecost_athena_query_results_bucket = "athena-query-results-bucket"
kubecost_cur_source_bucket           = "cur-source-bucket"
airflow_logs_bucket                  = "airflow-logs-bucket"

# First apply only. Set to true after Tailscale routes are approved.
enable_argocd_bootstrap = false
```

### 2. Create S3 backend bucket (once)

```bash
aws s3api create-bucket --bucket tailscale-eks-example --region us-east-1
```

### 3. Apply infrastructure without Argo CD bootstrap

```bash
export AWS_PROFILE=victor
terraform init -migrate-state
terraform validate
terraform apply
```

### 4. Approve Tailscale routes

```bash
terraform output -raw tailscale_subnet_router_hostname
terraform output -raw tailscale_subnet_route
terraform output -raw tailscale_subnet_ipv6_route
# Approve in Tailscale Admin Console
```

The hostname output is the base prefix. Actual router devices append their AZ suffix, for example `tailscale-eks-example-subnet-router-a`.

### 5. Enable Argo CD bootstrap and apply again

After the Tailscale IPv4 and IPv6 routes are approved, set this in `terraform.tfvars`:

```hcl
enable_argocd_bootstrap = true
```

Then apply again:

```bash
terraform apply
```

### 6. Configure kubeconfig

```bash
aws eks update-kubeconfig \
  --profile victor \
  --region $(terraform output -raw aws_region) \
  --name $(terraform output -raw cluster_name)
```

### 7. Encrypt secrets

Wait for the Sealed Secrets controller to be healthy, then generate and seal platform secrets:

```bash
bash scripts/seal-secrets.sh
```

### 8. Vendor charts

```bash
for app in gitops/apps/*/; do
  helm dependency update "$app" 2>/dev/null || true
done
```

## Platform URLs

```text
https://argocd.<domain>
https://airflow.<domain>
https://kubecost.<domain>
https://monitoring.<domain>       (Grafana)
https://spark-history.<domain>    (Spark History Server)
```

## What's Inside

### Terraform (Root)

| Resource | File |
|----------|------|
| VPC (dual-stack public/private subnets, IPv6 egress-only IGW, DNS64, no NAT Gateway) | `network.tf`, `locals.tf` |
| EKS cluster (private endpoint, KMS-encrypted secrets) | `eks.tf`, `kms.tf` |
| Subnet router ASGs (2 spot instances across 2 AZs, Tailscale + IPv4 NAT + NAT64/DNS64) | `tailscale-bootstrap.tf` |
| Route 53 + ACM wildcard TLS | `route53-acm.tf` |
| Karpenter (SQS queue, IAM) | `karpenter.tf` |
| Pod Identity (EBS CSI, LBC, ExternalDNS, Airflow, Spark, Velero, Loki, CNPG, Spark History) | `pod-identity.tf`, `velero.tf`, `observability.tf`, `database.tf` |
| S3 backend (state locking, no DynamoDB) | `backend.tf` |
| Argo CD bootstrap | `argocd.tf` |
| S3 buckets (Velero, Loki, ALB logs, Spark events, CNPG backups) | `velero.tf`, `observability.tf`, `database.tf` |

### Argo CD GitOps (app-of-apps)

| Wave | App | Purpose |
|------|-----|---------|
| 0 | `base` | Namespaces, StorageClass, RBAC, Ingresses, PDBs, NetworkPolicies, AlertRules |
| 1 | `aws-load-balancer-controller` | ALB provisioning |
| 1 | `external-dns` | Route 53 DNS records |
| 1 | `sealed-secrets` | Secret encryption (generates own key) |
| 1 | `cloudnative-pg` | PostgreSQL operator |
| 1 | `velero` | Cluster backup (S3 + EBS snapshots) |
| 2 | `argocd` | Argo CD (self-managed) |
| 2 | `karpenter` | Node provisioning |
| 2 | `kube-prometheus-stack` | Grafana + Prometheus + AlertManager |
| 3 | `karpenter-resources` | EC2NodeClass + NodePools |
| 3 | `airflow-db` | CloudNativePG PostgreSQL cluster |
| 3 | `loki` | Log aggregation (S3 backend) |
| 3 | `promtail` | Log collection (DaemonSet) |
| 4 | `airflow` | Workflow orchestrator (KubernetesExecutor) |
| 4 | `spark-operator` | Spark job management |
| 4 | `spark-history-server` | Event log viewer |
| 4 | `kubecost` | Cost analytics |
| 4 | `otel-collector` | OTLP log collection → Loki |

Some app wrapper `values.yaml` files keep `CHANGEME` placeholders as safe chart defaults. The Argo CD root Application and sealed-secret workflow provide live values where wired; verify remaining placeholders before relying on those specific services in a live environment.

### Airflow

- Metadata database: CloudNativePG PostgreSQL 17 (dedicated, 10 GiB, daily backup)
- Executor: KubernetesExecutor
- HA: 2 apiServer replicas + 2 scheduler replicas across nodes
- Metrics: StatsD → Prometheus (ServiceMonitor)
- Task remote logs: S3
- Pod/container logs: Promtail → Loki
- OTLP application logs: OpenTelemetry Collector → Loki for workloads that emit OTLP logs

### Security

- All application secrets encrypted with Sealed Secrets
- No plaintext secrets in Git or Terraform state
- TLS 1.2 minimum on all ingresses
- VPC CNI network policies isolating namespaces
- Bootstrap SG restricted to private subnets only
- KMS envelope encryption for EKS Kubernetes secrets
- Private EKS endpoint only (no public access)
- S3 buckets: SSE, no public access, lifecycle policies

### Backup

- Velero: daily full cluster backup (30d) + hourly critical (7d)
- Airflow DB: daily Barman backup to S3 (7d retention, PITR)
- ALB access logs: S3 (90d retention)

### Monitoring

- Grafana at `monitoring.<domain>`
- Prometheus: 50 GB / 15 days retention
- Loki: log aggregation from all pods
- Alert rules: node health, pod crashes, PVC usage, Karpenter capacity, Velero failures
- Spark History Server at `spark-history.<domain>`

## Validation

```bash
# Static
bash tests/platform_static_test.sh
bash tests/bootstrap_static_test.sh
terraform fmt -check -recursive *.tf
terraform validate

# Runtime
kubectl -n argocd get applications
kubectl get nodes
kubectl get ingress -A
kubectl -n airflow get pods
kubectl -n cnpg-system get clusters
```

## Destroy

```bash
terraform destroy
# Note: S3 buckets with versioning must be emptied first
```
