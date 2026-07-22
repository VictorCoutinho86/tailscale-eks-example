resource "aws_s3_bucket" "cnpg_backups" {
  bucket = "${local.name}-cnpg-${data.aws_caller_identity.current.account_id}"

  tags = local.tags
}

resource "aws_s3_bucket_versioning" "cnpg_backups" {
  bucket = aws_s3_bucket.cnpg_backups.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "cnpg_backups" {
  bucket = aws_s3_bucket.cnpg_backups.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "cnpg_backups" {
  bucket = aws_s3_bucket.cnpg_backups.id

  rule {
    id     = "expire-old-backups"
    status = "Enabled"

    expiration {
      days = 30
    }
  }
}

resource "aws_s3_bucket_public_access_block" "cnpg_backups" {
  bucket = aws_s3_bucket.cnpg_backups.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

module "cnpg_pod_identity" {
  source  = "terraform-aws-modules/eks-pod-identity/aws"
  version = "~> 2.0"

  name = "${local.name}-cnpg"

  policy_statements = [
    {
      sid    = "CNPGS3BackupAccess"
      effect = "Allow"
      actions = [
        "s3:GetObject",
        "s3:PutObject",
        "s3:DeleteObject",
        "s3:ListBucket",
        "s3:AbortMultipartUpload",
        "s3:ListMultipartUploadParts",
      ]
      resources = [
        aws_s3_bucket.cnpg_backups.arn,
        "${aws_s3_bucket.cnpg_backups.arn}/*",
      ]
    },
  ]

  associations = {
    cnpg = {
      cluster_name    = local.name
      namespace       = "cnpg-system"
      service_account = "cloudnative-pg"
    }
  }

  depends_on = [module.eks]
  tags       = local.tags
}
