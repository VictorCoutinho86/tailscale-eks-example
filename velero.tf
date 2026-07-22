resource "aws_s3_bucket" "velero" {
  bucket = "${local.name}-velero-${data.aws_caller_identity.current.account_id}"
  tags   = local.tags
}

resource "aws_s3_bucket_versioning" "velero" {
  bucket = aws_s3_bucket.velero.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "velero" {
  bucket = aws_s3_bucket.velero.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "velero" {
  bucket = aws_s3_bucket.velero.id
  rule {
    id     = "expire-old-backups"
    status = "Enabled"
    expiration {
      days = 30
    }
  }
}

resource "aws_s3_bucket_public_access_block" "velero" {
  bucket                  = aws_s3_bucket.velero.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

module "velero_pod_identity" {
  source  = "terraform-aws-modules/eks-pod-identity/aws"
  version = "~> 2.0"

  name = "${local.name}-velero"

  policy_statements = [
    {
      sid    = "VeleroEbsSnapshots"
      effect = "Allow"
      actions = [
        "ec2:DescribeVolumes",
        "ec2:DescribeSnapshots",
        "ec2:CreateTags",
        "ec2:CreateVolume",
        "ec2:CreateSnapshot",
        "ec2:DeleteSnapshot",
      ]
      resources = ["*"]
    },
    {
      sid    = "VeleroS3BucketAccess"
      effect = "Allow"
      actions = [
        "s3:GetObject",
        "s3:DeleteObject",
        "s3:PutObject",
        "s3:AbortMultipartUpload",
        "s3:ListMultipartUploadParts",
      ]
      resources = [
        "${aws_s3_bucket.velero.arn}/*",
      ]
    },
    {
      sid    = "VeleroS3BucketList"
      effect = "Allow"
      actions = [
        "s3:ListBucket",
      ]
      resources = [
        aws_s3_bucket.velero.arn,
      ]
    },
  ]

  associations = {
    velero = {
      cluster_name    = local.name
      namespace       = "velero"
      service_account = "velero-server"
    }
  }

  depends_on = [module.eks]
  tags       = local.tags
}
