#!/usr/bin/env bash
set -euo pipefail

bootstrap="templates/bootstrap.sh.tftpl"
locals_tf="locals.tf"
outputs_tf="outputs.tf"
bootstrap_tf="tailscale-bootstrap.tf"
bootstrap_iam_tf="bootstrap-iam.tf"

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

if ! grep -Fq -- '--advertise-routes="$VPC_CIDR,$VPC_IPV6_CIDR,${vpc_cidr_resolver}/32"' "$bootstrap"; then
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

if ! grep -q 'data "aws_ami" "bootstrap_ubuntu"' "$bootstrap_iam_tf"; then
  printf 'expected subnet router AMI data source to use Ubuntu\n' >&2
  exit 1
fi

if ! grep -q 'owners *= *\["099720109477"\]' "$bootstrap_iam_tf"; then
  printf 'expected subnet router AMI to use Canonical owner\n' >&2
  exit 1
fi

if ! grep -q 'ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-amd64-server-\*' "$bootstrap_iam_tf"; then
  printf 'expected subnet router AMI to filter Ubuntu 24.04 LTS gp3 server images\n' >&2
  exit 1
fi

if ! grep -q 'image_id *= *data.aws_ami.bootstrap_ubuntu.id' "$bootstrap_tf"; then
  printf 'expected subnet router launch template to use Ubuntu AMI\n' >&2
  exit 1
fi

if ! grep -q 'device_name *= *data.aws_ami.bootstrap_ubuntu.root_device_name' "$bootstrap_tf"; then
  printf 'expected subnet router root block device to use the Ubuntu AMI root device name\n' >&2
  exit 1
fi

if ! grep -q 'apt-get update' "$bootstrap" || ! grep -q 'apt-get install' "$bootstrap"; then
  printf 'expected bootstrap template to use apt on Ubuntu\n' >&2
  exit 1
fi

if ! grep -q 'awscli-exe-linux-x86_64.zip' "$bootstrap"; then
  printf 'expected bootstrap template to install AWS CLI v2 with the bundled installer\n' >&2
  exit 1
fi

if grep -q '^apt-get install .*awscli' "$bootstrap"; then
  printf 'expected bootstrap template not to install awscli from Ubuntu apt packages\n' >&2
  exit 1
fi

if grep -q 'dnf install' "$bootstrap"; then
  printf 'expected bootstrap template not to use dnf on Ubuntu\n' >&2
  exit 1
fi

if ! grep -q 'tayga' "$bootstrap" || ! grep -q '/etc/tayga.conf' "$bootstrap"; then
  printf 'expected bootstrap template to configure packaged tayga NAT64\n' >&2
  exit 1
fi

if grep -q 'authorized_keys\|/home/ubuntu/.ssh\|ssh-ed25519' "$bootstrap"; then
  printf 'expected bootstrap template not to bake personal SSH keys into subnet routers\n' >&2
  exit 1
fi

if ! grep -q 'resource "aws_autoscaling_group" "subnet_router"' "$bootstrap_tf"; then
  printf 'expected subnet router Auto Scaling Group\n' >&2
  exit 1
fi

if ! grep -q 'count = var.enable_bootstrap_instance ? 1 : 0' "$bootstrap_tf"; then
  printf 'expected a single subnet-router ASG\n' >&2
  exit 1
fi

for size in min_size max_size desired_capacity; do
  if ! grep -Eq "^[[:space:]]*${size}[[:space:]]*=[[:space:]]*1[[:space:]]*$" "$bootstrap_tf"; then
    printf 'expected subnet-router ASGs to use %s of 1\n' "$size" >&2
    exit 1
  fi
done

if ! grep -qF 'vpc_zone_identifier = [module.vpc.public_subnets[count.index]]' "$bootstrap_tf"; then
  printf 'expected subnet-router ASGs to be pinned to distinct public subnets by count.index\n' >&2
  exit 1
fi

