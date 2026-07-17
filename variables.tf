variable "aws_region" {
  description = "AWS region where the infrastructure will be created."
  type        = string
  default     = "us-east-1"
}

variable "aws_profile" {
  description = "Local AWS CLI profile used for both infrastructure apply and platform Kubernetes exec authentication."
  type        = string
  default     = "victor"
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

variable "route53_domain_name" {
  description = "Existing public Route 53 hosted zone domain used for platform DNS and ACM validation."
  type        = string
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
  description = "Create the EC2 subnet router instance that advertises the VPC subnet route."
  type        = bool
  default     = true
}

variable "bootstrap_instance_type" {
  description = "Instance type for the bootstrap EC2 subnet router instance."
  type        = string
  default     = "t3.micro"
}

variable "tailscale_subnet_router_auth_key" {
  description = "Tailscale auth key used by the bootstrap EC2 instance to join the tailnet and advertise the VPC subnet route."
  type        = string
  sensitive   = true
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

variable "tags" {
  description = "Additional tags applied to supported resources."
  type        = map(string)
  default     = {}
}
