# Internal ALB, ACM, and ExternalDNS Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace Tailscale Kubernetes Services and Argo CD bootstrap delivery with a two-phase Terraform deployment that installs the platform through `helm_release`, exposes Argo CD/Airflow/Kubecost through one internal ALB, and manages Route 53 records with ExternalDNS.

**Architecture:** The root Terraform application remains the infrastructure application and creates the VPC, persistent subnet-router EC2, private EKS cluster, Pod Identity roles, Route 53 DNS validation records, and ACM certificate. A new `platform/` Terraform application reads the root state, connects to the private EKS endpoint over the approved Tailscale route, installs Helm releases, and creates Kubernetes resources. Three namespace-local Ingresses share one ALB through an AWS Load Balancer Controller IngressGroup.

**Tech Stack:** Terraform, AWS EKS, AWS Load Balancer Controller, ExternalDNS, Route 53, ACM, EKS Pod Identity, Tailscale subnet routing, Helm provider, Kubernetes provider.

---

## File Structure

- Modify `variables.tf`: add the existing public Route 53 domain input and remove obsolete Tailscale Operator/Argo CD inputs.
- Modify `network.tf`: tag subnets for both internal and internet-facing AWS load balancers.
- Modify `pod-identity.tf`: add Pod Identity roles for AWS Load Balancer Controller and ExternalDNS.
- Modify `tailscale-bootstrap.tf`: make the existing EC2 resource a pre-EKS subnet router with no EKS dependency.
- Modify `templates/bootstrap.sh.tftpl`: remove Helm/EKS bootstrap and retain only Tailscale installation, forwarding, and route advertisement.
- Modify `bootstrap-iam.tf`: remove the obsolete EKS DescribeCluster permission from the subnet-router instance role.
- Create `route53-acm.tf`: discover the public hosted zone, issue the wildcard ACM certificate, and create DNS validation records.
- Modify `outputs.tf`: expose cluster connection data, hosted zone ID/ARN, ACM ARN, and platform values.
- Modify `versions.tf`: keep the infrastructure provider set limited to AWS.
- Create `platform/versions.tf`: declare Terraform, Helm, Kubernetes, and AWS providers for the platform application.
- Create `platform/providers.tf`: configure remote state, EKS Kubernetes authentication, Helm, and AWS profile inputs.
- Create `platform/variables.tf`: define platform chart versions, AWS profile, and platform settings.
- Create `platform/locals.tf`: derive the three service hostnames and backend service metadata from the infrastructure outputs.
- Create `platform/helm.tf`: install AWS Load Balancer Controller, ExternalDNS, Argo CD, Airflow, Kubecost, Spark Operator, and Karpenter.
- Create `platform/airflow-values.yaml`: move the existing Airflow GitOps values to the platform application.
- Create `platform/kubernetes.tf`: create namespaces, StorageClass, service accounts, RBAC, Karpenter resources, and three Ingresses.
- Create `tests/platform_static_test.sh`: verify the two-application boundary, Helm provider authentication, IAM/Ingress settings, and removal of the old Tailscale Operator path.
- Modify `README.md`: document the two applies, Route 53 domain input, Tailscale route approval, platform Helm application, ACM, and internal ALB URLs.
- Modify `docs/architecture_diagram.py` and regenerate `docs/architecture.png`: show the subnet router, private EKS API, platform Terraform application, internal ALB, ACM, and Route 53.
- Delete `gitops/root/` and `gitops/values/airflow.yaml`: remove the unused Argo CD app-of-apps delivery path after platform Terraform owns the resources.

---

### Task 1: Add Failing Platform Regression Tests

**Files:**
- Create: `tests/platform_static_test.sh`

- [ ] **Step 1: Write the failing static test before implementation**

