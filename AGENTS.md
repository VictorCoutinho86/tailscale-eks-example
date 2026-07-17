# Agent Context

This repository is a Terraform MVP for a private Amazon EKS platform accessed through a persistent Tailscale subnet router. Future agents should preserve the current two-phase design and avoid reintroducing the removed Tailscale Kubernetes Operator or Argo CD app-of-apps delivery path.

## Current Architecture

- Root Terraform application creates AWS infrastructure only.
- Kubernetes platform services are installed by Argo CD through the app-of-apps tree under `gitops/root`.
- The EKS API endpoint is private only.
- Local access to the private EKS API and internal ALB goes through the Tailscale subnet router EC2 instance.
- Argo CD, Airflow, and Kubecost are exposed through one shared internal AWS Application Load Balancer.
- The ALB uses host-based routing for `argocd.<domain>`, `airflow.<domain>`, and `kubecost.<domain>`.
- TLS is handled by an ACM wildcard certificate for `*.${route53_domain_name}`.
- DNS records are managed by ExternalDNS in an existing public Route 53 hosted zone.
- Public DNS names are intentionally discoverable, but the ALB is internal and reachable only from the VPC, including through the approved Tailscale subnet route.

## Decisions Made

- Tailscale HTTPS certificates are not supported by the current Tailscale account, so the platform uses ACM for TLS.
- The Tailscale Kubernetes Operator/API server proxy path was removed.
- The bootstrap EC2 instance is now a persistent subnet router, not a Kubernetes installer.
- Root Terraform must not install Helm charts or connect to Kubernetes.
- The persistent Tailscale subnet router EC2 instance bootstraps Argo CD and applies the root Application.
- `platform/` Terraform is retired as an apply target. Platform services are reconciled by Argo CD only.
- Karpenter `EC2NodeClass` and `NodePool` resources are installed through the GitOps tree under `gitops/apps/karpenter-resources`.
- ExternalDNS uses `extraArgs.aws-zone-type = public` for chart version `1.19.0`, which renders `--aws-zone-type=public`.
- AWS Load Balancer Controller and ExternalDNS use separate Pod Identity modules/roles for least privilege.
- Root and platform AWS profile defaults are aligned with `aws_profile = "victor"` so the identity that creates the EKS access entry matches the platform provider exec authentication by default.
- The user prefers not to use git worktrees for this repository.

## Root Terraform Responsibilities

- VPC and public subnets.
- Public subnet tags for both `kubernetes.io/role/elb` and `kubernetes.io/role/internal-elb`.
- Persistent Tailscale subnet router EC2 instance.
- Private-only EKS cluster and default managed node group.
- EKS addons and EBS CSI Pod Identity.
- Karpenter AWS resources.
- Pod Identity roles for AWS Load Balancer Controller, ExternalDNS, Airflow task pods, and Spark workloads.
- Existing public Route 53 hosted zone discovery.
- ACM wildcard certificate and DNS validation records.
- Outputs consumed by `platform/`, including cluster endpoint, CA data, Route 53 zone values, ACM certificate ARN, Karpenter queue, node role, VPC ID, AWS region, and cluster name.

## Platform GitOps Responsibilities

- Argo CD root Application bootstrapped by the Tailscale EC2 instance.
- GitOps tree under `gitops/` with app-of-apps pattern.
- `gitops/base/` Helm chart: namespaces, StorageClass, service accounts, RBAC, Ingresses.
- `gitops/apps/` service charts for Argo CD, AWS Load Balancer Controller, ExternalDNS, Karpenter, Karpenter resources, Airflow, Spark Operator, Kubecost, and Sealed Secrets.

## Required Local Configuration

`terraform.tfvars` is ignored and may contain sensitive values. Do not commit it.

Expected local values:

```hcl
aws_profile         = "victor"
route53_domain_name = "example.com"

tailscale_subnet_router_auth_key = "tskey-auth-example"
```

Remove obsolete values from local `terraform.tfvars`, including `argocd_repo_url`, Tailscale OAuth variables, and old Tailscale UI hostnames. If they remain, `terraform validate` can pass but will print undeclared-variable warnings.

## Apply Flow

Run root infrastructure first:

```bash
terraform init
terraform validate
terraform plan -out=tfplan
terraform apply tfplan
```

Approve the advertised VPC route in Tailscale after the subnet router appears:

```bash
terraform output -raw tailscale_subnet_router_hostname
terraform output -raw tailscale_subnet_route
```

After root infrastructure is applied and the Tailscale route is approved,
the bootstrap EC2 automatically installs Argo CD and applies the root Application.
Wait for the bootstrap to complete and verify the platform:

