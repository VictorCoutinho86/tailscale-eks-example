output "cluster_name" {
  description = "EKS cluster name."
  value       = module.eks.cluster_name
}

output "cluster_endpoint" {
  description = "Private EKS cluster endpoint."
  value       = module.eks.cluster_endpoint
}

output "cluster_ca_certificate" {
  description = "Base64-encoded CA certificate for the private EKS endpoint."
  value       = module.eks.cluster_certificate_authority_data
  sensitive   = true
}

output "aws_region" {
  description = "AWS region used by this stack."
  value       = var.aws_region
}

output "vpc_id" {
  description = "VPC ID."
  value       = module.vpc.vpc_id
}

output "vpc_ipv6_cidr_block" {
  description = "Amazon-provided IPv6 CIDR block associated with the VPC."
  value       = module.vpc.vpc_ipv6_cidr_block
}

output "public_subnet_ids" {
  description = "Public subnet IDs."
  value       = module.vpc.public_subnets
}

output "private_subnet_ipv6_cidr_blocks" {
  description = "IPv6 CIDR blocks assigned to private EKS subnets."
  value       = module.vpc.private_subnets_ipv6_cidr_blocks
}

output "tailscale_subnet_router_hostname" {
  description = "Tailscale subnet router hostname base prefix; each router appends its AZ suffix."
  value       = local.tailscale_subnet_router_hostname
}

output "tailscale_subnet_route" {
  description = "VPC CIDR advertised by the Tailscale subnet routers. Approve this route in the Tailscale admin console."
  value       = var.vpc_cidr
}

output "tailscale_subnet_ipv6_route" {
  description = "VPC IPv6 CIDR advertised by the Tailscale subnet routers. Approve this route in the Tailscale admin console."
  value       = module.vpc.vpc_ipv6_cidr_block
}

output "subnet_router_asg_names" {
  description = "Subnet router Auto Scaling Group names when enabled."
  value       = [for asg in aws_autoscaling_group.subnet_router : asg.name]
}

output "karpenter_queue_name" {
  description = "Karpenter interruption queue name."
  value       = module.karpenter.queue_name
}

output "karpenter_node_role_name" {
  description = "Karpenter node IAM role name used by EC2NodeClass resources."
  value       = module.karpenter.node_iam_role_name
}

output "route53_domain_name" {
  description = "Public Route 53 domain managed by ExternalDNS."
  value       = trimsuffix(var.route53_domain_name, ".")
}

output "route53_hosted_zone_id" {
  description = "Existing public Route 53 hosted zone ID."
  value       = data.aws_route53_zone.platform.zone_id
}

output "route53_hosted_zone_arn" {
  description = "Existing public Route 53 hosted zone ARN."
  value       = local.route53_hosted_zone_arn
}

output "platform_certificate_arn" {
  description = "Validated ACM wildcard certificate ARN for the platform ALB."
  value       = aws_acm_certificate_validation.platform.certificate_arn
}
