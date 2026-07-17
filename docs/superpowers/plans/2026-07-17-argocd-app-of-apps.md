# Argo CD App-of-Apps Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Move Kubernetes platform service ownership from Terraform `helm_release` resources to an Argo CD app-of-apps tree bootstrapped by the persistent Tailscale EC2 instance.

**Architecture:** Root Terraform continues to own AWS resources only. The persistent Tailscale subnet router EC2 instance becomes an idempotent bootstrapper that installs Argo CD and applies a root Argo CD Application pointing at this repository. Argo CD then reconciles base Kubernetes resources and all platform services.

**Tech Stack:** Terraform, AWS EKS, Tailscale, Bash cloud-init/systemd, kubectl, Helm, Argo CD Applications, Helm charts, static shell tests.

---

## File Structure

- Modify `tests/platform_static_test.sh`: replace Terraform-Helm ownership assertions with app-of-apps, GitOps, sync-wave, hook-policy, and fixed-3-AZ assertions.
- Modify `tests/bootstrap_static_test.sh`: require bootstrap script to install/use AWS CLI, kubectl, Helm, Tailscale, systemd retry, and Argo CD root Application apply.
- Modify `locals.tf`: use exactly 3 AZs and keep `/24` subnet calculation with `cidrsubnet(var.vpc_cidr, 8, index)`.
- Modify `variables.tf`: remove `public_subnet_count`, add GitOps bootstrap inputs if needed.
- Modify `bootstrap-iam.tf`: add EKS discovery permissions to the bootstrap role.
- Modify `eks.tf`: add an EKS access entry for the bootstrap EC2 IAM role.
- Modify `tailscale-bootstrap.tf`: pass EKS, Argo CD, repo, and platform values into the bootstrap template.
- Modify `templates/bootstrap.sh.tftpl`: create an idempotent systemd-managed bootstrap flow for Tailscale route advertisement plus Argo CD/root Application bootstrap.
- Add `templates/argocd-root-application.yaml.tftpl`: Terraform-rendered root Application manifest applied by bootstrap EC2.
- Add `gitops/root/Chart.yaml`, `gitops/root/values.yaml`, `gitops/root/templates/applications.yaml`: app-of-apps Helm chart.
- Add `gitops/base/*`: namespaces, StorageClass, service accounts, RBAC, and shared ALB Ingresses.
- Add `gitops/apps/*`: values and chart metadata for Argo CD, AWS Load Balancer Controller, ExternalDNS, Karpenter, Karpenter resources, Airflow, Spark Operator, Kubecost, and Sealed Secrets.
- Move `platform/airflow-values.yaml` content to `gitops/apps/airflow/values.yaml`.
- Move `platform/charts/karpenter-resources` to `gitops/apps/karpenter-resources/chart`.
- Retire `platform/helm.tf`, `platform/kubernetes.tf`, and platform provider usage so Terraform no longer owns Kubernetes resources.
- Modify `AGENTS.md`: document the new bootstrap/app-of-apps architecture and removed platform Terraform apply flow.

---

### Task 1: Rewrite Static Tests For New Ownership Model

**Files:**
- Modify: `tests/platform_static_test.sh`
- Modify: `tests/bootstrap_static_test.sh`

- [ ] **Step 1: Update platform static test expectations first**

Replace the old `helm_release` ownership checks in `tests/platform_static_test.sh` with checks that require GitOps ownership. Keep existing helper functions and AWS/ALB/ACM/Pod Identity checks where they still apply.

Use these exact required assertions in the test:

```bash
if grep -R -q 'resource "helm_release"' platform 2>/dev/null; then
  printf 'expected platform Terraform to stop owning Helm releases\n' >&2
  exit 1
fi

if grep -R -q 'resource "kubernetes_' platform 2>/dev/null; then
  printf 'expected platform Terraform to stop owning Kubernetes resources\n' >&2
  exit 1
fi

if ! test -f gitops/root/Chart.yaml || ! test -f gitops/root/templates/applications.yaml; then
  printf 'expected gitops/root Helm chart for app-of-apps\n' >&2
  exit 1
fi

for app in base argocd aws-load-balancer-controller external-dns karpenter karpenter-resources airflow spark-operator kubecost sealed-secrets; do
  if ! grep -R -q "name: ${app}" gitops/root/templates gitops/root/values.yaml; then
    printf 'expected root app-of-apps to define %s application\n' "$app" >&2
    exit 1
  fi
done

for app_dir in base argocd aws-load-balancer-controller external-dns karpenter karpenter-resources airflow spark-operator kubecost sealed-secrets; do
  if ! test -e "gitops/apps/${app_dir}" && ! test -e "gitops/${app_dir}"; then
    printf 'expected GitOps source for %s\n' "$app_dir" >&2
    exit 1
  fi
done

if ! grep -R -q 'argocd.argoproj.io/sync-wave' gitops; then
  printf 'expected GitOps resources to use Argo CD sync waves\n' >&2
  exit 1
fi

if ! grep -R -q 'useHelmHooks: false' gitops/apps/airflow; then
  printf 'expected Airflow Helm hooks to be disabled for Argo CD safety\n' >&2
  exit 1
fi

if grep -q 'variable "public_subnet_count"' variables.tf || grep -q 'public_subnet_count' locals.tf; then
  printf 'expected public_subnet_count to be removed\n' >&2
  exit 1
fi

if ! grep -q 'slice(data.aws_availability_zones.available.names, 0, 3)' locals.tf; then
  printf 'expected exactly 3 Availability Zones\n' >&2
  exit 1
fi

if ! grep -q 'cidrsubnet(var.vpc_cidr, 8, index)' locals.tf; then
  printf 'expected /24 public subnet calculation with cidrsubnet newbits 8\n' >&2
  exit 1
fi
```

