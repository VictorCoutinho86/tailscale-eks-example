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

if ! grep -qF -- '--auth-key="$TAILSCALE_SUBNET_ROUTER_AUTH_KEY"' "$bootstrap"; then
  printf 'expected tailscale up to use the subnet router auth key\n' >&2
  exit 1
fi

if ! grep -qF -- '--hostname="$TAILSCALE_SUBNET_ROUTER_HOSTNAME' "$bootstrap"; then
  printf 'expected tailscale up to set the subnet router hostname\n' >&2
  exit 1
fi

if ! grep -qF -- '--advertise-routes="$VPC_CIDR,${vpc_cidr_resolver}/32"' "$bootstrap"; then
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

if ! grep -q 'resource "aws_launch_template" "subnet_router"' "$bootstrap_tf"; then
  printf 'expected subnet router launch template\n' >&2
  exit 1
fi

if ! grep -q 'resource "aws_autoscaling_group" "subnet_router"' "$bootstrap_tf"; then
  printf 'expected subnet router Auto Scaling Group\n' >&2
  exit 1
fi

if ! grep -q 'min_size *= *3' "$bootstrap_tf"; then
  printf 'expected ASG min_size of 3 for per-AZ subnet router instances\n' >&2
  exit 1
fi

if ! grep -q 'desired_capacity *= *3' "$bootstrap_tf"; then
  printf 'expected ASG desired_capacity of 3 for per-AZ subnet router instances\n' >&2
  exit 1
fi

if ! grep -q 'mixed_instances_policy' "$bootstrap_tf"; then
  printf 'expected ASG to use a mixed instances policy for spot diversification\n' >&2
  exit 1
fi

if ! grep -q 'spot_allocation_strategy *= *"price-capacity-optimized"' "$bootstrap_tf"; then
  printf 'expected spot allocation strategy to balance price and capacity\n' >&2
  exit 1
fi

if ! grep -q 'on_demand_percentage_above_base_capacity *= *0' "$bootstrap_tf"; then
  printf 'expected all subnet router instances to be spot\n' >&2
  exit 1
fi

if ! grep -q 'instance_type = "t3.micro"' "$bootstrap_tf"; then
  printf 'expected t3.micro in spot instance type overrides\n' >&2
  exit 1
fi

if ! grep -q 'capacity_rebalance *= *true' "$bootstrap_tf"; then
  printf 'expected capacity_rebalance for zero-downtime spot instance replacement\n' >&2
  exit 1
fi

if ! grep -q 'instance_type = "t3.nano"' "$bootstrap_tf"; then
  printf 'expected t3.nano in spot instance type overrides\n' >&2
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

for forbidden in \
  'aws eks update-kubeconfig' \
  'helm upgrade --install argocd' \
  'kubectl apply' \
  'argocd-bootstrap.service' \
  'argocd-bootstrap.timer' \
  'systemctl enable --now argocd-bootstrap.timer'; do
  if grep -q "$forbidden" "$bootstrap"; then
    printf 'expected bootstrap template not to contain Kubernetes bootstrap command %s\n' "$forbidden" >&2
    exit 1
  fi
done

if ! grep -q 'MASQUERADE' "$bootstrap"; then
  printf 'expected bootstrap template to configure NAT masquerade\n' >&2
  exit 1
fi

if ! grep -q 'nat-masquerade.service' "$bootstrap"; then
  printf 'expected bootstrap template to persist NAT masquerade via systemd\n' >&2
  exit 1
fi

if ! grep -q 'protocol    = "-1"' bootstrap-iam.tf; then
  printf 'expected bootstrap security group to allow forwarded traffic\n' >&2
  exit 1
fi