```bash
#!/usr/bin/env bash
set -euo pipefail

infra_root="."
platform_root="platform"
bootstrap="templates/bootstrap.sh.tftpl"
pod_identity="pod-identity.tf"
network="network.tf"
variables="variables.tf"
outputs="outputs.tf"

if ! test -f "$platform_root/providers.tf"; then
  printf 'expected a separate platform Terraform application\n' >&2
  exit 1
fi

if ! grep -q 'required_providers' "$platform_root/versions.tf" || ! grep -q 'source.*hashicorp/helm' "$platform_root/versions.tf"; then
  printf 'expected the platform application to declare the Helm provider\n' >&2
  exit 1
fi

if ! grep -q 'exec' "$platform_root/providers.tf" || ! grep -q 'get-token' "$platform_root/providers.tf" || ! grep -q 'command.*aws' "$platform_root/providers.tf"; then
  printf 'expected the platform Helm/Kubernetes providers to authenticate with aws eks get-token\n' >&2
  exit 1
fi

if ! grep -q 'helm_release' "$platform_root/helm.tf"; then
  printf 'expected platform services to be installed with helm_release\n' >&2
  exit 1
fi

for release in aws_load_balancer_controller external_dns argocd airflow kubecost; do
  if ! grep -q "helm_release.*$release\|resource \"helm_release\" \"$release\"" "$platform_root/helm.tf"; then
    printf 'expected helm release %s\n' "$release" >&2
    exit 1
  fi
done

if ! grep -q 'alb.ingress.kubernetes.io/group.name' "$platform_root/kubernetes.tf"; then
  printf 'expected IngressGroup configuration for one shared ALB\n' >&2
  exit 1
fi

if ! grep -E -q '"alb\.ingress\.kubernetes\.io/scheme"[[:space:]]*=[[:space:]]*"internal"' "$platform_root/kubernetes.tf"; then
  printf 'expected the shared ALB to be internal\n' >&2
  exit 1
fi

if ! grep -q 'external-dns.alpha.kubernetes.io/hostname' "$platform_root/kubernetes.tf"; then
  printf 'expected ExternalDNS hostname annotations\n' >&2
  exit 1
fi

if ! grep -q 'attach_aws_lb_controller_policy' "$pod_identity"; then
  printf 'expected AWS Load Balancer Controller Pod Identity\n' >&2
  exit 1
fi

if ! grep -q 'attach_external_dns_policy' "$pod_identity"; then
  printf 'expected ExternalDNS Pod Identity\n' >&2
  exit 1
fi

if ! grep -q 'private_zone.*false' "$infra_root/route53-acm.tf"; then
  printf 'expected discovery of an existing public Route 53 hosted zone\n' >&2
  exit 1
fi

if ! grep -q 'aws_acm_certificate' "$infra_root/route53-acm.tf"; then
  printf 'expected ACM certificate managed by Terraform\n' >&2
  exit 1
fi

if grep -q 'apiServerProxyConfig\|tailscale.com/loadBalancerClass\|tailscale configure kubeconfig' "$bootstrap" "$platform_root" "$outputs"; then
  printf 'expected old Tailscale API/UI delivery path to be removed\n' >&2
  exit 1
fi

if grep -q 'aws eks update-kubeconfig\|helm upgrade --install\|helm repo add' "$bootstrap"; then
  printf 'expected bootstrap instance to be subnet-router-only\n' >&2
  exit 1
fi

if grep -q 'module.eks\|module.karpenter' tailscale-bootstrap.tf; then
  printf 'expected subnet router EC2 to be independent of EKS creation\n' >&2
  exit 1
fi

if ! grep -q 'kubernetes.io/role/internal-elb' "$network"; then
  printf 'expected subnet tagging for internal ALB discovery\n' >&2
  exit 1
fi

if ! grep -q 'route53_domain_name' "$variables" || ! grep -q 'certificate_arn' "$outputs"; then
  printf 'expected Route 53 domain input and ACM output\n' >&2
  exit 1
fi
```

- [ ] **Step 2: Make the test executable and run it**

Run:

```bash
chmod +x tests/platform_static_test.sh
rtk bash tests/platform_static_test.sh
```

Expected: FAIL because `platform/` and the new Route 53/ACM resources do not exist yet.

- [ ] **Step 3: Commit only the failing test**

```bash
rtk git add tests/platform_static_test.sh
rtk git commit -m "test: cover internal alb platform delivery"
```

---

### Task 2: Make the Root Application Infrastructure-Only

**Files:**
- Modify: `variables.tf`
- Modify: `network.tf`
- Modify: `tailscale-bootstrap.tf`
- Modify: `templates/bootstrap.sh.tftpl`
- Modify: `bootstrap-iam.tf`
- Modify: `locals.tf`
- Modify: `outputs.tf`

- [ ] **Step 1: Add the Route 53 domain input and remove obsolete Operator inputs**

Add to `variables.tf`:

```hcl
variable "route53_domain_name" {
  description = "Existing public Route 53 hosted zone domain used for platform DNS and ACM validation."
  type        = string
}
```

Remove the variables used only by the Tailscale Kubernetes Operator, Tailscale UI Services, Argo CD app-of-apps, and bootstrap Helm installation:

```text
tailscale_oauth_client_id
tailscale_oauth_client_secret
tailscale_operator_hostname
argocd_repo_url
argocd_target_revision
argocd_path
argocd_chart_version
argocd_tailscale_hostname
airflow_tailscale_hostname
kubecost_tailscale_hostname
```

Keep `tailscale_subnet_router_auth_key`, `enable_bootstrap_instance`, `bootstrap_instance_type`, `spark_workload_namespace`, and the workload policy variables. Remove the old root chart-version variables; the separate `platform/variables.tf` owns all Helm chart versions.

