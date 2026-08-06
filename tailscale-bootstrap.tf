locals {
  private_route_table_ids_by_router_az = {
    (local.subnet_router_azs[0]) = [
      module.vpc.private_route_table_ids[0],
      module.vpc.private_route_table_ids[2],
    ]
    (local.subnet_router_azs[1]) = [
      module.vpc.private_route_table_ids[1],
    ]
  }
}

resource "aws_launch_template" "subnet_router" {
  name_prefix = "${local.name}-subnet-router-"

  image_id      = data.aws_ami.bootstrap_ubuntu.id
  instance_type = var.bootstrap_instance_type

  vpc_security_group_ids = [aws_security_group.bootstrap.id]

  iam_instance_profile {
    name = aws_iam_instance_profile.bootstrap.name
  }

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
  }

  block_device_mappings {
    device_name = data.aws_ami.bootstrap_ubuntu.root_device_name
    ebs {
      volume_type           = "gp3"
      volume_size           = 20
      encrypted             = true
      delete_on_termination = true
    }
  }

  user_data = base64encode(templatefile("${path.module}/templates/bootstrap.sh.tftpl", {
    vpc_cidr                         = var.vpc_cidr
    vpc_cidr_resolver                = cidrhost(var.vpc_cidr, 2)
    tailscale_subnet_router_auth_key = var.tailscale_subnet_router_auth_key
    tailscale_subnet_router_hostname = local.tailscale_subnet_router_hostname
    aws_region                       = var.aws_region
    vpc_ipv6_cidr                    = module.vpc.vpc_ipv6_cidr_block
    nat64_prefix                     = local.nat64_prefix
    private_route_table_by_az = jsonencode({
      for az, rtb in zipmap(local.azs, module.vpc.private_route_table_ids) : az => rtb
    })
    private_route_table_ids_by_router_az = jsonencode({
      for az, route_table_ids in local.private_route_table_ids_by_router_az : az => route_table_ids
    })
  }))

  tag_specifications {
    resource_type = "instance"
    tags          = merge(local.tags, { Name = "${local.name}-subnet-router" })
  }

  lifecycle {
    create_before_destroy = true
  }

  depends_on = [module.vpc]
}

resource "aws_autoscaling_group" "subnet_router" {
  count = var.enable_bootstrap_instance ? 2 : 0

  name                = "${local.name}-subnet-router-${local.subnet_router_azs[count.index]}"
  vpc_zone_identifier = [module.vpc.public_subnets[count.index]]
  min_size            = 1
  max_size            = 1
  desired_capacity    = 1
  capacity_rebalance  = true

  mixed_instances_policy {
    instances_distribution {
      on_demand_base_capacity                  = 0
      on_demand_percentage_above_base_capacity = 0
      spot_allocation_strategy                 = "price-capacity-optimized"
    }

    launch_template {
      launch_template_specification {
        launch_template_id = aws_launch_template.subnet_router.id
        version            = "$Latest"
      }

      override {
        instance_type = "t3.micro"
      }
      override {
        instance_type = "t3.small"
      }
      override {
        instance_type = "t3a.micro"
      }
      override {
        instance_type = "t3a.small"
      }
      override {
        instance_type = "t2.micro"
      }
      override {
        instance_type = "t2.small"
      }
    }
  }

  tag {
    key                 = "Name"
    value               = "${local.name}-subnet-router-${local.subnet_router_azs[count.index]}"
    propagate_at_launch = true
  }
}