if ! grep -Fq 'name                = "${local.name}-subnet-router-${local.subnet_router_azs[count.index]}"' "$bootstrap_tf"; then
  printf 'expected subnet-router ASGs to use AZ-specific names by count.index\n' >&2
  exit 1
fi

if ! grep -Fq 'value               = "${local.name}-subnet-router-${local.subnet_router_azs[count.index]}"' "$bootstrap_tf"; then
  printf 'expected subnet-router ASGs to tag instances with AZ-specific names by count.index\n' >&2
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

if grep -q 'instance_type = "t3.nano"\|instance_type = "t3a.nano"' "$bootstrap_tf"; then
  printf 'expected subnet-router spot overrides not to use nano instances\n' >&2
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

if ! grep -q 'net.ipv6.conf.all.forwarding = 1' "$bootstrap"; then
  printf 'expected bootstrap to enable IPv6 forwarding for subnet routing and NAT64\n' >&2
  exit 1
fi

if ! grep -q 'VPC_IPV6_CIDR' "$bootstrap"; then
  printf 'expected bootstrap to receive the VPC IPv6 CIDR\n' >&2
  exit 1
fi

if ! grep -q 'NAT64_PREFIX' "$bootstrap"; then
  printf 'expected bootstrap to configure a NAT64 prefix\n' >&2
  exit 1
fi

if ! grep -Fq -- '--destination-ipv6-cidr-block "$NAT64_PREFIX"' "$bootstrap"; then
  printf 'expected bootstrap to manage NAT64 IPv6 route-table entries\n' >&2
  exit 1
fi

if ! grep -q 'unbound' "$bootstrap" || ! grep -q 'dns64-prefix:' "$bootstrap"; then
  printf 'expected bootstrap to configure DNS64 with unbound\n' >&2
  exit 1
fi

if ! grep -q 'systemctl enable unbound' "$bootstrap" || ! grep -q 'systemctl restart unbound' "$bootstrap" || grep -q 'systemctl enable --now unbound' "$bootstrap"; then
  printf 'expected bootstrap to validate DNS64 config before enabling and restarting unbound\n' >&2
  exit 1
fi

if ! grep -q 'nat64.service' "$bootstrap" || ! grep -q 'systemctl enable --now nat64.service' "$bootstrap"; then
  printf 'expected bootstrap to configure and enable NAT64 service\n' >&2
  exit 1
fi

if ! grep -q 'pid-file /run/tayga.pid' "$bootstrap" || \
  ! grep -q 'Type=forking' "$bootstrap" || \
  ! grep -q 'PIDFile=/run/tayga.pid' "$bootstrap" || \
  ! grep -q 'ExecStartPre=/usr/local/sbin/nat64-setup' "$bootstrap" || \
  ! grep -q 'ExecStart=/usr/sbin/tayga' "$bootstrap" || \
  ! grep -q 'Restart=on-failure' "$bootstrap"; then
  printf 'expected nat64.service to supervise tayga with systemd\n' >&2
  exit 1
fi

if grep -q 'pgrep -x tayga' "$bootstrap"; then
  printf 'expected nat64 setup not to use pgrep as a tayga process guard\n' >&2
  exit 1
fi

if grep -q 'RemainAfterExit=yes' "$bootstrap" && grep -A10 '\[Service\]' "$bootstrap" | grep -q 'ExecStart=/usr/local/sbin/nat64-setup'; then
  printf 'expected nat64 setup not to start tayga as a oneshot service\n' >&2
  exit 1
fi

if ! grep -q 'private_route_table_ids_by_router_az' "$bootstrap_tf"; then
  printf 'expected Terraform to pass router-AZ route-table assignments\n' >&2
  exit 1
fi

if ! grep -A2 -F 'local.subnet_router_azs[0]' "$bootstrap_tf" | grep -Fq 'module.vpc.private_route_table_ids'; then
  printf 'expected the single subnet router to receive all private route tables\n' >&2
  exit 1
fi

if ! grep -q 'protocol    = "-1"' bootstrap-iam.tf; then
  printf 'expected bootstrap security group to allow forwarded traffic\n' >&2
  exit 1
fi
