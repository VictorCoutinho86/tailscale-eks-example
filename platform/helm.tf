resource "helm_release" "aws_load_balancer_controller" {
  name             = "aws-load-balancer-controller"
  repository       = "https://aws.github.io/eks-charts"
  chart            = "aws-load-balancer-controller"
  version          = var.aws_load_balancer_controller_chart_version
  namespace        = "kube-system"
  create_namespace = false

  set = [
    {
      name  = "clusterName"
      value = data.terraform_remote_state.infra.outputs.cluster_name
    },
    {
      name  = "region"
      value = data.terraform_remote_state.infra.outputs.aws_region
    },
    {
      name  = "vpcId"
      value = data.terraform_remote_state.infra.outputs.vpc_id
    },
    {
      name  = "serviceAccount.create"
      value = "true"
    },
    {
      name  = "serviceAccount.name"
      value = "aws-load-balancer-controller"
    }
  ]
}

resource "helm_release" "external_dns" {
  name             = "external-dns"
  repository       = "https://kubernetes-sigs.github.io/external-dns"
  chart            = "external-dns"
  version          = var.external_dns_chart_version
  namespace        = "kube-system"
  create_namespace = false

  set = [
    {
      name  = "provider.name"
      value = "aws"
    },
    {
      name  = "serviceAccount.create"
      value = "true"
    },
    {
      name  = "serviceAccount.name"
      value = "external-dns"
    },
    {
      name  = "policy"
      value = "upsert-only"
    },
    {
      name  = "registry"
      value = "txt"
    },
    {
      name  = "txtOwnerId"
      value = data.terraform_remote_state.infra.outputs.cluster_name
    },
    {
      name  = "domainFilters[0]"
      value = data.terraform_remote_state.infra.outputs.route53_domain_name
    },
    {
      name  = "extraArgs.aws-zone-type"
      value = "public"
    }
  ]

  depends_on = [helm_release.aws_load_balancer_controller]
}

resource "helm_release" "argocd" {
  name             = "argocd"
  repository       = "https://argoproj.github.io/argo-helm"
  chart            = "argo-cd"
  version          = var.argocd_chart_version
  namespace        = kubernetes_namespace_v1.argocd.metadata[0].name
  create_namespace = false

  values = [yamlencode({
    server = {
      service = {
        type = "ClusterIP"
      }
    }
    configs = {
      params = {
        "server.insecure" = true
      }
    }
  })]

  depends_on = [
    helm_release.aws_load_balancer_controller,
    kubernetes_namespace_v1.argocd,
  ]
}

resource "helm_release" "airflow" {
  name             = "airflow"
  repository       = "https://airflow.apache.org"
  chart            = "airflow"
  version          = var.airflow_chart_version
  namespace        = kubernetes_namespace_v1.airflow.metadata[0].name
  create_namespace = false
  values           = [file("${path.module}/airflow-values.yaml")]

  depends_on = [
    helm_release.aws_load_balancer_controller,
    kubernetes_namespace_v1.airflow,
    kubernetes_service_account_v1.airflow_task,
  ]
}

resource "helm_release" "kubecost" {
  name             = "kubecost"
  repository       = "https://kubecost.github.io/cost-analyzer"
  chart            = "cost-analyzer"
  version          = var.kubecost_chart_version
  namespace        = kubernetes_namespace_v1.kubecost.metadata[0].name
  create_namespace = false

  values = [yamlencode({
    global = {
      clusterId = data.terraform_remote_state.infra.outputs.cluster_name
    }
    prometheus = {
      server = {
        global = {
          external_labels = {
            cluster_id = data.terraform_remote_state.infra.outputs.cluster_name
          }
        }
      }
    }
  })]

  depends_on = [
    helm_release.aws_load_balancer_controller,
    kubernetes_namespace_v1.kubecost,
  ]
}

resource "helm_release" "spark_operator" {
  name             = "spark-operator"
  repository       = "https://kubeflow.github.io/spark-operator"
  chart            = "spark-operator"
  version          = var.spark_operator_chart_version
  namespace        = kubernetes_namespace_v1.spark_operator.metadata[0].name
  create_namespace = false

  set = [
    {
      name  = "webhook.enable"
      value = "true"
    }
  ]

  depends_on = [
    helm_release.aws_load_balancer_controller,
    kubernetes_namespace_v1.spark_operator,
  ]
}

resource "helm_release" "karpenter" {
  name             = "karpenter"
  repository       = "oci://public.ecr.aws/karpenter"
  chart            = "karpenter"
  version          = var.karpenter_chart_version
  namespace        = kubernetes_namespace_v1.karpenter.metadata[0].name
  create_namespace = false

  set = [
    {
      name  = "settings.clusterName"
      value = data.terraform_remote_state.infra.outputs.cluster_name
    },
    {
      name  = "settings.interruptionQueue"
      value = data.terraform_remote_state.infra.outputs.karpenter_queue_name
    }
  ]

  depends_on = [
    helm_release.aws_load_balancer_controller,
    kubernetes_namespace_v1.karpenter,
  ]
}

resource "helm_release" "karpenter_resources" {
  name      = "karpenter-resources"
  chart     = "${path.module}/charts/karpenter-resources"
  namespace = kubernetes_namespace_v1.karpenter.metadata[0].name

  values = [yamlencode({
    clusterName     = data.terraform_remote_state.infra.outputs.cluster_name
    nodeRoleName    = data.terraform_remote_state.infra.outputs.karpenter_node_role_name
    sparkNodeLabels = { workload = "spark" }
  })]

  depends_on = [helm_release.karpenter]
}
