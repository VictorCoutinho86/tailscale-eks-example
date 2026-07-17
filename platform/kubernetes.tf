resource "kubernetes_namespace_v1" "argocd" {
  metadata { name = "argocd" }
}

resource "kubernetes_namespace_v1" "airflow" {
  metadata { name = "airflow" }
}

resource "kubernetes_namespace_v1" "kubecost" {
  metadata { name = "kubecost" }
}

resource "kubernetes_namespace_v1" "spark_operator" {
  metadata { name = "spark-operator" }
}

resource "kubernetes_namespace_v1" "spark_workloads" {
  metadata { name = var.spark_workload_namespace }
}

resource "kubernetes_namespace_v1" "karpenter" {
  metadata { name = "karpenter" }
}

resource "kubernetes_storage_class_v1" "gp3" {
  metadata {
    name = "gp3"
    annotations = {
      "storageclass.kubernetes.io/is-default-class" = "true"
    }
  }

  storage_provisioner    = "ebs.csi.aws.com"
  volume_binding_mode    = "WaitForFirstConsumer"
  allow_volume_expansion = true

  parameters = {
    type      = "gp3"
    encrypted = "true"
  }
}

resource "kubernetes_service_account_v1" "airflow_task" {
  metadata {
    name      = "airflow-task"
    namespace = kubernetes_namespace_v1.airflow.metadata[0].name
  }
}

resource "kubernetes_service_account_v1" "spark_workload" {
  metadata {
    name      = "spark-workload"
    namespace = kubernetes_namespace_v1.spark_workloads.metadata[0].name
  }
}

resource "kubernetes_role_v1" "airflow_spark_access" {
  metadata {
    name      = "airflow-spark-access"
    namespace = kubernetes_namespace_v1.spark_workloads.metadata[0].name
  }

  rule {
    api_groups = ["sparkoperator.k8s.io"]
    resources  = ["sparkapplications", "sparkapplications/status"]
    verbs      = ["create", "get", "list", "watch", "patch", "delete"]
  }

  rule {
    api_groups = [""]
    resources  = ["pods"]
    verbs      = ["get", "list", "watch"]
  }

  rule {
    api_groups = [""]
    resources  = ["pods/log"]
    verbs      = ["get"]
  }

  rule {
    api_groups = [""]
    resources  = ["events"]
    verbs      = ["get", "list", "watch"]
  }
}

resource "kubernetes_role_binding_v1" "airflow_spark_access" {
  metadata {
    name      = "airflow-spark-access"
    namespace = kubernetes_namespace_v1.spark_workloads.metadata[0].name
  }

  subject {
    kind      = "ServiceAccount"
    name      = kubernetes_service_account_v1.airflow_task.metadata[0].name
    namespace = kubernetes_namespace_v1.airflow.metadata[0].name
  }

  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "Role"
    name      = kubernetes_role_v1.airflow_spark_access.metadata[0].name
  }
}

resource "kubernetes_role_v1" "spark_driver" {
  metadata {
    name      = "spark-driver"
    namespace = kubernetes_namespace_v1.spark_workloads.metadata[0].name
  }

  rule {
    api_groups = [""]
    resources  = ["pods", "services", "configmaps", "persistentvolumeclaims"]
    verbs      = ["create", "get", "list", "watch", "delete"]
  }

  rule {
    api_groups = [""]
    resources  = ["pods/log"]
    verbs      = ["get"]
  }
}

resource "kubernetes_role_binding_v1" "spark_driver" {
  metadata {
    name      = "spark-driver"
    namespace = kubernetes_namespace_v1.spark_workloads.metadata[0].name
  }

  subject {
    kind      = "ServiceAccount"
    name      = kubernetes_service_account_v1.spark_workload.metadata[0].name
    namespace = kubernetes_namespace_v1.spark_workloads.metadata[0].name
  }

  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "Role"
    name      = kubernetes_role_v1.spark_driver.metadata[0].name
  }
}

resource "kubernetes_ingress_v1" "platform" {
  for_each = local.platform_ingresses

  metadata {
    name      = each.key
    namespace = each.value.namespace
    annotations = {
      "alb.ingress.kubernetes.io/scheme"          = "internal"
      "alb.ingress.kubernetes.io/target-type"     = "ip"
      "alb.ingress.kubernetes.io/group.name"      = "platform"
      "alb.ingress.kubernetes.io/listen-ports"    = "[{\"HTTP\":80},{\"HTTPS\":443}]"
      "alb.ingress.kubernetes.io/ssl-redirect"    = "443"
      "alb.ingress.kubernetes.io/certificate-arn" = data.terraform_remote_state.infra.outputs.platform_certificate_arn
      "external-dns.alpha.kubernetes.io/hostname" = each.value.hostname
    }
  }

  spec {
    ingress_class_name = "alb"

    rule {
      host = each.value.hostname

      http {
        path {
          path      = "/"
          path_type = "Prefix"

          backend {
            service {
              name = each.value.service_name
              port {
                number = each.value.service_port
              }
            }
          }
        }
      }
    }
  }

  depends_on = [
    helm_release.aws_load_balancer_controller,
    helm_release.external_dns,
    helm_release.argocd,
    helm_release.airflow,
    helm_release.kubecost,
  ]
}