- [ ] **Step 2: Update bootstrap static test expectations first**

In `tests/bootstrap_static_test.sh`, require the bootstrap template to contain the new bootstrap mechanisms:

```bash
bootstrap="templates/bootstrap.sh.tftpl"

for expected in \
  'tailscale up' \
  'aws eks update-kubeconfig' \
  'helm upgrade --install argocd' \
  'kubectl apply' \
  'argocd-bootstrap.service' \
  'argocd-bootstrap.timer' \
  'systemctl enable --now argocd-bootstrap.timer'; do
  if ! grep -q "$expected" "$bootstrap"; then
    printf 'expected bootstrap template to contain %s\n' "$expected" >&2
    exit 1
  fi
done

for expected in \
  'set -euo pipefail' \
  'until aws eks describe-cluster' \
  'until kubectl get namespace kube-system' \
  'creates=/var/lib/argocd-bootstrap/succeeded'; do
  if ! grep -q "$expected" "$bootstrap"; then
    printf 'expected idempotent/retryable bootstrap behavior %s\n' "$expected" >&2
    exit 1
  fi
done
```

- [ ] **Step 3: Run tests and verify they fail**

Run:

```bash
rtk bash tests/platform_static_test.sh
rtk bash tests/bootstrap_static_test.sh
```

Expected: both fail because GitOps files and bootstrap logic do not exist yet.

- [ ] **Step 4: Commit failing tests**

Run only if commits are allowed in the execution session:

```bash
git add tests/platform_static_test.sh tests/bootstrap_static_test.sh
git commit -m "test: expect argocd app-of-apps platform ownership"
```

---

### Task 2: Fix Network AZ Contract

**Files:**
- Modify: `locals.tf`
- Modify: `variables.tf`

- [ ] **Step 1: Remove configurable AZ variable**

Delete this block from `variables.tf`:

```hcl
variable "public_subnet_count" {
  description = "Number of public subnets and Availability Zones to use."
  type        = number
  default     = 3

  validation {
    condition     = var.public_subnet_count >= 2 && var.public_subnet_count <= 6
    error_message = "public_subnet_count must be between 2 and 6."
  }
}
```

- [ ] **Step 2: Pin locals to 3 AZs**

In `locals.tf`, replace the AZ and subnet locals with:

```hcl
locals {
  name = var.name

  azs = slice(data.aws_availability_zones.available.names, 0, 3)

  public_subnets = [
    for index, _ in local.azs : cidrsubnet(var.vpc_cidr, 8, index)
  ]

  tailscale_subnet_router_hostname = "${local.name}-subnet-router"

  tags = merge(
    {
      Project     = local.name
      Environment = var.environment
      Terraform   = "true"
    },
    var.tags
  )
}
```

- [ ] **Step 3: Update AZ precondition**

Replace `terraform_data.availability_zone_count` with:

```hcl
resource "terraform_data" "availability_zone_count" {
  input = length(data.aws_availability_zones.available.names)

  lifecycle {
    precondition {
      condition     = length(data.aws_availability_zones.available.names) >= 3
      error_message = "The selected AWS region must have at least 3 available Availability Zones."
    }
  }
}
```

- [ ] **Step 4: Run network-related tests**

Run:

```bash
rtk bash tests/platform_static_test.sh
rtk terraform fmt -check *.tf
rtk terraform validate
```

Expected: platform static test still fails on missing GitOps files; Terraform fmt/validate pass after formatting.

- [ ] **Step 5: Commit network change**

Run only if commits are allowed in the execution session:

```bash
git add locals.tf variables.tf tests/platform_static_test.sh
git commit -m "feat: pin vpc subnets to three azs"
```

---

### Task 3: Grant Bootstrap EC2 Cluster Bootstrap Access

**Files:**
- Modify: `bootstrap-iam.tf`
- Modify: `eks.tf`

