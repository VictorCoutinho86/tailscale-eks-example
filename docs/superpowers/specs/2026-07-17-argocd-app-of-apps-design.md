# Argo CD App-of-Apps Platform Design

## Context

The repository currently provisions AWS infrastructure in the root Terraform application and installs Kubernetes platform services from the separate `platform/` Terraform application with `helm_release` resources. This design intentionally changes that ownership model: Argo CD becomes the reconciler for all Kubernetes platform services through an app-of-apps pattern.

The private EKS API endpoint and internal platform ALB remain accessible through the persistent Tailscale subnet router EC2 instance. The Tailscale Kubernetes Operator, Tailscale API server proxy, and Tailscale load balancer service path remain out of scope.

## Goals

- Bootstrap Argo CD from the existing persistent Tailscale subnet router EC2 instance.
- Use an Argo CD root Application in this repository to create child Applications for every platform service.
- Move platform service ownership from Terraform `helm_release` resources to Argo CD Applications.
- Install and reconcile these services through Argo CD: Argo CD, AWS Load Balancer Controller, ExternalDNS, Karpenter, Karpenter resources, Airflow, Spark Operator, Kubecost, and Sealed Secrets.
- Handle chart hook behavior explicitly so known hook-sensitive charts do not leave Argo CD syncs stuck or unhealthy.
- Fix the VPC subnet layout to 3 Availability Zones and remove the configurable AZ count.

## Non-Goals

- Reintroduce the Tailscale Kubernetes Operator or API server proxy.
- Use root Terraform Kubernetes or Helm providers.
- Depend on a separate GitOps repository for this MVP.
- Make the number of AZs configurable.
- Preserve the current `platform/` Terraform Helm release ownership model.

## Architecture

Root Terraform remains responsible for AWS infrastructure: VPC, public subnets, private-only EKS, IAM roles and Pod Identity roles, ACM, Route 53 records for certificate validation, Karpenter AWS resources, and the persistent Tailscale subnet router EC2 instance.

The same persistent Tailscale EC2 instance also becomes the initial GitOps bootstrapper. Its bootstrap service installs the required CLI tools, connects to Tailscale, waits until the EKS cluster is reachable over the VPC route, authenticates to the cluster, installs Argo CD, and applies the root Argo CD Application.

After the root Application is applied, Argo CD owns the Kubernetes platform layer. Terraform should no longer install platform service Helm releases. The `platform/` Terraform application should be removed or reduced to non-owning validation artifacts during implementation, because service reconciliation must have a single source of truth.

## GitOps Layout

The GitOps source is this repository, using the existing `origin` remote URL. The root Application points to `gitops/root`.

`gitops/root` is a small Helm chart that renders the app-of-apps child Applications. The bootstrap EC2 applies the root Application from a Terraform-rendered template and passes cluster-specific Helm parameters into the root Application spec. Those parameters include cluster name, AWS region, VPC ID, Route 53 domain, ACM certificate ARN, Karpenter queue name, Karpenter node role name, repository URL, target revision, and Spark workload namespace. This keeps reusable app templates in Git while avoiding hardcoded runtime outputs in committed manifests.

Expected layout:

```text
gitops/
  root/
    Chart.yaml
    values.yaml
    templates/
      applications.yaml
  base/
    namespaces.yaml
    storageclass.yaml
    serviceaccounts.yaml
    rbac.yaml
    ingresses.yaml
  apps/
    argocd/
    aws-load-balancer-controller/
    external-dns/
    karpenter/
    karpenter-resources/
    airflow/
    spark-operator/
    kubecost/
    sealed-secrets/
```

The root Application uses the app-of-apps pattern and creates one child Application per service or platform base package. Child Applications should carry consistent labels so operators can sync or inspect the platform as a group.

## Services

### Argo CD

Argo CD is installed initially by the bootstrap EC2 instance with the pinned chart version already represented in the repo. After bootstrap, Argo CD also has a child Application so its desired state is represented in Git.

The Argo CD server remains `ClusterIP`, with `server.insecure=true`, because TLS termination stays on the shared internal AWS ALB using the ACM wildcard certificate.

### AWS Load Balancer Controller

AWS Load Balancer Controller is installed by an Argo CD Application. Its values include the EKS cluster name, AWS region, VPC ID, and service account name `aws-load-balancer-controller`.

The IAM role and Pod Identity association remain Terraform-owned AWS resources. Argo CD owns the Kubernetes chart and service account shape needed by the controller.