- [ ] **Step 2: Add internal ALB subnet discovery tagging**

Extend `module.vpc.public_subnet_tags` in `network.tf`:

```hcl
  public_subnet_tags = {
    "kubernetes.io/role/elb"         = "1"
    "kubernetes.io/role/internal-elb" = "1"
    "karpenter.sh/discovery"         = local.name
  }
```

- [ ] **Step 3: Convert the existing bootstrap resource into an independent subnet router**

Keep the resource address `aws_instance.bootstrap[0]` to avoid an unnecessary state rename. Remove the `module.eks` and `module.karpenter` dependencies and reduce the template input map to:

```hcl
  user_data = templatefile("${path.module}/templates/bootstrap.sh.tftpl", {
    aws_region                       = var.aws_region
    vpc_cidr                         = var.vpc_cidr
    tailscale_subnet_router_auth_key = var.tailscale_subnet_router_auth_key
    tailscale_subnet_router_hostname = local.tailscale_subnet_router_hostname
  })

  depends_on = [module.vpc]
```

The instance may be created after the VPC and subnet security group exist, but it must not depend on EKS.

- [ ] **Step 4: Reduce the bootstrap user-data script to subnet routing only**

Replace `templates/bootstrap.sh.tftpl` with the following behavior:

```bash
#!/bin/bash
set -euo pipefail

exec > >(tee /var/log/tailscale-subnet-router.log | logger -t tailscale-subnet-router -s 2>/dev/console) 2>&1

export VPC_CIDR="${vpc_cidr}"
TAILSCALE_SUBNET_ROUTER_AUTH_KEY="${tailscale_subnet_router_auth_key}"
export TAILSCALE_SUBNET_ROUTER_HOSTNAME="${tailscale_subnet_router_hostname}"

dnf install -y curl-minimal
curl -fsSL https://tailscale.com/install.sh | sh

cat >/etc/sysctl.d/99-tailscale.conf <<'EOF'
net.ipv4.ip_forward = 1
EOF
sysctl -p /etc/sysctl.d/99-tailscale.conf

systemctl enable --now tailscaled
tailscale up \
  --auth-key="$TAILSCALE_SUBNET_ROUTER_AUTH_KEY" \
  --hostname="$TAILSCALE_SUBNET_ROUTER_HOSTNAME" \
  --advertise-routes="$VPC_CIDR" \
  --accept-dns=false
unset TAILSCALE_SUBNET_ROUTER_AUTH_KEY
```

This script must not install `awscli`, `kubectl`, or Helm and must not invoke the EKS API.

- [ ] **Step 5: Remove the obsolete EKS permission from the subnet-router role**

Delete `aws_iam_role_policy.bootstrap` from `bootstrap-iam.tf`; the subnet router only requires outbound network access and does not call AWS APIs. Keep the instance profile only if the current resource wiring requires it; otherwise remove the role and profile together and remove their references from `tailscale-bootstrap.tf`.

- [ ] **Step 6: Remove Tailscale Operator and app-of-apps locals**

Remove from `locals.tf` the Tailscale Operator values, Tailscale UI Service YAML, and Argo CD root Application YAML. Keep only locals consumed by infrastructure outputs, ACM, tags, and the subnet router hostname.

- [ ] **Step 7: Run the root static checks**

Run:

```bash
rtk bash -n templates/bootstrap.sh.tftpl
rtk terraform fmt -check *.tf
rtk terraform validate
```

Expected: shell syntax, formatting, and root Terraform validation pass. The platform static test remains red until later tasks.

- [ ] **Step 8: Commit the infrastructure-only refactor**

```bash
rtk git add variables.tf network.tf tailscale-bootstrap.tf templates/bootstrap.sh.tftpl bootstrap-iam.tf locals.tf outputs.tf
rtk git commit -m "refactor: make root stack infrastructure only"
```

---

### Task 3: Add Route 53 Discovery, ACM Validation, and Pod Identity

**Files:**
- Create: `route53-acm.tf`
- Modify: `pod-identity.tf`
- Modify: `outputs.tf`

- [ ] **Step 1: Discover the existing public hosted zone and create the wildcard ACM certificate**

Create `route53-acm.tf`:

```hcl
data "aws_route53_zone" "platform" {
  name         = var.route53_domain_name
  private_zone = false
}

locals {
  route53_hosted_zone_arn = "arn:${data.aws_partition.current.partition}:route53:::hostedzone/${data.aws_route53_zone.platform.zone_id}"
}

resource "aws_acm_certificate" "platform" {
  domain_name       = "*.${trimsuffix(var.route53_domain_name, ".")}"
  validation_method  = "DNS"
  lifecycle {
    create_before_destroy = true
  }

  tags = local.tags
}

resource "aws_route53_record" "platform_certificate_validation" {
  for_each = {
    for option in aws_acm_certificate.platform.domain_validation_options : option.domain_name => {
      name   = option.resource_record_name
      record = option.resource_record_value
      type   = option.resource_record_type
    }
  }

  allow_overwrite = true
  zone_id         = data.aws_route53_zone.platform.zone_id
  name            = each.value.name
  type            = each.value.type
  ttl             = 60
  records         = [each.value.record]
}

resource "aws_acm_certificate_validation" "platform" {
  certificate_arn = aws_acm_certificate.platform.arn

  validation_record_fqdns = [
    for record in aws_route53_record.platform_certificate_validation : record.fqdn
  ]
}
```

- [ ] **Step 2: Add combined Pod Identity roles for the AWS controllers**

Add to `pod-identity.tf`:

```hcl
module "platform_pod_identity" {
  source  = "terraform-aws-modules/eks-pod-identity/aws"
  version = "~> 2.0"

  name = "${local.name}-platform"

  attach_aws_lb_controller_policy = true
  attach_external_dns_policy      = true
  external_dns_hosted_zone_arns   = [local.route53_hosted_zone_arn]

  associations = {
    aws_load_balancer_controller = {
      cluster_name    = local.name
      namespace       = "kube-system"
      service_account = "aws-load-balancer-controller"
    }
    external_dns = {
      cluster_name    = local.name
      namespace       = "kube-system"
      service_account = "external-dns"
    }
  }

  depends_on = [module.eks]
  tags       = local.tags
}
```

- [ ] **Step 3: Export the platform connection values**

Add/update outputs in `outputs.tf`:

```hcl
output "cluster_endpoint" {
  description = "Private EKS cluster endpoint."
  value       = module.eks.cluster_endpoint
}

output "cluster_ca_certificate" {
  description = "Base64-encoded CA certificate for the private EKS endpoint."
  value       = module.eks.cluster_certificate_authority_data
  sensitive   = true
}

output "route53_domain_name" {
  description = "Public Route 53 domain managed by ExternalDNS."
  value       = trimsuffix(var.route53_domain_name, ".")
}

output "route53_hosted_zone_id" {
  description = "Existing public Route 53 hosted zone ID."
  value       = data.aws_route53_zone.platform.zone_id
}

output "route53_hosted_zone_arn" {
  description = "Existing public Route 53 hosted zone ARN."
  value       = local.route53_hosted_zone_arn
}

output "platform_certificate_arn" {
  description = "Validated ACM wildcard certificate ARN for the platform ALB."
  value       = aws_acm_certificate_validation.platform.certificate_arn
}
```

- [ ] **Step 4: Run root validation**

Run:

```bash
rtk terraform fmt -check *.tf
rtk terraform validate
```

Expected: both pass without requiring the EKS API.

- [ ] **Step 5: Commit Route 53, ACM, and Pod Identity resources**

```bash
rtk git add route53-acm.tf pod-identity.tf outputs.tf
rtk git commit -m "feat: add platform alb and dns identities"
```

---

### Task 4: Create the Platform Terraform Application and Helm Providers

**Files:**
- Create: `platform/versions.tf`
- Create: `platform/providers.tf`
- Create: `platform/variables.tf`

- [ ] **Step 1: Declare platform providers**

Create `platform/versions.tf`:

```hcl
terraform {
  required_version = ">= 1.5.7"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 6.52, < 7.0"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 3.0"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.38"
    }
  }
}
```

- [ ] **Step 2: Configure remote state and the private EKS providers**

Create `platform/providers.tf`:

```hcl
data "terraform_remote_state" "infra" {
  backend = "local"

  config = {
    path = "${path.module}/../terraform.tfstate"
  }
}

provider "aws" {
  region = data.terraform_remote_state.infra.outputs.aws_region
}

provider "kubernetes" {
  host                   = data.terraform_remote_state.infra.outputs.cluster_endpoint
  cluster_ca_certificate = base64decode(data.terraform_remote_state.infra.outputs.cluster_ca_certificate)

  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    args = [
      "eks",
      "get-token",
      "--region",
      data.terraform_remote_state.infra.outputs.aws_region,
      "--cluster-name",
      data.terraform_remote_state.infra.outputs.cluster_name,
      "--profile",
      var.aws_profile,
    ]
  }
}

provider "helm" {
  kubernetes {
    host                   = data.terraform_remote_state.infra.outputs.cluster_endpoint
    cluster_ca_certificate = base64decode(data.terraform_remote_state.infra.outputs.cluster_ca_certificate)

    exec {
      api_version = "client.authentication.k8s.io/v1beta1"
      command     = "aws"
      args = [
        "eks",
        "get-token",
        "--region",
        data.terraform_remote_state.infra.outputs.aws_region,
        "--cluster-name",
        data.terraform_remote_state.infra.outputs.cluster_name,
        "--profile",
        var.aws_profile,
      ]
    }
  }
}
```