- [ ] **Step 1: Add EKS describe permissions to bootstrap role**

In `bootstrap-iam.tf`, add an IAM role policy for the bootstrap role. Use the existing bootstrap role resource name in the file; if it is `aws_iam_role.bootstrap`, add:

```hcl
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
```

- [ ] **Step 2: Add EKS access entry for bootstrap role**

In `eks.tf`, add a second access entry under `module "eks"` `access_entries`:

```hcl
    bootstrap_instance = {
      principal_arn = aws_iam_role.bootstrap.arn
      policy_associations = {
        admin = {
          policy_arn = "arn:${data.aws_partition.current.partition}:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"
          access_scope = {
            type = "cluster"
          }
        }
      }
    }
```

Keep the existing `current_caller` access entry unchanged.

- [ ] **Step 3: Validate Terraform**

Run:

```bash
rtk terraform fmt -check *.tf
rtk terraform validate
```

Expected: both pass.

- [ ] **Step 4: Commit IAM/access change**

Run only if commits are allowed in the execution session:

```bash
git add bootstrap-iam.tf eks.tf
git commit -m "feat: allow bootstrap instance to install argocd"
```

---

### Task 4: Add Terraform-Rendered Root Application Template

**Files:**
- Add: `templates/argocd-root-application.yaml.tftpl`
- Modify: `tailscale-bootstrap.tf`

- [ ] **Step 1: Create root Application template**

Create `templates/argocd-root-application.yaml.tftpl` with:

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: platform-root
  namespace: argocd
  labels:
    app.kubernetes.io/part-of: platform
spec:
  project: default
  source:
    repoURL: ${repo_url}
    targetRevision: ${target_revision}
    path: gitops/root
    helm:
      parameters:
        - name: global.repoURL
          value: ${repo_url}
        - name: global.targetRevision
          value: ${target_revision}
        - name: global.clusterName
          value: ${cluster_name}
        - name: global.awsRegion
          value: ${aws_region}
        - name: global.vpcId
          value: ${vpc_id}
        - name: global.domain
          value: ${domain}
        - name: global.certificateArn
          value: ${certificate_arn}
        - name: global.karpenterQueueName
          value: ${karpenter_queue_name}
        - name: global.karpenterNodeRoleName
          value: ${karpenter_node_role_name}
        - name: global.sparkWorkloadNamespace
          value: ${spark_workload_namespace}
  destination:
    server: https://kubernetes.default.svc
    namespace: argocd
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
```

- [ ] **Step 2: Add bootstrap variables in `tailscale-bootstrap.tf` templatefile call**

Modify the `user_data` templatefile map so it includes:

```hcl
    cluster_name              = module.eks.cluster_name
    aws_region                = var.aws_region
    argocd_chart_version      = "8.5.7"
    gitops_repo_url           = "https://github.com/VictorCoutinho86/tailscale-eks-example.git"
    gitops_target_revision    = "master"
    route53_domain_name       = trimsuffix(var.route53_domain_name, ".")
    platform_certificate_arn  = aws_acm_certificate_validation.platform.certificate_arn
    karpenter_queue_name      = module.karpenter.queue_name
    karpenter_node_role_name  = module.karpenter.node_iam_role_name
    spark_workload_namespace  = var.spark_workload_namespace
    argocd_root_application = templatefile("${path.module}/templates/argocd-root-application.yaml.tftpl", {
      repo_url                  = "https://github.com/VictorCoutinho86/tailscale-eks-example.git"
      target_revision           = "master"
      cluster_name              = module.eks.cluster_name
      aws_region                = var.aws_region
      vpc_id                    = module.vpc.vpc_id
      domain                    = trimsuffix(var.route53_domain_name, ".")
      certificate_arn           = aws_acm_certificate_validation.platform.certificate_arn
      karpenter_queue_name      = module.karpenter.queue_name
      karpenter_node_role_name  = module.karpenter.node_iam_role_name
      spark_workload_namespace  = var.spark_workload_namespace
    })
```

- [ ] **Step 3: Validate template syntax**

Run:

```bash
rtk terraform fmt -check *.tf
rtk terraform validate
```

Expected: Terraform validates the new template references.

- [ ] **Step 4: Commit root Application template**

Run only if commits are allowed in the execution session:

```bash
git add templates/argocd-root-application.yaml.tftpl tailscale-bootstrap.tf
git commit -m "feat: render argocd root application for bootstrap"
```

---

### Task 5: Make Bootstrap Script Idempotent And Retryable

**Files:**
- Modify: `templates/bootstrap.sh.tftpl`

- [ ] **Step 1: Replace linear bootstrap with systemd-managed script**

Preserve existing Tailscale install logic, then add a bootstrap script at `/usr/local/bin/argocd-bootstrap.sh` with this shape:

```bash
#!/usr/bin/env bash
set -euo pipefail

