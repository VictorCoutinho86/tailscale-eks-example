# Architecture Documentation Refresh Design

## Goal

Refresh the project-facing architecture documentation so `README.md`, `AGENTS.md`, and the generated architecture diagram all describe the current IPv6-first EKS platform accurately.

## Scope

- Keep the existing README and AGENTS structure.
- Make only surgical wording updates needed to align those docs with the implemented architecture.
- Update `docs/architecture_diagram.py` and regenerate `docs/architecture.png`.
- Do not change Terraform, Kubernetes manifests, GitOps behavior, or runtime architecture.

## Architecture Content To Represent

- Root Terraform creates AWS infrastructure only, except for the existing Argo CD bootstrap Helm releases.
- Argo CD reconciles Kubernetes platform services through the app-of-apps tree.
- The VPC is dual-stack across three AZs.
- EKS Pods and Services use IPv6.
- Normal IPv6 egress uses the egress-only internet gateway.
- There are no AWS NAT Gateway resources.
- Two Ubuntu 24.04 spot-backed subnet-router ASGs run in two public subnets/AZs.
- Subnet routers advertise the VPC IPv4 and IPv6 CIDRs through Tailscale.
- Subnet routers provide IPv4 NAT with iptables, NAT64 with tayga, and DNS64 fallback/diagnostics with Unbound.
- The third private subnet/AZ routes IPv4 NAT and NAT64 traffic to the fixed primary subnet-router.
- Argo CD, Airflow, Kubecost, Grafana, and Spark History Server use one shared internal dual-stack AWS ALB with host-based routing and ACM TLS.
- ExternalDNS writes public Route 53 records for the internal ALB hostnames.
- S3 buckets support Velero, Loki, ALB access logs, Spark events, and CloudNativePG backups.

## Diagram Design

The diagram should stay high-level and readable. It should show these relationships:

- Tailnet client reaches the private EKS API and internal ALB through Tailscale subnet routes.
- Terraform creates VPC, EKS, subnet-router ASGs, Route 53/ACM, IAM, and S3 buckets.
- Public subnets contain the two subnet-router ASGs and EKS control-plane ENIs.
- Private subnets contain EKS nodes, Karpenter nodes, Spark nodes, platform services, the internal dual-stack ALB, and route tables.
- Private route tables send IPv4 default and NAT64 prefix routes to the subnet-router layer.
- IPv6 workload egress goes to the egress-only internet gateway.
- Argo CD app-of-apps reconciles platform apps.
- AWS Load Balancer Controller reconciles the shared internal dual-stack ALB, and ExternalDNS updates Route 53.

## Validation

- `uv run --script docs/architecture_diagram.py` regenerates `docs/architecture.png` successfully.
- `bash tests/platform_static_test.sh` passes.
- `bash tests/bootstrap_static_test.sh` passes.
- `terraform fmt -check -recursive *.tf` passes if any Terraform file changes; no Terraform changes are expected.
- `git diff --check` passes.

## Out Of Scope

- Runtime `terraform plan`, `terraform apply`, or cluster verification.
- Reworking the full README structure.
- Adding detailed packet-flow documentation beyond the current high-level architecture summary.
- Changing the implemented infrastructure or GitOps manifests.