```bash
aws eks update-kubeconfig \
  --profile victor \
  --region $(terraform output -raw aws_region) \
  --name $(terraform output -raw cluster_name)

kubectl -n argocd get applications
```

## Access Flow

Configure kubeconfig through normal AWS EKS authentication, not through Tailscale API server proxy commands:

```bash
aws eks update-kubeconfig \
  --profile victor \
  --region $(terraform output -raw aws_region) \
  --name $(terraform output -raw cluster_name)

kubectl get nodes
```

Platform URLs are:

```text
https://argocd.<route53_domain_name>
https://airflow.<route53_domain_name>
https://kubecost.<route53_domain_name>
```

## Removed Paths To Avoid

Do not reintroduce these unless the architecture is explicitly changed:

- Tailscale Kubernetes Operator.
- `apiServerProxyConfig`.
- `tailscale configure kubeconfig`.
- `tailscale.com/loadBalancerClass` Services for platform UIs.
- Root bootstrap Helm installation.
- Root Terraform Kubernetes or Helm providers.
- Root Terraform `helm_release` resources.
- `platform/` Terraform application as an apply target.
- Root variables for `argocd_repo_url`, `argocd_target_revision`, `argocd_path`, `tailscale_oauth_client_id`, `tailscale_oauth_client_secret`, or old Tailscale UI hostnames.

## Important Files

- `variables.tf`: root inputs, including `aws_profile`, `route53_domain_name`, and subnet router auth key.
- `providers.tf`: root AWS provider uses `var.aws_profile` and `var.aws_region`.
- `templates/bootstrap.sh.tftpl`: subnet-router-only cloud-init script.
- `tailscale-bootstrap.tf`: EC2 subnet router, independent from EKS creation.
- `route53-acm.tf`: public Route 53 hosted zone discovery, ACM wildcard certificate, and DNS validation records.
- `pod-identity.tf`: separate Pod Identity modules for EBS CSI, AWS Load Balancer Controller, ExternalDNS, Airflow tasks, and Spark workloads.
- `outputs.tf`: root outputs consumed by the bootstrap EC2 instance and GitOps tree.
- `gitops/root/`: App-of-apps root Helm chart.
- `gitops/base/`: Shared platform base resources.
- `gitops/apps/`: Service Helm chart wrappers.
- `templates/argocd-root-application.yaml.tftpl`: Terraform-rendered root Application manifest.
- `tests/platform_static_test.sh`: regression checks for the two-app boundary, ALB, ACM/Route 53, ExternalDNS, Pod Identity, and removed old path.
- `tests/bootstrap_static_test.sh`: regression checks for subnet-router-only bootstrap behavior.
- `docs/architecture_diagram.py`: source for the architecture diagram.
- `docs/architecture.png`: generated architecture diagram.

## Validation Commands

Use RTK when available. If `rtk` is not installed in the shell, run the underlying command directly.

```bash
rtk bash -n tests/platform_static_test.sh
rtk bash -n tests/bootstrap_static_test.sh
rtk bash -n templates/bootstrap.sh.tftpl
rtk bash tests/platform_static_test.sh
rtk bash tests/bootstrap_static_test.sh
rtk terraform fmt -check *.tf
rtk terraform validate
```

Additional chart checks used during implementation:

```bash
rtk helm template external-dns external-dns \
  --repo https://kubernetes-sigs.github.io/external-dns \
  --version 1.19.0 \
  --set provider.name=aws \
  --set extraArgs.aws-zone-type=public | rg -- '--aws-zone-type=public'

rtk helm template external-dns external-dns \

rtk helm template kubecost cost-analyzer \
  --repo https://kubecost.github.io/cost-analyzer \
  --version 2.8.7 | rg '^  name: kubecost-cost-analyzer$'
```

## Known Warnings And Risks

- Root `terraform validate` may warn about undeclared variables if ignored local `terraform.tfvars` still contains old values. Clean the local file rather than reintroducing removed variables.
- If root and platform are applied with different `aws_profile` values, platform Kubernetes authentication can fail because the EKS access entry grants admin to the root caller identity.
- If `aws_profile` resolves to an STS assumed-role session instead of a stable IAM role or IAM user ARN, verify that the EKS access entry principal is acceptable for the intended workflow.
- Runtime `terraform apply` was not executed as part of the code change. Static and Terraform validation passed, but AWS/Kubernetes runtime behavior still requires the two-phase apply and Tailscale route approval.
- Protect Terraform state because the subnet router auth key is passed through EC2 user data.

## Last Implementation State

- Main implementation commit: `10d5f4c feat: deliver platform through internal alb`.
- Branch `master` was pushed to `origin/master` after the implementation.
- Verified after push: static tests, Terraform formatting, root validation, platform validation, and clean git sync.