- [ ] **Step 3: Define platform variables**

Create `platform/variables.tf`:

```hcl
variable "aws_profile" {
  description = "Local AWS CLI profile used by the Helm and Kubernetes exec authentication plugins."
  type        = string
  default     = "victor"
}

variable "aws_load_balancer_controller_chart_version" {
  description = "Pinned AWS Load Balancer Controller Helm chart version."
  type        = string
  default     = "1.13.0"
}

variable "external_dns_chart_version" {
  description = "Pinned ExternalDNS Helm chart version."
  type        = string
  default     = "1.19.0"
}

variable "argocd_chart_version" {
  description = "Pinned Argo CD Helm chart version."
  type        = string
  default     = "8.5.7"
}

variable "airflow_chart_version" {
  description = "Pinned Apache Airflow Helm chart version."
  type        = string
  default     = "1.22.0"
}

variable "kubecost_chart_version" {
  description = "Pinned Kubecost Helm chart version."
  type        = string
  default     = "2.8.7"
}

variable "spark_operator_chart_version" {
  description = "Pinned Spark Operator Helm chart version."
  type        = string
  default     = "2.5.1"
}

variable "karpenter_chart_version" {
  description = "Pinned Karpenter Helm chart version."
  type        = string
  default     = "1.13.0"
}
```

- [ ] **Step 4: Derive platform hostnames and backend metadata**

Create `platform/locals.tf`:

```hcl
locals {
  domain = trimsuffix(data.terraform_remote_state.infra.outputs.route53_domain_name, ".")

  platform_ingresses = {
    argocd = {
      namespace     = "argocd"
      hostname      = "argocd.${local.domain}"
      service_name  = "argocd-server"
      service_port  = 80
    }
    airflow = {
      namespace     = "airflow"
      hostname      = "airflow.${local.domain}"
      service_name  = "airflow-api-server"
      service_port  = 8080
    }
    kubecost = {
      namespace     = "kubecost"
      hostname      = "kubecost.${local.domain}"
      service_name  = "kubecost-cost-analyzer"
      service_port  = 9090
    }
  }
}
```

Use the map values in `platform/kubernetes.tf` with `for_each`; do not reference a Service in another namespace. If the pinned chart renders a different Service name, update only `service_name` after the chart rendering check.

- [ ] **Step 5: Initialize and validate the empty platform application**

Run from the repository root:

```bash
rtk terraform -chdir=platform init
rtk terraform -chdir=platform validate
```

Expected: initialization downloads Helm/Kubernetes providers and validation passes.

- [ ] **Step 6: Commit the platform provider application**

```bash
rtk git add platform/versions.tf platform/providers.tf platform/variables.tf platform/locals.tf
rtk git commit -m "feat: add platform terraform providers"
```

---

### Task 5: Install Platform Helm Releases with Terraform

**Files:**
- Create: `platform/helm.tf`
- Create: `platform/airflow-values.yaml`

- [ ] **Step 1: Move Airflow values into the platform application**

Copy the complete current `gitops/values/airflow.yaml` to `platform/airflow-values.yaml`. Preserve the existing GitDagBundle, memory limits, disabled persistence except PostgreSQL, and Argo hook settings. The platform Helm release will load it with `file("${path.module}/airflow-values.yaml")`.

- [ ] **Step 2: Add controller Helm releases**

Create `platform/helm.tf` with these releases:

```hcl
resource "helm_release" "aws_load_balancer_controller" {
  name             = "aws-load-balancer-controller"
  repository       = "https://aws.github.io/eks-charts"
  chart            = "aws-load-balancer-controller"
  version          = var.aws_load_balancer_controller_chart_version
  namespace        = "kube-system"
  create_namespace = false

  set {
    name  = "clusterName"
    value = data.terraform_remote_state.infra.outputs.cluster_name
  }

  set {
    name  = "region"
    value = data.terraform_remote_state.infra.outputs.aws_region
  }

  set {
    name  = "vpcId"
    value = data.terraform_remote_state.infra.outputs.vpc_id
  }

  set {
    name  = "serviceAccount.create"
    value = "true"
  }

  set {
    name  = "serviceAccount.name"
    value = "aws-load-balancer-controller"
  }

  depends_on = [data.terraform_remote_state.infra]
}

resource "helm_release" "external_dns" {
  name             = "external-dns"
  repository       = "https://kubernetes-sigs.github.io/external-dns"
  chart            = "external-dns"
  version          = var.external_dns_chart_version
  namespace        = "kube-system"
  create_namespace = false

  set {
    name  = "provider.name"
    value = "aws"
  }

  set {
    name  = "serviceAccount.create"
    value = "true"
  }

  set {
    name  = "serviceAccount.name"
    value = "external-dns"
  }

  set {
    name  = "policy"
    value = "upsert-only"
  }

  set {
    name  = "registry"
    value = "txt"
  }

  set {
    name  = "txtOwnerId"
    value = "tailscale-eks-example"
  }

  set {
    name  = "domainFilters[0]"
    value = data.terraform_remote_state.infra.outputs.route53_domain_name
  }

  set {
    name  = "zoneTypeFilters[0]"
    value = "public"
  }

  depends_on = [helm_release.aws_load_balancer_controller]
}
```

