#!/usr/bin/env bash
set -euo pipefail

bootstrap="templates/bootstrap.sh.tftpl"
locals_tf="locals.tf"
outputs_tf="outputs.tf"
bootstrap_tf="tailscale-bootstrap.tf"

if ! grep -q 'https://tailscale.com/install.sh' "$bootstrap"; then
  printf 'expected bootstrap to install Tailscale on the subnet router instance\n' >&2
  exit 1
fi

if ! grep -q 'systemctl enable --now tailscaled' "$bootstrap"; then
  printf 'expected bootstrap to enable and start tailscaled\n' >&2
  exit 1
fi

if ! grep -q 'net.ipv4.ip_forward = 1' "$bootstrap"; then
  printf 'expected bootstrap to enable IPv4 forwarding for subnet routing\n' >&2
  exit 1
fi

if ! grep -q 'sysctl -p /etc/sysctl.d/99-tailscale.conf' "$bootstrap"; then
  printf 'expected bootstrap to apply Tailscale sysctl forwarding configuration\n' >&2
  exit 1
fi

if ! grep -q 'tailscale up' "$bootstrap"; then
  printf 'expected bootstrap to join the tailnet with tailscale up\n' >&2
  exit 1
fi

if grep -q '^export TAILSCALE_SUBNET_ROUTER_AUTH_KEY=' "$bootstrap"; then
  printf 'expected bootstrap to keep the subnet router auth key out of child process environments\n' >&2
  exit 1
fi

if ! grep -q -- '--auth-key="\$TAILSCALE_SUBNET_ROUTER_AUTH_KEY"' "$bootstrap"; then
  printf 'expected tailscale up to use the subnet router auth key\n' >&2
  exit 1
fi

if ! grep -q -- '--hostname="\$TAILSCALE_SUBNET_ROUTER_HOSTNAME"' "$bootstrap"; then
  printf 'expected tailscale up to set the subnet router hostname\n' >&2
  exit 1
fi

if ! grep -q -- '--advertise-routes="\$VPC_CIDR,${vpc_cidr_resolver}/32"' "$bootstrap"; then
  printf 'expected bootstrap to advertise the VPC CIDR as a Tailscale subnet route\n' >&2
  exit 1
fi

if ! grep -q -- '--accept-dns=false' "$bootstrap"; then
  printf 'expected subnet router to preserve AWS DNS with --accept-dns=false\n' >&2
  exit 1
fi

if ! grep -q 'tailscale_subnet_router_auth_key' "$bootstrap_tf"; then
  printf 'expected bootstrap Terraform resource to pass the subnet router auth key into user_data\n' >&2
  exit 1
fi

if ! grep -q 'tailscale_subnet_router_hostname' "$locals_tf"; then
  printf 'expected locals to define a subnet router hostname\n' >&2
  exit 1
fi

if grep -q 'apiServerProxyConfig' "$locals_tf"; then
  printf 'expected Tailscale API server proxy config to be removed because this tailnet lacks HTTPS cert support\n' >&2
  exit 1
fi

if grep -q 'tailscale configure kubeconfig\|aws eks update-kubeconfig' "$outputs_tf"; then
  printf 'expected outputs to avoid kubeconfig command recommendations in the platform Terraform flow\n' >&2
  exit 1
fi

for expected in \
  'aws eks update-kubeconfig' \
  'helm upgrade --install argocd' \
  'kubectl apply' \
  'argocd-bootstrap.service' \
  'argocd-bootstrap.timer' \
  'systemctl enable --now argocd-bootstrap.timer'; do
  if ! grep -q "$expected" "$bootstrap"; then
    printf 'expected bootstrap template to contain %s\n' "$expected" >&2
    exit 1
  fi
done

for expected in \
  'set -euo pipefail' \
  'until aws eks describe-cluster' \
  'until kubectl get namespace kube-system' \
  '/var/lib/argocd-bootstrap/succeeded'; do
  if ! grep -q "$expected" "$bootstrap"; then
    printf 'expected idempotent/retryable bootstrap behavior %s\n' "$expected" >&2
    exit 1
  fi
done
