output "cluster_name" {
  description = "EKS cluster name."
  value       = module.eks.cluster_name
}

output "cluster_endpoint" {
  description = "Private EKS cluster endpoint."
  value       = module.eks.cluster_endpoint
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

output "tailscale_operator_hostname" {
  description = "Tailscale Operator hostname for kubeconfig configuration."
  value       = local.tailscale_operator_hostname
}

output "tailscale_kubeconfig_command" {
  description = "Command to configure kubeconfig through Tailscale after the operator is ready."
  value       = "tailscale configure kubeconfig ${local.tailscale_operator_hostname}"
}

output "argocd_tailscale_hostname" {
  description = "Tailscale hostname for the Argo CD UI."
  value       = local.argocd_tailscale_hostname
}

output "argocd_repo_url" {
  description = "Git repository URL Argo CD syncs."
  value       = var.argocd_repo_url
}

output "argocd_path" {
  description = "Git repository path for the Argo CD root app-of-apps."
  value       = var.argocd_path
}

output "bootstrap_instance_id" {
  description = "Temporary bootstrap instance ID when enabled."
  value       = try(aws_instance.bootstrap[0].id, null)
}

output "karpenter_queue_name" {
  description = "Karpenter interruption queue name."
  value       = module.karpenter.queue_name
}

output "airflow_tailscale_hostname" {
  description = "Tailscale hostname for the Airflow UI."
  value       = local.airflow_tailscale_hostname
}

output "kubecost_tailscale_hostname" {
  description = "Tailscale hostname for the Kubecost UI."
  value       = local.kubecost_tailscale_hostname
}
