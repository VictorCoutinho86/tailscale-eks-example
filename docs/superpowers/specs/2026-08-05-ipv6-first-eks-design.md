# IPv6-First EKS Cluster Design

## Goal

Create this platform as a greenfield IPv6-first EKS cluster. The Kubernetes and application layer should use IPv6 by default, while IPv4 remains only where AWS, EKS, EC2, Tailscale, or IPv4-only external dependencies require it.

The cluster has not been created yet, so this design does not include migration or blue-green cutover work.

## Key Decisions

- Use an EKS IPv6 cluster from creation time by setting the Kubernetes network IP family to IPv6.
- Keep the VPC dual-stack instead of attempting a pure IPv6-only VPC, because AWS/EKS plumbing still has IPv4 requirements.
- Do not create AWS NAT Gateway resources.
- Use an egress-only internet gateway for normal outbound IPv6 traffic from private subnets.
- Preserve the Tailscale subnet-router Auto Scaling Group as the private access path for humans and operators, running two instances in different AZs.
- Extend the subnet-router instances to advertise IPv6 VPC routes through Tailscale.
- Keep subnet-router-hosted IPv4 NAT for unavoidable IPv4 underlay traffic.
- Add subnet-router-hosted NAT64/DNS64 so IPv6 Pods can reach IPv4-only internet endpoints when needed.
- Use Ubuntu 24.04 for subnet-router AMIs because Amazon Linux 2023 does not package tayga or jool.
- Use packaged tayga for NAT64 and Unbound for local DNS64 fallback/diagnostics, with VPC subnet DNS64 enabled for private subnets.
- Keep a simple, low-cost spot ASG model for the subnet routers. Do not add managed NAT or complex HA machinery in the initial design.
- Keep three AZs for EKS subnets and nodes. The third AZ uses a fixed route to one of the two subnet-routers for IPv4 NAT and NAT64/DNS64 traffic.
- Treat workload and chart IPv6 compatibility as an explicit implementation concern, not as something guaranteed by the cluster IP family alone.

## Current Constraints From EKS And AWS

- EKS chooses the Pod and Service IP family at cluster creation time. This cannot be changed in place later.
- EKS does not provide dual-stack Pods or Services in the documented IPv6 cluster model. An IPv6 cluster means Pods and Services use IPv6.
- The VPC must have IPv6 CIDRs associated, and subnets used by EKS must support IPv6 addressing.
- EKS IPv6 clusters require the IPv6-specific VPC CNI IAM permissions, including the `AmazonEKS_CNI_IPv6_Policy` behavior.
- IPv6 egress to IPv6 destinations does not require NAT. Private subnet outbound-only internet access should use an egress-only internet gateway.
- IPv6 Pods accessing IPv4-only destinations require translation, either through AWS-managed NAT64/DNS64 patterns or through a custom NAT64/DNS64 router. This design uses the subnet-router-hosted path.

## Architecture

The platform remains a private EKS platform accessed through persistent Tailscale subnet routers.

The VPC is dual-stack across three AZs. Existing IPv4 subnet structure remains as the minimal underlay, while public and private subnets also receive IPv6 CIDR blocks. Private subnets route IPv6 internet egress through an egress-only internet gateway. Two public subnets in different AZs host the subnet-router instances, and public subnets remain available for AWS resources that require public subnet placement.

EKS is created with IPv6 cluster networking. Pods and Services receive IPv6 addresses. The AWS VPC CNI runs in IPv6-compatible mode with the required IAM permissions. The EKS endpoint remains private-only.

The subnet-router ASGs run two Ubuntu 24.04 spot instances in different public subnets/AZs. Each router advertises the VPC IPv4 and IPv6 ranges to Tailscale. Linux forwarding is enabled for both IPv4 and IPv6. The routers keep the current IPv4 NAT role for unavoidable private-subnet IPv4 egress and add tayga NAT64 plus Unbound DNS64 fallback/diagnostics for workloads that need to reach IPv4-only internet endpoints. The two AZs with routers route IPv4 NAT and NAT64 traffic to their local router. The third AZ routes that traffic to one fixed router, accepting cross-AZ traffic for this exception path.

