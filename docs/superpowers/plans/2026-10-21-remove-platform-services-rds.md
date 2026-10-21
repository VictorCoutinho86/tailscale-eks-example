# Remoção de serviços de plataforma e RDS para Airflow Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Remover oito Applications e suas dependências Terraform/GitOps, mantendo Airflow funcional com um RDS PostgreSQL mínimo e sem backup.

**Architecture:** Terraform continuará responsável pela infraestrutura AWS e criará o RDS privado, seu subnet group e security group. Argo CD continuará responsável somente pelos serviços restantes; o metadata database deixará de ser um Application Kubernetes. Secrets do Airflow serão criados por um script local como Secrets nativos do Kubernetes, sem Sealed Secrets, ESO ou Secrets Manager.

**Tech Stack:** Terraform >= 1.11, AWS provider >= 6.52, Amazon RDS PostgreSQL 17, Kubernetes Secrets, Helm/Argo CD, Bash static tests.

**Spec:** `docs/superpowers/specs/2026-10-21-remove-platform-services-rds-design.md`

## Global Constraints

- Remover exatamente: OpenTelemetry Collector, Alloy, Loki, kube-prometheus-stack, CloudNativePG, Velero, Sealed Secrets e `airflow-db`.
- Manter Airflow, Spark Operator, Kubecost, Argo CD, Karpenter, AWS Load Balancer Controller, ExternalDNS, VPC, Tailscale, ALB e ACM/Route 53.
- RDS: PostgreSQL 17, `db.t4g.micro`, 20 GiB gp3, privado, dual-stack, single-AZ, sem backup, sem snapshot final, sem Performance Insights e sem Enhanced Monitoring.
- A senha do RDS deve usar `password_wo`/`password_wo_version`; não usar `master_password` nem gravar senha em Git ou Terraform state.
- Não adicionar ESO, Secrets Manager, RDS Proxy, Multi-AZ, read replica, backup ou outro serviço pago.
- Não reintroduzir Kubernetes provider/root Helm ownership para serviços fora dos dois releases de bootstrap do Argo CD.
- Não editar especificações históricas em `docs/superpowers/specs/`; atualizar apenas documentação operacional atual.
- Alvos de versão verificados em 21/10/2026: EKS `1.37`, LBC `3.6.1`, ExternalDNS `1.23.0`, Argo CD chart `10.10.5`/app `v3.5.5`, Karpenter `1.15.0`, Airflow image `3.3.2` com chart `1.22.0`, Spark Operator `2.5.2`, Kubecost `3.3.1`, VPC CNI `v1.23.2-eksbuild.3`, Pod Identity Agent `v1.4.0-eksbuild.4`, CoreDNS `v1.14.7-eksbuild.11`, kube-proxy `v1.37.0-eksbuild.22` e EBS CSI `v1.67.1-eksbuild.1`.
- Os cinco pins de addons foram consultados com `aws eks describe-addon-versions --profile victor --region us-east-1 --kubernetes-version 1.37`; não usar `most_recent`.

## Review Focus

- **Remoção incompleta:** nenhum Application, chart, namespace, PDB, RBAC, ServiceMonitor, alerta, bucket ou Pod Identity dos oito serviços pode permanecer.
  - Teste: asserções negativas em `tests/platform_static_test.sh` e `git grep` sem ocorrências dos nomes removidos.
- **RDS caro ou público:** valores padrão não podem habilitar Multi-AZ, backup, snapshot, monitoramento, Performance Insights ou acesso público.
  - Teste: `tests/rds_static_test.sh` verifica cada atributo exato e o security group privado.
- **Airflow sem metadata database:** a connection Secret precisa apontar para o endpoint RDS, porta 5432, database `airflow` e `sslmode=require`.
  - Teste: `tests/airflow_secrets_static_test.sh` verifica o script e `helm template` verifica `metadataSecretName`.
- **Perda acidental de chaves do Airflow:** o script não deve sobrescrever Fernet, JWT, API ou admin Secrets existentes por padrão.
  - Teste: teste estático exige a guarda de existência; execução manual deve confirmar que uma segunda execução é idempotente.
