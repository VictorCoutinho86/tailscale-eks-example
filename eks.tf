module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 21.0"

  name               = local.name
  kubernetes_version = var.cluster_version

  endpoint_public_access  = false
  endpoint_private_access = true

  create_kms_key = false
  encryption_config = {
    resources        = ["secrets"]
    provider_key_arn = aws_kms_key.eks_secrets.arn
  }

  enable_cluster_creator_admin_permissions = false

  vpc_id                   = module.vpc.vpc_id
  subnet_ids               = module.vpc.private_subnets
  control_plane_subnet_ids = module.vpc.public_subnets

  addons = {
    vpc-cni = {
      most_recent    = true
      before_compute = true
      configuration_values = jsonencode({
        env = {
          ENABLE_PREFIX_DELEGATION = "true"
          WARM_PREFIX_TARGET       = "1"
        }
      })
    }

    eks-pod-identity-agent = {
      most_recent    = true
      before_compute = true
    }

    coredns = {
      most_recent = true
    }

    kube-proxy = {
      most_recent = true
    }

    aws-ebs-csi-driver = {
      most_recent = true
      pod_identity_association = [{
        role_arn        = module.aws_ebs_csi_pod_identity.iam_role_arn
        service_account = "ebs-csi-controller-sa"
      }]
    }
  }

  security_group_additional_rules = var.enable_bootstrap_instance ? {
    bootstrap_https = {
      description              = "Allow subnet router instance to reach the private EKS API endpoint"
      protocol                 = "tcp"
      from_port                = 443
      to_port                  = 443
      type                     = "ingress"
      source_security_group_id = aws_security_group.bootstrap.id
    }
  } : {}

  eks_managed_node_groups = {
    default = {
      ami_type       = var.default_node_ami_type
      instance_types = [var.default_node_instance_type]
      capacity_type  = var.default_node_capacity_type

      min_size     = var.default_node_count
      max_size     = var.default_node_count
      desired_size = var.default_node_count

      subnet_ids = module.vpc.private_subnets
    }
  }

  access_entries = {
    current_caller = {
      principal_arn = data.aws_caller_identity.current.arn
      policy_associations = {
        admin = {
          policy_arn = "arn:${data.aws_partition.current.partition}:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"
          access_scope = {
            type = "cluster"
          }
        }
      }
    }
    bootstrap_instance = {
      principal_arn = aws_iam_role.bootstrap.arn
      policy_associations = {
        admin = {
          policy_arn = "arn:${data.aws_partition.current.partition}:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"
          access_scope = {
            type = "cluster"
          }
        }
      }
    }
  }

  node_security_group_tags = merge(local.tags, {
    "karpenter.sh/discovery" = local.name
  })

  tags = local.tags
}