The shared internal ALB should be configured as dual-stack where supported. Platform DNS should allow clients to prefer IPv6 while preserving compatibility where AWS-managed load balancer behavior still exposes dual-stack plumbing.

## Traffic Flows

Normal IPv6 internet egress:

```text
Pod IPv6 -> private subnet ::/0 -> egress-only internet gateway -> IPv6 internet
```

IPv4-only internet egress from IPv6 Pods:

```text
Pod IPv6 -> DNS64 synthetic AAAA -> local or fixed subnet-router NAT64 -> IPv4 internet
```

Human access to private platform endpoints:

```text
Laptop -> Tailscale -> subnet-router -> private EKS API / internal ALB
```

Unavoidable IPv4 underlay egress:

```text
Private subnet IPv4 source -> local or fixed subnet-router IPv4 NAT -> IPv4 internet or AWS endpoint
```

## Terraform Scope

Root Terraform remains responsible for AWS infrastructure only, plus the existing Argo CD bootstrap exception already present in this repository.

Expected Terraform changes:

- `network.tf` and `locals.tf`: enable dual-stack VPC behavior, allocate IPv6 CIDRs to public and private subnets, enable IPv6 subnet behavior required by EKS, create or configure the egress-only internet gateway, and add private subnet `::/0` routing to it.
- `eks.tf`: set the EKS cluster IP family to IPv6, adjust VPC CNI add-on configuration for IPv6, and ensure the CNI has IPv6 IAM permissions.
- `tailscale-bootstrap.tf`: run the subnet-router ASG with two instances in two public subnets/AZs and pass IPv6 VPC and subnet route information into the subnet-router user data.
- `templates/bootstrap.sh.tftpl`: enable IPv6 forwarding, advertise IPv6 routes to Tailscale, keep IPv4 NAT, and configure tayga NAT64 plus Unbound DNS64 fallback/diagnostics on Ubuntu 24.04.
- `bootstrap-iam.tf`: update security group rules for IPv6 ingress/egress where needed and permit any required IPv6 route management actions if route self-configuration remains in the subnet-router.
- Private route table logic: keep three private route tables. The two router AZs use their local router for IPv4 NAT and NAT64/DNS64 routes. The third private route table points those routes to one fixed router.
- `outputs.tf`: expose IPv6 route values that need approval in Tailscale or verification during apply.
- `tests/platform_static_test.sh` and `tests/bootstrap_static_test.sh`: add regressions for IPv6 EKS, absence of NAT Gateway, egress-only IGW, IPv6 route advertisement, IPv6 forwarding, and NAT64/DNS64 configuration.

## GitOps And Workload Compatibility Scope

The GitOps tree must be reviewed for IPv6 assumptions. The implementation should not blindly add `ipFamilies` everywhere. In an EKS IPv6 cluster, Services should inherit the cluster family unless a chart hardcodes incompatible behavior. Changes should be targeted to charts that explicitly bind IPv4, configure load balancers, or rely on network assumptions that are not IPv6-safe.

Applications requiring explicit review:

- Spark Operator and Spark workloads: validate driver and executor networking, driver Service behavior, executor-to-driver discovery, pod DNS, event logs in S3, metrics, and operator status updates.
- Airflow: validate KubernetesExecutor task pods, remote logs, XCom S3 access, callbacks, and CNPG connectivity.
- CloudNativePG: validate cluster Services, pod readiness, replication, and Barman backups to S3.
- AWS Load Balancer Controller: configure internal ALB dual-stack behavior, target type `ip`, IPv6 pod targets, and health checks.
- ExternalDNS: ensure DNS records are correct for the internal dual-stack ALB.
- kube-prometheus-stack, Grafana, Loki, Promtail, and OpenTelemetry Collector: review receivers, scrape endpoints, and any bind addresses such as `0.0.0.0` that need IPv6-compatible treatment.
- Kubecost: validate metrics ingestion plus Athena and S3 access paths.

