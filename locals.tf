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

  private_subnets = [
    for index, _ in local.azs : cidrsubnet(var.vpc_cidr, 4, index + 1)
  ]

  tailscale_subnet_router_hostname = "${local.name}-subnet-router"

  airflow_s3_log_policy_statements = [
    {
      sid       = "AirflowRemoteLogsList"
      actions   = ["s3:ListBucket"]
      resources = ["arn:${data.aws_partition.current.partition}:s3:::${var.airflow_logs_bucket}"]
      condition = [{
        test     = "StringLike"
        variable = "s3:prefix"
        values   = ["airflow/logs", "airflow/logs/*"]
      }]
    },
    {
      sid       = "AirflowRemoteLogsObjects"
      actions   = ["s3:GetObject", "s3:PutObject"]
      resources = ["arn:${data.aws_partition.current.partition}:s3:::${var.airflow_logs_bucket}/airflow/logs/*"]
    }
  ]

  airflow_ebs_cleanup_policy_statements = [
    {
      sid       = "AirflowCleanupDescribeEbsVolumes"
      actions   = ["ec2:DescribeVolumes"]
      resources = ["*"]
    },
    {
      sid       = "AirflowCleanupDeleteEbsVolumes"
      actions   = ["ec2:DeleteVolume"]
      resources = ["arn:${data.aws_partition.current.partition}:ec2:${var.aws_region}:${data.aws_caller_identity.current.account_id}:volume/*"]
    }
  ]

  kubecost_athena_policy_statements = concat(
    [
      {
        sid = "KubecostAthenaWorkgroupAccess"
        actions = [
          "athena:BatchGetQueryExecution",
          "athena:GetQueryExecution",
          "athena:GetQueryResults",
          "athena:GetQueryResultsStream",
          "athena:StartQueryExecution",
          "athena:StopQueryExecution",
          "athena:GetWorkGroup",
        ]
        resources = [
          "arn:${data.aws_partition.current.partition}:athena:${var.aws_region}:${data.aws_caller_identity.current.account_id}:workgroup/${var.kubecost_athena_workgroup}",
        ]
      },
      {
        sid       = "KubecostAthenaListWorkgroups"
        actions   = ["athena:ListWorkGroups"]
        resources = ["*"]
      },
      {
        sid     = "KubecostGlueDatabaseRead"
        actions = ["glue:GetDatabase"]
        resources = [
          "arn:${data.aws_partition.current.partition}:glue:${var.aws_region}:${data.aws_caller_identity.current.account_id}:catalog",
          "arn:${data.aws_partition.current.partition}:glue:${var.aws_region}:${data.aws_caller_identity.current.account_id}:database/${var.kubecost_athena_database}",
        ]
      },
      {
        sid     = "KubecostGlueTableRead"
        actions = ["glue:GetTable", "glue:GetPartition", "glue:GetPartitions", "glue:BatchGetPartition"]
        resources = [
          "arn:${data.aws_partition.current.partition}:glue:${var.aws_region}:${data.aws_caller_identity.current.account_id}:catalog",
          "arn:${data.aws_partition.current.partition}:glue:${var.aws_region}:${data.aws_caller_identity.current.account_id}:database/${var.kubecost_athena_database}",
          "arn:${data.aws_partition.current.partition}:glue:${var.aws_region}:${data.aws_caller_identity.current.account_id}:table/${var.kubecost_athena_database}/${var.kubecost_athena_table}",
        ]
      },
      {
        sid     = "KubecostGlueFunctionRead"
        actions = ["glue:GetUserDefinedFunction"]
        resources = [
          "arn:${data.aws_partition.current.partition}:glue:${var.aws_region}:${data.aws_caller_identity.current.account_id}:catalog",
          "arn:${data.aws_partition.current.partition}:glue:${var.aws_region}:${data.aws_caller_identity.current.account_id}:database/${var.kubecost_athena_database}",
          "arn:${data.aws_partition.current.partition}:glue:${var.aws_region}:${data.aws_caller_identity.current.account_id}:userDefinedFunction/${var.kubecost_athena_database}/*",
        ]
      },
      {
        sid       = "KubecostCurBucketRead"
        actions   = ["s3:GetBucketLocation", "s3:ListBucket"]
        resources = ["arn:${data.aws_partition.current.partition}:s3:::${var.kubecost_cur_source_bucket}"]
      },
      {
        sid       = "KubecostCurObjectRead"
        actions   = ["s3:GetObject", "s3:GetObjectVersion"]
        resources = ["arn:${data.aws_partition.current.partition}:s3:::${var.kubecost_cur_source_bucket}/*"]
      },
      {
        sid       = "KubecostAthenaResultsBucket"
        actions   = ["s3:GetBucketLocation", "s3:ListBucket", "s3:ListBucketMultipartUploads"]
        resources = ["arn:${data.aws_partition.current.partition}:s3:::${var.kubecost_athena_query_results_bucket}"]
      },
      {
        sid = "KubecostAthenaResultsObjects"
        actions = [
          "s3:AbortMultipartUpload",
          "s3:GetObject",
          "s3:ListMultipartUploadParts",
          "s3:PutObject",
        ]
        resources = ["arn:${data.aws_partition.current.partition}:s3:::${var.kubecost_athena_query_results_bucket}/*"]
      },
    ],
    length(var.kubecost_kms_key_arns) > 0 ? [
      {
        sid       = "KubecostKmsDecrypt"
        actions   = ["kms:Decrypt", "kms:GenerateDataKey", "kms:DescribeKey"]
        resources = var.kubecost_kms_key_arns
      },
    ] : [],
  )

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
