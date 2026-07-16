# EKS Tailscale GitOps Infrastructure Design

## Goal

Create Terraform infrastructure for an Amazon EKS cluster that is reachable only through Tailscale, uses community Terraform modules, bootstraps Argo CD, and delegates platform application lifecycle to GitOps manifests in this repository.

The platform must include Karpenter, Airflow, Kubecost, and Spark Operator. AWS permissions for pods must use EKS Pod Identity through `terraform-aws-modules/eks-pod-identity/aws`; Kubernetes permissions must use Kubernetes RBAC managed through Argo CD.

## Current Project Context

The project already contains a Terraform root module, documentation, a generated architecture diagram, and a bootstrap script. The directory is not currently a Git repository, so the design document cannot be committed until the project is initialized as Git.

The current implementation installs Tailscale Operator, Karpenter, Airflow, Kubecost, Spark Operator, StorageClass, and Tailscale Services directly from the temporary bootstrap EC2 instance. The revised design changes that boundary: bootstrap installs only the minimum access and delivery plane, then Argo CD owns the platform layer.

## Architecture

The stack remains a single Terraform root module with focused files:

- `providers.tf` configures the AWS provider.
- `versions.tf` pins Terraform, AWS provider, and module compatibility constraints.
- `variables.tf` defines region, network, EKS, Tailscale, Argo CD, GitOps, Karpenter, workload identity, bootstrap, and tagging inputs.
- `locals.tf` centralizes names, tags, selected AZs, subnet CIDRs, hostnames, and common computed values.
- `network.tf` creates the VPC and S3 endpoint.
- `eks.tf` creates the EKS cluster, managed addons, and default managed node group.
- `pod-identity.tf` creates Pod Identity roles and associations with `terraform-aws-modules/eks-pod-identity/aws`.
- `karpenter.tf` creates Karpenter AWS infrastructure through `terraform-aws-modules/eks/aws//modules/karpenter` and exposes values needed by GitOps, such as cluster name, interruption queue name, and node role name.
- `platform.tf` is reduced to shared computed values that are still needed by Terraform; platform Kubernetes resources move into `gitops/`.
- `tailscale-bootstrap.tf` creates the temporary EC2 bootstrap path for private cluster access and initial delivery-plane installation.
- `outputs.tf` exposes cluster, network, Tailscale, Argo CD, and application access information.
- `gitops/` contains Argo CD Applications, Helm values, RBAC, ServiceAccounts, Tailscale Services, and platform manifests.
- `README.md` documents usage, architecture, bootstrap, access, cleanup, and cost.

The runtime flow is:

1. Terraform creates a public-subnet VPC with no NAT Gateway.
2. Terraform creates an EKS cluster with private API endpoint only.
3. Terraform creates a fixed default managed node group of four `t4g.small` On-Demand instances.
4. Terraform creates AWS-side IAM and EKS Pod Identity associations for EBS CSI, Airflow task pods, and Spark workload pods.
5. A temporary EC2 bootstrap instance inside the VPC installs the Tailscale Kubernetes Operator and Argo CD.
6. The bootstrap instance applies one Argo CD root Application that points to this repository's `gitops/root` path and passes Terraform-computed values as Helm parameters.
7. Argo CD installs and reconciles Karpenter, Airflow, Kubecost, Spark Operator, RBAC, ServiceAccounts, StorageClass, and Tailscale Services.
8. Operators access the private EKS API through the Tailscale Kubernetes Operator API server proxy.
9. Argo CD, Airflow, and Kubecost UIs are exposed to the tailnet through Tailscale `LoadBalancer` Services.
10. The bootstrap EC2 instance can be disabled and removed after Tailscale access and Argo CD sync are validated.

## Network Design

The VPC uses `terraform-aws-modules/vpc/aws`.

Defaults and behavior:

- Region is configurable with `var.aws_region` and defaults to `us-east-1`.
- VPC CIDR is configurable and defaults to `10.0.0.0/16`.
- Public subnet count is configurable and defaults to `4`, with a minimum of `2` for normal multi-AZ EKS operation.
- Terraform checks that the selected region has enough available Availability Zones for `public_subnet_count`.
- Public subnet CIDRs are computed from the VPC CIDR.
- NAT Gateway is disabled.
- DNS support and DNS hostnames are enabled.
- Public subnet tagging includes Kubernetes load balancer discovery tags and Karpenter discovery tags.
- Public subnets assign public IPv4 addresses on launch.
- An S3 Gateway VPC endpoint is created and associated with public route tables.

