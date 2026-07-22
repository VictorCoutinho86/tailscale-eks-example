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
  default     = "t2.medium"
}

variable "default_node_ami_type" {
  description = "AMI type for the default EKS managed node group."
  type        = string
  default     = "AL2023_x86_64_STANDARD"
  validation {
    condition     = contains(["AL2023_ARM_64_STANDARD", "AL2023_x86_64_STANDARD"], var.default_node_ami_type)
    error_message = "default_node_ami_type must be one of AL2023_ARM_64_STANDARD, AL2023_x86_64_STANDARD."
  }
}

variable "default_node_capacity_type" {
  description = "Capacity type for the default EKS managed node group."
  type        = string
  default     = "SPOT"
  validation {
    condition     = contains(["ON_DEMAND", "SPOT"], var.default_node_capacity_type)
    error_message = "default_node_capacity_type must be either ON_DEMAND or SPOT."
  }
}

variable "kubecost_athena_database" {
  description = "Existing Glue/Athena database containing the AWS CUR table."
  type        = string
}

variable "kubecost_athena_table" {
  description = "Existing Glue/Athena table containing the AWS CUR data."
  type        = string
}

variable "kubecost_athena_query_results_bucket" {
  description = "Existing S3 bucket used for Athena query results."
  type        = string
}

variable "kubecost_cur_source_bucket" {
  description = "Existing S3 bucket containing the AWS CUR objects."
  type        = string
}

variable "kubecost_athena_workgroup" {
  description = "Athena workgroup used for Kubecost CUR queries."
  type        = string
  default     = "primary"
}

variable "kubecost_kms_key_arns" {
  description = "Optional KMS key ARNs used to encrypt Kubecost CUR and Athena query-result buckets."
  type        = list(string)
  default     = []
}

variable "default_node_count" {
  description = "Fixed size for the default EKS managed node group."
  type        = number
  default     = 3
}

variable "enable_bootstrap_instance" {
  description = "Create the EC2 subnet router instance that advertises the VPC subnet route."
  type        = bool
  default     = true
}

variable "enable_argocd_bootstrap" {
  description = "Install Argo CD and the root Argo CD Application from Terraform after the Tailscale subnet route is approved."
  type        = bool
  default     = true
}

variable "bootstrap_instance_type" {
  description = "Fallback instance type for the subnet router launch template."
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

variable "airflow_logs_bucket" {
  description = "Existing S3 bucket where Airflow stores remote task logs under the airflow/logs prefix."
  type        = string
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
