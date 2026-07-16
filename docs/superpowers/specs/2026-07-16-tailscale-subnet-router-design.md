# Tailscale Subnet Router Access Design

## Context

The current cluster bootstrap succeeds: it installs the Tailscale Kubernetes Operator, Argo CD, the Argo CD Tailscale Service, and the root Argo CD Application. The remaining access issue is local `kubectl` access through the Tailscale Kubernetes API server proxy.

The API server proxy requires Tailscale HTTPS certificate support. The current tailnet returns `your Tailscale account does not support getting TLS certs`, so `kubectl` fails during TLS handshake with `remote error: tls: internal error`.

## Decision

Use a Tailscale subnet router to reach the EKS private endpoint directly instead of using the Tailscale API server proxy for `kubectl`.

The existing bootstrap EC2 instance will also act as the subnet router. It will join the tailnet using a Terraform-provided auth key and advertise the VPC CIDR.

## Architecture

Terraform will keep creating the AWS infrastructure, private-only EKS cluster, Pod Identity roles, Karpenter AWS resources, and bootstrap EC2 instance.

The bootstrap EC2 instance will run Tailscale during cloud-init and advertise `var.vpc_cidr`, which defaults to `10.0.0.0/16`.

After the route is approved in the Tailscale Admin Console, tailnet clients can reach private VPC addresses, including the private EKS API endpoint resolved by AWS DNS.

The Tailscale Kubernetes Operator remains installed because it still exposes Argo CD, Airflow, and Kubecost through Tailscale `LoadBalancer` Services. It is no longer the primary mechanism for `kubectl` access.

## Configuration

Add a sensitive Terraform variable:

```hcl
tailscale_subnet_router_auth_key = "tskey-auth-example"
```

The bootstrap template will install Tailscale and run the equivalent of:

```bash
tailscale up \
  --auth-key="$TAILSCALE_SUBNET_ROUTER_AUTH_KEY" \
  --hostname="${name}-subnet-router" \
  --advertise-routes="$VPC_CIDR" \
  --accept-dns=false
```

`--accept-dns=false` keeps AWS DNS behavior intact inside the EC2 instance.

## Access Flow

After `terraform apply`:

1. Approve the advertised VPC route in the Tailscale Admin Console.
2. Ensure the local device accepts subnet routes.
3. Configure kubeconfig using AWS EKS, not the Tailscale API server proxy:

```bash
aws eks update-kubeconfig \
  --profile victor \
  --region us-east-1 \
  --name tailscale-eks-example
```

4. Validate access:

```bash
kubectl get pods -A
```

If the EKS private endpoint hostname does not resolve from the client, configure Tailscale Split DNS for the relevant AWS private DNS name to use the VPC resolver, usually `10.0.0.2` for the default `10.0.0.0/16` VPC.

## Non-Goals

- Do not use `remote-exec` for the subnet router setup. Terraform provisioners are a last resort and would require SSH access that this stack intentionally avoids.
- Do not move bootstrap Helm installs to `helm_release` in the first phase. The Terraform Helm provider runs where Terraform runs, so it cannot reach the private EKS endpoint until the subnet route is already approved.
- Do not expose the EKS public API endpoint as part of this change.

## Security Notes

The subnet router auth key is sensitive and will be present in Terraform state through rendered EC2 user data. State must remain protected.

Advertised subnet routes must be approved in Tailscale and constrained by tailnet ACLs. At minimum, only trusted users/devices should have access to `10.0.0.0/16:*`.

The bootstrap instance becomes persistent infrastructure while subnet-routed access is required. Disabling `enable_bootstrap_instance` will remove the subnet router and break private `kubectl` access unless another subnet router exists.

## Testing

Static validation:

```bash
terraform fmt -check -recursive
terraform validate
bash -n templates/bootstrap.sh.tftpl
```

Runtime validation:

```bash
tailscale status
tailscale ping tailscale-eks-example-subnet-router
aws eks update-kubeconfig --profile victor --region us-east-1 --name tailscale-eks-example
kubectl get pods -A
```

Expected result: `kubectl` connects to the private EKS endpoint through the approved Tailscale subnet route without using `tailscale configure kubeconfig`.