STATE_DIR=/var/lib/argocd-bootstrap
SUCCESS_FILE="$STATE_DIR/succeeded"
ROOT_APP="$STATE_DIR/root-application.yaml"

mkdir -p "$STATE_DIR"

if [[ -f "$SUCCESS_FILE" ]]; then
  exit 0
fi

install_tools() {
  if ! command -v aws >/dev/null 2>&1; then
    yum install -y awscli
  fi

  if ! command -v kubectl >/dev/null 2>&1; then
    curl -fsSL -o /usr/local/bin/kubectl "https://dl.k8s.io/release/$(curl -fsSL https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
    chmod +x /usr/local/bin/kubectl
  fi

  if ! command -v helm >/dev/null 2>&1; then
    curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
  fi
}

wait_for_cluster() {
  until aws eks describe-cluster --region "${aws_region}" --name "${cluster_name}" >/dev/null 2>&1; do
    sleep 30
  done

  aws eks update-kubeconfig --region "${aws_region}" --name "${cluster_name}"

  until kubectl get namespace kube-system >/dev/null 2>&1; do
    sleep 30
  done
}

install_argocd() {
  kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f -
  helm repo add argo https://argoproj.github.io/argo-helm
  helm repo update argo
  helm upgrade --install argocd argo/argo-cd \
    --namespace argocd \
    --version "${argocd_chart_version}" \
    --set server.service.type=ClusterIP \
    --set configs.params.server\.insecure=true \
    --wait \
    --timeout 10m
}

apply_root_application() {
  cat > "$ROOT_APP" <<'ROOT_APPLICATION'
${argocd_root_application}
ROOT_APPLICATION
  kubectl apply -f "$ROOT_APP"
}

install_tools
wait_for_cluster
install_argocd
apply_root_application
touch "$SUCCESS_FILE"
```

- [ ] **Step 2: Add systemd unit and timer**

In the same template, add:

```bash
cat >/etc/systemd/system/argocd-bootstrap.service <<'EOF'
[Unit]
Description=Bootstrap Argo CD app-of-apps
After=network-online.target tailscaled.service
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/argocd-bootstrap.sh
EOF

cat >/etc/systemd/system/argocd-bootstrap.timer <<'EOF'
[Unit]
Description=Retry Argo CD bootstrap until it succeeds

[Timer]
OnBootSec=2min
OnUnitInactiveSec=5min
Unit=argocd-bootstrap.service

[Install]
WantedBy=timers.target
EOF

systemctl daemon-reload
systemctl enable --now argocd-bootstrap.timer
```

- [ ] **Step 3: Run bootstrap tests**

Run:

```bash
rtk bash -n templates/bootstrap.sh.tftpl
rtk bash tests/bootstrap_static_test.sh
```

Expected: syntax check and bootstrap static test pass.

- [ ] **Step 4: Commit bootstrap script change**

Run only if commits are allowed in the execution session:

```bash
git add templates/bootstrap.sh.tftpl tests/bootstrap_static_test.sh
git commit -m "feat: bootstrap argocd from subnet router"
```

---

### Task 6: Add App-of-Apps Root Helm Chart

**Files:**
- Add: `gitops/root/Chart.yaml`
- Add: `gitops/root/values.yaml`
- Add: `gitops/root/templates/applications.yaml`

- [ ] **Step 1: Create root chart metadata**

Create `gitops/root/Chart.yaml`:

```yaml
apiVersion: v2
name: platform-root
description: Argo CD app-of-apps root for platform services
type: application
version: 0.1.0
appVersion: "0.1.0"
```

- [ ] **Step 2: Create root chart values**

Create `gitops/root/values.yaml`:

```yaml
global:
  repoURL: https://github.com/VictorCoutinho86/tailscale-eks-example.git
  targetRevision: master
  clusterName: tailscale-eks-example
  awsRegion: us-east-1
  vpcId: vpc-00000000000000000
  domain: example.com
  certificateArn: arn:aws:acm:us-east-1:000000000000:certificate/00000000-0000-0000-0000-000000000000
  karpenterQueueName: tailscale-eks-example
  karpenterNodeRoleName: tailscale-eks-example-karpenter
  sparkWorkloadNamespace: spark-jobs
