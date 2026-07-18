resource "aws_instance" "bootstrap" {
  count = var.enable_bootstrap_instance ? 1 : 0

  ami                         = data.aws_ami.bootstrap_al2023.id
  instance_type               = var.bootstrap_instance_type
  subnet_id                   = module.vpc.public_subnets[0]
  vpc_security_group_ids      = [aws_security_group.bootstrap.id]
  iam_instance_profile        = aws_iam_instance_profile.bootstrap.name
  associate_public_ip_address = true

  user_data = templatefile("${path.module}/templates/bootstrap.sh.tftpl", {
    vpc_cidr                         = var.vpc_cidr
    vpc_cidr_resolver                = cidrhost(var.vpc_cidr, 2)
    tailscale_subnet_router_auth_key = var.tailscale_subnet_router_auth_key
    tailscale_subnet_router_hostname = local.tailscale_subnet_router_hostname
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

  lifecycle {
    ignore_changes = [user_data]
  }

  tags = merge(local.tags, { Name = "${local.name}-bootstrap" })
}