- **Conflito de ownership do Argo CD:** o Helm bootstrap deve criar `argocd-secret`, enquanto a Application GitOps não deve tentar recriá-lo.
  - Teste: asserções coordenadas em `argocd.tf` e `gitops/apps/argocd/values.yaml`, além de ausência do SealedSecret do Argo CD.

---

### Task 1: Upgrade retained services and vendored Helm dependencies

**Files:**
- Modify: `versions.tf`
- Modify: `eks.tf`
- Modify: `argocd.tf`
- Modify: `gitops/apps/aws-load-balancer-controller/Chart.yaml`
- Modify: `gitops/apps/aws-load-balancer-controller/Chart.lock`
- Replace: `gitops/apps/aws-load-balancer-controller/charts/aws-load-balancer-controller-*.tgz`
- Modify: `gitops/apps/external-dns/Chart.yaml`
- Modify: `gitops/apps/external-dns/Chart.lock`
- Replace: `gitops/apps/external-dns/charts/external-dns-*.tgz`
- Modify: `gitops/apps/argocd/Chart.yaml`
- Modify: `gitops/apps/argocd/Chart.lock`
- Replace: `gitops/apps/argocd/charts/argo-cd-*.tgz`
- Modify: `gitops/apps/karpenter/Chart.yaml`
- Modify: `gitops/apps/karpenter/Chart.lock`
- Modify: `gitops/apps/airflow/values.yaml`
- Modify: `gitops/apps/spark-operator/Chart.yaml`
- Modify: `gitops/apps/spark-operator/Chart.lock`
- Replace: `gitops/apps/spark-operator/charts/spark-operator-*.tgz`
- Modify: `gitops/apps/kubecost/Chart.yaml`
- Modify: `gitops/apps/kubecost/Chart.lock`
- Replace: `gitops/apps/kubecost/charts/kubecost-*.tgz`
- Create: `tests/versions_static_test.sh`
- Create: `tests/eks_addons_static_test.sh`

**Interfaces:**
- Consumes: official Helm repositories/OCI registry, current retained-service values and EKS `cluster_version`.
- Produces: pinned, vendored dependencies at the target versions and Terraform-compatible addon pins.

- [ ] **Step 1: Write failing version assertions**

Create `tests/versions_static_test.sh` to assert the target versions in every retained `Chart.yaml`/`Chart.lock`, both Argo CD chart references (`argocd.tf` and GitOps), Airflow `defaultAirflowTag`/`airflowVersion`, and Terraform `required_version >= 1.11.0`. Create `tests/eks_addons_static_test.sh` to assert all five explicit EKS addon pins and the absence of `most_recent`.

- [ ] **Step 2: Run the new test and verify it fails**

Run: `bash tests/versions_static_test.sh`

Expected: FAIL because the repository still pins the older retained-service versions and Terraform 1.10.

- [ ] **Step 3: Update the pins and compatibility-sensitive values**

Update the chart dependencies to the targets above and set the Terraform bootstrap Argo CD release to chart `10.10.5`. Set Airflow `defaultAirflowTag` and `airflowVersion` to `3.3.2`; keep chart `1.22.0` because the official chart index has no newer stable chart. Set `cluster_version` to `1.37`. Pin `eks.tf` to VPC CNI `v1.23.2-eksbuild.3`, Pod Identity Agent `v1.4.0-eksbuild.4`, CoreDNS `v1.14.7-eksbuild.11`, kube-proxy `v1.37.0-eksbuild.22` and EBS CSI `v1.67.1-eksbuild.1`, while retaining `enableNetworkPolicy = "true"` and the existing EBS Pod Identity association. Change Terraform's minimum version to `>= 1.11.0` because RDS `password_wo` requires it.

- [ ] **Step 4: Refresh locks and vendored packages**

Run `helm repo update`, then `helm dependency update` in each retained wrapper directory. Confirm `Chart.lock` and `charts/*.tgz` match the declared dependency versions; the Karpenter OCI dependency must resolve at `1.15.0`. Do not refresh retired application directories.

