variable "aws_region" {
  description = "AWS region where the infrastructure will be created."
  type        = string
  default     = "us-east-1"
}

variable "name" {
  description = "Base name used for the EKS cluster and related resources."
  type        = string
  default     = "tailscale-eks-example"
}

variable "environment" {
  description = "Environment tag value."
  type        = string
  default     = "dev"
}

variable "vpc_cidr" {
  description = "CIDR block for the VPC."
  type        = string
  default     = "10.0.0.0/16"
}

variable "public_subnet_count" {
  description = "Number of public subnets and Availability Zones to use."
  type        = number
  default     = 4

  validation {
    condition     = var.public_subnet_count >= 2 && var.public_subnet_count <= 6
    error_message = "public_subnet_count must be between 2 and 6."
  }
}

variable "cluster_version" {
  description = "Kubernetes version for the EKS cluster."
  type        = string
  default     = "1.36"

  validation {
    condition     = can(regex("^\\d+\\.\\d+$", var.cluster_version))
    error_message = "cluster_version must use minor version format like 1.36."
  }
}

variable "default_node_instance_type" {
  description = "Instance type for the default EKS managed node group."
  type        = string
  default     = "t4g.small"
}

variable "default_node_count" {
  description = "Fixed size for the default EKS managed node group."
  type        = number
  default     = 4
}

variable "enable_bootstrap_instance" {
  description = "Create the EC2 bootstrap/subnet router instance that installs in-cluster components and advertises the VPC subnet route."
  type        = bool
  default     = true
}

variable "bootstrap_instance_type" {
  description = "Instance type for the bootstrap EC2 subnet router instance."
  type        = string
  default     = "t3.micro"
}

variable "tailscale_oauth_client_id" {
  description = "Tailscale OAuth client ID used by the Kubernetes Operator."
  type        = string
  sensitive   = true
}

variable "tailscale_oauth_client_secret" {
  description = "Tailscale OAuth client secret used by the Kubernetes Operator."
  type        = string
  sensitive   = true
}

variable "tailscale_subnet_router_auth_key" {
  description = "Tailscale auth key used by the bootstrap EC2 instance to join the tailnet and advertise the VPC subnet route."
  type        = string
  sensitive   = true
}

variable "tailscale_operator_hostname" {
  description = "Hostname assigned to the Tailscale Kubernetes Operator device."
  type        = string
  default     = null
}

variable "argocd_repo_url" {
  description = "Git repository URL containing the Argo CD app-of-apps under argocd_path."
  type        = string
}

variable "argocd_target_revision" {
  description = "Git revision Argo CD should sync for the app-of-apps."
  type        = string
  default     = "master"
}

variable "argocd_path" {
  description = "Repository path to the Argo CD root app-of-apps Helm chart."
  type        = string
  default     = "gitops/root"
}

variable "argocd_chart_version" {
  description = "Argo CD Helm chart version."
  type        = string
  default     = "8.5.7"
}

variable "argocd_tailscale_hostname" {
  description = "Tailscale hostname for the Argo CD UI."
  type        = string
  default     = null
}

variable "karpenter_version" {
  description = "Karpenter Helm chart version. Default is the latest stable version validated during planning."
  type        = string
  default     = "1.13.0"
}

variable "airflow_chart_version" {
  description = "Apache Airflow Helm chart version."
  type        = string
  default     = "1.22.0"
}

variable "kubecost_chart_version" {
  description = "Kubecost cost-analyzer Helm chart version."
  type        = string
  default     = "2.8.7"
}

variable "spark_operator_chart_version" {
  description = "Kubeflow Spark Operator Helm chart version."
  type        = string
  default     = "2.5.1"
}

variable "spark_workload_namespace" {
  description = "Namespace where SparkApplication workloads and Spark driver/executor service accounts run."
  type        = string
  default     = "spark-jobs"
}

variable "airflow_task_policy_statements" {
  description = "Custom IAM policy statements for Airflow task pods. Keep empty until concrete AWS resource ARNs are known."
  type        = list(any)
  default     = []
}

variable "spark_workload_policy_statements" {
  description = "Custom IAM policy statements for Spark driver/executor pods. Keep empty until concrete AWS resource ARNs are known."
  type        = list(any)
  default     = []
}

variable "airflow_tailscale_hostname" {
  description = "Tailscale hostname for the Airflow web UI."
  type        = string
  default     = null
}

variable "kubecost_tailscale_hostname" {
  description = "Tailscale hostname for the Kubecost UI."
  type        = string
  default     = null
}

variable "tags" {
  description = "Additional tags applied to supported resources."
  type        = map(string)
  default     = {}
}
