# Tailscale EKS Example

Terraform infrastructure for a private Amazon EKS platform accessed through a Tailscale subnet router. Platform services are installed with a second Terraform application using `helm_release`, exposed through one internal AWS Application Load Balancer, protected by ACM TLS, and registered in Route 53 by ExternalDNS.

## Architecture

![Tailscale EKS platform architecture](docs/architecture.png)

Regenerate the diagram with:

```bash
uv run --script docs/architecture_diagram.py
```

## Prerequisites

- Terraform `>= 1.5.7`.
- AWS credentials with permissions for VPC, EKS, IAM, EC2, SQS, EventBridge, ACM, Route 53, and ELB resources.
- A public Route 53 hosted zone for `route53_domain_name`.
- A reusable, non-ephemeral Tailscale auth key for the subnet router EC2 instance.
- Tailscale CLI on the local machine.
- AWS CLI and `kubectl` on the local machine.

## Root Infrastructure

Create a local `terraform.tfvars` file. Do not commit it; `.gitignore` excludes `*.tfvars`.

```hcl
aws_profile         = "victor"
route53_domain_name = "example.com"

tailscale_subnet_router_auth_key = "tskey-auth-example"
```

Optional workload AWS permissions are empty by default. Add least-privilege statements only when concrete AWS resource ARNs are known:

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

Apply the root infrastructure first:

```bash
terraform init
terraform validate
terraform plan -out=tfplan
terraform apply tfplan
```

The root stack creates:

- VPC and public subnets tagged for Karpenter and internal ALB discovery.
- Persistent EC2 subnet router running Tailscale.
- Private-only EKS cluster and managed node group.
- EKS addons and EBS CSI Pod Identity.
- Karpenter AWS resources.
- Pod Identity roles for AWS Load Balancer Controller, ExternalDNS, Airflow tasks, and Spark workloads.
- ACM wildcard certificate for `*.${route53_domain_name}` validated through the existing public Route 53 hosted zone.

After apply, approve the advertised VPC route in the Tailscale Admin Console:

```bash
terraform output -raw tailscale_subnet_router_hostname
terraform output -raw tailscale_subnet_route
```

For the default VPC, approve `10.0.0.0/16` on `tailscale-eks-example-subnet-router`.

## Platform Application

After the Tailscale route is approved, apply the platform Terraform application:

```bash
terraform -chdir=platform init
terraform -chdir=platform validate
terraform -chdir=platform plan -out=platform.tfplan
terraform -chdir=platform apply platform.tfplan
```

The platform stack connects to the private EKS endpoint over the Tailscale subnet route and installs:

- AWS Load Balancer Controller.
- ExternalDNS.
- Argo CD.
- Airflow.
- Kubecost.
- Spark Operator.
- Karpenter Helm chart.
- Namespaces, `gp3` StorageClass, service accounts, RBAC, Karpenter `EC2NodeClass`/`NodePool`, and Ingresses.

One internal ALB serves the three UI endpoints using host-based routing:

```text
https://argocd.example.com
https://airflow.example.com
https://kubecost.example.com
```

ExternalDNS creates the records in the existing public hosted zone. The names are publicly discoverable, but the ALB is internal and reachable only from the VPC, including through the approved Tailscale subnet route.

## Access

Configure local kubeconfig after the subnet route is active:

```bash
aws eks update-kubeconfig \
  --profile victor \
  --region $(terraform output -raw aws_region) \
  --name $(terraform output -raw cluster_name)

kubectl get nodes
```

Open the platform URLs from a tailnet device after `platform` apply and DNS propagation:

```text
https://argocd.$(terraform output -raw route53_domain_name)
https://airflow.$(terraform output -raw route53_domain_name)
https://kubecost.$(terraform output -raw route53_domain_name)
```

To get the initial Argo CD admin password:

```bash
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d
```

## Permissions Model

- AWS permissions use EKS Pod Identity through `terraform-aws-modules/eks-pod-identity/aws`.
- Kubernetes permissions use Terraform-managed Kubernetes RBAC in `platform/kubernetes.tf`.
- `aws-ebs-csi-driver` uses a Pod Identity role with the EBS CSI policy.
- AWS Load Balancer Controller uses a Pod Identity role with the AWS LB Controller policy.
- ExternalDNS uses a Pod Identity role scoped to the discovered Route 53 hosted zone.
- `airflow-task` is the Airflow task pod identity for AWS APIs when explicitly configured.
- `spark-workload` is the Spark driver/executor identity for AWS APIs when explicitly configured.

## Subnet Router

The EC2 subnet router is persistent infrastructure. Do not set `enable_bootstrap_instance=false` unless another subnet router advertises the VPC CIDR. Removing it breaks local access to the private EKS endpoint and internal ALB.

The Tailscale auth key is sensitive and appears in Terraform state through EC2 user data. Protect local and remote state.

## Defaults

- Region: `us-east-1`.
- Kubernetes: `1.36`.
- Network: public subnets, no NAT Gateway, S3 Gateway endpoint.
- EKS API endpoint: private only.
- Managed EKS addons: VPC CNI, EKS Pod Identity Agent, CoreDNS, kube-proxy, and EBS CSI driver.
- Storage: default encrypted `gp3` StorageClass.
- Default node group: `t4g.small` Spot nodes.
- Argo CD chart: `8.5.7`.
- Airflow chart: `1.22.0`, `KubernetesExecutor`, embedded PostgreSQL.
- Kubecost chart: `2.8.7`.
- Spark Operator chart: `2.5.1`.
- Karpenter chart: `1.13.0`.

## Validation

Static validation:

```bash
bash tests/bootstrap_static_test.sh
bash tests/platform_static_test.sh
bash -n templates/bootstrap.sh.tftpl
terraform fmt -check *.tf
terraform validate
terraform -chdir=platform fmt -check
terraform -chdir=platform validate
```

Runtime validation after both applies:

```bash
tailscale status
tailscale ping $(terraform output -raw tailscale_subnet_router_hostname)
kubectl get nodes
kubectl -n kube-system get pods -l app.kubernetes.io/name=aws-load-balancer-controller
kubectl -n kube-system get pods -l app.kubernetes.io/name=external-dns
kubectl get ingress -A
kubectl get ec2nodeclass,nodepool
kubectl -n argocd get pods
kubectl -n airflow get pods
kubectl -n kubecost get pods
kubectl -n spark-operator get pods
```

Destroy platform resources before root infrastructure:

```bash
terraform -chdir=platform destroy
terraform destroy
```
