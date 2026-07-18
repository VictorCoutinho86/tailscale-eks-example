module "aws_ebs_csi_pod_identity" {
  source  = "terraform-aws-modules/eks-pod-identity/aws"
  version = "~> 2.0"

  name = "${local.name}-aws-ebs-csi"

  attach_aws_ebs_csi_policy = true

  tags = local.tags
}

module "aws_load_balancer_controller_pod_identity" {
  source  = "terraform-aws-modules/eks-pod-identity/aws"
  version = "~> 2.0"

  name = "${local.name}-aws-lbc"

  attach_aws_lb_controller_policy = true

  associations = {
    aws_load_balancer_controller = {
      cluster_name    = local.name
      namespace       = "kube-system"
      service_account = "aws-load-balancer-controller"
    }
  }

  depends_on = [module.eks]
  tags       = local.tags
}

module "external_dns_pod_identity" {
  source  = "terraform-aws-modules/eks-pod-identity/aws"
  version = "~> 2.0"

  name = "${local.name}-external-dns"

  attach_external_dns_policy    = true
  external_dns_hosted_zone_arns = [local.route53_hosted_zone_arn]

  associations = {
    external_dns = {
      cluster_name    = local.name
      namespace       = "kube-system"
      service_account = "external-dns"
    }
  }

  depends_on = [module.eks]
  tags       = local.tags
}

module "airflow_task_pod_identity" {
  source  = "terraform-aws-modules/eks-pod-identity/aws"
  version = "~> 2.0"

  name = "${local.name}-airflow-task"

  attach_custom_policy = true
  policy_statements = concat(
    var.airflow_task_policy_statements,
    local.airflow_s3_log_policy_statements,
  )

  associations = {
    airflow_task = {
      cluster_name    = local.name
      namespace       = "airflow"
      service_account = "airflow-task"
    }
    airflow_api_server = {
      cluster_name    = local.name
      namespace       = "airflow"
      service_account = "airflow-api-server"
    }
    airflow_scheduler = {
      cluster_name    = local.name
      namespace       = "airflow"
      service_account = "airflow-scheduler"
    }
    airflow_dag_processor = {
      cluster_name    = local.name
      namespace       = "airflow"
      service_account = "airflow-dag-processor"
    }
    airflow_triggerer = {
      cluster_name    = local.name
      namespace       = "airflow"
      service_account = "airflow-triggerer"
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
