resource "helm_release" "argocd" {
  count = var.enable_argocd_bootstrap ? 1 : 0

  name             = "argocd"
  repository       = "https://argoproj.github.io/argo-helm"
  chart            = "argo-cd"
  version          = "8.5.7"
  namespace        = "argocd"
  create_namespace = true

  wait    = true
  timeout = 600

  set = [
    {
      name  = "server.service.type"
      value = "ClusterIP"
    },
    {
      name  = "configs.params.server\\.insecure"
      value = "true"
      type  = "string"
    }
  ]
}

resource "helm_release" "argocd_root_application" {
  count = var.enable_argocd_bootstrap ? 1 : 0

  name      = "argocd-root-application"
  chart     = "${path.module}/charts/argocd-root-application"
  namespace = "argocd"

  wait    = true
  timeout = 300

  values = [yamlencode({
    repoURL                          = "https://github.com/VictorCoutinho86/tailscale-eks-example.git"
    targetRevision                   = "master"
    clusterName                      = module.eks.cluster_name
    awsRegion                        = var.aws_region
    vpcId                            = module.vpc.vpc_id
    domain                           = trimsuffix(var.route53_domain_name, ".")
    certificateArn                   = aws_acm_certificate_validation.platform.certificate_arn
    karpenterQueueName               = module.karpenter.queue_name
    karpenterNodeRoleName            = module.karpenter.node_iam_role_name
    sparkWorkloadNamespace           = var.spark_workload_namespace
    airflowLogsBucket                = var.airflow_logs_bucket
    kubecostAthenaAccountId          = data.aws_caller_identity.current.account_id
    kubecostAthenaDatabase           = var.kubecost_athena_database
    kubecostAthenaTable              = var.kubecost_athena_table
    kubecostAthenaQueryResultsBucket = var.kubecost_athena_query_results_bucket
    kubecostAthenaWorkgroup          = var.kubecost_athena_workgroup
  })]

  depends_on = [helm_release.argocd]
}
