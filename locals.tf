data "aws_availability_zones" "available" {
  state = "available"
}

data "aws_partition" "current" {}

locals {
  name = var.name

  azs = slice(data.aws_availability_zones.available.names, 0, min(var.public_subnet_count, length(data.aws_availability_zones.available.names)))

  public_subnets = [
    for index, _ in local.azs : cidrsubnet(var.vpc_cidr, 8, index)
  ]

  tailscale_operator_hostname      = coalesce(var.tailscale_operator_hostname, "${local.name}-operator")
  tailscale_subnet_router_hostname = "${local.name}-subnet-router"
  argocd_tailscale_hostname        = coalesce(var.argocd_tailscale_hostname, "${local.name}-argocd")
  airflow_tailscale_hostname       = coalesce(var.airflow_tailscale_hostname, "${local.name}-airflow")
  kubecost_tailscale_hostname      = coalesce(var.kubecost_tailscale_hostname, "${local.name}-kubecost")

  tailscale_operator_values_yaml = yamlencode({
    oauth = {
      clientId     = var.tailscale_oauth_client_id
      clientSecret = var.tailscale_oauth_client_secret
    }
    operatorConfig = {
      hostname = local.tailscale_operator_hostname
    }
  })

  argocd_values_yaml = yamlencode({
    server = {
      service = {
        type = "ClusterIP"
      }
    }
  })

  argocd_tailscale_service_yaml = yamlencode({
    apiVersion = "v1"
    kind       = "Service"
    metadata = {
      name      = "argocd-tailscale"
      namespace = "argocd"
      annotations = {
        "tailscale.com/hostname" = local.argocd_tailscale_hostname
      }
    }
    spec = {
      type              = "LoadBalancer"
      loadBalancerClass = "tailscale"
      selector = {
        "app.kubernetes.io/name" = "argocd-server"
      }
      ports = [{
        name       = "https"
        port       = 443
        targetPort = 8080
        protocol   = "TCP"
      }]
    }
  })

  argocd_root_application_yaml = yamlencode({
    apiVersion = "argoproj.io/v1alpha1"
    kind       = "Application"
    metadata = {
      name      = "platform-root"
      namespace = "argocd"
    }
    spec = {
      project = "default"
      source = {
        repoURL        = var.argocd_repo_url
        targetRevision = var.argocd_target_revision
        path           = var.argocd_path
        helm = {
          parameters = [
            { name = "global.clusterName", value = local.name },
            { name = "global.awsRegion", value = var.aws_region },
            { name = "global.repoURL", value = var.argocd_repo_url },
            { name = "global.targetRevision", value = var.argocd_target_revision },
            { name = "global.argocdTailscaleHostname", value = local.argocd_tailscale_hostname },
            { name = "global.airflowTailscaleHostname", value = local.airflow_tailscale_hostname },
            { name = "global.kubecostTailscaleHostname", value = local.kubecost_tailscale_hostname },
            { name = "global.sparkWorkloadNamespace", value = var.spark_workload_namespace },
            { name = "versions.karpenter", value = var.karpenter_version },
            { name = "versions.airflow", value = var.airflow_chart_version },
            { name = "versions.kubecost", value = var.kubecost_chart_version },
            { name = "versions.sparkOperator", value = var.spark_operator_chart_version },
            { name = "karpenter.interruptionQueueName", value = module.karpenter.queue_name },
            { name = "karpenter.nodeRoleName", value = module.karpenter.node_iam_role_name }
          ]
        }
      }
      destination = {
        server    = "https://kubernetes.default.svc"
        namespace = "argocd"
      }
      syncPolicy = {
        automated = {
          prune    = true
          selfHeal = true
        }
        syncOptions = ["CreateNamespace=true"]
      }
    }
  })

  tags = merge(
    {
      Project     = local.name
      Environment = var.environment
      Terraform   = "true"
    },
    var.tags
  )
}

resource "terraform_data" "availability_zone_count" {
  input = var.public_subnet_count

  lifecycle {
    precondition {
      condition     = length(data.aws_availability_zones.available.names) >= var.public_subnet_count
      error_message = "The selected AWS region must have at least public_subnet_count available Availability Zones."
    }
  }
}
