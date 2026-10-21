#!/usr/bin/env bash
set -euo pipefail

rds="airflow-rds.tf"
variables="variables.tf"
outputs="outputs.tf"

for expected in \
  'resource "aws_db_instance" "airflow"' \
  'engine[[:space:]]*=[[:space:]]*"postgres"' \
  'engine_version[[:space:]]*=[[:space:]]*"17"' \
  'instance_class[[:space:]]*=[[:space:]]*"db.t4g.micro"' \
  'allocated_storage[[:space:]]*=[[:space:]]*20' \
  'storage_type[[:space:]]*=[[:space:]]*"gp3"' \
  'network_type[[:space:]]*=[[:space:]]*"DUAL"' \
  'multi_az[[:space:]]*=[[:space:]]*false' \
  'publicly_accessible[[:space:]]*=[[:space:]]*false' \
  'backup_retention_period[[:space:]]*=[[:space:]]*0' \
  'delete_automated_backups[[:space:]]*=[[:space:]]*true' \
  'skip_final_snapshot[[:space:]]*=[[:space:]]*true' \
  'deletion_protection[[:space:]]*=[[:space:]]*false' \
  'monitoring_interval[[:space:]]*=[[:space:]]*0' \
  'performance_insights_enabled[[:space:]]*=[[:space:]]*false' \
  'password_wo[[:space:]]*=[[:space:]]*var\.airflow_db_password' \
  'password_wo_version[[:space:]]*=[[:space:]]*1'; do
  if ! grep -Eq "$expected" "$rds"; then
    printf 'expected RDS setting: %s\n' "$expected" >&2
    exit 1
  fi
done

for expected in \
  'variable "airflow_db_password"' \
  'sensitive   = true'; do
  if ! grep -Fq "$expected" "$variables"; then
    printf 'expected variable setting: %s\n' "$expected" >&2
    exit 1
  fi
done

if ! grep -q 'output "airflow_db_address"' "$outputs"; then
  printf 'expected airflow_db_address output\n' >&2
  exit 1
fi

printf 'minimal private Airflow RDS contract is present\n'