- [ ] **Step 5: Review upgrade compatibility before proceeding**

Render/lint all retained wrappers. For AWS Load Balancer Controller, review CRD changes and the v3.x Gateway API `v1beta1` deprecation; apply the new CRDs before the Helm upgrade. For Argo CD, review the chart 8.x→10.x changes to `configs.params` and ApplicationSet defaults, verify that Terraform creates `argocd-secret`, and verify that the bootstrap-created `argocd-redis` Secret exists before keeping GitOps `redisSecretInit.enabled: false`. For Karpenter, confirm `karpenter.sh/v1` and `karpenter.k8s.aws/v1` resources remain valid. Keep ExternalDNS `policy: upsert-only`; keep Spark `webhook.enable: true`; render Kubecost CUR JSON; and disable Airflow StatsD only as part of the observability removal, not as a chart-upgrade workaround.

- [ ] **Step 6: Run tests and commit**

Run: `bash tests/versions_static_test.sh && bash tests/eks_addons_static_test.sh && terraform fmt -check -recursive *.tf && terraform validate`

Expected: PASS with all retained dependencies pinned and rendered successfully.

```bash
git add versions.tf eks.tf argocd.tf gitops/apps tests/versions_static_test.sh
git commit -m "chore: upgrade retained platform services"
```

### Task 2: Add the minimal private RDS infrastructure

**Files:**
- Create: `airflow-rds.tf`
- Modify: `variables.tf`
- Modify: `outputs.tf`
- Create: `tests/rds_static_test.sh`
- Modify: `tests/platform_static_test.sh`

**Interfaces:**
- Consumes: `module.vpc.private_subnets`, `module.vpc.private_subnets_cidr_blocks`, `module.vpc.private_subnets_ipv6_cidr_blocks`, `module.vpc.vpc_id`, `local.name`, `var.aws_region`, `var.tags`.
- Produces: `aws_db_instance.airflow`, `aws_db_subnet_group.airflow`, `aws_security_group.airflow_db`, and output `airflow_db_address` consumed by the Secrets script.

- [ ] **Step 1: Write failing static assertions**

Add checks to `tests/rds_static_test.sh` for the exact RDS resource and these values: `engine = "postgres"`, `engine_version = "17"`, `instance_class = "db.t4g.micro"`, `allocated_storage = 20`, `storage_type = "gp3"`, `network_type = "DUAL"`, `multi_az = false`, `publicly_accessible = false`, `backup_retention_period = 0`, `delete_automated_backups = true`, `skip_final_snapshot = true`, `deletion_protection = false`, `monitoring_interval = 0`, `performance_insights_enabled = false`, and `password_wo`.

- [ ] **Step 2: Run the new test and verify it fails**

Run: `bash tests/rds_static_test.sh`

Expected: FAIL because `airflow-rds.tf` and the RDS resources do not exist.

- [ ] **Step 3: Implement the RDS resources**

In `airflow-rds.tf`, create the private subnet group, a dedicated security group with TCP/5432 ingress from the private IPv4 and IPv6 subnet CIDRs and unrestricted egress, and the single RDS instance. Set `master_username = "airflow"`, `db_name = "airflow"`, `storage_encrypted = true`, `manage_master_user_password` absent, `password_wo = var.airflow_db_password`, and `password_wo_version = 1`. Do not add a monitoring IAM role.

Add sensitive, required `airflow_db_password` to `variables.tf` with validation for a non-empty value. Add `airflow_db_address` as a non-sensitive output. Do not output the password.

- [ ] **Step 4: Run the test and verify it passes**

