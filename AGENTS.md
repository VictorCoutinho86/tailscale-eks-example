# Agent Context

This repository is a production-grade private Amazon EKS platform accessed through a persistent Tailscale subnet router. Future agents should preserve the current two-phase design and avoid reintroducing the removed Tailscale Kubernetes Operator or Argo CD app-of-apps delivery path.

## Current Architecture

- Root Terraform application creates AWS infrastructure only.
- Kubernetes platform services are installed by Argo CD through the app-of-apps tree under `gitops/root`.
- The EKS API endpoint is private only, encrypted with KMS envelope encryption.
- Local access to the private EKS API and internal ALB goes through the Tailscale subnet router EC2 instances.
- The subnet router runs as an Auto Scaling Group with 1 spot instance per AZ (3 total), serving as both Tailscale subnet router and NAT instance.
- Argo CD, Airflow, Kubecost, Grafana, and Spark History Server are exposed through one shared internal AWS Application Load Balancer.
- The ALB uses host-based routing with TLS 1.2 minimum.
- TLS is handled by an ACM wildcard certificate for `*.${route53_domain_name}`.
- DNS records are managed by ExternalDNS in an existing public Route 53 hosted zone.
- Public DNS names are intentionally discoverable, but the ALB is internal and reachable only from the VPC, including through the approved Tailscale subnet route.
- Terraform state is stored in S3 with native locking (`use_lockfile=true`, no DynamoDB).
- Airflow metadata database runs on a dedicated CloudNativePG PostgreSQL 17 cluster (1 instance, 10 GiB, daily Barman backup).

## Decisions Made

- Tailscale HTTPS certificates are not supported by the current Tailscale account, so the platform uses ACM for TLS.
- The Tailscale Kubernetes Operator/API server proxy path was removed.
- The bootstrap EC2 instance was replaced with an ASG of spot instances across AZs.
- Root Terraform must not install Helm charts or connect to Kubernetes.
- Argo CD is bootstrapped by Terraform (`helm_release` in `argocd.tf`) and then self-manages via GitOps.
- `platform/` Terraform is retired as an apply target. Platform services are reconciled by Argo CD only.
- Karpenter `EC2NodeClass` and `NodePool` resources are installed through the GitOps tree under `gitops/apps/karpenter-resources`.
- ExternalDNS chart is pinned to 1.19.0 with `extraArgs.aws-zone-type = public`.
- AWS Load Balancer Controller and ExternalDNS use separate Pod Identity modules/roles for least privilege.
- Root AWS profile defaults to `victor` via `terraform.tfvars`. Set `AWS_PROFILE=victor` for all Terraform commands.
- The user prefers not to use git worktrees for this repository.
- Sealed Secrets generates its own key (no ESO/AWS Secrets Manager import).
- CloudNativePG is the preferred PostgreSQL operator over RDS. Backups use Barman to S3.
- All application secrets use SealedSecret resources. No plaintext secrets in Git or Terraform state.
- The `admin_password` Terraform variable was removed. Passwords now flow through SealedSecrets only.

## Root Terraform Responsibilities

