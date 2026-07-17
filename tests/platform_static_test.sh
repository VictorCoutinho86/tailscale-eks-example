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

if ! grep -q 'alb.ingress.kubernetes.io/scheme.*internal' "$platform_root/kubernetes.tf"; then
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
