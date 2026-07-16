#!/usr/bin/env bash
set -euo pipefail

bootstrap="templates/bootstrap.sh.tftpl"
locals_tf="locals.tf"
outputs_tf="outputs.tf"
bootstrap_tf="tailscale-bootstrap.tf"

if ! grep -q '^export KUBECONFIG=' "$bootstrap"; then
  printf 'expected bootstrap to export KUBECONFIG before helm/kubectl commands\n' >&2
  exit 1
fi

if ! grep -q -- 'aws eks update-kubeconfig .* --kubeconfig "\$KUBECONFIG"' "$bootstrap"; then
  printf 'expected aws eks update-kubeconfig to write to explicit KUBECONFIG\n' >&2
  exit 1
fi

kubeconfig_line=$(grep -n '^export KUBECONFIG=' "$bootstrap" | cut -d: -f1 | head -n1)
helm_line=$(grep -n '^helm repo add' "$bootstrap" | cut -d: -f1 | head -n1)

if (( kubeconfig_line >= helm_line )); then
  printf 'expected KUBECONFIG export before helm commands\n' >&2
  exit 1
fi

if ! grep -q 'https://tailscale.com/install.sh' "$bootstrap"; then
  printf 'expected bootstrap to install Tailscale on the subnet router instance\n' >&2
  exit 1
fi

if ! grep -q 'systemctl enable --now tailscaled' "$bootstrap"; then
  printf 'expected bootstrap to enable and start tailscaled\n' >&2
  exit 1
fi

if ! grep -q 'tailscale up' "$bootstrap"; then
  printf 'expected bootstrap to join the tailnet with tailscale up\n' >&2
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

if ! grep -q -- '--advertise-routes="\$VPC_CIDR"' "$bootstrap"; then
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

if grep -q 'tailscale configure kubeconfig' "$outputs_tf"; then
  printf 'expected outputs to stop recommending Tailscale API server proxy kubeconfig\n' >&2
  exit 1
fi

if ! grep -q 'aws eks update-kubeconfig' "$outputs_tf"; then
  printf 'expected outputs to recommend AWS EKS kubeconfig over the subnet route\n' >&2
  exit 1
fi
