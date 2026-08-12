# Agent Context

This repository is a production-grade private Amazon EKS platform accessed through persistent Tailscale subnet routers. Future agents should preserve the current two-phase design and the Argo CD app-of-apps delivery path, and avoid reintroducing the removed Tailscale Kubernetes Operator path.

## Current Architecture

- Root Terraform application creates AWS infrastructure only.
- Kubernetes platform services are installed by Argo CD through the app-of-apps tree under `gitops/root`.
- The VPC is dual-stack across three AZs. EKS Pods and Services use IPv6.
- The EKS API endpoint is private only, encrypted with KMS envelope encryption.
- Local access to the private EKS API and internal ALB goes through the Tailscale subnet router EC2 instances.
- Private subnet IPv6 egress uses an egress-only internet gateway and does not use AWS NAT Gateway.
- The subnet router runs as two spot-backed Auto Scaling Groups in two AZs.
- The third AZ routes IPv4 NAT and NAT64/DNS64 traffic to one fixed subnet-router.
- The subnet routers advertise the VPC IPv4 and IPv6 CIDRs through Tailscale.
- Argo CD, Airflow, Kubecost, Grafana, and Spark History Server are exposed through one shared internal dual-stack AWS Application Load Balancer.
- The ALB uses host-based routing with TLS 1.2 minimum.
- TLS is handled by an ACM wildcard certificate for `*.${route53_domain_name}`.
- DNS records are managed by ExternalDNS in an existing public Route 53 hosted zone.
- Public DNS names are intentionally discoverable, but the ALB is internal and reachable only from the VPC, including through the approved Tailscale subnet route.
- Terraform state is stored in S3 with native locking (`use_lockfile=true`, no DynamoDB).
- Airflow metadata database runs on a dedicated CloudNativePG PostgreSQL 17 cluster (1 instance, 10 GiB, daily Barman backup).

## Decisions Made

- Tailscale HTTPS certificates are not supported by the current Tailscale account, so the platform uses ACM for TLS.
- The Tailscale Kubernetes Operator/API server proxy path was removed.
- The bootstrap EC2 instance was replaced with two spot-backed Auto Scaling Groups in two AZs.
- Subnet-router AMIs use Ubuntu 24.04 because Amazon Linux 2023 does not package tayga or jool for NAT64.
- NAT64 uses packaged tayga. DNS64 uses VPC subnet DNS64 plus local Unbound on each subnet router as a fallback and diagnostic resolver.
- Root Terraform must not install platform service Helm charts or connect to Kubernetes, except for the existing Argo CD bootstrap Helm releases in `argocd.tf`.
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

- Dual-stack VPC across three AZs with public /24 subnets (subnet-router ASGs, EKS control-plane ENIs) and private /20 subnets (EKS nodes, Karpenter, internal dual-stack ALB).
- IPv6 private subnet egress through an egress-only internet gateway, with no AWS NAT Gateway resources.
- `kubernetes.io/role/elb` on public subnets; `kubernetes.io/role/internal-elb` and `karpenter.sh/discovery` on private subnets.
- Two subnet-router ASGs in two AZs (1 spot instance each, mixed instance types, capacity rebalance).
- Each subnet-router instance self-configures assigned private route tables (`replace-route` via cloud-init), acts as IPv4 NAT (iptables MASQUERADE), provides NAT64 with tayga and DNS64 with Unbound, and advertises the VPC IPv4 and IPv6 CIDRs via Tailscale.
- The third AZ's private route table sends IPv4 NAT and NAT64 traffic to the fixed primary subnet-router.
- Private-only IPv6 EKS cluster with KMS secrets encryption, CloudWatch log retention (90 days), VPC CNI network policy enabled, default managed node group.
- EKS addons: VPC CNI, EKS Pod Identity Agent, CoreDNS, kube-proxy, EBS CSI driver.
- Karpenter AWS resources (SQS queue, IAM).
- Pod Identity roles for EBS CSI, AWS Load Balancer Controller, ExternalDNS, Airflow tasks, Spark workloads, Velero, Loki, CloudNativePG, and Spark History Server.
- S3 buckets: Velero (backups), Loki (logs), ALB access logs, Spark events, CNPG backups.
- Existing public Route 53 hosted zone discovery.
- ACM wildcard certificate and DNS validation records.
- Terraform S3 backend with native locking (no DynamoDB needed).
- KMS key for EKS secrets envelope encryption (rotation enabled).
- Outputs and values consumed by Argo CD root Application include Route 53 zone values, ACM certificate ARN, Karpenter queue, node role, VPC ID, AWS region, cluster name, and selected S3 bucket names passed through `argocd.tf`.

## Platform GitOps Responsibilities