Run: `bash tests/rds_static_test.sh`

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add airflow-rds.tf variables.tf outputs.tf tests/rds_static_test.sh tests/platform_static_test.sh
git commit -m "feat: add minimal private airflow rds"
```

### Task 3: Remove Terraform resources and IAM for retired services

**Files:**
- Delete: `velero.tf`
- Delete: `database.tf`
- Modify: `observability.tf`
- Modify: `argocd.tf`
- Modify: `charts/argocd-root-application/templates/application.yaml`
- Modify: `charts/argocd-root-application/values.yaml`
- Modify: `gitops/root/values.yaml`
- Modify: `tests/platform_static_test.sh`

**Interfaces:**
- Consumes: RDS resources from Task 2 and retained `observability.tf` resources for ALB access logs and Spark events.
- Produces: no Terraform references to Velero, Loki, CNPG or their buckets/Pod Identity modules.

- [ ] **Step 1: Add failing absence assertions**

Extend `tests/platform_static_test.sh` to require that `velero.tf` and `database.tf` are absent, `argocd.tf` contains no `cnpgBackupBucket`, `veleroBucket` or `lokiBucket`, and `observability.tf` contains no `aws_s3_bucket.loki` or `loki_pod_identity`.

- [ ] **Step 2: Run the affected tests and verify they fail**

Run: `bash tests/platform_static_test.sh`

Expected: FAIL against the current bucket, Pod Identity and root Application references.

- [ ] **Step 3: Remove only retired infrastructure**

Delete the two dedicated Terraform files. Remove Loki resources and module blocks from `observability.tf` while preserving ALB access-log and Spark-event buckets. Remove the three retired bucket values from `argocd.tf`, the intermediate root Application chart template/values, and `gitops/root/values.yaml`. Do not alter Airflow S3 logs, Spark IAM, Kubecost IAM, EBS CSI, LBC or ExternalDNS IAM.

- [ ] **Step 4: Run tests and Terraform validation**

Run: `bash tests/platform_static_test.sh && terraform fmt -check -recursive *.tf && terraform validate`

Expected: PASS with no dangling Terraform references to deleted resources.

- [ ] **Step 5: Commit**

```bash
git add -u velero.tf database.tf observability.tf argocd.tf charts/argocd-root-application gitops/root/values.yaml tests/platform_static_test.sh
git commit -m "chore: remove retired backup and database infrastructure"
```

### Task 4: Prune the Argo CD tree and shared Kubernetes resources

**Files:**
- Delete: `gitops/apps/otel-collector/`
- Delete: `gitops/apps/alloy/`
- Delete: `gitops/apps/loki/`
- Delete: `gitops/apps/kube-prometheus-stack/`
- Delete: `gitops/apps/cloudnative-pg/`
- Delete: `gitops/apps/velero/`
- Delete: `gitops/apps/sealed-secrets/`
- Delete: `gitops/apps/airflow-db/`
- Modify: `gitops/root/templates/applications.yaml`
- Modify: `gitops/base/templates/namespaces.yaml`
- Modify: `gitops/base/templates/network-policies.yaml`
- Modify: `gitops/base/templates/pdbs.yaml`
- Delete: `gitops/base/templates/alert-rules.yaml`
- Delete: `gitops/base/templates/servicemonitors.yaml`
- Modify: `gitops/apps/airflow/values.yaml`
- Modify: `gitops/apps/argocd/values.yaml`
- Delete: `gitops/apps/argocd/templates/argocd-secret-sealed.yaml`
- Modify: `argocd.tf`

**Interfaces:**
- Consumes: retained root Application parameters and base chart.
- Produces: exactly nine child Applications: `base`, `argocd`, `aws-load-balancer-controller`, `external-dns`, `karpenter`, `karpenter-resources`, `airflow`, `spark-operator`, and `kubecost`.

- [ ] **Step 1: Add failing GitOps assertions**

Update `tests/platform_static_test.sh` so the expected Application/source list contains only the nine retained Applications, and add negative checks for all eight removed names, removed CRD resource kinds, `monitoring`, `cnpg-system`, `sealed-secrets`, `velero`, and the deleted chart directories.

- [ ] **Step 2: Run the test and verify it fails**

Run: `bash tests/platform_static_test.sh`

Expected: FAIL because the current app-of-apps and base chart still render retired services.

- [ ] **Step 3: Remove the retired Applications and shared resources**

Delete the eight app directories and their vendored dependencies. Remove their entries and special values branches from `gitops/root/templates/applications.yaml`; remove `cloudnative-pg`, `kube-prometheus-stack` and `airflow-db` from the ServerSideApply list. Remove retired namespaces, the `cnpg-system` and `monitoring` network-policy rules, the Sealed Secrets PDB, AlertRules and ServiceMonitors. Disable Airflow StatsD and Prometheus-specific configuration. Set the Terraform bootstrap Argo CD chart to create its own `argocd-secret`; leave the self-managed Argo CD chart with creation disabled to avoid Helm ownership conflict.

- [ ] **Step 4: Render and test the tree**

Run: `bash tests/platform_static_test.sh && helm template platform-root gitops/root --set global.repoURL=https://example.invalid/repo.git --set global.targetRevision=master`