- [ ] **Step 3: Add application Helm releases**

Append to `platform/helm.tf`:

```hcl
resource "helm_release" "argocd" {
  name             = "argocd"
  repository       = "https://argoproj.github.io/argo-helm"
  chart            = "argo-cd"
  version          = var.argocd_chart_version
  namespace        = "argocd"
  create_namespace = true

  values = [yamlencode({
    server = {
      service = { type = "ClusterIP" }
    }
    configs = {
      params = { "server.insecure" = true }
    }
  })]

  depends_on = [helm_release.aws_load_balancer_controller]
}

resource "helm_release" "airflow" {
  name             = "airflow"
  repository       = "https://airflow.apache.org"
  chart            = "airflow"
  version          = var.airflow_chart_version
  namespace        = "airflow"
  create_namespace = true
  values           = [file("${path.module}/airflow-values.yaml")]

  depends_on = [helm_release.aws_load_balancer_controller]
}

resource "helm_release" "kubecost" {
  name             = "kubecost"
  repository       = "https://kubecost.github.io/cost-analyzer"
  chart            = "cost-analyzer"
  version          = var.kubecost_chart_version
  namespace        = "kubecost"
  create_namespace = true

  values = [yamlencode({
    global = {
      clusterId = data.terraform_remote_state.infra.outputs.cluster_name
    }
    prometheus = {
      server = {
        global = {
          external_labels = {
            cluster_id = data.terraform_remote_state.infra.outputs.cluster_name
          }
        }
      }
    }
  })]

  depends_on = [helm_release.aws_load_balancer_controller]
}

resource "helm_release" "spark_operator" {
  name             = "spark-operator"
  repository       = "https://kubeflow.github.io/spark-operator"
  chart            = "spark-operator"
  version          = var.spark_operator_chart_version
  namespace        = "spark-operator"
  create_namespace = true

  set {
    name  = "webhook.enable"
    value = "true"
  }

  depends_on = [helm_release.aws_load_balancer_controller]
}

resource "helm_release" "karpenter" {
  name             = "karpenter"
  repository       = "oci://public.ecr.aws/karpenter"
  chart            = "karpenter"
  version          = var.karpenter_chart_version
  namespace        = "karpenter"
  create_namespace = true

  set {
    name  = "settings.clusterName"
    value = data.terraform_remote_state.infra.outputs.cluster_name
  }

  set {
    name  = "settings.interruptionQueue"
    value = data.terraform_remote_state.infra.outputs.karpenter_queue_name
  }

  depends_on = [helm_release.aws_load_balancer_controller]
}
```

- [ ] **Step 4: Validate Helm release plans after the first infrastructure apply**

Run:

```bash
rtk terraform -chdir=platform fmt -check
rtk terraform -chdir=platform validate
rtk terraform -chdir=platform plan
```

Expected: the plan contains the seven Helm releases and no provider connection error, provided the EKS endpoint is reachable over the approved Tailscale route.

- [ ] **Step 5: Commit Helm releases and values**

```bash
rtk git add platform/helm.tf platform/airflow-values.yaml
rtk git commit -m "feat: install platform with helm releases"
```

---

### Task 6: Add Kubernetes Platform Resources and Shared Internal ALB

**Files:**
- Create: `platform/kubernetes.tf`

- [ ] **Step 1: Create platform namespaces and base resources**

Use `kubernetes_namespace_v1`, `kubernetes_storage_class_v1`, `kubernetes_service_account_v1`, `kubernetes_role_v1`, and `kubernetes_role_binding_v1` resources to preserve the existing namespaces, encrypted `gp3` StorageClass, Airflow/Spark service accounts, and namespaced RBAC currently under `gitops/root/templates/platform.yaml`.

The ServiceAccounts must use these exact names because Pod Identity associations are created in the infrastructure application:

```text
airflow/airflow-task
"${spark_workload_namespace}"/spark-workload
kube-system/aws-load-balancer-controller
kube-system/external-dns
```

- [ ] **Step 2: Create Karpenter resources after the Karpenter release**

Use `kubernetes_manifest` for `EC2NodeClass/default`, `NodePool/default`, and `NodePool/spark`, preserving the current manifests from `gitops/root/templates/karpenter-resources.yaml`. Add:

