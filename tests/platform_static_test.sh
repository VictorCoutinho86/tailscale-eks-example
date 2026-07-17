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

provider_block_contains() {
  local provider_name="$1"

  awk -v provider_name="$provider_name" '
    $0 ~ "^[[:space:]]*provider[[:space:]]+\"" provider_name "\"[[:space:]]*\\{" {
      in_block = 1
      depth = 0
    }

    in_block {
      block = block $0 "\n"
      line = $0
      depth += gsub(/\{/, "", line)
      depth -= gsub(/\}/, "", line)

      if (depth == 0) {
        found = block ~ /exec/ && block ~ /get-token/ && block ~ /command[[:space:]]*=[[:space:]]*"aws"/
        exit
      }
    }

    END { exit(found ? 0 : 1) }
  ' "$platform_root/providers.tf"
}

for provider in kubernetes helm; do
  if ! provider_block_contains "$provider"; then
    printf 'expected provider %s to configure aws eks get-token authentication\n' "$provider" >&2
    exit 1
  fi
done

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

for ingress_requirement in \
  'resource "kubernetes_ingress_v1" "platform"' \
  'for_each = local.platform_ingresses' \
  'ingress_class_name = "alb"'; do
  if ! grep -F -q -- "$ingress_requirement" "$platform_root/kubernetes.tf"; then
    printf 'expected Ingress requirement %s\n' "$ingress_requirement" >&2
    exit 1
  fi
done

for hostname in argocd airflow kubecost; do
  if ! grep -q "hostname[[:space:]]*=[[:space:]]*\"${hostname}\." "$platform_root/locals.tf"; then
    printf 'expected %s hostname entry in platform locals\n' "$hostname" >&2
    exit 1
  fi
done

if ! grep -E -q -- '"alb\.ingress\.kubernetes\.io/scheme"[[:space:]]*=[[:space:]]*"internal"' "$platform_root/kubernetes.tf"; then
  printf 'expected the shared ALB scheme annotation to assign internal\n' >&2
  exit 1
fi

for annotation in \
  'alb.ingress.kubernetes.io/group.name' \
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

old_path_pattern='apiServerProxyConfig|tailscale\.com/loadBalancerClass|tailscale configure kubeconfig'
for file in ./*.tf templates/*.tftpl platform/*; do
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

  case "$file" in
    "$bootstrap")
      forbidden_pattern='aws[[:space:]]+eks|awscli|kubectl|helm'
      ;;
    platform/*|outputs.tf)
      forbidden_pattern='aws[[:space:]]+eks|awscli|kubectl|helm[[:space:]]+(upgrade|repo|install)'
      ;;
    *)
      forbidden_pattern=''
      ;;
  esac

  if [[ -n "$forbidden_pattern" && "$content" =~ $forbidden_pattern ]]; then
    printf 'expected obsolete CLI delivery commands to be removed from %s\n' "$file" >&2
    exit 1
  fi
done

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
