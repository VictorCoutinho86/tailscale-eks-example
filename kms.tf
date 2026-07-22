resource "aws_kms_key" "eks_secrets" {
  description             = "KMS key for EKS envelope encryption of Kubernetes secrets"
  deletion_window_in_days = 30
  enable_key_rotation     = true

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "EnableIAMUserPermissions"
        Effect = "Allow"
        Principal = {
          AWS = data.aws_caller_identity.current.arn
        }
        Action   = "kms:*"
        Resource = "*"
      },
      {
        Sid    = "AllowEKSUseKey"
        Effect = "Allow"
        Principal = {
          Service = "eks.${data.aws_partition.current.dns_suffix}"
        }
        Action = [
          "kms:Encrypt",
          "kms:Decrypt",
          "kms:ReEncrypt*",
          "kms:GenerateDataKey*",
          "kms:DescribeKey",
        ]
        Resource = "*"
      }
    ]
  })

  tags = merge(local.tags, { Name = "${local.name}-eks-secrets" })
}

resource "aws_kms_alias" "eks_secrets" {
  name          = "alias/${local.name}-eks-secrets"
  target_key_id = aws_kms_key.eks_secrets.key_id
}
