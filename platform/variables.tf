variable "aws_profile" {
  description = "Local AWS CLI profile used by the Helm and Kubernetes exec authentication plugins."
  type        = string
  default     = "victor"
}

variable "aws_load_balancer_controller_chart_version" {
  description = "Pinned AWS Load Balancer Controller Helm chart version."
  type        = string
  default     = "1.13.0"
}

variable "external_dns_chart_version" {
  description = "Pinned ExternalDNS Helm chart version."
  type        = string
  default     = "1.19.0"
}

variable "argocd_chart_version" {
  description = "Pinned Argo CD Helm chart version."
  type        = string
  default     = "8.5.7"
}

variable "airflow_chart_version" {
  description = "Pinned Apache Airflow Helm chart version."
  type        = string
  default     = "1.22.0"
}

variable "kubecost_chart_version" {
  description = "Pinned Kubecost Helm chart version."
  type        = string
  default     = "2.8.7"
}

variable "spark_operator_chart_version" {
  description = "Pinned Spark Operator Helm chart version."
  type        = string
  default     = "2.5.1"
}

variable "karpenter_chart_version" {
  description = "Pinned Karpenter Helm chart version."
  type        = string
  default     = "1.13.0"
}

variable "spark_workload_namespace" {
  description = "Namespace where SparkApplication workloads and Spark driver/executor service accounts run."
  type        = string
  default     = "spark-jobs"
}
