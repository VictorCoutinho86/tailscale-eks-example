# Production Hardening Plan

**Status:** Draft | **Date:** 2026-07-20 | **Scope:** tailscale-eks-example

---

## Overview

This document describes all changes required to move the `tailscale-eks-example` platform from MVP to production-grade, ready for real data workloads (Airflow + Spark pipelines). It covers Terraform infrastructure, Argo CD-managed GitOps services, and operational practices.

### Context

The current platform has a solid two-phase architecture: Root Terraform creates AWS infrastructure, Argo CD reconciles platform services via an app-of-apps tree under `gitops/`. Access goes through a persistent Tailscale subnet router. The foundation is correct — this plan hardens it for production use.

### Design Decisions (pre-approved)

- **Secrets:** Sealed Secrets for all application secrets in Git. External Secrets Operator (ESO) used solely to sync the Sealed Secrets controller's private key from AWS Secrets Manager (for DR/bootstrap). App secrets are always sealed and never touch Secrets Manager directly.
- **Database:** Airflow uses its bundled PostgreSQL. CloudNativePG is the preferred alternative over RDS when a dedicated database becomes necessary (see Out of Scope).
- **EKS version:** 1.36 (latest available, confirmed by the user).

---

## Changes by Workstream

Each workstream is independent and can be implemented in parallel by different agents. Implementation order is described in the [Implementation Sequence](#implementation-sequence) section below.

---

### Workstream A: Secrets Management

**Goal:** Eliminate all plaintext secrets from Git and Terraform state. Use Sealed Secrets for app secrets, with ESO to sync the Sealed Secrets private key from AWS Secrets Manager for disaster recovery.

#### A1. Add External Secrets Operator to GitOps

- **File:** `gitops/apps/external-secrets/` (new directory)
- Create a Helm chart wrapper for `external-secrets` (chart version TBD — recommend latest stable).
- Add vendored `.tgz` chart.
- Add to `gitops/root/templates/applications.yaml` as a new application in **wave 1** (alongside `sealed-secrets`, before it so the key is available early).
- Values: minimal — ESO uses Pod Identity for AWS auth, so no AWS credentials needed in the chart.

#### A2. ESO Pod Identity Role (Terraform)

- **File:** `pod-identity.tf` (append)
- New module `module.external_secrets_pod_identity` using `terraform-aws-modules/eks-pod-identity/aws`.
- Policy: allow `secretsmanager:GetSecretValue` on the specific Secrets Manager secret ARN only (not wildcard).
- Service account: `external-secrets` in namespace `external-secrets`.
- Depends on `module.eks`.

#### A3. AWS Secrets Manager Secret for Sealed Secrets Key (Terraform)

- **File:** `secrets-manager.tf` (new file)
- `aws_secretsmanager_secret.sealed_secrets_key` — stores the controller's TLS key pair.
- `aws_secretsmanager_secret_version.sealed_secrets_key` — initial value with `lifecycle { ignore_changes = [secret_string] }` so manual rotation does not trigger replacement.
- Secret name: `${local.name}-sealed-secrets-key`.
- Value format (`jsonencode`):

```json
{
  "tls.crt": "<PEM certificate>",
  "tls.key": "<PEM private key>"
}
```

- **Manual bootstrap step:** The initial key pair must be generated and uploaded to Secrets Manager before ESO can sync it. Provide a script or documented procedure.

#### A4. ESO ClusterSecretStore and ExternalSecret (GitOps)

- **File:** `gitops/base/templates/sealed-secrets-key-external-secret.yaml` (new)
- `ClusterSecretStore` referencing AWS Secrets Manager, using Pod Identity (no `secretRef` needed).
- `ExternalSecret` syncing to Kubernetes Secret `sealed-secrets-key` in namespace `kube-system` (or wherever Sealed Secrets expects it) with labels `sealedsecrets.bitnami.com/sealed-secrets-key: active`.
- These resources are in the `base` app (wave 0) so they exist before `sealed-secrets` controller starts. Ensure ESO is running before Sealed Secrets tries to read the key.

> **Note on ordering:** If ESO is not yet running when `base` applies, the `ExternalSecret` resource will be created but the actual secret won't sync until ESO is healthy. Sealed Secrets controller will generate a self-signed key on startup. Once ESO syncs the key from Secrets Manager, the controller picks it up and existing SealedSecrets become decryptable. This is an acceptable bootstrap sequence.

#### A5. Seal All Application Secrets

Replace **all** plaintext secrets — including both admin passwords — with `SealedSecret` resources committed to Git and reconciled by Argo CD. Terraform no longer passes any secret values; it only creates the AWS Secrets Manager secret for the Sealed Secrets key bootstrap (A3).

| Secret | Currently In | SealedSecret Location |
|--------|-------------|----------------------|
| Airflow fernet key | `gitops/apps/airflow/values.yaml:6` | `gitops/apps/airflow/templates/fernet-key-sealed-secret.yaml` |
| Airflow JWT secret | `gitops/apps/airflow/values.yaml:7` | `gitops/apps/airflow/templates/fernet-key-sealed-secret.yaml` (same secret, `airflow-fernet-key`) |
| Airflow API secret key | `gitops/apps/airflow/values.yaml:8` | `gitops/apps/airflow/templates/api-secret-key-sealed-secret.yaml` |
| Airflow admin password | `argocd.tf:59` → `gitops/root/templates/applications.yaml:79` (via values) | `gitops/apps/airflow/templates/admin-password-sealed-secret.yaml` |
| Argo CD admin password | `argocd.tf:26,59` (bcrypt hash via values) | `gitops/apps/argocd/templates/argocd-secret-sealed.yaml` |

For Airflow:
- Remove the plaintext keys from `gitops/apps/airflow/values.yaml`.
- Replace the existing wrapper templates (`fernet-key-secret.yaml`, `jwt-secret.yaml`, `api-secret-key-secret.yaml`) with `SealedSecret` resources. These contain the same keys but encrypted by Sealed Secrets.
- The Airflow chart already references `fernetKeySecretName: airflow-fernet-key` etc., so the Secret names remain the same — only the resource type changes from `Secret` to `SealedSecret`.
- For the **admin password**: create a new `SealedSecret` (e.g., `airflow-admin-credentials`) in the `airflow` namespace containing the key `admin-password`. Reference it in Airflow values via `createUserJob.defaultUser.existingSecret` and `existingSecretKey`. Remove the `adminPassword` injection from `gitops/root/templates/applications.yaml` (lines 77-79) and from `argocd.tf` (line 59 where it flows to the root Application).

For Argo CD:
- Remove the `adminPassword` value entirely from `argocd.tf` (lines 25-28 in the `helm_release.argocd` block, and line 59 in the root Application values).
- Remove the `adminPassword` injection from `gitops/root/templates/applications.yaml` (line 79 — already covered above, shared with Airflow removal).
- Create a `SealedSecret` containing the full `argocd-secret` structure in the `argocd` namespace with `admin.password` (bcrypt hash), `admin.passwordMtime`, and `server.secretkey`.
- Set `configs.secret.createSecret: false` in `gitops/apps/argocd/values.yaml` to prevent the chart from creating a competing Secret.
- After the SealedSecret is applied, use `argocd account update-password` to rotate the admin password (the SealedSecret bootstraps the initial one).

> **Note:** Both admin passwords flow through Argo CD reconciliation only — Terraform does not touch them. The sealed secret manifests are committed to Git, and Argo CD applies them via the app-of-apps tree (wave 2+ so the Sealed Secrets controller is already decrypting). The Sealed Secrets controller decrypts them using the key synced by ESO from AWS Secrets Manager (A4).

#### A6. Terraform Variable and State Cleanup

- Remove `var.admin_password` from `variables.tf` entirely — it is no longer needed since both Argo CD and Airflow admin passwords come from SealedSecrets synced via Argo CD. Terraform has no remaining consumer of this value.
- The `tailscale_subnet_router_auth_key` variable is injected into EC2 `user_data` and thus stored in Terraform state. This is acceptable because `user_data` has `ignore_changes` lifecycle and the auth key is consumed once during boot. Document the need to rotate this key periodically.

---

### Workstream B: Terraform State & Encryption

**Goal:** Remote state with locking, KMS encryption for Kubernetes secrets.

#### B1. S3 Backend for Terraform State

- **File:** `backend.tf` (new file)
- S3 bucket for state: `${local.name}-terraform-state-<account-id>-us-east-1`.
- DynamoDB table for locking: `${local.name}-terraform-locks`.
- **Bootstrap problem:** The S3 bucket must exist before `terraform init` can use it. Two options:
  - **(Recommended)** Create the bucket and DynamoDB table in a separate "bootstrap" Terraform workspace or manually via AWS CLI. Document the procedure.
  - Use `terraform { backend "s3" {} }` with partial configuration, passing bucket/key/region via `-backend-config` flags or a `backend.tfvars` file.
- Enable bucket versioning and server-side encryption (SSE-S3 or KMS).
- Enable DynamoDB point-in-time recovery.

#### B2. KMS Encryption for EKS Secrets

- **File:** `kms.tf` (new file)
- Create a KMS key with alias `alias/${local.name}-eks-secrets`.
- Key policy: allow EKS service principal, root account, and the current caller identity to use the key.
- Add `cluster_encryption_config` to `module.eks` in `eks.tf`:

```hcl
cluster_encryption_config = {
  provider = {
    key_arn = aws_kms_key.eks_secrets.arn
  }
  resources = ["secrets"]
}
```

- KMS key should have `deletion_window_in_days = 30` and `enable_key_rotation = true`.

---

### Workstream C: Backup & Disaster Recovery

**Goal:** Automated backup of Kubernetes resources and persistent volumes.

#### C1. Velero Installation (GitOps)

- **File:** `gitops/apps/velero/` (new directory)
- Create Helm chart wrapper for Velero (`vmware-tanzu/velero`).
- Add vendored `.tgz` chart.
- Add to `gitops/root/templates/applications.yaml` as **wave 1**.
- Configuration:
  - `initContainers` with the `velero-plugin-for-aws` image.
  - `configuration.backupStorageLocation.bucket`: S3 bucket created by Terraform.
  - `configuration.volumeSnapshotLocation.config.region`: AWS region.
  - `credentials.useSecret: false` — use Pod Identity instead.

#### C2. Velero S3 Bucket and Pod Identity (Terraform)

- **File:** `velero.tf` (new file)
- S3 bucket for backups with versioning, SSE, and lifecycle policy (e.g., retain daily backups for 30 days, monthly for 365 days).
- Pod Identity module for Velero with a policy allowing S3 CRUD on the bucket and EC2 snapshot operations.
- Service account: `velero` in namespace `velero`.

#### C3. Backup Schedule (GitOps)

- **File:** `gitops/apps/velero/templates/backup-schedule.yaml` (new)
- `Schedule` resource: daily full cluster backup at 02:00 UTC, TTL 30 days.
- `Schedule` resource: hourly backup for critical namespaces (`airflow`, `argocd`), TTL 7 days.
- `VolumeSnapshotClass` resource for EBS CSI snapshots (if not already present — check `gitops/base/templates/storageclass.yaml`).

> **Note:** `VolumeSnapshotClass` requires the EBS CSI driver (already installed as an EKS addon). The CRD comes with the driver. Only the `VolumeSnapshotClass` resource itself needs to be added.

#### C4. Velero Restore Procedure (Documentation)

- Document the restore procedure: how to restore the entire cluster, a single namespace, or a single PVC in a disaster scenario.
- Add to README or a separate `docs/disaster-recovery.md`.

---

### Workstream D: Observability

**Goal:** Metrics, dashboards, log aggregation, and alerting for all platform components.

#### D1. kube-prometheus-stack (GitOps)

- **File:** `gitops/apps/kube-prometheus-stack/` (new directory)
- Helm chart wrapper for `prometheus-community/kube-prometheus-stack`.
- Add vendored `.tgz` chart.
- Add to `gitops/root/templates/applications.yaml` as **wave 2** (after core infrastructure).
- Configuration:
  - `grafana.ingress` on the internal ALB at `monitoring.<domain>`, same ALB group (`platform`).
  - `grafana.adminPassword` via SealedSecret (already convered in Workstream A).
  - `prometheus.retention: 15d` and `prometheus.retentionSize: 50GB`.
  - `alertmanager.enabled: true` — configure Slack/PagerDuty receivers post-install.
  - Enable node exporter, kube-state-metrics, and EKS-specific metrics.
  - Keep `defaultRules` enabled for out-of-the-box alerts.

#### D2. Loki for Log Aggregation (GitOps)

- **File:** `gitops/apps/loki/` (new directory)
- Helm chart wrapper for `grafana/loki` with S3 storage.
- S3 bucket for Loki chunks and index (created by Terraform).
- Pod Identity for Loki to access S3.
- Minimal configuration: single-binary mode or simple scalable mode depending on log volume.

#### D3. Promtail for Log Collection (GitOps)

- **File:** `gitops/apps/promtail/` or integrated into `loki/` chart.
- DaemonSet to collect container logs (`stdout`/`stderr`) and ship to Loki. This covers all pod-level logs automatically with no per-workload configuration.
- Configuration to exclude noisy components if needed.

**Coverage — what Promtail collects vs. what stays in S3:**

| Log type | Collected by Promtail → Loki | Reason |
|----------|------------------------------|--------|
| All pod stdout/stderr (Argo CD, ExternalDNS, LBC, Karpenter, etc.) | Yes | Default Kubernetes container logs |
| Airflow component logs (webserver, scheduler, triggerer, dag processor) | Yes | stdout/stderr |
| Spark driver/executor pod logs | Yes | stdout/stderr |
| Airflow task logs (DAG execution) | **No** → S3 only | Configured via `remote_logging` (`remote_base_log_folder: s3://.../airflow/logs`). These are written to files inside the worker pod, not stdout. Promtail does not tail in-pod files by default. |
| Spark event logs (History Server) | **No** → S3 only | Written directly to S3 by the Spark application (`spark.eventLog.dir: s3://...`). Never touches stdout. |

This split is intentional and common: **Loki** serves operational observability (is the pod running? crash loop? resource issues?), while **S3** is the long-term repository for workload-specific debugging logs (DAG task outputs, Spark job details). Both are accessible via Grafana — Loki natively, S3 logs viewable through the Airflow UI and Spark History Server UI.

If unified log aggregation in Loki is desired later, Airflow can be configured with a Loki log handler (via `elasticsearch` or a custom `airflow.utils.log` handler) and Spark can use a Loki-compatible log4j appender. This is out of scope for the initial production hardening.
#### D4. Alerting Rules

- Custom PrometheusRule resources (in `gitops/base/templates/alert-rules.yaml`):
  - **Certificate expiry:** Alert when ACM certificate expires in < 30 days.
  - **Node health:** Alert when any node is NotReady for > 5 minutes.
  - **Pod crashes:** Alert when any pod in critical namespaces is in CrashLoopBackOff.
  - **PVC usage:** Alert when PVC is > 85% full.
  - **Karpenter capacity:** Alert when NodePool CPU/memory limit is reached.
  - **Velero backup failure:** Alert when scheduled backup fails.

#### D5. ALB Access Logs

- Enable ALB access logs on an S3 bucket for the internal ALB.
- Add annotation `alb.ingress.kubernetes.io/load-balancer-attributes: access_logs.s3.enabled=true,access_logs.s3.bucket=<bucket-name>` to all Ingress resources in `gitops/base/templates/ingresses.yaml`.

#### D6. Spark History Server

- **File:** `gitops/apps/spark-history-server/` (new directory)
- Dedicated chart wrapper for the Spark History Server. This can be enabled via the existing `spark-operator` chart wrapper (the `kubeflow/spark-operator` Helm chart includes a `sparkHistoryServer` sub-chart) or installed as a standalone deployment.
- **If enabled via spark-operator wrapper:** add `sparkHistoryServer.enabled: true` and configure the UI service, S3 event log path, and ingress in `gitops/apps/spark-operator/values.yaml`.
- **If standalone:** create a separate `gitops/apps/spark-history-server/` Helm chart wrapper. Add to `gitops/root/templates/applications.yaml` as **wave 4** (alongside spark-operator and airflow).
- Configuration:
  - Ingress on the internal ALB at `spark-history.<domain>`, same ALB group (`platform`), adding a corresponding Ingress resource in `gitops/base/templates/ingresses.yaml`.
  - Event log storage in S3 (new bucket or dedicated prefix under an existing bucket).
  - Read-only S3 access via Pod Identity (new module in `pod-identity.tf` for `spark-history` service account).

- **S3 Bucket and Pod Identity (Terraform):**
  - New S3 bucket (e.g., `${local.name}-spark-events`) for Spark event logs with versioning and lifecycle policy (expire logs after 90 days).
  - New Pod Identity module `module.spark_history_pod_identity` with `s3:GetObject` and `s3:ListBucket` on the event log bucket.
  - Service account: `spark-history` in namespace `spark-history` (or `spark-operator`).
  - Spark driver pods also need `s3:PutObject` on this bucket to write event logs. Extend the existing `module.spark_workload_pod_identity` policy or create a dedicated inline policy.

- **Spark application configuration:**
  - Spark applications must be configured to write event logs to S3:
    ```
    spark.eventLog.enabled: true
    spark.eventLog.dir: s3://<bucket>/spark-events/
    ```
  - This can be set as defaults in the Spark Operator configuration or per-application via `sparkConf` in the `SparkApplication` CRD.

#### D7. OpenTelemetry Collector

- **File:** `gitops/apps/otel-collector/` (new directory)
- Helm chart wrapper for `open-telemetry/opentelemetry-collector`.
- Add to `gitops/root/templates/applications.yaml` as **wave 4** (alongside Airflow and Spark Operator — traces need to be ready when workloads start).
- Minimal deployment: `mode: deployment`, OTLP gRPC receiver on port 4317.
- Export traces to Loki's native OTLP endpoint (Loki 3.x supports OTLP ingest without Tempo).
- Loki must have OTLP ingestion enabled in its configuration (update D2):

```yaml
loki:
  limits_config:
    allow_structured_metadata: true
  otlp_config:
    enabled: true
```

- OTel Collector config:

```yaml
config:
  receivers:
    otlp:
      protocols:
        grpc:
          endpoint: 0.0.0.0:4317
  exporters:
    otlphttp:
      endpoint: http://loki.observability:3100/otlp
    debug:
      verbosity: basic
  service:
    pipelines:
      traces:
        receivers: [otlp]
        exporters: [otlphttp, debug]
```

- Traces from Airflow show: DAG task execution spans, database query durations, provider API calls (S3, Athena), and error propagation chains. Viewable in Grafana via the Loki data source (Loki 3.x serves traces as Tempo-compatible API).



---

### Workstream E: Security Hardening

**Goal:** Defense in depth — network isolation, TLS enforcement, and secure defaults.

#### E1. Ingress TLS Policy

- **File:** `gitops/base/templates/ingresses.yaml`
- Add `alb.ingress.kubernetes.io/ssl-policy: ELBSecurityPolicy-TLS13-1-2-2021-06` to enforce minimum TLS 1.2.

#### E2. AWS WAF (Optional)

- **File:** `waf.tf` (new file)
- Create WAFv2 Web ACL with AWS managed rule groups:
  - `AWSManagedRulesCommonRuleSet`
  - `AWSManagedRulesAmazonIpReputationList`
  - `AWSManagedRulesKnownBadInputsRuleSet`
- Associate WAF with the internal ALB via Ingress annotation:

```yaml
alb.ingress.kubernetes.io/wafv2-acl-arn: <waf_acl_arn>
```

- The WAF ACL ARN must flow through Terraform outputs → root Application values → base Ingress annotations.
- If WAF is too heavy for initial rollout, defer but keep the Terraform resource in the plan.

#### E3. Security Group Hardening

- **File:** `bootstrap-iam.tf`
- Current state: `aws_security_group.bootstrap` allows **all** ingress from the VPC CIDR (`cidr_blocks = [var.vpc_cidr]`). This is overly permissive even for a NAT/subnet-router.
- **Change:** Restrict ingress to only:
  - VPC private subnet CIDRs (not the entire VPC — exclude public subnets).
  - Protocol `tcp` on ports `22` (SSH from Tailscale), `443` (for EKS API calls), and protocol `-1` (all — for NAT masquerade return traffic).
  - Alternatively, keep protocol `-1` for private subnets only (NAT requires it) but add an explicit deny rule for public subnets.

- **File:** `eks.tf` (line 51-60)
- Current: EKS security group allows HTTPS from the bootstrap SG. This is correct and should remain.

#### E4. Network Policies

- **File:** `gitops/base/templates/network-policies.yaml` (new)
- Install Calico or Cilium? The EKS VPC CNI supports Kubernetes NetworkPolicies natively (since version 1.14+ with `ENABLE_NETWORK_POLICY` flag). The VPC CNI addon is already installed with prefix delegation. Enable the network policy feature:

```hcl
# In eks.tf, vpc-cni addon configuration
configuration_values = jsonencode({
  env = {
    ENABLE_PREFIX_DELEGATION = "true"
    WARM_PREFIX_TARGET       = "1"
    ENABLE_NETWORK_POLICY    = "true"
  }
})
```

- NetworkPolicy resources:
  - **Deny all** ingress by default in each namespace.
  - **Allow specific** ingress:
    - `argocd`: from ALB security group, allow 80/443; from `argocd` namespace (internal communication).
    - `airflow`: from ALB, allow 8080; from `airflow` namespace; from `spark-jobs` namespace.
    - `kubecost`: from ALB, allow 9090; from all namespaces (metrics scraping).
    - `spark-history`: from ALB, allow 18080.
    - `kube-system`: from all namespaces (DNS, metrics).
    - `karpenter`: from `kube-system` only.
  - **Egress:** allow all by default (Internet access needed for Tailscale, Git, container registries).

#### E5. EKS Cluster Endpoint Access Policy

- **File:** `eks.tf`
- Current: `endpoint_public_access = false`, `endpoint_private_access = true`. This is already correct for a private cluster.
- Add `cluster_endpoint_private_access_cidrs` — restrict access to the private endpoint to only the VPC CIDR (or specific subnets). Currently the default is `["0.0.0.0/0"]` for the private endpoint, which means any device in the VPC can reach the API. Restrict to the VPC CIDR block.

---

### Workstream F: Operational Hardening

**Goal:** High availability, resource protection, and controlled scaling.

#### F1. Pod Disruption Budgets

- **File:** `gitops/base/templates/pdbs.yaml` (new) or inline in each app chart wrapper.
- PDBs for critical components:

| Component | Type | minAvailable / maxUnavailable |
|-----------|------|------------------------------|
| Argo CD server | PDB | `maxUnavailable: 1` |
| Argo CD repo-server | PDB | `maxUnavailable: 1` |
| Argo CD redis | PDB | `maxUnavailable: 1` |
| Argo CD application-controller | PDB | `maxUnavailable: 1` |
| Airflow API server | PDB | `minAvailable: 1` |
| Airflow scheduler | PDB | `maxUnavailable: 1` |
| ExternalDNS | PDB | `maxUnavailable: 1` |
| AWS LBC | PDB | `maxUnavailable: 1` |
| Sealed Secrets | PDB | `maxUnavailable: 1` |
| Spark History Server | PDB | `maxUnavailable: 1` |

- These PDBs prevent voluntary disruptions (node drains, Karpenter consolidation) from taking down critical services.

#### F2. Resource Requests and Limits

- **File:** Various `gitops/apps/*/values.yaml` files.
- Define `resources.requests` and `resources.limits` for all components that currently lack them:

| Component | Priority | Reason |
|-----------|----------|--------|
| Argo CD (server, repo-server, controller, redis) | Critical | Without limits, application-controller can OOM or starve other pods |
| ExternalDNS | High | Lightweight but should have bounds |
| AWS LBC | High | Manages all Ingress — must not be evicted |
| Sealed Secrets | Medium | Batch workload, but secrets decryption must work |
| ESO | Medium | Syncs secrets — must be reliable |
| Karpenter | High | Node provisioning — must have guaranteed resources |
| Kubecost | Low | Cost analytics — non-critical for workload operations |
| Spark Operator | Low | Manages Spark jobs — nodes can fail, jobs retry |

- Use the Kubernetes Vertical Pod Autoscaler (VPA) in recommendation mode initially to determine appropriate values, then harden with fixed requests.

#### F3. Karpenter NodePool Tuning

- **File:** `gitops/apps/karpenter-resources/chart/templates/nodepools.yaml`
- **consolidateAfter:** Change from `1m` to `5m` for `default` and `spark` pools. 1-minute consolidation is too aggressive for production — workloads running under 60s can be interrupted.
- **terminationGracePeriod:** Add `terminationGracePeriod: 5m` to both nodepools (requires Karpenter >= 1.0). This gives pods time to drain gracefully.
- **budgets:** Add a disruption budget for the `default` NodePool:

```yaml
budgets:
  - nodes: "90%"
    reasons:
      - "Empty"
      - "Underutilized"
```

Currently only the `spark` pool has a budget. The `default` pool should also have one to prevent mass node termination.

#### F4. Bootstrap Instance HA

- **File:** `tailscale-bootstrap.tf`
- Current: single EC2 instance in `public_subnets[0]` (one AZ). This is a single point of failure for:
  - Tailscale connectivity (can't reach EKS API or ALB).
  - NAT for private subnet egress (pods can't pull images or reach the internet).
- **Options (choose one during implementation):**

  **Option 1: Auto Scaling Group with fixed count of 1, with rebalance.**
  - ASG with `min=1, max=1, desired=1`, spanning multiple public subnets.
  - The ASG replaces the instance if it fails.
  - Tailscale reconnect is automatic (auth key persists in user data).
  - Acceptance: 1-2 minutes of downtime during instance replacement.
  - This is the **simplest** option and acceptable for non-critical windows.

  **Option 2: Auto Scaling Group with 2 instances across AZs.**
  - Each instance advertises the same VPC subnet route.
  - Tailscale client routes traffic to the nearest/healthiest subnet router.
  - iptables NAT on both instances: private route tables use a weighted ECMP route or primary/secondary with health checks.
  - More complex but zero downtime.

  **Recommendation:** Start with **Option 1** (ASG, single instance, auto-recovery). Upgrade to Option 2 if SLAs require zero downtime for Tailscale connectivity.

- **Changes in Terraform:**
  - Replace `aws_instance.bootstrap` with an `aws_launch_template` + `aws_autoscaling_group`.
  - The NAT route (`aws_route.private_nat_instance`) must reference the ASG or instance dynamically. ASG doesn't expose a single ENI — options:
    - If using Option 1 (single instance), tag the ENI and reference it via a data source.
    - If using Option 2 (two instances), consider a different NAT mechanism (e.g., use the instance's primary ENI from the ASG, updating route on launch via lifecycle hook).

  - **Simpler approach:** Keep `aws_instance` but add `aws_autoscaling_group` with `min=1, max=1` as a wrapper. Or add an `aws_ec2_instance_recovery` alarm via CloudWatch for auto-recovery. This is the least invasive change.

#### F5. Log Retention Policy

- **File:** `eks.tf` or `logging.tf` (new)
- EKS control plane logs (API server, audit, authenticator, controller manager, scheduler) should have explicit CloudWatch log group retention. Default is "never expire" which accumulates costs.
- Set retention to 90 days for audit logs, 30 days for others.
- If using the EKS module's `cloudwatch_log_group_retention_in_days` parameter, set it. Otherwise, create explicit `aws_cloudwatch_log_group` resources with retention.

#### F6. Airflow Production Hardening

- **File:** `gitops/apps/airflow/values.yaml`
- **Chart:** Official Apache Airflow chart (`https://airflow.apache.org`), version 1.22.0.

**F6a. apiServer and Scheduler HA (2 replicas on different nodes)**

```yaml
airflow:
  apiServer:
    replicas: 2
    topologySpreadConstraints:
      - maxSkew: 1
        topologyKey: kubernetes.io/hostname
        whenUnsatisfiable: DoNotSchedule
        labelSelector:
          matchLabels:
            component: api-server

  scheduler:
    replicas: 2
    topologySpreadConstraints:
      - maxSkew: 1
        topologyKey: kubernetes.io/hostname
        whenUnsatisfiable: DoNotSchedule
        labelSelector:
          matchLabels:
            component: scheduler
```

- Multiple schedulers coordinate through the metadata database (Airflow 2.x+ native feature). Only one scheduler is "active" for DAG parsing; all schedulers can queue task instances. This protects against single-node failure — if the node running the active scheduler goes down, another picks up automatically.
- `DoNotSchedule` ensures each replica lands on a different node. If the cluster has fewer than 2 nodes available, the second replica stays Pending (acceptable trade-off for HA).

**F6b. StatsD for Prometheus Metrics**

The official Airflow Helm chart includes a built-in StatsD sidecar with a Prometheus exporter. Enable it in `values.yaml`:

```yaml
airflow:
  statsd:
    enabled: true
    # The chart deploys a statsd daemon + Prometheus exporter on port 9102
    # Airflow sends metrics to localhost:9125 (statsd protocol)

  config:
    metrics:
      statsd_on: "True"
      statsd_host: "localhost"
      statsd_port: "9125"
      statsd_prefix: "airflow"
```

- The built-in exporter exposes Prometheus metrics at `<pod-ip>:9102/metrics`.
- Add a `ServiceMonitor` resource in `gitops/base/templates/` (or in the Airflow wrapper chart) to tell Prometheus to scrape Airflow pods on port 9102:

```yaml
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: airflow-metrics
  namespace: airflow
spec:
  selector:
    matchLabels:
      component: statsd
  endpoints:
    - port: metrics
      interval: 30s
```

- This enables Prometheus metrics for: DAG execution duration, task success/failure rates, scheduler heartbeat, queued tasks, pool usage, and operator-specific metrics.

**F6c. OTLP for Traces**

Enable OpenTelemetry tracing in Airflow and send spans to an OTLP collector:

```yaml
airflow:
  config:
    traces:
      otel_on: "True"
      otel_host: "otel-collector.observability"  # OTel Collector service
      otel_port: "4317"
      otel_ssl_active: "False"

  extraPipPackages:
    - apache-airflow[otel]
```

**OTel Collector (new GitOps app):**

- **File:** `gitops/apps/otel-collector/` (new directory)
- Deploy the OpenTelemetry Collector (`open-telemetry/opentelemetry-collector` Helm chart) as a new app in **wave 4** (alongside Airflow).
- Minimal mode: `deployment` with OTLP gRPC receiver on port 4317, exporting traces to a backend.
- Trace backend options (choose one during implementation):
  - **Grafana Tempo** (self-hosted, aligns with existing Grafana) — recommended.
  - **Direct to Grafana Loki** (Loki 3.0+ supports natively ingesting OTLP traces).
  - **AWS X-Ray** (managed, no self-hosted component needed).

- **If using Tempo:** add a fourth GitOps app (`gitops/apps/tempo/`) for Grafana Tempo, S3 backend for trace storage, Ingress on the internal ALB.

- **If using Loki for traces:** the existing Loki instance (D2) with OTLP ingestion enabled. No additional deployment needed. Configure OTel Collector to export to Loki's OTLP endpoint.

  Recommended path: **Loki for traces** since it's already in the plan and Loki 3.x supports OTLP natively. This avoids deploying Tempo.

- **OTel Collector config (Loki backend):**

```yaml
receivers:
  otlp:
    protocols:
      grpc:
        endpoint: 0.0.0.0:4317

exporters:
  otlphttp:
    endpoint: http://loki.observability:3100/otlp

service:
  pipelines:
    traces:
      receivers: [otlp]
      exporters: [otlphttp]
```

- Tracing provides visibility into DAG task execution: span per task instance, database queries, provider API calls (S3, Athena), and cross-service propagation.

> **Note:** StatsD covers metrics (quantitative: how long? how many?); OTLP covers traces (qualitative: what happened inside each task?). Both are essential for production debugging of data pipelines.

---

### Workstream G: GitOps & Delivery Improvements

**Goal:** Pinned revisions, cleaner configuration, and correct documentation.

#### G1. Pin targetRevision

- **File:** `argocd.tf:44`
- Change `targetRevision = "master"` to a specific git tag or commit hash.
- For production, use semantic versioning tags (e.g., `v1.0.0`).
- Each infrastructure promotion (dev → staging → production) updates the tag.

#### G2. Airflow DAG Source Pinning

- **File:** `gitops/apps/airflow/values.yaml:43`
- Change `tracking_ref: master` to a specific tag or commit hash.
- The Airflow `dagBundleConfigList` should reference a stable version of DAGs.

#### G3. Kubecost Comment Fix

- **File:** `gitops/apps/kubecost/values.yaml`
- The comment on `networkCosts.enabled: true` says "Disabled for this MVP cluster" — update to reflect the actual enabled state.

#### G4. Kubecost Service Account Cleanup

- **File:** `gitops/apps/kubecost/values.yaml`
- The `extraObjects` creates a `kubecost-aws` ServiceAccount. The Pod Identity module's `associations` block also creates/references this SA. Verify no conflict. The `extraObjects` is likely redundant if Pod Identity creates the SA.

#### G5. AGENTS.md Reference Fix

- **File:** `AGENTS.md:145`
- Remove reference to non-existent `templates/argocd-root-application.yaml.tftpl`. The root Application is now rendered by `charts/argocd-root-application/`.

#### G6. README Update

- **File:** `README.md`
- Remove all references to the retired `platform/` Terraform apply target.
- Remove `helm_release` references for platform services.
- Update apply flow to reflect root-only Terraform.
- Add sections for secrets rotation, backup/restore, and monitoring access.

#### G7. Architecture Diagram Update

- **File:** `docs/architecture_diagram.py`
- Update "Platform Terraform helm_release" nodes to reflect Argo CD app-of-apps GitOps delivery.

---

## Implementation Sequence

Dependencies between workstreams dictate the rollout order. Workstreams marked as **parallel** can be implemented concurrently by different agents.

```
Phase 1 (Foundation) — in sequence:
  B1: S3 Backend for Terraform State
  B2: KMS Encryption for EKS Secrets
  E5: EKS Cluster Endpoint Access Policy

Phase 2 (Secrets) — in sequence:
  A2: ESO Pod Identity (Terraform)
  A3: Secrets Manager Secret (Terraform)
  A1: ESO GitOps App
  A4: ESO ClusterSecretStore + ExternalSecret (GitOps base)
  A5: Seal All Application Secrets

Phase 3 (Parallel — can start after Phase 2):
  C1+C2+C3: Velero Backup
  D1+D2+D3+D4+D7: Observability
  F1: Pod Disruption Budgets

Phase 4 (Parallel — independent):
  E1: Ingress TLS Policy
  E3: Security Group Hardening
  E4: Network Policies
  F2: Resource Requests/Limits
  F3: Karpenter NodePool Tuning
  F4: Bootstrap Instance HA
  F5: Log Retention Policy
  F6: Airflow Production Hardening
  D6: Spark History Server

Phase 5 (Cleanup) — in sequence:
  G1: Pin targetRevision
  G2: Airflow DAG Source Pinning
  G3+G4: Kubecost Fixes
  G5: AGENTS.md Fix
  G6: README Update
  G7: Architecture Diagram Update
```

### Recommended Implementation Order (all phases)

1. **B1 → B2 → E5.** Remote state and encryption first — these require `terraform apply` and state migration.
2. **A2 → A3 → A1 → A4 → A5.** Secrets management — Terraform creates ESO IAM and Secrets Manager secret, then GitOps deploys ESO and configures Sealed Secrets key sync, then seal all secrets.
3. **[C, D, F1] in parallel.** Backup, monitoring, and PDBs — these don't depend on each other.
4. **[E1, E3, E4, F2, F3, F4, F5, F6, D6] in parallel.** Security and operational hardening.
5. **G1 → G2 → G3+G4 → G5 → G6 → G7.** Final cleanup and documentation.

---

## Verification Checklist

After all changes are implemented, verify:

### Infrastructure
- [ ] `terraform init` works with S3 backend and DynamoDB lock
- [ ] `terraform plan` shows no destructive changes
- [ ] `terraform apply` succeeds
- [ ] EKS cluster encrypts secrets with KMS CMK
- [ ] Subnet router/NAT is reachable via Tailscale
- [ ] Private subnet egress works through NAT

### Secrets
- [ ] `aws secretsmanager get-secret-value` on Sealed Secrets key returns valid PEM
- [ ] ESO `ExternalSecret` status is `SecretSynced`
- [ ] Sealed Secrets controller uses the synced key (`kubectl logs -n sealed-secrets`)
- [ ] All `SealedSecret` resources decode successfully
- [ ] Airflow webserver starts and fernet key matches
- [ ] Argo CD admin login works via SealedSecret-based password
- [ ] No plaintext secret values in Git (`rg -n 'fernetKey\:|jwtSecret\:|apiSecretKey\:|adminPassword\:' gitops/ returns only sealed or removed references`)

### Backup
- [ ] Velero `Backup` resource completes without errors
- [ ] Velero `BackupStorageLocation` is `Available`
- [ ] Test restore of a single namespace (e.g., `airflow`) in a sandbox
- [ ] VolumeSnapshotClass exists and EBS snapshots can be created

### Monitoring
- [ ] Prometheus targets all showing UP
- [ ] Grafana accessible at `monitoring.<domain>` via Tailscale
- [ ] AlertManager or Grafana alerts firing for test conditions
- [ ] Loki receiving logs from all namespaces
- [ ] ALB access logs appear in S3
- [ ] Spark History Server accessible at `spark-history.<domain>` via Tailscale
- [ ] Spark event logs written to S3 and visible in the History Server UI
- [ ] OTel Collector receiving traces, export successful to Loki

### Security
- [ ] Ingresses reject TLS < 1.2
- [ ] Bootstrap SG does not allow public subnets CIDR
- [ ] NetworkPolicies isolating argocd, airflow, kubecost, spark-history namespaces
- [ ] EKS private endpoint restricted to VPC CIDR

### Operations
- [ ] PDBs exist for all critical components
- [ ] Resource requests/limits defined for all deployments
- [ ] Karpenter `consolidateAfter` is 5m+
- [ ] ASG for bootstrap instance recovers on failure
- [ ] CloudWatch logs have retention policy set

### Airflow Production
- [ ] Airflow apiServer running with 2 replicas on different nodes
- [ ] Airflow scheduler running with 2 replicas on different nodes
- [ ] StatsD metrics visible in Prometheus (`airflow_*` metrics)
- [ ] ServiceMonitor for Airflow statsd scraping active
- [ ] OTLP traces visible in Grafana (via Loki or Tempo)
- [ ] OTel Collector running and receiving spans from Airflow
- [ ] `EXPOSE_CONFIG` set to `non-sensitive-only` (not `true`) in production
- [ ] PostgreSQL persistence enabled (`postgresql.persistence.enabled: true`)

### Static Tests
- [ ] `rtk bash tests/platform_static_test.sh` — all pass (update tests for new resources)
- [ ] `rtk bash tests/bootstrap_static_test.sh` — all pass
- [ ] `rtk terraform fmt -check *.tf` — passes
- [ ] `rtk terraform validate` — passes

---

## Risk Assessment

| Risk | Likelihood | Impact | Mitigation |
|------|-----------|--------|------------|
| Sealed Secrets key rotation breaks all sealed secrets | Low | High | Keep old key in controller as backup during rotation window. Re-seal incrementally. |
| ESO syncing wrong key overwrites existing Sealed Secrets key | Low | Critical | Use separate Secret name for synced key, verify labels before controller picks it up. |
| Bootstrap instance ASG migration causes Tailscale disconnect | Medium | Medium | Test in a staging environment first. Keep old instance running during migration. |
| KMS key deletion blocks cluster access | Low | Critical | Key has 30-day deletion window. AWS prevents deletion of in-use keys. |
| NetworkPolicies break inter-namespace communication | Medium | High | Deploy policies in audit/log-only mode first (if supported). Apply deny rules last. |
| Karpenter consolidation interval increase causes cost increase | Medium | Low | Acceptable trade-off for stability. Monitor with Kubecost. |

---

## Out of Scope (Future Iterations)

These items are recognized as production gaps but deferred:

1. **External database for Airflow** — bundled PostgreSQL is acceptable for initial production with regular backups (Velero covers this). When metadata volume or availability requirements grow, **CloudNativePG** is the preferred alternative over RDS:
   - Runs inside the EKS cluster, managed declaratively via a `Cluster` CRD — fully GitOps-compatible.
   - Already compatible with the existing stack: uses EBS CSI driver for storage, Karpenter for node provisioning, Velero for disaster recovery.
   - Built-in backup via Barman to S3 with point-in-time recovery — no additional complexity compared to Velero-only.
   - No external AWS dependency beyond S3 for backups; accessible internally over the VPC (no public exposure).
   - Estimated footprint: ~1-2 vCPU and 2-4 GiB for Airflow metadata workloads.
2. **Multi-cluster / multi-region** — single cluster in single region is acceptable for initial production.
3. **GitOps promotion pipeline** (dev → staging → prod) — use different Git branches or Kustomize overlays for environment promotion. Out of scope for this hardening phase.
4. **AWS Shield Advanced / DDoS protection** — WAF is sufficient for initial production on an internal ALB.
5. **IRSA migration** — already using Pod Identity which is the recommended approach.
6. **Cilium/Calico CNI replacement** — VPC CNI with NetworkPolicy support is sufficient.
7. **Service Mesh (Istio/Linkerd)** — not needed for initial production.