- VPC with public /24 subnets (subnet-router ASG, EKS control-plane ENIs) and private /20 subnets (EKS nodes, Karpenter, internal ALB).
- `kubernetes.io/role/elb` on public subnets; `kubernetes.io/role/internal-elb` and `karpenter.sh/discovery` on private subnets.
- Subnet-router ASG (3 spot instances, 1 per AZ, mixed instance types, capacity rebalance).
- Each ASG instance self-configures its AZ's private route table (`replace-route` via cloud-init), acts as NAT (iptables MASQUERADE), and advertises the VPC CIDR via Tailscale.
- Private-only EKS cluster with KMS secrets encryption, CloudWatch log retention (90 days), VPC CNI network policy enabled, default managed node group.
- EKS addons: VPC CNI, EKS Pod Identity Agent, CoreDNS, kube-proxy, EBS CSI driver.
- Karpenter AWS resources (SQS queue, IAM).
- Pod Identity roles for EBS CSI, AWS Load Balancer Controller, ExternalDNS, Airflow tasks, Spark workloads, Velero, Loki, CloudNativePG, and Spark History Server.
- S3 buckets: Velero (backups), Loki (logs), ALB access logs, Spark events, CNPG backups.
- Existing public Route 53 hosted zone discovery.
- ACM wildcard certificate and DNS validation records.
- Terraform S3 backend with native locking (no DynamoDB needed).
- KMS key for EKS secrets envelope encryption (rotation enabled).
- Outputs consumed by Argo CD root Application, including cluster endpoint, CA data, Route 53 zone values, ACM certificate ARN, Karpenter queue, node role, VPC ID, AWS region, cluster name, and S3 bucket names.

## Platform GitOps Responsibilities

- Argo CD root Application bootstrapped by Terraform (`helm_release.argocd_root_application`).
- GitOps tree under `gitops/` with app-of-apps pattern.
- `gitops/base/` Helm chart: namespaces, StorageClass, service accounts, RBAC, Ingresses, PDBs, NetworkPolicies, AlertRules, ServiceMonitors.
- `gitops/apps/` service charts for 17 applications:
  - Wave 1: aws-load-balancer-controller, external-dns, sealed-secrets, cloudnative-pg, velero
  - Wave 2: argocd, karpenter, kube-prometheus-stack
  - Wave 3: karpenter-resources, airflow-db, loki, promtail
  - Wave 4: airflow, spark-operator, spark-history-server, kubecost, otel-collector

## Required Local Configuration

`terraform.tfvars` is ignored and may contain sensitive values. Do not commit it.

Expected local values:

```hcl
aws_profile         = "victor"
route53_domain_name = "example.com"

tailscale_subnet_router_auth_key = "tskey-auth-example"
```

## Apply Flow

Run root infrastructure first:

```bash
export AWS_PROFILE=victor
terraform init -migrate-state
terraform validate
terraform apply
```

Approve the advertised VPC route in Tailscale after the subnet router instances appear:

```bash
terraform output -raw tailscale_subnet_router_hostname
terraform output -raw tailscale_subnet_route
```

After root infrastructure is applied and the Tailscale route is approved, Argo CD is installed by Terraform and the root Application is applied. Wait and verify:

```bash
aws eks update-kubeconfig \
  --profile victor \
  --region $(terraform output -raw aws_region) \
  --name $(terraform output -raw cluster_name)

kubectl -n argocd get applications
```

After Sealed Secrets is running, encrypt secrets:

```bash
bash scripts/seal-secrets.sh
```

Vendor GitOps chart dependencies:

```bash
for app in gitops/apps/*/; do
  helm dependency update "$app" 2>/dev/null || true
done
```

After committing sealed values, Argo CD will sync them automatically.

## Access Flow

```bash
aws eks update-kubeconfig \
  --profile victor \
  --region $(terraform output -raw aws_region) \
  --name $(terraform output -raw cluster_name)

kubectl get nodes
```

Platform URLs:

```text
https://argocd.<route53_domain_name>
https://airflow.<route53_domain_name>
https://kubecost.<route53_domain_name>
https://monitoring.<route53_domain_name>
https://spark-history.<route53_domain_name>
```

## Removed Paths To Avoid

Do not reintroduce these unless the architecture is explicitly changed:

