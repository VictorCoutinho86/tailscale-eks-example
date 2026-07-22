# Tailscale EKS Platform

Production-grade private Amazon EKS platform accessed through a Tailscale subnet router. Infrastructure is created by Terraform. Platform services are reconciled by Argo CD through a GitOps app-of-apps tree. All UIs are exposed through one shared internal AWS Application Load Balancer, protected by ACM TLS, with DNS managed by ExternalDNS in Route 53.

## Architecture

![Tailscale EKS platform architecture](docs/architecture.png)

Regenerate the diagram:

```bash
uv run --script docs/architecture_diagram.py
```

## Prerequisites

- Terraform `>= 1.5.7` with S3 backend (bucket created manually)
- AWS credentials (`AWS_PROFILE=victor` or equivalent)
- A public Route 53 hosted zone for `route53_domain_name`
- A reusable Tailscale auth key for the subnet router instances
- Tailscale CLI, AWS CLI, `kubectl` on the local machine
- Helm 3 (for chart vendoring: `helm dependency update`)

## Quick Start

### 1. Create local config

```hcl
# terraform.tfvars (gitignored — do not commit)
aws_profile         = "victor"
route53_domain_name = "example.com"
tailscale_subnet_router_auth_key = "tskey-auth-example"
```

### 2. Create S3 backend bucket (once)

```bash
aws s3api create-bucket --bucket tailscale-eks-example --region us-east-1
```

### 3. Apply infrastructure

```bash
export AWS_PROFILE=victor
terraform init -migrate-state
terraform validate
terraform apply
```

### 4. Approve Tailscale route

```bash
terraform output -raw tailscale_subnet_router_hostname
terraform output -raw tailscale_subnet_route
# Approve in Tailscale Admin Console
```

### 5. Configure kubeconfig

```bash
aws eks update-kubeconfig \
  --profile victor \
  --region $(terraform output -raw aws_region) \
  --name $(terraform output -raw cluster_name)
```

### 6. Encrypt secrets

```bash
bash scripts/seal-secrets.sh
```

### 7. Vendor charts

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
| VPC (public /24 + private /20, 3 AZs) | `network.tf`, `locals.tf` |
| EKS cluster (private endpoint, KMS-encrypted secrets) | `eks.tf`, `kms.tf` |
| Subnet router ASG (3 spot instances, 1 per AZ, Tailscale + NAT) | `tailscale-bootstrap.tf` |
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
| 4 | `otel-collector` | Distributed tracing (OTLP → Loki) |

### Airflow

- Metadata database: CloudNativePG PostgreSQL 17 (dedicated, 10 GiB, backup diário)
- Executor: KubernetesExecutor
- HA: 2 apiServer replicas + 2 scheduler replicas across nodes
- Metrics: StatsD → Prometheus (ServiceMonitor)
- Traces: OTLP → OpenTelemetry Collector → Loki
- Remote logging: S3

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