Spark is a first-class acceptance target. A minimal `SparkApplication` must run successfully, create driver and executor Pods, expose the driver Service, write event logs, and report status through the operator in the IPv6 cluster.

## NAT64/DNS64 Direction

The subnet-router instances host the IPv4 translation path instead of using AWS NAT Gateway. Implementation testing replaced the Amazon Linux 2023 assumption with Ubuntu 24.04 because AL2023 does not package tayga or jool. The required behavior is fixed:

- IPv6 Pods resolve IPv4-only names into synthetic IPv6 addresses through private subnet DNS64, with local Unbound available on each subnet router as fallback and diagnostics.
- Traffic to the NAT64 prefix routes to a local subnet-router in router AZs, or to one fixed subnet-router from the third AZ.
- The subnet-router translates that traffic to IPv4 and forwards it to the IPv4 internet.
- The implementation uses packaged tayga for NAT64 and stays small and inspectable, matching the existing bootstrap script style.
- No managed NAT Gateway is introduced.

Because the ASG remains spot-based and intentionally simple, disruption to some Tailscale access, IPv4 NAT, and IPv4-only egress through NAT64 is acceptable during router replacement. Native IPv6 egress through the egress-only internet gateway should remain independent of NAT64 availability.

## Risks

- A wrong EKS IP family choice requires cluster recreation.
- Some AWS add-ons or Helm charts may still assume IPv4 behavior and need targeted fixes.
- Subnet-router-hosted NAT64/DNS64 is a custom operations surface.
- The subnet-router pair becomes responsible for private access, IPv4 NAT, and NAT64 translation.
- Spot interruption can temporarily affect Tailscale access and IPv4-only egress routed through the interrupted router.
- The third AZ's IPv4-only egress path depends on a fixed router in another AZ and can incur cross-AZ traffic charges.
- ALB dual-stack and IPv6 pod targets require careful AWS Load Balancer Controller configuration.
- Public DNS names remain discoverable, while the ALB remains internal and reachable only through VPC/Tailscale paths.

## Acceptance Criteria

- Terraform validation and static tests pass.
- Terraform creates no `aws_nat_gateway` resources.
- The VPC and EKS subnets have IPv6 CIDRs.
- The EKS cluster is created with IPv6 Pod and Service networking.
- Private subnets route `::/0` to an egress-only internet gateway.
- IPv4 NAT and NAT64 routes are explicit: router AZs use local routers, and the third AZ points to one fixed router.
- The subnet-router instances advertise the approved IPv6 VPC route through Tailscale.
- The subnet-router instances enable IPv4 and IPv6 forwarding.
- The subnet-router instances keep IPv4 NAT and provide NAT64/DNS64.
- A test Pod reaches an IPv6 internet endpoint without NAT Gateway.
- A test Pod reaches an IPv4-only internet endpoint through NAT64/DNS64.
- Local `kubectl` reaches the private EKS API through Tailscale.
- Platform URLs resolve and reach the shared internal ALB, preferring IPv6 where available.
- A minimal SparkApplication succeeds with driver, executors, driver Service, operator status, and event logs.
- An Airflow KubernetesExecutor task pod runs and reaches CNPG and S3.
- Observability components collect Prometheus metrics plus Loki, Promtail, and OTLP logs in the IPv6 cluster.

## Out Of Scope

- Migrating an existing EKS cluster to IPv6.
- Adding AWS NAT Gateway for IPv4 or NAT64 egress.
- Reintroducing the Tailscale Kubernetes Operator or API server proxy path.
- Reintroducing root Terraform Helm delivery for platform services beyond the current Argo CD bootstrap exception.
- Adding complex route failover or managed HA for NAT64 in the first implementation.
