resource "random_id" "airflow_fernet" {
  byte_length = 32
}

resource "random_password" "airflow_jwt" {
  length  = 128
  special = false
}

resource "random_password" "airflow_api" {
  length  = 64
  special = false
}

resource "random_password" "airflow_admin" {
  length  = 64
  special = false
}

resource "kubernetes_namespace_v1" "airflow" {
  count = var.enable_argocd_bootstrap ? 1 : 0


  metadata {
    name = "airflow"
  }

  lifecycle {
    ignore_changes = [metadata[0].annotations]
  }
}

resource "kubernetes_secret_v1" "airflow_fernet" {
  count = var.enable_argocd_bootstrap ? 1 : 0


  metadata {
    name      = "airflow-fernet-key"
    namespace = kubernetes_namespace_v1.airflow[0].metadata[0].name
  }

  data = {
    fernet-key = random_id.airflow_fernet.b64_url
  }
}

resource "kubernetes_secret_v1" "airflow_jwt" {
  count = var.enable_argocd_bootstrap ? 1 : 0


  metadata {
    name      = "airflow-jwt-secret"
    namespace = kubernetes_namespace_v1.airflow[0].metadata[0].name
  }

  data = {
    jwt-secret = random_password.airflow_jwt.result
  }
}

resource "kubernetes_secret_v1" "airflow_api" {
  count = var.enable_argocd_bootstrap ? 1 : 0


  metadata {
    name      = "airflow-api-secret-key"
    namespace = kubernetes_namespace_v1.airflow[0].metadata[0].name
  }

  data = {
    api-secret-key = random_password.airflow_api.result
  }
}

resource "kubernetes_secret_v1" "airflow_admin" {
  count = var.enable_argocd_bootstrap ? 1 : 0


  metadata {
    name      = "airflow-admin-credentials"
    namespace = kubernetes_namespace_v1.airflow[0].metadata[0].name
  }

  data = {
    admin-password = random_password.airflow_admin.result
  }
}

resource "kubernetes_secret_v1" "airflow_db" {
  count = var.enable_argocd_bootstrap ? 1 : 0


  metadata {
    name      = "airflow-db-credentials"
    namespace = kubernetes_namespace_v1.airflow[0].metadata[0].name
  }

  data = {
    connection = "postgresql://airflow:${urlencode(var.airflow_db_password)}@${aws_db_instance.airflow.address}:5432/airflow?sslmode=require"
    username   = "airflow"
    password   = var.airflow_db_password
  }
}

data "kubernetes_secret_v1" "argocd_initial_admin" {
  count = var.enable_argocd_bootstrap ? 1 : 0

  metadata {
    name      = "argocd-initial-admin-secret"
    namespace = "argocd"
  }

}