```

- [ ] **Step 3: Create Applications template**

Create `gitops/root/templates/applications.yaml` with one Application per item:

```yaml
{{- $repoURL := .Values.global.repoURL -}}
{{- $targetRevision := .Values.global.targetRevision -}}
{{- $apps := list
  (dict "name" "base" "path" "gitops/base" "namespace" "argocd" "wave" "0")
  (dict "name" "aws-load-balancer-controller" "path" "gitops/apps/aws-load-balancer-controller" "namespace" "kube-system" "wave" "1")
  (dict "name" "external-dns" "path" "gitops/apps/external-dns" "namespace" "kube-system" "wave" "1")
  (dict "name" "sealed-secrets" "path" "gitops/apps/sealed-secrets" "namespace" "sealed-secrets" "wave" "1")
  (dict "name" "argocd" "path" "gitops/apps/argocd" "namespace" "argocd" "wave" "2")
  (dict "name" "karpenter" "path" "gitops/apps/karpenter" "namespace" "karpenter" "wave" "2")
  (dict "name" "karpenter-resources" "path" "gitops/apps/karpenter-resources/chart" "namespace" "karpenter" "wave" "3")
  (dict "name" "airflow" "path" "gitops/apps/airflow" "namespace" "airflow" "wave" "4")
  (dict "name" "spark-operator" "path" "gitops/apps/spark-operator" "namespace" "spark-operator" "wave" "4")
  (dict "name" "kubecost" "path" "gitops/apps/kubecost" "namespace" "kubecost" "wave" "4")
-}}
{{- range $app := $apps }}
---
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: {{ $app.name }}
  namespace: argocd
  labels:
    app.kubernetes.io/part-of: platform
  annotations:
    argocd.argoproj.io/sync-wave: {{ $app.wave | quote }}
spec:
  project: default
  source:
    repoURL: {{ $repoURL | quote }}
    targetRevision: {{ $targetRevision | quote }}
    path: {{ $app.path | quote }}
    helm:
      values: |
        global:
{{ toYaml $.Values.global | indent 10 }}
{{ if eq $app.name "aws-load-balancer-controller" }}
        aws-load-balancer-controller:
          clusterName: {{ $.Values.global.clusterName | quote }}
          region: {{ $.Values.global.awsRegion | quote }}
          vpcId: {{ $.Values.global.vpcId | quote }}
          serviceAccount:
            create: false
            name: aws-load-balancer-controller
{{ else if eq $app.name "external-dns" }}
        external-dns:
          provider:
            name: aws
          serviceAccount:
            create: false
            name: external-dns
          policy: upsert-only
          registry: txt
          txtOwnerId: {{ $.Values.global.clusterName | quote }}
          domainFilters:
            - {{ $.Values.global.domain | quote }}
          extraArgs:
            aws-zone-type: public
{{ else if eq $app.name "karpenter" }}
        karpenter:
          settings:
            clusterName: {{ $.Values.global.clusterName | quote }}
            interruptionQueue: {{ $.Values.global.karpenterQueueName | quote }}
{{ else if eq $app.name "karpenter-resources" }}
        clusterName: {{ $.Values.global.clusterName | quote }}
        nodeRoleName: {{ $.Values.global.karpenterNodeRoleName | quote }}
        sparkNodeLabels:
          workload: spark
{{ else if eq $app.name "kubecost" }}
        cost-analyzer:
          global:
            clusterId: {{ $.Values.global.clusterName | quote }}
          prometheus:
            server:
              global:
                external_labels:
                  cluster_id: {{ $.Values.global.clusterName | quote }}
{{ end }}
  destination:
    server: https://kubernetes.default.svc
    namespace: {{ $app.namespace | quote }}
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
{{- end }}
```

- [ ] **Step 4: Render root chart**

Run:

```bash
rtk helm template platform-root gitops/root
```

Expected: output contains 10 `kind: Application` manifests.

- [ ] **Step 5: Commit root chart**

Run only if commits are allowed in the execution session:

```bash
git add gitops/root
git commit -m "feat: add argocd app-of-apps root chart"
```

---

### Task 7: Add Base GitOps Chart

**Files:**
- Add: `gitops/base/Chart.yaml`
- Add: `gitops/base/values.yaml`
- Add: `gitops/base/templates/namespaces.yaml`
- Add: `gitops/base/templates/storageclass.yaml`
- Add: `gitops/base/templates/serviceaccounts.yaml`
- Add: `gitops/base/templates/rbac.yaml`
- Add: `gitops/base/templates/ingresses.yaml`

- [ ] **Step 1: Create base chart metadata and values**

Create `gitops/base/Chart.yaml`:

```yaml
apiVersion: v2
name: platform-base
description: Shared platform namespaces, RBAC, storage, and ingresses
type: application
version: 0.1.0
appVersion: "0.1.0"
```

Create `gitops/base/values.yaml`:

```yaml
global:
  domain: example.com
  certificateArn: arn:aws:acm:us-east-1:000000000000:certificate/00000000-0000-0000-0000-000000000000
  sparkWorkloadNamespace: spark-jobs