```hcl
depends_on = [helm_release.karpenter]
```

Use Terraform values for cluster name, Karpenter node role name, discovery tags, and interruption queue from `terraform_remote_state.infra`.

- [ ] **Step 3: Create one Ingress per application namespace**

Use `kubernetes_ingress_v1` resources with these host/service mappings:

```text
argocd.example.com   -> argocd/argocd-server:80
airflow.example.com  -> airflow/airflow-api-server:8080
kubecost.example.com -> kubecost/kubecost-cost-analyzer:9090
```

The actual hostnames must be constructed from `data.terraform_remote_state.infra.outputs.route53_domain_name`. Each Ingress must include the same ALB group settings:

```hcl
metadata {
  annotations = {
    "alb.ingress.kubernetes.io/scheme"              = "internal"
    "alb.ingress.kubernetes.io/target-type"         = "ip"
    "alb.ingress.kubernetes.io/group.name"           = "platform"
    "alb.ingress.kubernetes.io/listen-ports"        = "[{\"HTTP\":80},{\"HTTPS\":443}]"
    "alb.ingress.kubernetes.io/ssl-redirect"        = "443"
    "alb.ingress.kubernetes.io/certificate-arn"     = data.terraform_remote_state.infra.outputs.platform_certificate_arn
    "external-dns.alpha.kubernetes.io/hostname"     = each.value.hostname
  }
}
```

Set `for_each = local.platform_ingresses`, `ingress_class_name = "alb"`, and use `each.value.namespace`, `each.value.hostname`, `each.value.service_name`, and `each.value.service_port` in the resource. Set `depends_on = [helm_release.aws_load_balancer_controller, helm_release.external_dns, helm_release.argocd, helm_release.airflow, helm_release.kubecost]`.

- [ ] **Step 4: Verify the rendered Ingress service names before apply**

Run:

```bash
rtk helm template airflow airflow --repo https://airflow.apache.org --version 1.22.0 -f platform/airflow-values.yaml
rtk helm template kubecost cost-analyzer --repo https://kubecost.github.io/cost-analyzer --version 2.8.7
```

Expected: the chart output contains `airflow-api-server` and `kubecost-cost-analyzer`. If a pinned chart changes a Service name, update only the corresponding Ingress backend before applying.

- [ ] **Step 5: Validate the platform application**

Run:

```bash
rtk terraform -chdir=platform fmt -check
rtk terraform -chdir=platform validate
rtk terraform -chdir=platform plan
```

Expected: plan contains namespaces, RBAC, Karpenter manifests, and exactly three Ingress resources sharing one ALB group.

- [ ] **Step 6: Commit Kubernetes resources**

```bash
rtk git add platform/kubernetes.tf
rtk git commit -m "feat: expose platform through shared internal alb"
```

---

### Task 7: Remove the Obsolete GitOps/Tailscale UI Path and Update Docs

**Files:**
- Delete: `gitops/root/`
- Delete: `gitops/values/airflow.yaml`
- Modify: `README.md`
- Modify: `docs/architecture_diagram.py`
- Regenerate: `docs/architecture.png`

- [ ] **Step 1: Delete obsolete app-of-apps and Tailscale Service manifests**

Remove `gitops/root/` and `gitops/values/airflow.yaml` after the platform Terraform application owns the equivalent Helm releases and Kubernetes resources.

- [ ] **Step 2: Document the two-apply workflow and domain input**

Update the `terraform.tfvars` example:

```hcl
route53_domain_name = "example.com"

tailscale_subnet_router_auth_key = "tskey-auth-example"
```

Document:

```bash
terraform apply

# Approve/enable the advertised VPC route in Tailscale, then:
terraform -chdir=platform init
terraform -chdir=platform apply
```

Document the final URLs:

```text
https://argocd.example.com
https://airflow.example.com
https://kubecost.example.com
```

State that the ALB is internal, records are created in the existing public hosted zone, the names are publicly discoverable, and access still requires the Tailscale subnet route.

- [ ] **Step 3: Update runtime validation documentation**

Use:

```bash
tailscale status
tailscale ping $(terraform output -raw tailscale_subnet_router_hostname)
aws eks update-kubeconfig --profile victor --region $(terraform output -raw aws_region) --name $(terraform output -raw cluster_name)
kubectl get nodes
terraform -chdir=platform plan
kubectl get ingress -A
```

- [ ] **Step 4: Update and regenerate the architecture diagram**

Show these edges in `docs/architecture_diagram.py`:

```text
tailnet client -> subnet router EC2 -> private VPC/EKS/ALB
platform Terraform -> Helm releases -> Kubernetes services
ExternalDNS -> public Route 53 hosted zone
Terraform -> ACM certificate -> internal ALB HTTPS listener
```

