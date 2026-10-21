resource "aws_db_subnet_group" "airflow" {
  name       = "${local.name}-airflow"
  subnet_ids = module.vpc.private_subnets

  tags = merge(local.tags, {
    Name = "${local.name}-airflow"
  })
}

resource "aws_security_group" "airflow_db" {
  name        = "${local.name}-airflow-db"
  description = "Allow private EKS subnets to reach the Airflow PostgreSQL database"
  vpc_id      = module.vpc.vpc_id

  ingress {
    description      = "PostgreSQL from private IPv4 subnets"
    protocol         = "tcp"
    from_port        = 5432
    to_port          = 5432
    cidr_blocks      = module.vpc.private_subnets_cidr_blocks
    ipv6_cidr_blocks = []
  }

  ingress {
    description      = "PostgreSQL from private IPv6 subnets"
    protocol         = "tcp"
    from_port        = 5432
    to_port          = 5432
    cidr_blocks      = []
    ipv6_cidr_blocks = module.vpc.private_subnets_ipv6_cidr_blocks
  }

  egress {
    description = "Allow all outbound traffic"
    protocol    = "-1"
    from_port   = 0
    to_port     = 0
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    description      = "Allow all outbound IPv6 traffic"
    protocol         = "-1"
    from_port        = 0
    to_port          = 0
    ipv6_cidr_blocks = ["::/0"]
  }

  tags = merge(local.tags, {
    Name = "${local.name}-airflow-db"
  })
}

resource "aws_db_instance" "airflow" {
  identifier = "${local.name}-airflow"

  engine                       = "postgres"
  engine_version               = "17"
  instance_class               = "db.t4g.micro"
  allocated_storage            = 20
  storage_type                 = "gp3"
  storage_encrypted            = true
  network_type                 = "DUAL"
  availability_zone            = local.azs[0]
  db_subnet_group_name         = aws_db_subnet_group.airflow.name
  vpc_security_group_ids       = [aws_security_group.airflow_db.id]
  publicly_accessible          = false
  multi_az                     = false
  backup_retention_period      = 0
  delete_automated_backups     = true
  skip_final_snapshot          = true
  deletion_protection          = false
  monitoring_interval          = 0
  performance_insights_enabled = false
  maintenance_window           = "sun:05:00-sun:06:00"
  apply_immediately            = false

  db_name             = "airflow"
  username            = "airflow"
  password_wo         = var.airflow_db_password
  password_wo_version = 1

  tags = merge(local.tags, {
    Name = "${local.name}-airflow"
  })
}
