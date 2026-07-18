# Terraform Argo CD Bootstrap Design

## Context

The current implementation makes the persistent Tailscale subnet router EC2 instance install Argo CD and apply the root Argo CD Application from user data. This has proven hard to debug because bootstrap failures happen inside EC2 systemd/cloud-init after Terraform has already completed.

The desired change is to move Argo CD bootstrap ownership back to Terraform while keeping all platform services owned by Argo CD app-of-apps.

## Goals

- Install Argo CD from root Terraform with `helm_release`.
- Install the root Argo CD Application from root Terraform.
- Keep the Tailscale EC2 instance focused on subnet routing, DNS route advertisement, optional SSH debug access, and not Kubernetes installation.
- Keep Airflow, Spark Operator, Kubecost, Sealed Secrets, AWS Load Balancer Controller, ExternalDNS, Karpenter, and Karpenter resources owned by Argo CD child Applications under `gitops/root`.

## Non-Goals

- Reintroduce the old `platform/` Terraform apply target.
- Install platform services other than Argo CD/root Application with Terraform.
- Reintroduce the Tailscale Kubernetes Operator or API server proxy.

## Design

Root Terraform gains a Helm provider using the private EKS endpoint and AWS exec authentication with `var.aws_profile`. Operators must run the Argo CD bootstrap phase from a machine that can reach the private endpoint through the approved Tailscale subnet route and split DNS.

Argo CD bootstrap is gated by `enable_argocd_bootstrap`, which defaults to `false`. This preserves the initial infrastructure phase: create AWS infrastructure and the subnet router first, approve the Tailscale route, then enable the Terraform Helm bootstrap in a second apply.

Root Terraform adds:

- `helm_release.argocd` for the `argo-cd` chart, pinned to `8.5.7`, with `create_namespace=true`, `server.service.type=ClusterIP`, and `configs.params.server.insecure=true`.
- `helm_release.argocd_root_application` to install a local bootstrap chart from `charts/argocd-root-application` after the Argo CD CRD exists.

The EC2 user data script removes AWS CLI, kubectl, Helm, Argo CD installation, root Application application, and the `argocd-bootstrap` systemd service/timer. It keeps Tailscale installation, IP forwarding, route advertisement for the VPC CIDR and VPC resolver `/32`, and optional SSH key setup for debugging.

## Ordering

- First apply: EKS cluster, default node group, and subnet router are created with `enable_argocd_bootstrap=false`.
- The operator approves the advertised Tailscale subnet route and verifies split DNS/private endpoint access.
- Second apply: set `enable_argocd_bootstrap=true`; `helm_release.argocd` installs Argo CD.
- `helm_release.argocd_root_application` installs the root Application after the Argo CD CRD exists and the release is ready.

## Tests

Static tests should change to enforce:

- Bootstrap template does not contain `aws eks update-kubeconfig`, `kubectl apply`, `helm upgrade --install argocd`, `argocd-bootstrap.service`, or `argocd-bootstrap.timer`.
- Root Terraform declares the `hashicorp/helm` provider.
- Root Terraform has `helm_release "argocd"` and `helm_release "argocd_root_application"` gated by `enable_argocd_bootstrap` only for bootstrap.
- Platform Terraform remains retired.
- GitOps app-of-apps tree remains present.

## Risks

- The Argo CD bootstrap apply depends on private EKS connectivity. This is intentional for reliability and observability, but the apply must run from a device with Tailscale route and split DNS working.
- If `aws_profile` used for Terraform does not match a principal with EKS admin access, the Kubernetes and Helm providers will fail authentication.