This intentionally keeps the network simple and aligned with the requested public-subnet design. Public IPv4 cost is accepted for the initial implementation. A future design can move nodes to non-public addressing with additional VPC endpoints or another egress strategy.

## EKS Design

The cluster uses `terraform-aws-modules/eks/aws`.

Cluster behavior:

- Kubernetes version defaults to `1.36`, remains configurable with `var.cluster_version`, and uses minor-version format such as `1.36`.
- Public API endpoint is disabled.
- Private API endpoint is enabled.
- Public VPC subnets are used for the control plane and node groups.
- Cluster creator admin permissions are disabled.
- Bootstrap access is modeled explicitly with an access entry for the bootstrap IAM role.
- While bootstrap is enabled, the cluster security group allows HTTPS ingress from the bootstrap instance security group so the EC2 bootstrap can reach the private API endpoint.
- Tags are applied consistently across supported resources.

Managed EKS addons:

- `vpc-cni` with `before_compute = true`, `most_recent = true`, `ENABLE_PREFIX_DELEGATION = "true"`, and `WARM_PREFIX_TARGET = "1"`.
- `eks-pod-identity-agent` with `before_compute = true`.
- `coredns` with `most_recent = true`.
- `kube-proxy` with `most_recent = true`.
- `aws-ebs-csi-driver` with `most_recent = true` and a Pod Identity association created by `terraform-aws-modules/eks-pod-identity/aws`.

The default encrypted `gp3` StorageClass is moved from bootstrap into GitOps and applied by Argo CD after EBS CSI is active. Existing default StorageClass annotations should be cleared by a manifest or documented manual command only if the cluster creates another default class.

## Default Node Group

The default managed node group is fixed-size and On-Demand:

- Instance type: `t4g.small`.
- Capacity type: `ON_DEMAND`.
- Desired size: `4`.
- Minimum size: `4`.
- Maximum size: `4`.
- AMI type: ARM-compatible AL2023 managed node AMI.
- Subnets: public subnets from the VPC module.

This group provides stable baseline capacity for CoreDNS, the Tailscale Operator, Argo CD, Karpenter, and small platform workloads.

## Bootstrap Design

The EKS API endpoint is private from the beginning, so Terraform cannot rely on local Kubernetes or Helm providers unless the operator machine is already inside the VPC or tailnet path. The bootstrap EC2 instance remains the private in-VPC installer.

Bootstrap responsibilities:

- Install `kubectl` and Helm.
- Configure kubeconfig for the private EKS API.
- Install the Tailscale Kubernetes Operator Helm chart in the `tailscale` namespace with API server proxy enabled.
- Install Argo CD Helm chart in the `argocd` namespace.
- Apply a Tailscale Service for the Argo CD server so the UI is reachable from the tailnet.
- Apply one Argo CD root Application pointing to this repository's `gitops/root` chart with Terraform-computed Helm parameters.
- Wait for the Tailscale Operator and Argo CD control plane to become ready.

Bootstrap must not directly install Karpenter, Airflow, Kubecost, Spark Operator, workload RBAC, or platform Services. Those resources belong to Argo CD.

The bootstrap EC2 instance, bootstrap access entry, and bootstrap cluster security group ingress can be removed by setting `enable_bootstrap_instance=false` after Tailscale access and Argo CD sync are validated.

## GitOps Design

Argo CD uses this repository after it is published to a Git remote. Terraform exposes variables for:

- `argocd_repo_url`: Git repository URL.
- `argocd_target_revision`: branch, tag, or commit, defaulting to a normal branch value such as `main`.
- `argocd_path`: path to the root app-of-apps chart, defaulting to `gitops/root`.
- `argocd_tailscale_hostname`: Tailscale hostname for the Argo CD UI.

The repository contains a `gitops/` tree with a Helm-based app-of-apps layout:

- `gitops/root/Chart.yaml`: minimal Helm chart metadata for the root app-of-apps.
- `gitops/root/values.yaml`: defaults for child Applications, chart versions, namespaces, and hostnames.
- `gitops/root/templates/*.yaml`: templated Argo CD child Applications and cluster-specific platform manifests.
- `gitops/apps/karpenter.yaml`: Karpenter Helm chart Application.
- `gitops/apps/karpenter-resources.yaml`: Karpenter `EC2NodeClass` and `NodePool` Application or plain manifests.
- `gitops/apps/airflow.yaml`: Airflow Helm chart Application.
- `gitops/apps/kubecost.yaml`: Kubecost Helm chart Application.
- `gitops/apps/spark-operator.yaml`: Spark Operator Helm chart Application.
- `gitops/apps/platform.yaml`: StorageClass, ServiceAccounts, RBAC, and Tailscale Services.
- `gitops/platform/`: shared manifests or Helm templates for ServiceAccounts, RBAC, StorageClass, and Tailscale Services.
- `gitops/values/`: Helm values files for platform charts.

