resource "aws_instance" "bootstrap" {
  count = var.enable_bootstrap_instance ? 1 : 0

  ami                         = data.aws_ami.bootstrap_al2023.id
  instance_type               = var.bootstrap_instance_type
  subnet_id                   = module.vpc.public_subnets[0]
  vpc_security_group_ids      = [aws_security_group.bootstrap.id]
  iam_instance_profile        = aws_iam_instance_profile.bootstrap.name
  associate_public_ip_address = true

  user_data_replace_on_change = true
  user_data = templatefile("${path.module}/templates/bootstrap.sh.tftpl", {
    vpc_cidr                         = var.vpc_cidr
    vpc_cidr_resolver                = cidrhost(var.vpc_cidr, 2)
    tailscale_subnet_router_auth_key = var.tailscale_subnet_router_auth_key
    tailscale_subnet_router_hostname = local.tailscale_subnet_router_hostname
    cluster_name                     = module.eks.cluster_name
    aws_region                       = var.aws_region
    argocd_chart_version             = "8.5.7"
    gitops_repo_url                  = "https://github.com/VictorCoutinho86/tailscale-eks-example.git"
    gitops_target_revision           = "master"
    route53_domain_name              = trimsuffix(var.route53_domain_name, ".")
    platform_certificate_arn         = aws_acm_certificate_validation.platform.certificate_arn
    karpenter_queue_name             = module.karpenter.queue_name
    karpenter_node_role_name         = module.karpenter.node_iam_role_name
    spark_workload_namespace         = var.spark_workload_namespace
    argocd_root_application = templatefile("${path.module}/templates/argocd-root-application.yaml.tftpl", {
      repo_url                 = "https://github.com/VictorCoutinho86/tailscale-eks-example.git"
      target_revision          = "master"
      cluster_name             = module.eks.cluster_name
      aws_region               = var.aws_region
      vpc_id                   = module.vpc.vpc_id
      domain                   = trimsuffix(var.route53_domain_name, ".")
      certificate_arn          = aws_acm_certificate_validation.platform.certificate_arn
      karpenter_queue_name     = module.karpenter.queue_name
      karpenter_node_role_name = module.karpenter.node_iam_role_name
      spark_workload_namespace = var.spark_workload_namespace
    })
  })

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
  }

  root_block_device {
    volume_type           = "gp3"
    volume_size           = 20
    encrypted             = true
    delete_on_termination = true
  }

  depends_on = [module.vpc]

  tags = merge(local.tags, { Name = "${local.name}-bootstrap" })
}
