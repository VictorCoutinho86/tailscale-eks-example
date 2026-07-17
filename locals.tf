data "aws_availability_zones" "available" {
  state = "available"
}

data "aws_partition" "current" {}

data "aws_caller_identity" "current" {}

locals {
  name = var.name

  azs = slice(data.aws_availability_zones.available.names, 0, 3)

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
  input = length(data.aws_availability_zones.available.names)

  lifecycle {
    precondition {
      condition     = length(data.aws_availability_zones.available.names) >= 3
      error_message = "The selected AWS region must have at least 3 available Availability Zones."
    }
  }
}
