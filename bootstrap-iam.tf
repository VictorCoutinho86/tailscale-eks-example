data "aws_ami" "bootstrap_ubuntu" {
  most_recent = true
  owners      = ["099720109477"]

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-amd64-server-*"]
  }

  filter {
    name   = "architecture"
    values = ["x86_64"]
  }
}

resource "aws_security_group" "bootstrap" {
  name        = "${local.name}-bootstrap"
  description = "Bootstrap instance egress-only security group"
  vpc_id      = module.vpc.vpc_id

  ingress {
    description = "Allow all traffic from private subnets for NAT forwarding and SSH debug"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = local.private_subnets
  }

  ingress {
    description      = "Allow all IPv6 traffic from private subnets for subnet routing and NAT64"
    from_port        = 0
    to_port          = 0
    protocol         = "-1"
    ipv6_cidr_blocks = module.vpc.private_subnets_ipv6_cidr_blocks
  }

  egress {
    description = "Allow all outbound traffic for NAT forwarding"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    description      = "Allow all IPv6 outbound traffic for subnet routing"
    from_port        = 0
    to_port          = 0
    protocol         = "-1"
    ipv6_cidr_blocks = ["::/0"]
  }

  tags = merge(local.tags, { Name = "${local.name}-bootstrap" })
}

resource "aws_iam_role" "bootstrap" {
  name = "${local.name}-bootstrap"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Service = "ec2.${data.aws_partition.current.dns_suffix}"
      }
      Action = "sts:AssumeRole"
    }]
  })

  tags = local.tags
}

resource "aws_iam_instance_profile" "bootstrap" {
  name = "${local.name}-bootstrap"
  role = aws_iam_role.bootstrap.name

  tags = local.tags
}

resource "aws_iam_role_policy_attachment" "bootstrap_ssm" {
  role       = aws_iam_role.bootstrap.name
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_role_policy" "bootstrap_eks_discovery" {
  name = "${local.name}-bootstrap-eks-discovery"
  role = aws_iam_role.bootstrap.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "eks:DescribeCluster"
        ]
        Resource = module.eks.cluster_arn
      }
    ]
  })
}

resource "aws_iam_role_policy" "bootstrap_nat_routing" {
  name = "${local.name}-bootstrap-nat-routing"
  role = aws_iam_role.bootstrap.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "ec2:ModifyInstanceAttribute",
        ]
        Resource = "*"
        Condition = {
          StringEquals = {
            "aws:ResourceTag/Project" = local.name
          }
        }
      },
      {
        Effect = "Allow"
        Action = [
          "ec2:ReplaceRoute",
          "ec2:CreateRoute",
        ]
        Resource = [
          for rtb_id in module.vpc.private_route_table_ids :
          "arn:${data.aws_partition.current.partition}:ec2:${var.aws_region}:${data.aws_caller_identity.current.account_id}:route-table/${rtb_id}"
        ]
      }
    ]
  })
}