```

- [ ] **Step 2: Create namespaces template**

Create `gitops/base/templates/namespaces.yaml`:

```yaml
{{- range $namespace := list "argocd" "airflow" "kubecost" "spark-operator" .Values.global.sparkWorkloadNamespace "karpenter" "sealed-secrets" }}
---
apiVersion: v1
kind: Namespace
metadata:
  name: {{ $namespace | quote }}
  annotations:
    argocd.argoproj.io/sync-wave: "0"
{{- end }}
```

- [ ] **Step 3: Create StorageClass template**

Create `gitops/base/templates/storageclass.yaml`:

```yaml
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: gp3
  annotations:
    storageclass.kubernetes.io/is-default-class: "true"
    argocd.argoproj.io/sync-wave: "0"
provisioner: ebs.csi.aws.com
volumeBindingMode: WaitForFirstConsumer
allowVolumeExpansion: true
parameters:
  type: gp3
  encrypted: "true"
```

- [ ] **Step 4: Create service accounts template**

Create `gitops/base/templates/serviceaccounts.yaml`:

```yaml
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: aws-load-balancer-controller
  namespace: kube-system
  annotations:
    argocd.argoproj.io/sync-wave: "0"
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: external-dns
  namespace: kube-system
  annotations:
    argocd.argoproj.io/sync-wave: "0"
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: airflow-task
  namespace: airflow
  annotations:
    argocd.argoproj.io/sync-wave: "0"
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: spark-workload
  namespace: {{ .Values.global.sparkWorkloadNamespace | quote }}
  annotations:
    argocd.argoproj.io/sync-wave: "0"
```

- [ ] **Step 5: Create RBAC template**

Create `gitops/base/templates/rbac.yaml` by translating the existing `platform/kubernetes.tf` Airflow/Spark Role and RoleBinding resources into YAML. Include these exact API groups and resources:

```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: airflow-spark-access
  namespace: {{ .Values.global.sparkWorkloadNamespace | quote }}
  annotations:
    argocd.argoproj.io/sync-wave: "0"
rules:
  - apiGroups: ["sparkoperator.k8s.io"]
    resources: ["sparkapplications", "sparkapplications/status"]
    verbs: ["create", "get", "list", "watch", "patch", "delete"]
  - apiGroups: [""]
    resources: ["pods"]
    verbs: ["get", "list", "watch"]
  - apiGroups: [""]
    resources: ["pods/log"]
    verbs: ["get"]
  - apiGroups: [""]
    resources: ["events"]
    verbs: ["get", "list", "watch"]
```

Also include the `airflow-spark-access` RoleBinding, `spark-driver` Role, and `spark-driver` RoleBinding from `platform/kubernetes.tf` with the same verbs and subjects.

- [ ] **Step 6: Create Ingresses template**

Create `gitops/base/templates/ingresses.yaml` with three Ingresses for Argo CD, Airflow, and Kubecost. Use this exact annotation set for each:

```yaml
alb.ingress.kubernetes.io/scheme: internal
alb.ingress.kubernetes.io/target-type: ip
alb.ingress.kubernetes.io/group.name: platform
alb.ingress.kubernetes.io/listen-ports: '[{"HTTP":80},{"HTTPS":443}]'
alb.ingress.kubernetes.io/ssl-redirect: "443"
alb.ingress.kubernetes.io/certificate-arn: {{ .Values.global.certificateArn | quote }}
external-dns.alpha.kubernetes.io/hostname: {{ printf "argocd.%s" .Values.global.domain | quote }}
argocd.argoproj.io/sync-wave: "4"
```

Use service backends:

```yaml
argocd: service argocd-server port 80
airflow: service airflow-api-server port 8080
kubecost: service kubecost-cost-analyzer port 9090
```

- [ ] **Step 7: Render base chart**

Run:

```bash
rtk helm template platform-base gitops/base
```

Expected: output contains Namespace, StorageClass, ServiceAccount, Role, RoleBinding, and Ingress manifests.

- [ ] **Step 8: Commit base chart**

Run only if commits are allowed in the execution session:

```bash
git add gitops/base
git commit -m "feat: add gitops platform base resources"
```

---

### Task 8: Add Service GitOps Charts And Values

**Files:**
- Add: `gitops/apps/argocd/Chart.yaml`, `gitops/apps/argocd/values.yaml`
- Add: `gitops/apps/aws-load-balancer-controller/Chart.yaml`, `gitops/apps/aws-load-balancer-controller/values.yaml`
- Add: `gitops/apps/external-dns/Chart.yaml`, `gitops/apps/external-dns/values.yaml`
- Add: `gitops/apps/karpenter/Chart.yaml`, `gitops/apps/karpenter/values.yaml`
- Add: `gitops/apps/airflow/Chart.yaml`, `gitops/apps/airflow/values.yaml`
- Add: `gitops/apps/spark-operator/Chart.yaml`, `gitops/apps/spark-operator/values.yaml`
- Add: `gitops/apps/kubecost/Chart.yaml`, `gitops/apps/kubecost/values.yaml`
- Add: `gitops/apps/sealed-secrets/Chart.yaml`, `gitops/apps/sealed-secrets/values.yaml`
- Move: `platform/charts/karpenter-resources` to `gitops/apps/karpenter-resources/chart`

- [ ] **Step 1: Create dependency chart wrappers**

For each third-party service, create a small Helm chart with dependency metadata.

Example for `gitops/apps/argocd/Chart.yaml`:

```yaml
apiVersion: v2
name: argocd-platform
description: Platform-managed Argo CD
type: application
version: 0.1.0
dependencies:
  - name: argo-cd
    version: 8.5.7
    repository: https://argoproj.github.io/argo-helm