- Argo CD root Application bootstrapped by Terraform (`helm_release.argocd_root_application`).
- GitOps tree under `gitops/` with app-of-apps pattern.
- `gitops/base/` Helm chart: namespaces, StorageClass, service accounts, RBAC, Ingresses, PDBs, NetworkPolicies, AlertRules, ServiceMonitors.
- `gitops/apps/` service charts for 17 applications:
  - Wave 1: aws-load-balancer-controller, external-dns, sealed-secrets, cloudnative-pg, velero, karpenter
  - Wave 2: argocd, kube-prometheus-stack
  - Wave 3: karpenter-resources, airflow-db, loki, alloy
  - Wave 4: airflow, spark-operator, spark-history-server, kubecost, otel-collector

## Required Local Configuration

`terraform.tfvars` is ignored and may contain sensitive values. Do not commit it.

Expected local values:

```hcl
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

## Apply Flow

Run root infrastructure first with `enable_argocd_bootstrap = false`:

```bash
export AWS_PROFILE=victor
terraform init -migrate-state
terraform validate
terraform apply
```

Approve the advertised VPC IPv4 and IPv6 routes in Tailscale after the subnet router instances appear:

```bash
terraform output -raw tailscale_subnet_router_hostname
terraform output -raw tailscale_subnet_route
terraform output -raw tailscale_subnet_ipv6_route
```

The hostname output is the base prefix. Actual router devices append their AZ suffix, for example `tailscale-eks-example-subnet-router-a`.

After root infrastructure is applied and the Tailscale routes are approved, set `enable_argocd_bootstrap = true` and apply again. Terraform then installs Argo CD and the root Application through the existing bootstrap Helm releases.

Wait and verify:

```bash
aws eks update-kubeconfig \
  --profile victor \
  --region $(terraform output -raw aws_region) \
  --name $(terraform output -raw cluster_name)

kubectl -n argocd get applications
```

After the Sealed Secrets controller is healthy, encrypt secrets:

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
- Root bootstrap Helm installation for platform services outside the existing Argo CD bootstrap.
- Root Terraform Kubernetes provider, or Helm ownership beyond the existing Argo CD bootstrap releases.
- Root Terraform `helm_release` resources (except `helm_release.argocd` and `helm_release.argocd_root_application`).
- `platform/` Terraform application as an apply target.
- Root variables for `argocd_repo_url`, `argocd_target_revision`, `argocd_path`, `tailscale_oauth_client_id`, `tailscale_oauth_client_secret`, or old Tailscale UI hostnames.
- `admin_password` variable, output, and any Terraform-managed secret values.
- DynamoDB for state locking (S3 native locking supersedes it).
- Single NAT instance (replaced by two subnet-router ASGs with cloud-init route management).
- Plaintext secrets in Airflow values.yaml or Terraform argocd.tf.

## Important Files

- `variables.tf`: root inputs (`aws_profile`, `route53_domain_name`, subnet router auth key, etc.)
- `providers.tf`: root AWS provider uses `var.aws_profile` and `var.aws_region`.
- `backend.tf`: S3 backend with native locking.
- `network.tf`: dual-stack VPC, subnets, IPv6 egress-only IGW, DNS64, S3 gateway endpoint, NAT precondition.
- `eks.tf`: EKS cluster, addons, KMS encryption, CloudWatch logs, managed node group.
- `kms.tf`: KMS key for EKS secrets encryption.
- `tailscale-bootstrap.tf`: launch template + ASGs for subnet router/NAT64 instances.
- `bootstrap-iam.tf`: SG, IAM role, NAT routing permissions.
- `pod-identity.tf`: Pod Identity for EBS CSI, LBC, ExternalDNS, Airflow, Spark.
- `velero.tf`: S3 bucket + Pod Identity for Velero backups.
- `observability.tf`: S3 buckets + Pod Identity for Loki, ALB logs, Spark events, Spark History.
- `database.tf`: S3 bucket + Pod Identity for CloudNativePG backups.
- `route53-acm.tf`: public Route 53 hosted zone discovery, ACM wildcard certificate, DNS validation records.
- `karpenter.tf`: Karpenter interruption queue and IAM.
- `argocd.tf`: Argo CD bootstrap + root Application deployment.
- `outputs.tf`: root outputs consumed by the bootstrap and GitOps tree.
- `templates/bootstrap.sh.tftpl`: cloud-init for Ubuntu subnet routers (self-configuring Tailscale, IPv4 NAT, tayga NAT64, and Unbound DNS64).
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
- Some app wrapper `values.yaml` files keep `CHANGEME` placeholders as safe chart defaults. Verify remaining placeholders are overridden by root Application values or sealed-secret generation before relying on those services in a live environment.
- SealedSecrets contains placeholder encrypted values until `scripts/seal-secrets.sh` is run against the live cluster. Run it after Sealed Secrets controller is healthy.
- On destroy, S3 buckets with versioning enabled must be emptied first.
