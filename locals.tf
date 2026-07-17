data "aws_availability_zones" "available" {
  state = "available"
}

data "aws_partition" "current" {}

data "aws_caller_identity" "current" {}

locals {
  name = var.name

  azs = slice(data.aws_availability_zones.available.names, 0, min(var.public_subnet_count, length(data.aws_availability_zones.available.names)))

  public_subnets = [
    for index, _ in local.azs : cidrsubnet(var.vpc_cidr, 8, index)
  ]

  tailscale_subnet_router_hostname = "${local.name}-subnet-router"

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
