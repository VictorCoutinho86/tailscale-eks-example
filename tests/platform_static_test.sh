#!/usr/bin/env bash
set -euo pipefail

infra_root="."
platform_root="platform"
bootstrap="templates/bootstrap.sh.tftpl"
pod_identity="pod-identity.tf"
network="network.tf"
variables="variables.tf"
outputs="outputs.tf"

if ! grep -q 'attach_aws_lb_controller_policy' "$pod_identity"; then
  printf 'expected AWS Load Balancer Controller Pod Identity\n' >&2
  exit 1
fi

if ! grep -q 'module "aws_load_balancer_controller_pod_identity"' "$pod_identity"; then
  printf 'expected a dedicated AWS Load Balancer Controller Pod Identity module\n' >&2
  exit 1
fi

if ! grep -q 'attach_external_dns_policy' "$pod_identity"; then
  printf 'expected ExternalDNS Pod Identity\n' >&2
  exit 1
fi

if ! grep -q 'module "external_dns_pod_identity"' "$pod_identity"; then
  printf 'expected a dedicated ExternalDNS Pod Identity module\n' >&2
  exit 1
fi

if ! grep -q 'private_zone.*false' "$infra_root/route53-acm.tf"; then
  printf 'expected discovery of an existing public Route 53 hosted zone\n' >&2
  exit 1
fi

for resource in \
  'aws_acm_certificate' \
  'aws_route53_record' \
  'domain_validation_options' \
  'aws_acm_certificate_validation' \
  '*.${trimsuffix(var.route53_domain_name, ".")}' \
  'validation_method = "DNS"'; do
  if ! grep -F -q -- "$resource" "$infra_root/route53-acm.tf"; then
    printf 'expected Route 53/ACM assertion %s\n' "$resource" >&2
    exit 1
  fi
done

old_path_pattern='apiServerProxyConfig|tailscale\.com/loadBalancerClass|tailscale configure kubeconfig'
if ! static_files=$(git ls-files -co --exclude-standard -- '*.tf' 'templates/*.tftpl' 'platform/**'); then
  printf 'unable to list static-check inputs\n' >&2
  exit 1
fi

while IFS= read -r file || [[ -n "$file" ]]; do
  if [[ ! -f "$file" ]]; then
    continue
  fi

  if ! content=$(<"$file"); then
    printf 'unable to read static-check input %s\n' "$file" >&2
    exit 1
  fi

  if [[ "$content" =~ $old_path_pattern ]]; then
    printf 'expected old Tailscale API/UI delivery path to be removed from %s\n' "$file" >&2
    exit 1
  fi
done <<EOF
$static_files
EOF

if ! grep -q 'kubernetes.io/role/internal-elb' "$network"; then
  printf 'expected subnet tagging for internal ALB discovery\n' >&2
  exit 1
fi

if ! grep -q 'route53_domain_name' "$variables" || ! grep -q 'platform_certificate_arn' "$outputs"; then
  printf 'expected Route 53 domain input and ACM output\n' >&2
  exit 1
fi

if grep -R -q 'resource "helm_release"' platform 2>/dev/null; then
  printf 'expected platform Terraform to stop owning Helm releases\n' >&2
  exit 1
fi

if grep -R -q 'resource "kubernetes_' platform 2>/dev/null; then
  printf 'expected platform Terraform to stop owning Kubernetes resources\n' >&2
  exit 1
fi

if ! test -f gitops/root/Chart.yaml || ! test -f gitops/root/templates/applications.yaml; then
  printf 'expected gitops/root Helm chart for app-of-apps\n' >&2
  exit 1
fi

for app in base argocd aws-load-balancer-controller external-dns karpenter karpenter-resources airflow spark-operator kubecost sealed-secrets; do
  if ! grep -R -q "\"name\" \"${app}\"" gitops/root/templates; then
    printf 'expected root app-of-apps to define %s application\n' "$app" >&2
    exit 1
  fi
done

for app_dir in base argocd aws-load-balancer-controller external-dns karpenter karpenter-resources airflow spark-operator kubecost sealed-secrets; do
  if ! test -e "gitops/apps/${app_dir}" && ! test -e "gitops/${app_dir}"; then
    printf 'expected GitOps source for %s\n' "$app_dir" >&2
    exit 1
  fi
done

if ! grep -R -q 'argocd.argoproj.io/sync-wave' gitops; then
  printf 'expected GitOps resources to use Argo CD sync waves\n' >&2
  exit 1
fi

if ! grep -R -q 'useHelmHooks: false' gitops/apps/airflow; then
  printf 'expected Airflow Helm hooks to be disabled for Argo CD safety\n' >&2
  exit 1
fi

if grep -q 'variable "public_subnet_count"' variables.tf || grep -q 'public_subnet_count' locals.tf; then
  printf 'expected public_subnet_count to be removed\n' >&2
  exit 1
fi

if ! grep -q 'slice(data.aws_availability_zones.available.names, 0, 3)' locals.tf; then
  printf 'expected exactly 3 Availability Zones\n' >&2
  exit 1
fi

if ! grep -q 'cidrsubnet(var.vpc_cidr, 8, index)' locals.tf; then
  printf 'expected /24 public subnet calculation with cidrsubnet newbits 8\n' >&2
  exit 1
fi
