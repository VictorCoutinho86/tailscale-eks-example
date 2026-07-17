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

hcl_block_contains() {
  local file="$1"
  local header="$2"
  local needle="$3"

  awk -v header="$header" -v needle="$needle" '
    function starts_block(line) {
      sub(/^[[:space:]]*/, "", line)
      if (substr(line, 1, length(header)) != header) {
        return 0
      }

      remainder = substr(line, length(header) + 1)
      return remainder ~ /^[[:space:]]*\{/
    }

    !in_block && !finished && starts_block($0) {
      in_block = 1
      depth = 0
    }

    in_block {
      normalized_line = $0
      gsub(/[[:space:]]+/, " ", normalized_line)
      block = block normalized_line "\n"
      line = $0
      depth += gsub(/\{/, "", line)
      depth -= gsub(/\}/, "", line)

      if (depth == 0) {
        found = index(block, needle) > 0
        finished = 1
        in_block = 0
      }
    }

    END { exit (finished && found ? 0 : 1) }
  ' "$file"
}

for provider in kubernetes helm; do
  for provider_needle in \
    'exec' \
    'get-token' \
    'command = "aws"'; do
    if ! hcl_block_contains "$platform_root/providers.tf" "provider \"$provider\"" "$provider_needle"; then
      printf 'expected provider %s to contain %s\n' "$provider" "$provider_needle" >&2
      exit 1
    fi
  done
done

if ! grep -q 'helm_release' "$platform_root/helm.tf"; then
  printf 'expected platform services to be installed with helm_release\n' >&2
  exit 1
fi

for release in aws_load_balancer_controller external_dns argocd airflow kubecost spark_operator karpenter karpenter_resources; do
  if ! grep -q "helm_release.*$release\|resource \"helm_release\" \"$release\"" "$platform_root/helm.tf"; then
    printf 'expected helm release %s\n' "$release" >&2
    exit 1
  fi
done

if ! hcl_block_contains "$platform_root/helm.tf" 'resource "helm_release" "external_dns"' 'name = "extraArgs.aws-zone-type"' || \
  ! hcl_block_contains "$platform_root/helm.tf" 'resource "helm_release" "external_dns"' 'value = "public"'; then
  printf 'expected ExternalDNS to filter public Route 53 zones with --aws-zone-type\n' >&2
  exit 1
fi

if grep -q 'resource "kubernetes_manifest" "karpenter' "$platform_root/kubernetes.tf"; then
  printf 'expected Karpenter CRD-backed resources to be installed by Helm, not kubernetes_manifest\n' >&2
  exit 1
fi

if ! grep -q 'karpenter.k8s.aws/v1' "$platform_root/charts/karpenter-resources/templates/ec2nodeclass.yaml" || \
  ! grep -q 'karpenter.sh/v1' "$platform_root/charts/karpenter-resources/templates/nodepools.yaml"; then
  printf 'expected local Helm chart to define Karpenter CRD-backed resources\n' >&2
  exit 1
fi

for hostname in argocd airflow kubecost; do
  if ! grep -q "hostname[[:space:]]*=[[:space:]]*\"${hostname}\." "$platform_root/locals.tf"; then
    printf 'expected %s hostname entry in platform locals\n' "$hostname" >&2
    exit 1
  fi
done

for ingress_needle in \
  'for_each = local.platform_ingresses' \
  'ingress_class_name = "alb"' \
  '"alb.ingress.kubernetes.io/scheme" = "internal"' \
  '"alb.ingress.kubernetes.io/group.name"' \
  '"alb.ingress.kubernetes.io/certificate-arn"' \
  '"external-dns.alpha.kubernetes.io/hostname"'; do
  if ! hcl_block_contains "$platform_root/kubernetes.tf" 'resource "kubernetes_ingress_v1" "platform"' "$ingress_needle"; then
    printf 'expected platform Ingress to contain %s\n' "$ingress_needle" >&2
    exit 1
  fi
done

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

  relative_file="${file#./}"
  case "$relative_file" in
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
done <<EOF
$static_files
EOF

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
