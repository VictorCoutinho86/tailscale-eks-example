# Private Subnets and NAT Instance Design

## Context

The current Terraform root module creates one VPC with three public `/24` subnets. The private-only EKS API is reached through a persistent Tailscale subnet-router EC2 instance in a public subnet. EKS cluster subnet inputs and the default managed node group currently use public subnets.

The next change is to add larger private subnets, reuse the subnet-router EC2 instance as a NAT instance, and move EKS worker capacity to private subnets while preserving the current two-phase access model.

## Goals

- Add three private subnets with substantially more available IPs than the existing public `/24` subnets.
- Use the existing Tailscale subnet-router EC2 instance as the single NAT instance for private subnet egress.
- Configure EKS worker nodes and Karpenter-launched nodes to use private subnets.
- Keep the subnet-router in a public subnet with a public IP, Tailscale route advertisement, and SSH/debug access.
- Preserve root Terraform as the AWS infrastructure owner and Argo CD as the platform services owner.

## Non-Goals

- Add AWS NAT Gateways.
- Add one NAT instance per Availability Zone.
- Reintroduce the Tailscale Kubernetes Operator, API server proxy, Helm releases for platform services, or the retired `platform/` apply path.
- Move Argo CD child applications out of GitOps.

## Network Design

Keep the existing three public `/24` subnets for the internet gateway route, subnet-router EC2 placement, and EKS control-plane ENIs as currently configured.

Add three private `/20` subnets, one per Availability Zone:

- `10.0.16.0/20`
- `10.0.32.0/20`
- `10.0.48.0/20`

These ranges avoid overlap with the existing public `/24` subnets generated from the VPC CIDR. With the default `10.0.0.0/16` VPC, each private subnet provides roughly 4091 usable IPv4 addresses.

Private subnet tags:

- `kubernetes.io/role/internal-elb = 1`
- `karpenter.sh/discovery = local.name`

Public subnet tags should keep `kubernetes.io/role/elb = 1`; `kubernetes.io/role/internal-elb` should move to private subnets so internal ALBs are placed privately.

## NAT Instance Design

The existing subnet-router EC2 instance remains in the first public subnet and becomes the single NAT instance for private subnet egress.

Terraform changes:

- Set `source_dest_check = false` on `aws_instance.bootstrap`.
- Add private subnet default routes, `0.0.0.0/0`, targeting the subnet-router primary network interface.
- Keep `enable_nat_gateway = false` in the VPC module.
- Attach the S3 gateway VPC endpoint to private route tables instead of only public route tables.

Bootstrap script changes:

- Keep Tailscale installation, `tailscaled`, IPv4 forwarding, and route advertisement for the VPC CIDR plus VPC resolver `/32`.
- Add persistent NAT masquerade rules for traffic from the VPC CIDR leaving through the public network interface.
- Keep `--accept-dns=false` so the EC2 instance preserves AWS DNS behavior.

Security group changes:

- Allow the subnet-router to receive forwarded traffic from the private subnet CIDRs or the VPC CIDR as needed for NAT.
- Keep outbound HTTP, HTTPS, and DNS rules required for package installation, Tailscale, and AWS service access.

This is intentionally a low-cost MVP trade-off. The NAT path is single-instance and single-AZ: if the subnet-router instance is stopped, replaced, or unhealthy, private nodes lose internet egress until it recovers.

## EKS Design

Use private subnets for worker capacity:

- `module.eks.subnet_ids = module.vpc.private_subnets`
- Default managed node group `subnet_ids = module.vpc.private_subnets`
- Karpenter `EC2NodeClass` subnet selectors should discover/select private subnets through `karpenter.sh/discovery` tags.

Keep EKS control-plane ENIs on the existing public subnet set:

- `control_plane_subnet_ids = module.vpc.public_subnets`

The EKS API endpoint remains private-only. Operators still reach it through the approved Tailscale route and split DNS before running the Argo CD Terraform bootstrap phase.

## Apply Flow

The apply flow remains two-phase:

1. Apply AWS infrastructure with `enable_argocd_bootstrap=false`.
2. Approve the Tailscale advertised VPC route.
3. Verify private EKS endpoint access through Tailscale and split DNS.
4. Apply again with `enable_argocd_bootstrap=true` to install Argo CD and the root Application through Terraform Helm.

For an existing cluster, moving the default managed node group from public to private subnets may require node group replacement or a new node group, depending on the Terraform plan. The implementation should inspect the plan and avoid surprise destructive behavior.

## Testing

Static tests should assert:

- Private subnets are defined as `/20` ranges.
- EKS node subnet inputs use `module.vpc.private_subnets`.
- EKS control-plane subnet inputs remain `module.vpc.public_subnets`.
- The subnet-router EC2 instance has `source_dest_check = false`.
- No AWS NAT Gateway is enabled.
- Private route tables route `0.0.0.0/0` to the subnet-router network interface.
- The S3 gateway endpoint is attached to private route tables.
- Karpenter discovery tags are present on private subnets.

Validation commands:

- `rtk bash tests/platform_static_test.sh`
- `rtk bash tests/bootstrap_static_test.sh`
- `rtk terraform fmt -check *.tf`
- `rtk terraform validate`
- `rtk terraform plan -out=tfplan`

Runtime checks after apply:

- Nodes have private IPs from the new private `/20` subnets.
- Pods can pull images and reach required public endpoints through the NAT instance.
- Internal ALBs land in private subnets.
- Argo CD syncs the GitOps app-of-apps tree successfully.

## Risks

- The NAT instance is a single point of failure for private subnet internet egress.
- Routing all private subnet egress through one small instance may become a throughput bottleneck.
- Existing managed node group subnet migration can be disruptive if Terraform replaces the node group.
- Incorrect NAT masquerade or source/destination check settings will prevent private nodes from reaching public services.
- If private route tables are wrong, nodes may fail to register or pull images.