The root Argo CD Application is rendered by the bootstrap script, not stored as a static cluster-specific file in Git. It points at `gitops/root` and supplies Terraform-computed Helm parameters including cluster name, AWS region, Karpenter interruption queue name, Karpenter node role name, Tailscale hostnames, and chart versions. This avoids stale committed YAML when Terraform variables change.

Argo CD Applications use automated sync with `CreateNamespace=true` for namespaces owned by the platform. Destructive pruning should be enabled only for resources that are fully owned by GitOps. For the initial implementation, automated sync can self-heal and prune for platform-owned namespaces, while shared cluster resources are kept minimal and explicit.

## Tailscale Access Design

Only the private EKS API endpoint is exposed by AWS. External cluster access is provided by the Tailscale Kubernetes Operator API server proxy.

Tailscale credentials are provided as sensitive Terraform variables and rendered into a temporary Helm values file on the bootstrap instance with restrictive file permissions. Terraform state must be protected because sensitive values can still be stored through rendered user data and provider/resource state.

Tailscale Services:

- `argocd-tailscale` exposes the Argo CD server in the `argocd` namespace.
- `airflow-tailscale` exposes the Airflow API/web server in the `airflow` namespace.
- `kubecost-tailscale` exposes the Kubecost UI in the `kubecost` namespace.

These Services use `type: LoadBalancer` and `loadBalancerClass: tailscale`. They do not create public AWS load balancers.

## Pod Identity And Permissions Design

AWS permissions and Kubernetes permissions are intentionally separate.

AWS permissions:

- Managed by Terraform using `terraform-aws-modules/eks-pod-identity/aws`.
- Associated to specific Kubernetes ServiceAccounts by namespace and name.
- Scoped by workload role, not by broad platform ownership.
- Start with component-level roles, then split into per-DAG, per-team, or per-application roles when real boundaries are known.

Kubernetes permissions:

- Managed by Argo CD through namespaced `Role` and `RoleBinding` manifests.
- Used for Airflow to create and observe task pods and SparkApplications.
- Used for Spark driver pods to manage executor pods and driver services.
- Kept namespaced unless a concrete cross-namespace requirement exists.

Initial Pod Identity modules:

- `aws-ebs-csi`: attaches the EBS CSI policy and associates with `kube-system/ebs-csi-controller-sa`.
- `airflow-task`: custom policy for Airflow task pods that need AWS APIs such as S3, Athena, Glue, EMR, RDS IAM auth, or KMS.
- `spark-workload`: custom policy for Spark driver and executor pods that need AWS APIs such as S3, Athena, Glue, RDS IAM auth, or KMS.

The initial policies should be explicit and least-privilege where resource names are known. If this example does not create the target S3 buckets, databases, workgroups, or EMR resources, the variables should accept ARNs or ARN patterns and default to empty permissions rather than using account-wide wildcards by default.

ECR image pull permissions normally belong to the node/Kubelet path, not Airflow or Spark workload ServiceAccounts. Add ECR actions to workload Pod Identity only if application code calls ECR APIs directly.

RDS access usually requires network reachability and database credentials. Add IAM permissions only for RDS IAM authentication or RDS control-plane API calls.

## Airflow Design

Airflow uses the official Apache Airflow Helm chart from `https://airflow.apache.org`.

Defaults:

- Release name: `airflow`.
- Namespace: `airflow`.
- Executor: `KubernetesExecutor`.
- PostgreSQL: embedded chart dependency for this example.
- Web/API access: Tailscale Service, not public AWS load balancer.
- Chart version: configurable with `var.airflow_chart_version`, defaulting to the current project value `1.22.0`.

ServiceAccounts:

- Airflow control-plane components use the chart-managed or explicitly named Airflow ServiceAccount with only the Kubernetes permissions they need.
- Airflow task pods use a deterministic ServiceAccount such as `airflow-task`.
- `airflow-task` is associated to the `airflow-task` Pod Identity role by Terraform.

Airflow-to-Spark permissions:

- Airflow gets namespaced RBAC to create, get, list, watch, patch, and delete SparkApplication resources in the Spark workload namespace.
- Airflow gets read access to pods, pod logs, and events needed to inspect Spark status and logs.
- These permissions are Kubernetes RBAC, not AWS IAM.