Regenerate:

```bash
uv run --script docs/architecture_diagram.py
```

- [ ] **Step 5: Run documentation/static checks**

Run:

```bash
rtk bash tests/platform_static_test.sh
rtk bash tests/bootstrap_static_test.sh
rtk terraform fmt -check *.tf
rtk terraform validate
rtk terraform -chdir=platform fmt -check
rtk terraform -chdir=platform validate
```

Expected: all checks pass and no active README/architecture reference recommends `tailscale configure kubeconfig` or Tailscale UI Services.

- [ ] **Step 6: Commit cleanup and documentation**

```bash
rtk git add -A README.md docs/architecture_diagram.py docs/architecture.png gitops platform tests
rtk git commit -m "docs: document internal alb platform workflow"
```

---

### Task 8: Execute the Two-Phase MVP and Final Verification

**Files:**
- Verify: root Terraform application and `platform/` application

- [ ] **Step 1: Add local root variables without committing secrets**

Add to the existing ignored root `terraform.tfvars`:

```hcl
route53_domain_name             = "example.com"
tailscale_subnet_router_auth_key = "tskey-auth-example"
```

Do not commit the actual domain-specific file if it contains secrets or local credentials.

- [ ] **Step 2: Apply infrastructure**

Run:

```bash
rtk terraform init
rtk terraform validate
rtk terraform plan -out=tfplan
rtk terraform apply tfplan
```

Expected: VPC, subnet router EC2, private EKS, Pod Identity roles, ACM certificate, and Route 53 validation records are created. The root apply must not attempt to connect to Kubernetes.

- [ ] **Step 3: Approve/enable the Tailscale route and verify reachability**

Approve the route for the subnet router in the Tailscale Admin Console, or enable the advertised route with the Tailscale provider after the device appears. Then run:

```bash
rtk tailscale status
rtk tailscale ping $(terraform output -raw tailscale_subnet_router_hostname)
```

Expected: the subnet router is online and the VPC CIDR route is enabled.

- [ ] **Step 4: Plan and apply the platform application**

Run:

```bash
rtk terraform -chdir=platform init
rtk terraform -chdir=platform plan -out=platform.tfplan
rtk terraform -chdir=platform apply platform.tfplan
```

Expected: Helm provider reaches the private EKS endpoint over Tailscale and installs seven Helm releases: AWS Load Balancer Controller, ExternalDNS, Argo CD, Airflow, Kubecost, Spark Operator, and Karpenter without a `localhost:8080` or TLS proxy error.

- [ ] **Step 5: Validate Kubernetes, ALB, ACM, and DNS**

Run:

```bash
rtk aws acm describe-certificate --region us-east-1 --certificate-arn $(terraform output -raw platform_certificate_arn)
rtk kubectl -n kube-system get pods -l app.kubernetes.io/name=aws-load-balancer-controller
rtk kubectl -n kube-system get pods -l app.kubernetes.io/name=external-dns
rtk kubectl get ingress -A
rtk kubectl -n argocd get ingress argocd
rtk kubectl -n airflow get ingress airflow
rtk kubectl -n kubecost get ingress kubecost
rtk kubectl get nodes
```

Expected: ACM status is `ISSUED`, one ALB hostname appears in the three Ingress statuses, ExternalDNS creates `argocd.<domain>`, `airflow.<domain>`, and `kubecost.<domain>`, and all services report healthy backends.

- [ ] **Step 6: Push implementation commits**

Run:

```bash
rtk git status --short --branch
rtk git diff --check origin/master...HEAD
rtk git push
```

Expected: only intended files are changed, no whitespace errors exist, and `master` is synchronized with `origin/master`.

---

## Self-Review

- Spec coverage: Tasks 2-3 cover infrastructure-only routing, Route 53 discovery, ACM validation, Pod Identity, and public hosted-zone access. Tasks 4-6 cover the separate platform application, Helm providers/releases, one shared internal ALB, three namespace-local Ingresses, and ExternalDNS. Task 7 covers removal of the old Tailscale/Argo delivery path and documentation. Task 8 covers the two-phase MVP runtime workflow.
- Provider ordering: the plan never configures a Helm provider in the root EKS-creation application. The platform provider reads remote state only after the first apply and uses `depends_on` on release resources for Kubernetes ordering.
- Namespace correctness: each Ingress points only to a Service in its own namespace; the shared ALB is achieved through the same IngressGroup.
- Security: the ALB is internal, controller permissions are Pod Identity-based, ExternalDNS is restricted to the discovered Route 53 zone and `upsert-only`, and the Tailscale auth key remains a sensitive state concern.
- Placeholder scan: no unresolved implementation placeholders are present. `example.com` and `tskey-auth-example` appear only as explicit local configuration examples.
