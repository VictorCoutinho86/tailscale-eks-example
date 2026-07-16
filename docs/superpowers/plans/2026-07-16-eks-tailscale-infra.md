# EKS Tailscale GitOps Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Refactor the stack so Terraform bootstraps private EKS access and Argo CD, while Argo CD reconciles Karpenter, Airflow, Kubecost, Spark Operator, platform RBAC, and Tailscale Services.

**Architecture:** Terraform remains responsible for AWS infrastructure, EKS addons, Karpenter AWS resources, and EKS Pod Identity roles/associations. The temporary bootstrap EC2 instance installs only Tailscale Operator and Argo CD, then applies an Argo CD root Application pointed at a Helm-based app-of-apps under `gitops/root`. AWS permissions are managed with Pod Identity; Kubernetes permissions are managed with RBAC manifests in GitOps.

**Tech Stack:** Terraform >= 1.5.7, AWS provider >= 6.52, `terraform-aws-modules/vpc/aws`, `terraform-aws-modules/eks/aws`, `terraform-aws-modules/eks-pod-identity/aws`, Amazon EKS, Tailscale Kubernetes Operator, Argo CD, Karpenter, Apache Airflow, Kubecost, Spark Operator, Diagrams.

---

## File Structure

- Modify `.gitignore`: ignore extensionless Terraform plan file `tfplan`.
- Modify `versions.tf`: add no provider unless needed; Pod Identity module is declared directly in `pod-identity.tf`.
- Modify `variables.tf`: add Argo CD/GitOps variables, Argo CD hostname, Spark workload namespace, and workload AWS ARN inputs.
- Modify `locals.tf`: add Argo CD hostname and GitOps root Application YAML rendered for bootstrap.
- Modify `eks.tf`: remove hand-written EBS CSI IAM role and let the Pod Identity module create the EBS CSI association.
- Create `pod-identity.tf`: define EBS CSI, Airflow task, and Spark workload Pod Identity modules.
- Modify `karpenter.tf`: keep AWS infrastructure and remove local Kubernetes manifest rendering that bootstrap used directly.
- Replace `platform.tf`: keep only Terraform-computed platform values if needed; Kubernetes resources move into `gitops/`.
- Modify `tailscale-bootstrap.tf`: pass only Tailscale, Argo CD, and root Application values to bootstrap.
- Replace `templates/bootstrap.sh.tftpl`: install Tailscale Operator, install Argo CD, apply root Application, and wait for readiness.
- Create `gitops/root/*`: Helm chart app-of-apps templates.
- Create `gitops/values/*`: Helm values for Airflow, Kubecost, Spark Operator, and Karpenter.
- Create `gitops/platform/*`: StorageClass, ServiceAccounts, RBAC, and Tailscale Services.
- Modify `gitops/root/templates/karpenter-resources.yaml`: add a dedicated Spark NodePool with taint-based isolation, `r` instance category, spot/on-demand capacity, and local NVMe requirement.
- Modify `outputs.tf`: add Argo CD hostname and GitOps repo/path outputs.
- Modify `README.md`: document GitOps boundary, Argo CD, Pod Identity/RBAC split, and updated validation.
- Modify `docs/architecture_diagram.py`: show Argo CD as reconciler instead of bootstrap installing every platform chart.

---

### Task 1: Terraform Inputs And Local Values

**Files:**
- Modify: `.gitignore`
- Modify: `variables.tf`
- Modify: `locals.tf`
- Modify: `outputs.tf`

- [ ] **Step 1: Add GitOps and permission variables**

Add variables for `argocd_repo_url`, `argocd_target_revision`, `argocd_path`, `argocd_tailscale_hostname`, `spark_workload_namespace`, `airflow_task_policy_statements`, and `spark_workload_policy_statements`.

- [ ] **Step 2: Add locals and outputs**

Add `local.argocd_tailscale_hostname` and render `local.argocd_root_application_yaml` with Terraform-computed Helm parameters for the root app-of-apps.

- [ ] **Step 3: Verify Terraform parsing**

Run: `rtk terraform fmt -check -recursive`

Expected: PASS after formatting.

Run: `rtk terraform validate`

Expected: may fail until later tasks add referenced modules and files; any failure must be due to missing later-task symbols only.

---

### Task 2: Pod Identity Modules

**Files:**
- Create: `pod-identity.tf`
- Modify: `eks.tf`

- [ ] **Step 1: Replace hand-written EBS CSI IAM role**

Remove `aws_iam_role.ebs_csi` and `aws_iam_role_policy_attachment.ebs_csi`. Create `module "aws_ebs_csi_pod_identity"` using `terraform-aws-modules/eks-pod-identity/aws` with `attach_aws_ebs_csi_policy = true` and association `kube-system/ebs-csi-controller-sa`.

- [ ] **Step 2: Add workload identities**

Create `module "airflow_task_pod_identity"` and `module "spark_workload_pod_identity"` with `attach_custom_policy = true`, policy statements from variables, and associations for `airflow/airflow-task` and `${var.spark_workload_namespace}/spark-workload`.

- [ ] **Step 3: Keep the EBS CSI addon association external**

Keep the `aws-ebs-csi-driver` addon enabled in `module.eks`, but do not define an inline `pod_identity_association` there. The `aws_ebs_csi_pod_identity` module creates the association after the cluster exists, avoiding a dependency cycle between the EKS module and Pod Identity module.