- Tailscale Kubernetes Operator.
- `apiServerProxyConfig`.
- `tailscale configure kubeconfig`.
- `tailscale.com/loadBalancerClass` Services for platform UIs.
- Root bootstrap Helm installation.
- Root Terraform Kubernetes or Helm providers.
- Root Terraform `helm_release` resources (except `helm_release.argocd` and `helm_release.argocd_root_application`).
- `platform/` Terraform application as an apply target.
- Root variables for `argocd_repo_url`, `argocd_target_revision`, `argocd_path`, `tailscale_oauth_client_id`, `tailscale_oauth_client_secret`, or old Tailscale UI hostnames.
- `admin_password` variable, output, and any Terraform-managed secret values.
- DynamoDB for state locking (S3 native locking supersedes it).
- Single NAT instance (replaced by per-AZ ASG with cloud-init route management).
- Plaintext secrets in Airflow values.yaml or Terraform argocd.tf.

## Important Files

- `variables.tf`: root inputs (`aws_profile`, `route53_domain_name`, subnet router auth key, etc.)
- `providers.tf`: root AWS provider uses `var.aws_profile` and `var.aws_region`.
- `backend.tf`: S3 backend with native locking.
- `network.tf`: VPC, subnets, S3 gateway endpoint, NAT precondition.
- `eks.tf`: EKS cluster, addons, KMS encryption, CloudWatch logs, managed node group.
- `kms.tf`: KMS key for EKS secrets encryption.
- `tailscale-bootstrap.tf`: launch template + ASG for per-AZ subnet router/NAT instances.
- `bootstrap-iam.tf`: SG, IAM role, NAT routing permissions.
- `pod-identity.tf`: Pod Identity for EBS CSI, LBC, ExternalDNS, Airflow, Spark.
- `velero.tf`: S3 bucket + Pod Identity for Velero backups.
- `observability.tf`: S3 buckets + Pod Identity for Loki, ALB logs, Spark events, Spark History.
- `database.tf`: S3 bucket + Pod Identity for CloudNativePG backups.
- `route53-acm.tf`: public Route 53 hosted zone discovery, ACM wildcard certificate, DNS validation records.
- `karpenter.tf`: Karpenter interruption queue and IAM.
- `argocd.tf`: Argo CD bootstrap + root Application deployment.
- `outputs.tf`: root outputs consumed by the bootstrap and GitOps tree.
- `templates/bootstrap.sh.tftpl`: cloud-init for subnet router (self-configuring NAT + Tailscale).
- `gitops/root/`: App-of-apps root Helm chart.
- `gitops/base/`: Shared platform base resources (ingresses, PDBs, network policies, alert rules, service monitors).
- `gitops/apps/`: 17 service Helm chart wrappers.
- `charts/argocd-root-application/`: Helm chart that renders the root Argo CD Application.
- `scripts/seal-secrets.sh`: helper to generate and encrypt all platform secrets.
- `tests/platform_static_test.sh`: regression checks for platform infra and GitOps structure.
- `tests/bootstrap_static_test.sh`: regression checks for subnet-router ASG behavior.
- `docs/architecture_diagram.py`: source for the architecture diagram.
- `docs/architecture.png`: generated architecture diagram.

## Validation Commands

```bash
bash -n tests/platform_static_test.sh
bash -n tests/bootstrap_static_test.sh
bash -n templates/bootstrap.sh.tftpl
bash tests/platform_static_test.sh
bash tests/bootstrap_static_test.sh
terraform fmt -check -recursive *.tf
terraform validate
```

## Known Warnings And Risks

- `terraform validate` may warn about undeclared variables if `terraform.tfvars` still contains removed values. Clean the local file regularly.
- If the AWS profile resolves to an STS assumed-role session instead of a stable IAM role or IAM user ARN, verify EKS access entry compatibility.
- Protect Terraform state in S3 — the subnet router auth key is passed through EC2 user data.
- New GitOps apps require `helm dependency update` in each directory before Argo CD can sync. Run `for app in gitops/apps/*/; do helm dependency update "$app" 2>/dev/null || true; done`.
- SealedSecrets contains placeholder encrypted values until `scripts/seal-secrets.sh` is run against the live cluster. Run it after Sealed Secrets controller is healthy.
- On destroy, S3 buckets with versioning enabled must be emptied first.