Expected: PASS; rendered output contains only the nine retained Applications and no retired service names or monitoring CRDs.

- [ ] **Step 5: Commit**

```bash
git add -u argocd.tf gitops/root gitops/base gitops/apps tests/platform_static_test.sh
git commit -m "chore: prune retired argocd applications"
```

### Task 5: Replace Sealed Secrets and CNPG credentials with native Airflow Secrets

**Files:**
- Delete: `scripts/seal-secrets.sh`
- Create: `scripts/create-airflow-secrets.sh`
- Delete: `gitops/apps/airflow/templates/fernet-key-sealed-secret.yaml`
- Delete: `gitops/apps/airflow/templates/jwt-sealed-secret.yaml`
- Delete: `gitops/apps/airflow/templates/api-secret-key-sealed-secret.yaml`
- Delete: `gitops/apps/airflow/templates/admin-password-sealed-secret.yaml`
- Delete: `gitops/apps/airflow-db/templates/db-credentials-sealed-secret.yaml`
- Create: `tests/airflow_secrets_static_test.sh`
- Modify: `tests/platform_static_test.sh`

**Interfaces:**
- Consumes: `terraform output -raw airflow_db_address`, `AIRFLOW_DB_PASSWORD`, and the retained Airflow chart secret names.
- Produces: Kubernetes Secrets `airflow-fernet-key`, `airflow-jwt-secret`, `airflow-api-secret-key`, `airflow-admin-credentials` and `airflow-db-credentials` in namespace `airflow`.

- [ ] **Step 1: Write failing script assertions**

Create `tests/airflow_secrets_static_test.sh` checking that the replacement script requires `kubectl`, `python3`, `AIRFLOW_DB_PASSWORD`, uses `terraform output -raw airflow_db_address`, creates all five expected Secret names, includes `sslmode=require`, does not print secret values, and has an existence guard for the four non-database Airflow Secrets.

- [ ] **Step 2: Run the test and verify it fails**

Run: `bash tests/airflow_secrets_static_test.sh`

Expected: FAIL because only the Sealed Secrets script exists.

- [ ] **Step 3: Implement the native Secret script**

Create an idempotent Bash script that generates missing Fernet/JWT/API/admin values with Python, reads the RDS address from Terraform, URL-encodes the supplied database password, and applies Secrets through `kubectl create secret generic --dry-run=client -o yaml | kubectl apply -f -`. Preserve existing app Secrets; always update the database Secret so it points to RDS. Never write generated values to files or echo them. Remove the old script and all SealedSecret templates.

- [ ] **Step 4: Test shell syntax and static contract**

Run: `bash -n scripts/create-airflow-secrets.sh && bash tests/airflow_secrets_static_test.sh && ! git grep -n 'SealedSecret\|sealedsecrets\.bitnami\.com\|kubeseal\|seal-secrets\.sh' -- ':!docs/superpowers/specs/*'`

Expected: PASS and no current operational file references the removed secret mechanism.

- [ ] **Step 5: Commit**

```bash
git add -u scripts gitops/apps/airflow gitops/apps/airflow-db tests
git add scripts/create-airflow-secrets.sh tests/airflow_secrets_static_test.sh
git commit -m "feat: manage airflow credentials as native kubernetes secrets"
```