- [ ] **Step 4: Verify module wiring**

Run: `rtk terraform fmt -check -recursive`

Expected: PASS.

Run: `rtk terraform validate`

Expected: no references to deleted `aws_iam_role.ebs_csi` remain.

---

### Task 3: GitOps App-Of-Apps Manifests

**Files:**
- Create: `gitops/root/Chart.yaml`
- Create: `gitops/root/values.yaml`
- Create: `gitops/root/templates/*.yaml`
- Create: `gitops/values/*.yaml`
- Create: `gitops/platform/*.yaml`

- [ ] **Step 1: Create root Helm chart**

Create a minimal chart that templates child Argo CD Applications for Karpenter, Karpenter resources, Airflow, Kubecost, Spark Operator, and platform manifests.

- [ ] **Step 2: Add Helm values**

Create values files for chart configuration currently embedded in `bootstrap.sh.tftpl`: Karpenter settings, Airflow `KubernetesExecutor`, Kubecost cluster ID, and Spark Operator webhook.

- [ ] **Step 3: Add platform manifests**

Create StorageClass, ServiceAccounts, Airflow-to-Spark RBAC, Spark driver RBAC, and Tailscale Services for Argo CD, Airflow, and Kubecost.

- [ ] **Step 3a: Add Spark-exclusive Karpenter NodePool**

Create a `spark` NodePool in `gitops/root/templates/karpenter-resources.yaml` with label `workload=spark`, taint `workload=spark:NoSchedule`, requirements for instance category `r`, capacity types `spot` and `on-demand`, and `karpenter.k8s.aws/instance-local-nvme Gte ["1"]`. Document that SparkApplication driver and executor pod specs must tolerate and select this workload label.

- [ ] **Step 4: Verify YAML shape**

Run: `rtk terraform fmt -check -recursive`

Expected: PASS.

Terraform validate will not validate GitOps YAML, so inspect generated files for complete `apiVersion`, `kind`, `metadata`, and namespace fields.

---

### Task 4: Bootstrap Refactor

**Files:**
- Modify: `tailscale-bootstrap.tf`
- Replace: `templates/bootstrap.sh.tftpl`
- Modify: `platform.tf`
- Modify: `karpenter.tf`

- [ ] **Step 1: Reduce template inputs**

Pass only AWS region, cluster name/version, Tailscale Operator values, Argo CD values, and root Application YAML into `templatefile()`.

- [ ] **Step 2: Rewrite bootstrap script**

Install Helm and kubectl, install Tailscale Operator, install Argo CD, apply the Argo CD root Application, then wait for `tailscale/operator`, `argocd/argocd-server`, `argocd/argocd-application-controller`, and root Application existence.

- [ ] **Step 3: Remove direct platform installs**

Delete bootstrap commands that install Karpenter, Airflow, Kubecost, Spark Operator, StorageClass, and Airflow/Kubecost Services directly.

- [ ] **Step 4: Validate shell syntax**

Run: `rtk bash -n templates/bootstrap.sh.tftpl`

Expected: PASS.

---

### Task 5: Documentation And Diagram

**Files:**
- Modify: `README.md`
- Modify: `docs/architecture_diagram.py`
- Regenerate: `docs/architecture.png`

- [ ] **Step 1: Update README**

Document the Terraform/GitOps split, required `argocd_repo_url`, access to Argo CD via Tailscale, Pod Identity/RBAC separation, cleanup, and validation.

- [ ] **Step 2: Update diagram source**

Show bootstrap installing Tailscale Operator and Argo CD only. Show Argo CD reconciling Karpenter, Airflow, Kubecost, Spark Operator, StorageClass, RBAC, and Tailscale Services.

- [ ] **Step 3: Regenerate the diagram**

Run: `rtk uv run --script docs/architecture_diagram.py`

Expected: `docs/architecture.png` is regenerated successfully.

---

### Task 6: Verification

**Files:**
- All changed files

- [ ] **Step 1: Static validation**

Run: `rtk terraform fmt -check -recursive`

Expected: PASS.

Run: `rtk terraform validate`

Expected: PASS.

Run: `rtk bash -n templates/bootstrap.sh.tftpl`

Expected: PASS.

- [ ] **Step 2: Plan validation when credentials are available**

Run: `rtk terraform plan -out=tfplan`

Expected: PASS if AWS/Tailscale variables and permissions are available. If it fails due to missing local secrets or AWS permissions, record the exact blocker.

- [ ] **Step 3: Final review**

Run: `rtk git status`

Expected: changed files are limited to the Terraform, GitOps, docs, and plan files for this refactor. Do not commit unless explicitly requested.

---

## Self-Review

- Spec coverage: Terraform/GitOps split, Argo CD bootstrap, Pod Identity modules, Airflow/Spark RBAC split, Spark-exclusive Karpenter NodePool, documentation, diagram, and validation are covered by Tasks 1-6.
- Placeholder scan: the plan contains no unresolved placeholders; variable-driven AWS policies are intentionally inputs because concrete target AWS resources are out of scope.
- Type consistency: ServiceAccount names are consistent across Terraform and GitOps: `airflow-task`, `spark-workload`, and `ebs-csi-controller-sa`.
