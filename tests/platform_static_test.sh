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

if ! grep -A4 'variable "default_node_count"' "$variables" | grep -q 'default     = 3'; then
  printf 'expected default EKS node group count to be 3\n' >&2
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

if ! grep -q 'source.*hashicorp/helm' versions.tf; then
  printf 'expected root Terraform to declare Helm provider for Argo CD bootstrap\n' >&2
  exit 1
fi

if ! grep -q 'variable "enable_argocd_bootstrap"' "$variables"; then
  printf 'expected an explicit phase-2 switch for Terraform Argo CD bootstrap\n' >&2
  exit 1
fi

if ! grep -R -q 'count = var.enable_argocd_bootstrap ? 1 : 0' . --include='*.tf'; then
  printf 'expected Terraform Argo CD bootstrap resources to be gated until Tailscale route approval\n' >&2
  exit 1
fi

if ! grep -R -q 'resource "helm_release" "argocd"' . --include='*.tf'; then
  printf 'expected root Terraform helm_release.argocd bootstrap\n' >&2
  exit 1
fi

if ! grep -R -q 'resource "helm_release" "argocd_root_application"' . --include='*.tf'; then
  printf 'expected root Terraform helm_release.argocd_root_application bootstrap\n' >&2
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

if ! grep -q 'repository: https://bitnami.github.io/sealed-secrets' gitops/apps/sealed-secrets/Chart.yaml; then
  printf 'expected sealed-secrets to use the current bitnami.github.io repository\n' >&2
  exit 1
fi

if ! grep -q 'version: 2.19.1' gitops/apps/sealed-secrets/Chart.yaml; then
  printf 'expected sealed-secrets chart pinned to 2.19.1\n' >&2
  exit 1
fi

if ! test -f gitops/apps/sealed-secrets/charts/sealed-secrets-2.19.1.tgz; then
  printf 'expected vendored sealed-secrets 2.19.1 chart tgz\n' >&2
  exit 1
fi

if ! grep -q 'repository: https://kubecost.github.io/kubecost/' gitops/apps/kubecost/Chart.yaml; then
  printf 'expected kubecost to use the current kubecost.github.io/kubecost repository\n' >&2
  exit 1
fi

if ! grep -q 'name: kubecost' gitops/apps/kubecost/Chart.yaml || ! grep -q 'version: 3.2.1' gitops/apps/kubecost/Chart.yaml; then
  printf 'expected kubecost chart dependency pinned to kubecost 3.2.1\n' >&2
  exit 1
fi

if ! test -f gitops/apps/kubecost/charts/kubecost-3.2.1.tgz; then
  printf 'expected vendored kubecost 3.2.1 chart tgz\n' >&2
  exit 1
fi

for key in fernetKey jwtSecret apiSecretKey; do
  if ! grep -E "^  ${key}: ['\"]?[A-Za-z0-9+/=_-]+" gitops/apps/airflow/values.yaml >/dev/null; then
    printf 'expected airflow values to define a static %s\n' "$key" >&2
    exit 1
  fi
done

if ! grep -B3 'ServerSideApply=true' gitops/root/templates/applications.yaml | grep -q 'spark-operator'; then
  printf 'expected spark-operator Application to use ServerSideApply=true for large CRDs\n' >&2
  exit 1
fi

if grep -R -q 'bitnami-labs.github.io\|kubecost.github.io/cost-analyzer' gitops; then
  printf 'expected discontinued chart repositories to be removed from gitops tree\n' >&2
  exit 1
fi

if ! grep -q 'name: kubecost-frontend' gitops/base/templates/ingresses.yaml; then
  printf 'expected kubecost ingress to target the kubecost 3.x frontend service\n' >&2
  exit 1
fi
