locals {
  domain = trimsuffix(data.terraform_remote_state.infra.outputs.route53_domain_name, ".")

  platform_ingresses = {
    argocd = {
      namespace    = "argocd"
      hostname     = "argocd.${local.domain}"
      service_name = "argocd-server"
      service_port = 80
    }
    airflow = {
      namespace    = "airflow"
      hostname     = "airflow.${local.domain}"
      service_name = "airflow-api-server"
      service_port = 8080
    }
    kubecost = {
      namespace    = "kubecost"
      hostname     = "kubecost.${local.domain}"
      service_name = "kubecost-cost-analyzer"
      service_port = 9090
    }
  }
}