```

Use these dependencies:

```yaml
aws-load-balancer-controller: repository https://aws.github.io/eks-charts, chart aws-load-balancer-controller, version 1.13.0
external-dns: repository https://kubernetes-sigs.github.io/external-dns, chart external-dns, version 1.19.0
karpenter: repository oci://public.ecr.aws/karpenter, chart karpenter, version 1.13.0
airflow: repository https://airflow.apache.org, chart airflow, version 1.22.0
spark-operator: repository https://kubeflow.github.io/spark-operator, chart spark-operator, version 2.5.1
kubecost: repository https://kubecost.github.io/cost-analyzer, chart cost-analyzer, version 2.8.7
sealed-secrets: repository https://bitnami-labs.github.io/sealed-secrets, chart sealed-secrets, version 2.17.7
```

- [ ] **Step 2: Create Argo CD values**

Create `gitops/apps/argocd/values.yaml`:

```yaml
argo-cd:
  server:
    service:
      type: ClusterIP
  configs:
    params:
      server.insecure: true
```

- [ ] **Step 3: Create AWS Load Balancer Controller values**

Create `gitops/apps/aws-load-balancer-controller/values.yaml` with static service account ownership only. Cluster-specific values are injected by `gitops/root/templates/applications.yaml`.

```yaml
aws-load-balancer-controller:
  serviceAccount:
    create: false
    name: aws-load-balancer-controller
```

- [ ] **Step 4: Create ExternalDNS values**

Create `gitops/apps/external-dns/values.yaml` with static values. Cluster-specific `txtOwnerId` and `domainFilters` are injected by the root Application.

```yaml
external-dns:
  provider:
    name: aws
  serviceAccount:
    create: false
    name: external-dns
  policy: upsert-only
  registry: txt
  extraArgs:
    aws-zone-type: public
```

- [ ] **Step 5: Create Karpenter values**

Create `gitops/apps/karpenter/values.yaml`. Cluster-specific Karpenter settings are injected by the root Application.

```yaml
karpenter: {}
```

- [ ] **Step 6: Move Airflow values**

Move `platform/airflow-values.yaml` to `gitops/apps/airflow/values.yaml`, nesting it under the dependency key `airflow:`. Preserve the current hook-safe block:

```yaml
airflow:
  createUserJob:
    useHelmHooks: false
    applyCustomEnv: false
  migrateDatabaseJob:
    useHelmHooks: false
    applyCustomEnv: false
    jobAnnotations:
      argocd.argoproj.io/hook: Sync
```

- [ ] **Step 7: Create Spark Operator values**

Create `gitops/apps/spark-operator/values.yaml`:

```yaml
spark-operator:
  webhook:
    enable: true
```

- [ ] **Step 8: Create Kubecost values**

Create `gitops/apps/kubecost/values.yaml`. Cluster ID settings are injected by the root Application.

```yaml
cost-analyzer: {}
```

- [ ] **Step 9: Create Sealed Secrets values**

Create `gitops/apps/sealed-secrets/values.yaml`:

```yaml
sealed-secrets:
  fullnameOverride: sealed-secrets-controller
```

- [ ] **Step 10: Move Karpenter resources chart**

Move `platform/charts/karpenter-resources` to `gitops/apps/karpenter-resources/chart`. Keep static defaults in `gitops/apps/karpenter-resources/chart/values.yaml`; cluster-specific values are injected by the root Application.

```yaml
clusterName: tailscale-eks-example
nodeRoleName: tailscale-eks-example-karpenter
sparkNodeLabels:
  workload: spark