The first implementation should not create one IAM role with every possible AWS permission. It should expose variables for allowed ARNs and keep empty or narrow defaults.

## Spark Operator Design

Spark Operator uses the Kubeflow Spark Operator Helm chart from `https://kubeflow.github.io/spark-operator`.

Defaults:

- Release name: `spark-operator`.
- Namespace: `spark-operator`.
- Webhook enabled.
- No UI exposure.
- Chart version: configurable with `var.spark_operator_chart_version`, defaulting to the current project value `2.5.1`.

Permission model:

- The `spark-operator` ServiceAccount receives Kubernetes controller RBAC required by the Helm chart.
- The operator controller does not receive broad AWS data-plane permissions by default.
- SparkApplication driver pods use a deterministic ServiceAccount such as `spark-workload`.
- `spark-workload` is associated to the `spark-workload` Pod Identity role by Terraform.
- Spark driver RBAC is applied in the Spark workload namespace so driver pods can manage executor pods and required services.

AWS permissions such as S3, Athena, Glue, KMS, and RDS IAM auth belong to Spark driver/executor workload pods unless the operator itself is proven to call those APIs.

## Karpenter Design

Karpenter AWS infrastructure uses `terraform-aws-modules/eks/aws//modules/karpenter`.

AWS integration:

- The EKS module Karpenter submodule creates the controller IAM role and policy.
- The submodule creates the Pod Identity association for the Karpenter controller.
- The submodule creates the node IAM role, instance profile, and access entry for Karpenter-provisioned instances.
- The submodule creates SQS queues and EventBridge rules for Spot interruption handling and capacity rebalancing.
- Terraform configures required `karpenter.sh/discovery` tags on subnets and on the EKS node security group.

Kubernetes resources move to GitOps:

- Karpenter Helm chart is installed by Argo CD.
- `EC2NodeClass` named `default` is managed by Argo CD.
- `NodePool` named `default` is managed by Argo CD.
- `NodePool` named `spark` is managed by Argo CD for Spark driver/executor pods only.

Default NodePool behavior:

- Allowed instance families: `t2`, `t3`, and `t4g`.
- Allowed architectures: `amd64` and `arm64`.
- Allowed capacity types: `spot` and `on-demand`.
- OS: Linux.
- AMI selector: AL2023 latest alias.
- Subnet and security group selection by cluster discovery tags.

Spark NodePool behavior:

- NodePool name: `spark`.
- Label: `workload=spark`.
- Taint: `workload=spark:NoSchedule`, so non-Spark pods cannot schedule onto these nodes unless they explicitly tolerate the taint.
- Allowed instance category: `r` only.
- Allowed capacity types: `spot` and `on-demand`.
- Local NVMe requirement: `karpenter.k8s.aws/instance-local-nvme` with `Gte ["1"]`, which restricts provisioning to instance types with local NVMe instance storage available.
- SparkApplication driver and executor pod specs must use `serviceAccount: spark-workload`, tolerate `workload=spark:NoSchedule`, and select `workload=spark` so Spark jobs land on the dedicated NodePool.

The default managed node group remains in place so Karpenter itself has stable capacity independent of Karpenter-provisioned nodes.

## Kubecost Design

Kubecost uses the Kubecost Helm chart `kubecost/cost-analyzer` from `https://kubecost.github.io/cost-analyzer`.

Defaults:

- Release name: `kubecost`.
- Namespace: `kubecost`.
- Chart version: configurable with `var.kubecost_chart_version`, defaulting to the current project value `2.8.7`.
- The default installation includes the chart's bundled monitoring components unless explicitly disabled later.
- Web UI is exposed to the tailnet with a Tailscale `LoadBalancer` Service.

Kubecost does not receive application data-plane AWS permissions in the initial design.

## Documentation Design

The README must be updated to describe:

- The Terraform/GitOps boundary.
- The bootstrap flow for Tailscale Operator and Argo CD only.
- Required GitOps variables: repository URL, target revision, and path.
- How to configure kubeconfig through Tailscale.
- How to access Argo CD, Airflow, and Kubecost through Tailscale Services.
- How to remove the temporary bootstrap EC2 instance after validation.
- Karpenter behavior and constraints.
- Airflow, Kubecost, and Spark Operator behavior, namespaces, access paths, and validation commands.
- Pod Identity and RBAC separation.
- Security notes for Terraform state and Tailscale credentials.
- Approximate monthly cost estimate.

