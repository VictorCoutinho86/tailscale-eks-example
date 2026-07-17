# Internal ALB, ACM, and ExternalDNS Design

## Context

The cluster already has a Tailscale subnet router that advertises the VPC CIDR, allowing tailnet clients to reach private AWS addresses. The Tailscale Kubernetes Operator API server proxy cannot be used because the current tailnet does not support Tailscale TLS certificates.

The current platform Services for Argo CD, Airflow, and Kubecost use the Tailscale Kubernetes Operator. The desired replacement is an AWS-native internal Application Load Balancer with DNS records managed by ExternalDNS and TLS terminated by ACM. The MVP will use Terraform `helm_release` resources for platform installation in a second Terraform application after the EKS cluster is available.

## Decision

Use one internal AWS Application Load Balancer for Argo CD, Airflow, and Kubecost. Route requests by hostname:

```text
argocd.<domain>
airflow.<domain>
kubecost.<domain>
```

The root domain is provided through Terraform as a variable. Terraform locates the existing public Route 53 hosted zone for that domain and uses it for ACM DNS validation and ExternalDNS records.

The ALB remains private because its scheme is `internal`. The DNS names are publicly discoverable because records are written to the public hosted zone, but the private ALB is not reachable from the public internet. Access still requires the Tailscale subnet route into the VPC.

The deployment is intentionally split into two applications:

1. The infrastructure application creates the VPC, persistent Tailscale subnet router EC2, EKS cluster, IAM/Pod Identity resources, Route 53 data, and ACM certificate.
2. The platform application connects to the private EKS endpoint through the approved Tailscale route and installs Helm releases and Kubernetes Ingress resources.

This two-apply workflow is acceptable for the MVP and avoids configuring the Helm provider before the EKS API exists.

## Components

### AWS Load Balancer Controller

Install the AWS Load Balancer Controller with a Terraform `helm_release` from the AWS EKS Helm repository. Its ServiceAccount is managed by the platform application and receives an AWS Pod Identity association created by the infrastructure application.

The controller creates an internal ALB from Kubernetes Ingress resources. The VPC public subnets retain their public load-balancer role tag and also receive the internal load-balancer role tag required for subnet discovery.

### ExternalDNS

Install ExternalDNS with a Terraform `helm_release` from its official Helm repository. It watches Ingress resources, uses the AWS provider, and is restricted to the supplied domain. Its ServiceAccount receives a least-privilege Route 53 policy through EKS Pod Identity.

ExternalDNS uses TXT ownership records and an `upsert-only` policy so it cannot delete unrelated records from the hosted zone. The implementation must configure a stable TXT owner ID.

### ACM

Terraform creates a public ACM certificate in the AWS region with:

```text
*.${var.route53_domain_name}
```

Terraform creates the ACM DNS validation records in the existing public Route 53 zone and waits for certificate validation before the Ingress is reconciled.

### Shared Ingress

The platform Terraform application creates three Ingress resources, one in each application namespace, because Kubernetes Ingress backends cannot reference Services in another namespace. All three Ingresses use the same AWS Load Balancer Controller IngressGroup, so they share one ALB and provide one host rule each. The AWS Load Balancer Controller uses:

```yaml
alb.ingress.kubernetes.io/scheme: internal
alb.ingress.kubernetes.io/target-type: ip
alb.ingress.kubernetes.io/group.name: platform
alb.ingress.kubernetes.io/certificate-arn: <validated ACM certificate>
```

The ALB listens on HTTPS and redirects HTTP to HTTPS. The three Ingresses forward to the existing ClusterIP Services in `argocd`, `airflow`, and `kubecost`. The platform application installs Argo CD, Airflow, and Kubecost with `helm_release` before creating the corresponding Ingress resources. The Argo CD server is configured for HTTP behind the ALB because TLS terminates at the ALB; the client-facing connection remains HTTPS.

## Terraform Inputs and Resources

Add:

```hcl
variable "route53_domain_name" {
  description = "Existing public Route 53 hosted zone domain used for platform DNS and ACM validation."
  type        = string
}
```

Terraform will use `data.aws_route53_zone` with `private_zone = false` to locate the existing zone. Route 53 IAM policy resources use the hosted zone ID in the ARN form:

```text
arn:aws:route53:::hostedzone/<zone-id>
```

Terraform creates:

- ACM certificate and DNS validation records.
- AWS Load Balancer Controller Pod Identity role and association.
- ExternalDNS Pod Identity role and association.
- Route 53 permissions scoped to the discovered hosted zone.

The existing Tailscale OAuth variables, Tailscale Operator Helm installation, and Tailscale Service manifests are removed. The Tailscale subnet router auth key remains required for private network access. The previous bootstrap Helm installation is removed; the persistent EC2 instance only provides subnet routing.

The platform application consumes the infrastructure outputs through `terraform_remote_state` and configures the Helm and Kubernetes providers with the private EKS endpoint and AWS `eks get-token` exec authentication. Each `helm_release` uses `depends_on` for its required IAM, namespace, and controller prerequisites, but provider initialization is handled by the separate platform application rather than a provider-level dependency.

## Access Flow

After the infrastructure application, approve or enable the advertised Tailscale route. Then apply the platform application:

```bash
terraform -chdir=platform init
terraform -chdir=platform apply
```

The platform application installs the Helm releases and Ingress resources directly. It does not depend on Argo CD for the MVP.

From a tailnet device, the user opens:

```text
https://argocd.<domain>
https://airflow.<domain>
https://kubecost.<domain>
```

The local device must be able to resolve the public Route 53 records and reach the resolved private ALB addresses through the approved Tailscale VPC route. If public DNS resolution does not return usable private addresses from the client environment, configure Tailscale split DNS or a private DNS arrangement without changing the hostnames.

## Security and Failure Handling

- The ALB is internal and has no internet-facing listener.
- Tailscale ACLs control which tailnet devices can reach the VPC CIDR and ALB ports.
- ACM certificate validation fails fast if the supplied domain does not match an existing public Route 53 hosted zone.
- ExternalDNS cannot modify hosted zones outside the supplied domain and cannot delete records because of `upsert-only`.
- AWS Load Balancer Controller and ExternalDNS receive separate Pod Identity roles.
- Route 53 and ACM configuration remains in Terraform; Kubernetes platform installation and application routing are managed by the platform Terraform application for the MVP.

## Non-Goals

- Do not use the Tailscale Kubernetes API server proxy.
- Do not create a public ALB.
- Do not create separate ALBs for Argo CD, Airflow, and Kubecost.
- Do not configure the Helm provider in the same Terraform application that creates the EKS cluster.
- Do not require Argo CD for the MVP platform installation.

## Validation

Static validation:

```bash
terraform fmt -check *.tf
terraform validate
terraform -chdir=platform validate
```

Runtime validation:

```bash
aws route53 get-hosted-zone --hosted-zone-id <zone-id>
aws acm describe-certificate --certificate-arn <certificate-arn>
terraform -chdir=platform plan
kubectl -n kube-system get deployment aws-load-balancer-controller external-dns
kubectl -n kube-system get serviceaccount aws-load-balancer-controller external-dns
kubectl -n argocd get ingress argocd
kubectl -n airflow get ingress airflow
kubectl -n kubecost get ingress kubecost
```

Expected result: one internal ALB has HTTPS host rules for all three services, ACM is issued, ExternalDNS creates the three Route 53 records, and the hostnames resolve and respond from a tailnet client.
