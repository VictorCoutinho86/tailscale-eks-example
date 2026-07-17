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

output "public_subnet_ids" {
  description = "Public subnet IDs."
  value       = module.vpc.public_subnets
}

output "tailscale_subnet_router_hostname" {
  description = "Tailscale subnet router hostname that advertises the VPC CIDR."
  value       = local.tailscale_subnet_router_hostname
}

output "tailscale_subnet_route" {
  description = "VPC CIDR advertised by the Tailscale subnet router. Approve this route in the Tailscale admin console."
  value       = var.vpc_cidr
}

output "bootstrap_instance_id" {
  description = "Bootstrap subnet router instance ID when enabled."
  value       = try(aws_instance.bootstrap[0].id, null)
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
