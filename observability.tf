resource "aws_s3_bucket" "loki" {
  bucket = "${local.name}-loki-${data.aws_caller_identity.current.account_id}"
  tags   = local.tags
}

resource "aws_s3_bucket_server_side_encryption_configuration" "loki" {
  bucket = aws_s3_bucket.loki.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "loki" {
  bucket = aws_s3_bucket.loki.id
  rule {
    id     = "expire-old-chunks"
    status = "Enabled"
    expiration {
      days = 30
    }
  }
}

resource "aws_s3_bucket_public_access_block" "loki" {
  bucket                  = aws_s3_bucket.loki.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket" "alb_access_logs" {
  bucket = "${local.name}-alb-logs-${data.aws_caller_identity.current.account_id}"
  tags   = local.tags
}

resource "aws_s3_bucket_server_side_encryption_configuration" "alb_logs" {
  bucket = aws_s3_bucket.alb_access_logs.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "alb_logs" {
  bucket = aws_s3_bucket.alb_access_logs.id
  rule {
    id     = "expire-old-logs"
    status = "Enabled"
    expiration {
      days = 90
    }
  }
}

resource "aws_s3_bucket_public_access_block" "alb_logs" {
  bucket                  = aws_s3_bucket.alb_access_logs.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket" "spark_events" {
  bucket = "${local.name}-spark-events-${data.aws_caller_identity.current.account_id}"
  tags   = local.tags
}

resource "aws_s3_bucket_versioning" "spark_events" {
  bucket = aws_s3_bucket.spark_events.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "spark_events" {
  bucket = aws_s3_bucket.spark_events.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "spark_events" {
  bucket = aws_s3_bucket.spark_events.id
  rule {
    id     = "expire-old-logs"
    status = "Enabled"
    expiration {
      days = 90
    }
  }
}

resource "aws_s3_bucket_public_access_block" "spark_events" {
  bucket                  = aws_s3_bucket.spark_events.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

module "loki_pod_identity" {
  source  = "terraform-aws-modules/eks-pod-identity/aws"
  version = "~> 2.0"

  name = "${local.name}-loki"

  policy_statements = [
    {
      sid    = "LokiS3Access"
      effect = "Allow"
      actions = [
        "s3:GetObject",
        "s3:PutObject",
        "s3:DeleteObject",
        "s3:ListBucket",
      ]
      resources = [
        aws_s3_bucket.loki.arn,
        "${aws_s3_bucket.loki.arn}/*",
      ]
    },
  ]

  associations = {
    loki = {
      cluster_name    = local.name
      namespace       = "monitoring"
      service_account = "loki"
    }
  }

  depends_on = [module.eks]
  tags       = local.tags
}

module "spark_history_pod_identity" {
  source  = "terraform-aws-modules/eks-pod-identity/aws"
  version = "~> 2.0"

  name = "${local.name}-spark-history"

  policy_statements = [
    {
      sid    = "SparkHistoryS3Read"
      effect = "Allow"
      actions = [
        "s3:GetObject",
        "s3:ListBucket",
      ]
      resources = [
        aws_s3_bucket.spark_events.arn,
        "${aws_s3_bucket.spark_events.arn}/*",
      ]
    },
  ]

  associations = {
    spark_history = {
      cluster_name    = local.name
      namespace       = "spark-history"
      service_account = "spark-history"
    }
  }

  depends_on = [module.eks]
  tags       = local.tags
}
