module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 6.0"

  name = local.name
  cidr = var.vpc_cidr
  azs  = local.azs

  public_subnets  = local.public_subnets
  private_subnets = local.private_subnets

  enable_ipv6 = true

  public_subnet_ipv6_prefixes  = local.public_subnet_ipv6_prefixes
  private_subnet_ipv6_prefixes = local.private_subnet_ipv6_prefixes

  public_subnet_assign_ipv6_address_on_creation  = true
  private_subnet_assign_ipv6_address_on_creation = true
  private_subnet_enable_dns64                    = true

  create_egress_only_igw = true

  enable_dns_hostnames = true
  enable_dns_support   = true

  enable_nat_gateway = false

  map_public_ip_on_launch = true

  public_subnet_tags = {
    "kubernetes.io/role/elb" = "1"
  }

  private_subnet_tags = {
    "kubernetes.io/role/internal-elb" = "1"
    "karpenter.sh/discovery"          = local.name
  }

  tags = local.tags
}

module "vpc_endpoints" {
  source  = "terraform-aws-modules/vpc/aws//modules/vpc-endpoints"
  version = "~> 6.0"

  vpc_id = module.vpc.vpc_id
  endpoints = {
    s3 = {
      service         = "s3"
      service_type    = "Gateway"
      route_table_ids = module.vpc.private_route_table_ids
      tags            = { Name = "${local.name}-s3-endpoint" }
    }
  }

  tags = local.tags
}

resource "terraform_data" "private_subnet_nat_precondition" {
  input = var.enable_bootstrap_instance

  lifecycle {
    precondition {
      condition     = var.enable_bootstrap_instance
      error_message = "enable_bootstrap_instance must be true while private subnet egress uses the subnet-router NAT instance."
    }
  }
}
