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

if ! grep -q 'exec' "$platform_root/providers.tf"; then
  printf 'expected the platform Helm/Kubernetes providers to authenticate with aws eks get-token\n' >&2
  exit 1
fi

get_token_count=$(grep -c 'get-token' "$platform_root/providers.tf" || true)
aws_command_count=$(grep -c 'command[[:space:]]*=[[:space:]]*"aws"' "$platform_root/providers.tf" || true)
if (( get_token_count < 2 || aws_command_count < 2 )); then
  printf 'expected both platform providers to configure aws eks get-token authentication\n' >&2
  exit 1
fi

if ! grep -q 'helm_release' "$platform_root/helm.tf"; then
  printf 'expected platform services to be installed with helm_release\n' >&2
  exit 1
fi

for release in aws_load_balancer_controller external_dns argocd airflow kubecost spark_operator karpenter; do
  if ! grep -q "helm_release.*$release\|resource \"helm_release\" \"$release\"" "$platform_root/helm.tf"; then
    printf 'expected helm release %s\n' "$release" >&2
    exit 1
  fi
done

if ! grep -F -q -- 'resource "kubernetes_ingress_v1"' "$platform_root/kubernetes.tf" || ! grep -q 'for_each[[:space:]]*=[[:space:]]*local\.platform_ingresses' "$platform_root/kubernetes.tf"; then
  printf 'expected one Ingress resource driven by local.platform_ingresses\n' >&2
  exit 1
fi

for hostname in argocd airflow kubecost; do
  if ! grep -q "hostname[[:space:]]*=[[:space:]]*\"${hostname}\." "$platform_root/locals.tf"; then
    printf 'expected %s hostname entry in platform locals\n' "$hostname" >&2
    exit 1
  fi
done

for annotation in \
  'alb.ingress.kubernetes.io/group.name' \
  'alb.ingress.kubernetes.io/scheme' \
  'internal' \
  'alb.ingress.kubernetes.io/certificate-arn' \
  'external-dns.alpha.kubernetes.io/hostname'; do
  if ! grep -F -q -- "$annotation" "$platform_root/kubernetes.tf"; then
    printf 'expected Ingress setting %s\n' "$annotation" >&2
    exit 1
  fi
done

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

if grep -R -q -E -- 'apiServerProxyConfig|tailscale.com/loadBalancerClass|tailscale configure kubeconfig' "$bootstrap" "$platform_root" "$outputs"; then
  printf 'expected old Tailscale API/UI delivery path to be removed\n' >&2
  exit 1
fi

if grep -E -q -- 'aws eks|awscli|kubectl|helm' "$bootstrap"; then
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

if ! grep -q 'route53_domain_name' "$variables" || ! grep -q 'platform_certificate_arn' "$outputs"; then
  printf 'expected Route 53 domain input and ACM output\n' >&2
  exit 1
fi