```

- [ ] **Step 11: Render dependency charts**

Run:

```bash
rtk helm dependency build gitops/apps/argocd
rtk helm dependency build gitops/apps/aws-load-balancer-controller
rtk helm dependency build gitops/apps/external-dns
rtk helm dependency build gitops/apps/karpenter
rtk helm dependency build gitops/apps/airflow
rtk helm dependency build gitops/apps/spark-operator
rtk helm dependency build gitops/apps/kubecost
rtk helm dependency build gitops/apps/sealed-secrets
rtk helm template platform-root gitops/root | rg 'clusterName|domainFilters|interruptionQueue|nodeRoleName'
rtk helm template airflow gitops/apps/airflow | rg 'argocd.argoproj.io/hook'
```

Expected: dependencies build, root render shows dynamic values in child Applications, and Airflow render shows the Argo hook annotation for the migration job.

- [ ] **Step 12: Commit service charts**

Run only if commits are allowed in the execution session:

```bash
git add gitops/apps platform/airflow-values.yaml platform/charts/karpenter-resources
git commit -m "feat: add gitops platform service charts"
```

---

### Task 9: Retire Platform Terraform Ownership

**Files:**
- Delete or empty ownership resources: `platform/helm.tf`
- Delete or empty ownership resources: `platform/kubernetes.tf`
- Modify or delete: `platform/providers.tf`, `platform/variables.tf`, `platform/locals.tf`, `platform/versions.tf`
- Modify: `AGENTS.md`

- [ ] **Step 1: Remove platform Helm and Kubernetes resources**

Delete `platform/helm.tf` and `platform/kubernetes.tf`, or leave files with comments only if needed for historical context. The static test must not find `resource "helm_release"` or `resource "kubernetes_` under `platform/`.

- [ ] **Step 2: Remove obsolete platform provider requirements**

If `platform/` no longer has Terraform resources, remove Kubernetes and Helm providers from `platform/versions.tf` and `platform/providers.tf`, or delete the platform Terraform application entirely. Keep no apply flow that can create Kubernetes resources.

- [ ] **Step 3: Update AGENTS.md architecture notes**

Replace the old statements:

```markdown
- `platform/` is a separate Terraform application that installs Kubernetes platform services with `helm_release`.
- Argo CD remains installed as a platform service, but no longer owns the platform through a GitOps app-of-apps chart.
```

with:

```markdown
- Kubernetes platform services are installed by Argo CD through the app-of-apps tree under `gitops/root`.
- The persistent Tailscale subnet router EC2 instance bootstraps Argo CD and applies the root Application.
- `platform/` is retired as an apply target and must not own Helm releases or Kubernetes resources.
```

Update the apply flow to remove `terraform -chdir=platform apply` and describe waiting for the bootstrap EC2/Argo CD sync instead.

- [ ] **Step 4: Run static tests**

Run:

```bash
rtk bash tests/platform_static_test.sh
```

Expected: pass after GitOps files exist and platform ownership is retired.

- [ ] **Step 5: Commit platform retirement**

Run only if commits are allowed in the execution session:

```bash
git add platform AGENTS.md tests/platform_static_test.sh
git commit -m "refactor: retire platform terraform ownership"
```

---

### Task 10: Final Validation And Documentation Pass

**Files:**
- Modify: `outputs.tf` if output descriptions mention platform Terraform consumption
- Modify: `docs/architecture_diagram.py` if it still shows platform Terraform as Helm owner
- Regenerate: `docs/architecture.png` if diagram source changes

- [ ] **Step 1: Update stale output/docs references**

Search for stale platform Terraform ownership text:

```bash
rtk rg 'platform Terraform|helm_release|app-of-apps.*removed|Argo CD root app-of-apps under `gitops/root/`|terraform -chdir=platform apply' .
```

Replace stale references with the new architecture. Keep historical specs unchanged under `docs/superpowers/specs/2026-07-16-*` unless they are used as current operational docs.

- [ ] **Step 2: Run full validation**

Run:

```bash
rtk bash -n tests/platform_static_test.sh
rtk bash -n tests/bootstrap_static_test.sh
rtk bash -n templates/bootstrap.sh.tftpl
rtk bash tests/platform_static_test.sh
rtk bash tests/bootstrap_static_test.sh
rtk terraform fmt -check *.tf
rtk terraform validate
rtk helm template platform-root gitops/root
rtk helm template platform-base gitops/base
```

Expected: all commands pass.

- [ ] **Step 3: Inspect final diff**

Run:

```bash
rtk git status --short
rtk git diff --check
rtk git diff --stat
```

Expected: only intended files changed; `git diff --check` passes.

- [ ] **Step 4: Commit final docs/validation fixes**

Run only if commits are allowed in the execution session:

```bash
git add outputs.tf docs AGENTS.md tests templates gitops locals.tf variables.tf bootstrap-iam.tf eks.tf tailscale-bootstrap.tf platform
git commit -m "docs: align architecture with argocd app-of-apps"
```

---

## Self-Review Notes

- Spec coverage: tasks cover bootstrap EC2, app-of-apps root, all listed services, safe hook policy, 3 fixed AZs, platform Terraform retirement, tests, and docs.
- No implementation task should reintroduce the Tailscale Kubernetes Operator, Tailscale API server proxy, or root Terraform Kubernetes/Helm providers.
- Dynamic cluster-specific chart values are injected by the root app-of-apps template, not by templating child `values.yaml` files.
