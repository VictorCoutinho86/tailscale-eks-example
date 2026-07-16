module "aws_ebs_csi_pod_identity" {
  source  = "terraform-aws-modules/eks-pod-identity/aws"
  version = "~> 2.0"

  name = "${local.name}-aws-ebs-csi"

  attach_aws_ebs_csi_policy = true

  associations = {
    ebs_csi = {
      cluster_name    = local.name
      namespace       = "kube-system"
      service_account = "ebs-csi-controller-sa"
    }
  }

  depends_on = [module.eks]

  tags = local.tags
}

module "airflow_task_pod_identity" {
  source  = "terraform-aws-modules/eks-pod-identity/aws"
  version = "~> 2.0"

  name = "${local.name}-airflow-task"

  attach_custom_policy = length(var.airflow_task_policy_statements) > 0
  policy_statements    = var.airflow_task_policy_statements

  associations = {
    airflow_task = {
      cluster_name    = local.name
      namespace       = "airflow"
      service_account = "airflow-task"
    }
  }

  depends_on = [module.eks]

  tags = local.tags
}

module "spark_workload_pod_identity" {
  source  = "terraform-aws-modules/eks-pod-identity/aws"
  version = "~> 2.0"

  name                 = "${local.name}-spark-workload"
  attach_custom_policy = length(var.spark_workload_policy_statements) > 0
  policy_statements    = var.spark_workload_policy_statements

  associations = {
    spark_workload = {
      cluster_name    = local.name
      namespace       = var.spark_workload_namespace
      service_account = "spark-workload"
    }
  }

  depends_on = [module.eks]

  tags = local.tags
}