### ExternalDNS

ExternalDNS is installed by an Argo CD Application. It keeps the existing behavior:

- `provider.name=aws`
- `policy=upsert-only`
- `registry=txt`
- `txtOwnerId=<cluster name>`
- `domainFilters[0]=<route53 domain>`
- `extraArgs.aws-zone-type=public`

The IAM role and Pod Identity association remain Terraform-owned AWS resources.

### Karpenter

Karpenter is installed by an Argo CD Application after base controllers are present. It receives cluster name and interruption queue values from Terraform-rendered configuration.

### Karpenter Resources

The existing local chart for `EC2NodeClass` and `NodePool` remains as a separate GitOps application. It must sync after Karpenter so CRDs exist before CRD-backed resources are applied.

### Airflow

Airflow moves from `platform/airflow-values.yaml` into the GitOps tree. It keeps the current KubernetesExecutor configuration, DAG bundle configuration, resource limits, disabled persistence defaults, and `airflow-task` service account.

Airflow keeps hook-safe values:

- `createUserJob.useHelmHooks=false`
- `createUserJob.applyCustomEnv=false`
- `migrateDatabaseJob.useHelmHooks=false`
- `migrateDatabaseJob.applyCustomEnv=false`
- migration job annotated as an Argo CD `Sync` hook when needed

### Spark Operator

Spark Operator is installed by an Argo CD Application with webhook support enabled. The Spark workload namespace and service account remain part of the base platform resources so Airflow can submit SparkApplications consistently.

### Kubecost

Kubecost is installed by an Argo CD Application. It keeps the current cluster ID and Prometheus external label configuration derived from the Terraform cluster name output.

### Sealed Secrets

Sealed Secrets is added as an Argo CD-managed platform service. It uses its own namespace, `sealed-secrets`. CRDs must sync before any sealed secret consumers are introduced.

## Base Kubernetes Resources

Base resources should be GitOps-managed so Terraform does not remain the owner of Kubernetes platform objects. This includes:

- Namespaces: `argocd`, `airflow`, `kubecost`, `spark-operator`, `spark-jobs`, `karpenter`, and `sealed-secrets`.
- The default `gp3` StorageClass.
- Service accounts required by Pod Identity: `aws-load-balancer-controller`, `external-dns`, `airflow-task`, and `spark-workload`.
- Airflow-to-Spark RBAC.
- Spark driver RBAC.
- Shared internal ALB Ingresses for Argo CD, Airflow, and Kubecost.

Ingresses continue to use one internal ALB group with host-based routing and these annotations:

- `alb.ingress.kubernetes.io/scheme=internal`
- `alb.ingress.kubernetes.io/target-type=ip`
- `alb.ingress.kubernetes.io/group.name=platform`
- `alb.ingress.kubernetes.io/listen-ports=[{"HTTP":80},{"HTTPS":443}]`
- `alb.ingress.kubernetes.io/ssl-redirect=443`
- `alb.ingress.kubernetes.io/certificate-arn=<ACM wildcard certificate ARN>`
- `external-dns.alpha.kubernetes.io/hostname=<service host>`

## Bootstrap EC2 Flow

The existing persistent Tailscale subnet router EC2 instance gains a systemd-managed bootstrap flow instead of relying only on one-shot user data commands. The service must be idempotent and safe to rerun after instance reboot.

Bootstrap sequence:

1. Install required packages and CLIs if missing: AWS CLI, kubectl, Helm, and Tailscale.
2. Connect the instance to Tailscale with the provided auth key and advertise the VPC CIDR route.
3. Wait until the EKS cluster exists and `eks:DescribeCluster` succeeds.
4. Wait until the private EKS API endpoint is reachable from the instance.
5. Generate kubeconfig with `aws eks update-kubeconfig` using the instance role.
6. Ensure the `argocd` namespace exists.
7. Run `helm upgrade --install argocd` with the pinned Argo CD chart and bootstrap values.
8. Apply the root Argo CD Application pointing at `gitops/root` in this repository, with Helm parameters rendered from Terraform outputs.
9. Exit successfully if the same desired state is already present.

The root Terraform EKS access entries must grant the bootstrap EC2 IAM role enough Kubernetes access to install Argo CD and the root Application. The instance role also needs AWS permissions for EKS cluster discovery.

## Networking And AZs

The VPC uses exactly 3 Availability Zones from the selected region:

```hcl
locals {
  azs = slice(data.aws_availability_zones.available.names, 0, 3)

  public_subnets = [
    for index, _ in local.azs : cidrsubnet(var.vpc_cidr, 8, index)
  ]
}
```

The `public_subnet_count` variable is removed. Terraform should keep a precondition that the selected region has at least 3 available AZs.

For the default `10.0.0.0/16` VPC CIDR, this keeps the current `/24` subnet sizing and creates one public subnet per AZ.

## Hook And Sync Policy

Argo CD sync order uses sync waves. Lower waves sync first.

Recommended wave model:

- Wave 0: base resources, namespaces, service accounts, RBAC, StorageClass.
- Wave 1: AWS Load Balancer Controller, ExternalDNS, and Sealed Secrets.
- Wave 2: Argo CD self-management and Karpenter.
- Wave 3: Karpenter CRD-backed resources.
- Wave 4: Airflow, Spark Operator, and Kubecost.

Hook policy:

- Prefer chart-supported values that disable Helm hooks when hooks are known to be problematic under Argo CD.
- Use Argo CD hooks only for resources that need sync-phase semantics.
- Use `argocd.argoproj.io/hook: Skip` only for specific rendered hook resources that block sync and cannot be disabled cleanly through chart values.
- Avoid adding native Argo CD hooks to an Application unless Helm hook behavior for that Application has been reviewed, because Argo CD ignores Helm hooks when native Argo CD hooks are present.

The Airflow chart gets explicit hook-safe configuration from the start. Spark Operator, Kubecost, and Sealed Secrets should be checked with rendered manifests during implementation and patched only where the rendered chart requires it.

## Terraform Ownership

Root Terraform remains the owner of AWS resources only. It should not configure Kubernetes or Helm providers.

The previous `platform/` Terraform application is retired as an apply target. Implementation should remove its Kubernetes and Helm resources or convert any retained files into non-owning source artifacts under `gitops/`. No retained `platform/` file may create Kubernetes resources owned by Argo CD.

## Testing And Validation

Static tests must be updated to enforce the new architecture:

- Root Terraform has no Kubernetes or Helm providers.
- Bootstrap template intentionally contains AWS CLI, kubectl, and Helm usage.
- Bootstrap flow is systemd-managed or otherwise retryable and idempotent.
- Root Application exists under `gitops/root`.
- Child Applications exist for Argo CD, AWS Load Balancer Controller, ExternalDNS, Karpenter, Karpenter resources, Airflow, Spark Operator, Kubecost, and Sealed Secrets.
- Sync waves are present.
- Airflow Helm hooks are disabled through values.
- ALB, ACM, public Route 53 discovery, and ExternalDNS public-zone filtering remain present.
- `public_subnet_count` is removed.
- The subnet layout uses 3 AZs and `/24` public subnets derived with `cidrsubnet(var.vpc_cidr, 8, index)`.

Expected validation commands:

```bash
rtk bash -n tests/platform_static_test.sh
rtk bash -n tests/bootstrap_static_test.sh
rtk bash -n templates/bootstrap.sh.tftpl
rtk bash tests/platform_static_test.sh
rtk bash tests/bootstrap_static_test.sh
rtk terraform fmt -check *.tf
rtk terraform validate
```

Implementation should add render checks for GitOps manifests and selected Helm charts once the final layout exists.

## Risks

- The bootstrap EC2 role becomes more privileged because it can authenticate to EKS and install Argo CD. This is intentional but must be documented and scoped to the cluster bootstrap need.
- Moving ownership from Terraform to Argo CD can cause drift or duplicate ownership if old `platform/` resources are not removed cleanly.
- Bootstrap timing is sensitive because the EC2 can start before EKS is ready. A retryable systemd service mitigates this.
- Argo CD hook behavior differs from Helm CLI behavior. Chart values and rendered manifests must be reviewed during implementation.
- Because Argo CD points to this repository, changes must be pushed to the remote before the cluster can reconcile them from Git.

## Approved Decisions

- Use the existing persistent Tailscale EC2 instance as both subnet router and Argo CD bootstrapper.
- Use this repository as the GitOps source.
- Manage all platform services with Argo CD app-of-apps.
- Use a safe hook policy per chart instead of accepting Helm hook behavior blindly.
- Use exactly 3 AZs.
- Keep subnet calculation as `cidrsubnet(var.vpc_cidr, 8, index)`.
- Remove `public_subnet_count`.
