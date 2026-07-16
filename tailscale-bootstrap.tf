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
    aws_region                     = var.aws_region
    cluster_name                   = module.eks.cluster_name
    cluster_version                = var.cluster_version
    tailscale_operator_values_yaml = local.tailscale_operator_values_yaml
    argocd_chart_version           = var.argocd_chart_version
    argocd_values_yaml             = local.argocd_values_yaml
    argocd_tailscale_service_yaml  = local.argocd_tailscale_service_yaml
    argocd_root_application_yaml   = local.argocd_root_application_yaml
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

  depends_on = [
    module.eks,
    module.karpenter
  ]

  tags = merge(local.tags, { Name = "${local.name}-bootstrap" })
}