### Task 6: Update current documentation and architecture diagram

**Files:**
- Modify: `README.md`
- Modify: `AGENTS.md`
- Modify: `docs/architecture_diagram.py`
- Regenerate: `docs/architecture.png`

**Interfaces:**
- Consumes: final Terraform and GitOps resource names from Tasks 1–5.
- Produces: operational documentation with no claim that removed services or backups exist.

- [ ] **Step 1: Add documentation checks**

Extend the static checks or add a documentation check that rejects current operational references to Grafana/Prometheus/Loki/Alloy/OTel/Velero/CNPG/Sealed Secrets and `monitoring.*`, while requiring the RDS settings, `airflow_db_password`, native Secret script, and no-backup warning.

- [ ] **Step 2: Run the check and verify it fails**

Run: `bash tests/platform_static_test.sh`

Expected: FAIL against the existing README/context/diagram source.

- [ ] **Step 3: Update documentation and diagram**

Rewrite the current service tables, apply flow, validation commands and backup/monitoring sections. Document the RDS endpoint/password setup order, native Secret lifecycle, irreversible no-backup behavior, retained Airflow S3 logs, and the absence of cluster backup/metrics/log aggregation. Replace the diagram's CNPG/observability/backup nodes with a private RDS node and the retained services only.

- [ ] **Step 4: Regenerate and verify**

Run: `uv run docs/architecture_diagram.py && bash tests/platform_static_test.sh`

Expected: the PNG is regenerated and the operational checks pass.

- [ ] **Step 5: Commit**

```bash
git add README.md AGENTS.md docs/architecture_diagram.py docs/architecture.png tests/platform_static_test.sh
git commit -m "docs: describe lean airflow rds platform"
```

### Task 7: Full verification and destructive-change review

**Files:**
- Modify only files identified by failing verification; no unrelated cleanup.

- [ ] **Step 1: Run all shell syntax checks**

Run: `bash -n tests/platform_static_test.sh && bash -n tests/bootstrap_static_test.sh && bash -n tests/versions_static_test.sh && bash -n tests/eks_addons_static_test.sh && bash -n tests/airflow_secrets_static_test.sh && bash -n tests/rds_static_test.sh && bash -n templates/bootstrap.sh.tftpl`

Expected: PASS.

- [ ] **Step 2: Run repository static tests**

Run: `bash tests/versions_static_test.sh && bash tests/eks_addons_static_test.sh && bash tests/platform_static_test.sh && bash tests/bootstrap_static_test.sh && bash tests/private_network_static_test.sh && bash tests/karpenter_static_test.sh && bash tests/kubecost_cur_static_test.sh`

Expected: PASS with all removed-service assertions inverted or deleted and all retained service checks intact.

- [ ] **Step 3: Validate Terraform and rendered charts**

Run: `terraform fmt -check -recursive *.tf && terraform validate && helm template platform-root gitops/root --set global.repoURL=https://example.invalid/repo.git --set global.targetRevision=master`

Expected: PASS; no provider/schema errors and no rendered retired Applications.

- [ ] **Step 4: Preflight destructive AWS assumptions**

Before apply, verify `db.t4g.micro` with PostgreSQL 17 and dual-stack is orderable in `var.aws_region`, confirm the three retired versioned buckets are empty, and review `terraform plan` for expected RDS creation plus only the intended bucket/IAM/GitOps deletions. Do not apply a plan containing unexpected database replacement or unrelated infrastructure destruction.

- [ ] **Step 5: Validate runtime sequence after approval**

Apply infrastructure with the existing bootstrap phase rules, run `scripts/create-airflow-secrets.sh`, sync Argo CD, and verify:

```bash
kubectl -n argocd get applications
kubectl -n airflow get pods
kubectl -n airflow get secret airflow-db-credentials
kubectl -n airflow logs job/airflow-migrate-database --tail=100
kubectl -n airflow get pods -l component=scheduler
```

Expected: only retained Applications exist, Airflow reaches Ready, migrations complete against the RDS endpoint, and no removed namespace or controller remains.
