# Tailscale EKS Example

Terraform infrastructure for an Amazon EKS cluster with a private API endpoint, Tailscale-based cluster access, Argo CD GitOps delivery, Karpenter autoscaling, Airflow, Kubecost, and Spark Operator.

## Architecture

![Tailscale EKS platform architecture](docs/architecture.png)

The diagram is generated with [Diagrams](https://diagrams.mingrammer.com/). Regenerate it with:

```bash
uv run --script docs/architecture_diagram.py
```

## Prerequisites

- Terraform `>= 1.5.7`.
- AWS credentials with access to create VPC, EKS, IAM, EC2, SQS, EventBridge, and related resources.
- Tailscale OAuth client ID and secret for the Kubernetes Operator.
- Tailscale CLI on the operator machine for subnet router validation.
- `kubectl` for post-bootstrap validation.
- A Git remote containing this repository, because Argo CD syncs `gitops/root` from `argocd_repo_url`.

## Usage

Create a local `terraform.tfvars` file. Do not commit this file; it contains Tailscale OAuth credentials and `.gitignore` excludes `*.tfvars`.

```hcl
tailscale_oauth_client_id        = "tskey-client-example"
tailscale_oauth_client_secret    = "tskey-secret-example"
tailscale_subnet_router_auth_key = "tskey-auth-example"

# Required after this repository is published.
argocd_repo_url = "https://github.com/VictorCoutinho86/tailscale-eks-example.git"

# Optional GitOps overrides.
argocd_target_revision = "master"
argocd_path            = "gitops/root"

# Optional hostname overrides. Defaults are based on var.name.
tailscale_operator_hostname = "tailscale-eks-example-operator"
argocd_tailscale_hostname   = "tailscale-eks-example-argocd"
airflow_tailscale_hostname  = "tailscale-eks-example-airflow"
kubecost_tailscale_hostname = "tailscale-eks-example-kubecost"
```

Optional workload AWS permissions are intentionally empty by default. Add least-privilege statements only when concrete AWS resource ARNs are known:

```hcl
airflow_task_policy_statements = [
  {
    sid       = "ReadAirflowData"
    actions   = ["s3:GetObject", "s3:ListBucket"]
    resources = ["arn:aws:s3:::example-bucket", "arn:aws:s3:::example-bucket/airflow/*"]
  }
]

spark_workload_policy_statements = [
  {
    sid       = "SparkDataLakeAccess"
    actions   = ["s3:GetObject", "s3:PutObject", "s3:ListBucket"]
    resources = ["arn:aws:s3:::example-bucket", "arn:aws:s3:::example-bucket/spark/*"]
  }
]
```

Initialize and review the stack:

```bash
terraform init
terraform validate
terraform plan -out=tfplan
```

Apply only after reviewing the plan:

```bash
terraform apply tfplan
```

## GitOps Boundary

Terraform creates AWS infrastructure, EKS, EKS addons, Karpenter AWS resources, the bootstrap instance that persists while used as the Tailscale subnet router, and EKS Pod Identity roles/associations.

The bootstrap EC2 instance installs only:

- Tailscale Kubernetes Operator.
- Argo CD.
- Argo CD Tailscale Service.
- One Argo CD root Application pointing at `argocd_repo_url`, `argocd_target_revision`, and `argocd_path`.

Argo CD then reconciles:

- Karpenter Helm chart.
- Karpenter `EC2NodeClass` and `NodePool`.
- Airflow Helm chart.
- Kubecost Helm chart.
- Spark Operator Helm chart.
- `gp3` StorageClass.
- Airflow/Spark ServiceAccounts and RBAC.
- Argo CD, Airflow, and Kubecost Tailscale Services.

Airflow chart values live in `gitops/values/airflow.yaml`. The Airflow Argo CD Application uses multi-source Helm values so it can install the upstream chart from `https://airflow.apache.org` while reading `$values/gitops/values/airflow.yaml` from this repository.

The Airflow values disable Helm hooks for `createUserJob` and `migrateDatabaseJob`, which avoids common GitOps/Argo CD issues with Helm hooks and immutable Kubernetes Jobs. The migration job also has `argocd.argoproj.io/hook: Sync` so migrations run during Argo CD sync.

## Access

The EKS API endpoint is private. Local `kubectl` access uses the Tailscale subnet router running on the bootstrap EC2 instance.

After `terraform apply`, approve the advertised VPC route in the Tailscale Admin Console:

```bash
terraform output -raw tailscale_subnet_router_hostname
terraform output -raw tailscale_subnet_route
```

For the default VPC, approve `10.0.0.0/16` on `tailscale-eks-example-subnet-router`.

Then configure kubeconfig with AWS EKS:

```bash
aws eks update-kubeconfig \
  --profile victor \
  --region $(terraform output -raw aws_region) \
  --name $(terraform output -raw cluster_name)

kubectl get nodes
```

If the private EKS endpoint hostname does not resolve from your local machine, configure Tailscale Split DNS to forward the relevant AWS private DNS name to the VPC resolver. For the default `10.0.0.0/16` VPC, the resolver is usually `10.0.0.2`.

Get UI hostnames:

```bash
terraform output -raw argocd_tailscale_hostname
terraform output -raw airflow_tailscale_hostname
terraform output -raw kubecost_tailscale_hostname
```

Open those hostnames from a device in the tailnet. They are exposed through Tailscale Services, not public AWS load balancers.

To get the initial Argo CD admin password:

```bash
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d
```

## Permissions Model

AWS permissions and Kubernetes permissions are separate.

- AWS permissions use EKS Pod Identity through `terraform-aws-modules/eks-pod-identity/aws`.
- Kubernetes permissions use namespaced `Role` and `RoleBinding` manifests under `gitops/root/templates`.
- `aws-ebs-csi-driver` uses a Pod Identity role with the EBS CSI policy.
- `airflow-task` is the Airflow task pod identity for AWS APIs such as S3, Athena, Glue, EMR, RDS IAM auth, or KMS when explicitly configured.
- `spark-workload` is the Spark driver/executor identity for AWS APIs such as S3, Athena, Glue, RDS IAM auth, or KMS when explicitly configured.
- Spark Operator does not receive broad AWS data-plane permissions by default.
- ECR image pull permissions normally belong to the node/Kubelet path, not application ServiceAccounts.

## Bootstrap Instance and Subnet Router

The bootstrap EC2 instance is persistent in this design because it also acts as the Tailscale subnet router for private EKS API access.

Do not set `enable_bootstrap_instance=false` unless another subnet router advertises the VPC CIDR. Removing the bootstrap instance removes the subnet route and breaks local `kubectl` access to the private endpoint.

## Defaults

- Region: `us-east-1`.
- Kubernetes: `1.36`.
- Network: 4 public subnets, no NAT Gateway, S3 Gateway endpoint.
- EKS API endpoint: private only.
- Managed EKS addons: VPC CNI, EKS Pod Identity Agent, CoreDNS, kube-proxy, and EBS CSI driver.
- Storage: default encrypted `gp3` StorageClass managed by Argo CD.
- Default node group: 4 `t4g.small` On-Demand nodes.
- Argo CD: chart `8.5.7`, UI exposed through Tailscale.
- Karpenter: chart `1.13.0`, AWS resources from `terraform-aws-modules/eks/aws//modules/karpenter`, default NodePool for `t2`, `t3`, and `t4g` Spot or On-Demand nodes.
- Spark Karpenter NodePool: dedicated `spark` NodePool, tainted with `workload=spark:NoSchedule`, limited to `r` instance category, Spot or On-Demand, and instance types with local NVMe storage.
- Airflow: chart `1.22.0`, `KubernetesExecutor`, embedded PostgreSQL.
- Kubecost: chart `2.8.7`.
- Spark Operator: chart `2.5.1`, webhook enabled.
- Airflow and Kubecost access: Tailscale `LoadBalancer` Services.

## Approximate Monthly Cost

Approximate for `us-east-1`; excludes taxes, data transfer, logs, workload storage, and Karpenter-created workload nodes.

```text
EKS control plane:                 about US$73/month
4x t4g.small On-Demand nodes:       about US$49/month
4x public IPv4 addresses:           about US$15/month
4x gp3 root EBS volumes:            about US$6/month
S3 Gateway VPC endpoint:            US$0/hour endpoint charge
Bootstrap subnet router t3.micro:    while enable_bootstrap_instance=true
Karpenter nodes:                     variable by workload and Spot/On-Demand mix
Argo CD/Airflow/Kubecost/Spark:      variable compute and persistent volume cost

Estimated base infrastructure:       about US$140-150/month before platform growth
```

Public IPv4 cost is accepted for now. If it becomes material, move nodes away from public IPv4 and add the required private endpoints or another egress design.

## Notes

- The EKS public API endpoint is disabled; access is through the Tailscale subnet route to the private endpoint.
- The bootstrap EC2 instance exists because the private endpoint needs an in-VPC installer for initial Tailscale and Argo CD setup.
- Terraform variables are marked sensitive, but Tailscale credentials can still land in Terraform state through rendered bootstrap user data. Protect local and remote state.
- Karpenter AWS resources are created by `terraform-aws-modules/eks/aws//modules/karpenter`.
- Airflow embedded PostgreSQL is acceptable for this example but should not be treated as production-critical storage.
- Argo CD, Airflow, and Kubecost are exposed through Tailscale Services, not public AWS load balancers.
- The bootstrap instance writes logs to `/var/log/eks-bootstrap.log`.

## Spark Job Scheduling

Spark jobs should use the dedicated Karpenter NodePool by setting the driver and executor pod scheduling fields in each `SparkApplication`:

```yaml
spec:
  driver:
    serviceAccount: spark-workload
    nodeSelector:
      workload: spark
    tolerations:
      - key: workload
        operator: Equal
        value: spark
        effect: NoSchedule
  executor:
    nodeSelector:
      workload: spark
    tolerations:
      - key: workload
        operator: Equal
        value: spark
        effect: NoSchedule
```

The `spark` NodePool only allows `r` family instances with local NVMe storage and supports both Spot and On-Demand capacity. Non-Spark pods cannot schedule there unless they explicitly tolerate `workload=spark:NoSchedule`.

## Validation

Static validation:

```bash
terraform fmt -check -recursive
terraform validate
terraform plan -out=tfplan
bash -n templates/bootstrap.sh.tftpl
```

Runtime validation after apply:

```bash
tailscale status
tailscale ping $(terraform output -raw tailscale_subnet_router_hostname)
aws eks update-kubeconfig --profile victor --region $(terraform output -raw aws_region) --name $(terraform output -raw cluster_name)
kubectl get nodes
kubectl -n tailscale get pods
kubectl -n argocd get pods,applications
kubectl -n karpenter get pods
kubectl get ec2nodeclass,nodepool
kubectl get nodepool spark -o yaml
kubectl -n airflow get pods
kubectl -n kubecost get pods
kubectl -n spark-operator get pods
kubectl -n argocd get svc argocd-tailscale
kubectl -n airflow get svc airflow-tailscale
kubectl -n kubecost get svc kubecost-tailscale
```

Destroy when finished:

```bash
terraform destroy
```