The generated Diagrams architecture image should be updated to include Argo CD and show that Argo CD reconciles the platform layer.

## Cost Documentation

The README includes an approximate monthly cost block for the default configuration. The estimate is explicitly approximate and region-dependent.

Expected baseline items:

- EKS control plane.
- Four `t4g.small` On-Demand nodes.
- Public IPv4 hourly charges for the four default nodes.
- EBS root volumes for the nodes.
- S3 Gateway endpoint with no hourly endpoint charge.
- Temporary EC2 bootstrap cost only while enabled.
- Karpenter-provisioned nodes as variable cost based on workloads and Spot/On-Demand mix.
- Argo CD, Airflow, Kubecost, Spark Operator, and their persistent volumes as additional workload cost that may require Karpenter-created nodes.

Public IPv4 cost remains accepted for now and can be optimized later with a different node egress/addressing design.

## Security Considerations

- The EKS public API endpoint remains disabled.
- Cluster administration from outside AWS goes through the Tailscale API server proxy.
- The bootstrap EC2 instance is temporary and should be removed after validation.
- Terraform variables containing Tailscale credentials are marked sensitive.
- Sensitive values may still appear in Terraform state through rendered user data or provider/resource state; state storage must be protected.
- Public subnets and public IPv4 are used by design, but security groups avoid broad inbound access.
- Karpenter is allowed to create Spot and On-Demand nodes, so workloads should use scheduling controls where interruption tolerance matters.
- Argo CD, Airflow, and Kubecost are exposed only inside the tailnet via Tailscale-managed Services.
- Airflow uses embedded PostgreSQL for simplicity; this is not equivalent to a managed production database.
- Broad AWS permissions must not be attached to the Spark Operator controller or all Airflow components by default.
- Pod Identity roles should be split when different DAGs, teams, or Spark applications need different AWS access boundaries.

## Verification Plan

Static verification:

- `terraform fmt -check -recursive`.
- `terraform validate`.
- `terraform plan` when credentials and permissions are available.
- Static review that no public EKS API endpoint is enabled.
- Static review that NAT Gateway remains disabled.
- Static review that VPC CNI prefix delegation is configured before compute.
- Static review that EBS CSI uses `terraform-aws-modules/eks-pod-identity/aws`, not a hand-written IAM role.
- Static review that Airflow and Spark AWS access uses Pod Identity associations, not Kubernetes annotations or node IAM permissions.
- Static review that Airflow-to-Spark status/log access is Kubernetes RBAC, not AWS IAM.
- Static review that bootstrap no longer installs Karpenter, Airflow, Kubecost, or Spark Operator directly.
- README review for GitOps, bootstrap, access, cleanup, diagram, permissions, and cost sections.

Runtime verification after apply:

- EKS cluster reports private endpoint only.
- Managed node group reaches four ready nodes.
- EKS addons are active.
- Tailscale Operator pods are ready.
- `tailscale configure kubeconfig <operator-hostname>` works from a tailnet device.
- Argo CD pods are ready.
- Argo CD root Application syncs successfully.
- Karpenter controller is ready.
- Karpenter `EC2NodeClass` and `NodePool` exist.
- A test unschedulable pod can trigger a Karpenter node from allowed families.
- Airflow web/API server and scheduler are ready in the `airflow` namespace.
- Airflow task pod can assume the `airflow-task` Pod Identity role and access only allowed AWS resources.
- Kubecost pods are ready in the `kubecost` namespace.
- Spark Operator pods are ready in the `spark-operator` namespace.
- Spark driver pod can assume the `spark-workload` Pod Identity role and access only allowed AWS resources.
- Airflow can create and observe a SparkApplication in the intended namespace and read relevant pod logs.
- Argo CD, Airflow, and Kubecost Tailscale Service hostnames work from a tailnet device.

## Out Of Scope

- Moving nodes to private subnets or eliminating public IPv4 cost in the first implementation.
- NAT Gateway-based egress.
- Full production observability beyond Kubecost's bundled components.
- Airflow production hardening such as RDS, external secrets, DAG sync, SSO, or remote logging.
- Creating application-specific S3 buckets, RDS databases, Athena workgroups, Glue databases, EMR clusters, or EMR Serverless applications.
- Defining final per-DAG, per-team, or per-Spark-application IAM policies without concrete resource boundaries.
- Workload deployment beyond test resources needed to verify Karpenter, Pod Identity, Airflow-to-Spark RBAC, and Spark Operator.
- Multi-environment orchestration.
- Remote Terraform state backend unless requested separately.
