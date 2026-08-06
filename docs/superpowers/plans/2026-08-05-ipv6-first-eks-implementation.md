# IPv6-First EKS Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Convert the greenfield EKS platform to IPv6-first networking with no AWS NAT Gateway, native IPv6 egress, and subnet-router-hosted IPv4/NAT64 fallback.

**Architecture:** The VPC stays dual-stack across three AZs. EKS is created with IPv6 Pod/Service networking. IPv6 egress uses an egress-only internet gateway, while two Tailscale subnet-router spot ASGs in different AZs provide private access, IPv4 NAT, and NAT64/DNS64; the third AZ uses a fixed route to one router for IPv4-only egress.

**Tech Stack:** Terraform, terraform-aws-vpc `~> 6.0`, terraform-aws-eks `~> 21.0`, AWS EC2 route tables, Ubuntu 24.04 cloud-init, Tailscale subnet routing, Helm GitOps charts, Argo CD.

**Commit Policy:** Do not commit during execution unless the user explicitly requests it. Stage nothing unless asked.

**AWS Profile:** Use `AWS_PROFILE=victor` for Terraform commands that may initialize, validate, plan, apply, or query AWS-backed provider/backend state.

---

## File Structure

- Modify `.gitignore`: keep `.superpowers/` ignored for local brainstorming artifacts.
- Modify `locals.tf`: add IPv6 subnet prefix locals and subnet-router AZ selection locals.
- Modify `network.tf`: enable VPC IPv6, assign IPv6 prefixes, enable egress-only IGW, and preserve no NAT Gateway.
- Modify `eks.tf`: set `ip_family = "ipv6"`, create the CNI IPv6 IAM policy, and keep VPC CNI network policy enabled.
- Modify `karpenter.tf`: pass `cluster_ip_family = module.eks.cluster_ip_family` to the Karpenter submodule so node IAM policy selection matches IPv6.
- Modify `bootstrap-iam.tf`: add IPv6 security group rules and allow IPv6 route replacement/creation.
- Modify `tailscale-bootstrap.tf`: change subnet-router capacity from 3 instances to 2 single-instance ASGs pinned to two public subnets/AZs, and pass IPv6/NAT64 route inputs to cloud-init.
- Modify `templates/bootstrap.sh.tftpl`: enable IPv6 forwarding, advertise IPv6 Tailscale routes, configure IPv4 NAT routes and NAT64 prefix routes, and install/configure DNS64/NAT64 services.
- Modify `outputs.tf`: add IPv6 route outputs and update subnet-router ASG outputs for two ASGs.
- Modify `gitops/base/templates/ingresses.yaml`: add ALB dual-stack annotation to platform ingresses.
- Modify `gitops/apps/kube-prometheus-stack/values.yaml`: add ALB dual-stack annotation to Grafana ingress if it is independently rendered by that chart.
- Modify `gitops/apps/spark-history-server/values.yaml`: add ALB dual-stack annotation to Spark History Server ingress if it is independently rendered by that chart.
- Modify `gitops/apps/otel-collector/values.yaml`: replace IPv4-only OTLP bind addresses with IPv6-compatible binds.
- Modify `gitops/apps/spark-operator/values.yaml` and `gitops/root/templates/applications.yaml`: add Spark IPv6-safe defaults that are supported by the chart and keep the operator watching the configured Spark workload namespace.
- Modify `tests/platform_static_test.sh`: update static assertions for IPv6 EKS, dual-stack VPC, egress-only IGW, no NAT Gateway, ALB dual-stack, and app IPv6 compatibility checks.
- Modify `tests/bootstrap_static_test.sh`: update static assertions for two subnet routers, IPv6 forwarding, IPv6 route advertisement, NAT64/DNS64, and fixed third-AZ routing.
- Optionally modify `README.md` and `AGENTS.md`: update architecture text after implementation passes validation.

---

### Task 1: Update Static Tests For The New IPv6 Contract

**Files:**
- Modify: `tests/bootstrap_static_test.sh`
- Modify: `tests/platform_static_test.sh`

- [ ] **Step 1: Update subnet-router count expectations**

In `tests/bootstrap_static_test.sh`, replace the checks expecting `min_size = 3` and `desired_capacity = 3` with checks expecting per-ASG single-instance capacity and two ASGs:

```bash
if ! grep -q 'count = var.enable_bootstrap_instance ? 2 : 0' "$bootstrap_tf"; then
  printf 'expected two subnet-router ASGs in different AZs\n' >&2
  exit 1
fi

for size in min_size max_size desired_capacity; do
  if ! grep -q "${size} *= *1" "$bootstrap_tf"; then
    printf 'expected subnet-router ASGs to use %s of 1\n' "$size" >&2
    exit 1
  fi
done
```

- [ ] **Step 2: Add IPv6 and NAT64 bootstrap assertions**

Append these assertions to `tests/bootstrap_static_test.sh` after the existing IPv4 forwarding/NAT checks:

```bash
if ! grep -q 'net.ipv6.conf.all.forwarding = 1' "$bootstrap"; then
  printf 'expected bootstrap to enable IPv6 forwarding for subnet routing and NAT64\n' >&2
  exit 1
fi

if ! grep -q 'VPC_IPV6_CIDR' "$bootstrap"; then
  printf 'expected bootstrap to receive the VPC IPv6 CIDR\n' >&2
  exit 1
fi

if ! grep -q 'NAT64_PREFIX' "$bootstrap"; then
  printf 'expected bootstrap to configure a NAT64 prefix\n' >&2
  exit 1
fi

if ! grep -q -- '--destination-ipv6-cidr-block' "$bootstrap"; then
  printf 'expected bootstrap to manage IPv6 route-table entries\n' >&2
  exit 1
fi

if ! grep -q 'DNS64' "$bootstrap" && ! grep -qi 'dns64' "$bootstrap"; then
  printf 'expected bootstrap to configure DNS64\n' >&2
  exit 1
fi

if ! grep -q 'NAT64' "$bootstrap" && ! grep -qi 'nat64' "$bootstrap"; then
  printf 'expected bootstrap to configure NAT64\n' >&2
  exit 1
fi

if ! grep -q 'private_route_table_ids_by_router_az' "$bootstrap_tf"; then
  printf 'expected Terraform to pass router-AZ route-table assignments\n' >&2
  exit 1
fi
```

- [ ] **Step 3: Add Terraform IPv6 platform assertions**

Append these assertions to `tests/platform_static_test.sh` near the existing VPC/EKS checks:

```bash
if ! grep -q 'enable_ipv6 *= *true' network.tf; then
  printf 'expected VPC IPv6 to be enabled\n' >&2
  exit 1
fi

if ! grep -q 'create_egress_only_igw *= *true' network.tf; then
  printf 'expected egress-only internet gateway for IPv6 private egress\n' >&2
  exit 1
fi

if ! grep -q 'public_subnet_ipv6_prefixes' network.tf || ! grep -q 'private_subnet_ipv6_prefixes' network.tf; then
  printf 'expected IPv6 prefixes assigned to public and private subnets\n' >&2
  exit 1
fi

if grep -q 'resource "aws_nat_gateway"' ./*.tf || grep -q 'enable_nat_gateway *= *true' network.tf; then
  printf 'expected no AWS NAT Gateway resources\n' >&2
  exit 1
fi

if ! grep -q 'ip_family *= *"ipv6"' eks.tf; then
  printf 'expected EKS cluster IP family to be IPv6\n' >&2
  exit 1
fi

if ! grep -q 'create_cni_ipv6_iam_policy *= *true' eks.tf; then
  printf 'expected EKS module to create the VPC CNI IPv6 IAM policy\n' >&2
  exit 1
fi

if ! grep -q 'cluster_ip_family *= *module.eks.cluster_ip_family' karpenter.tf; then
  printf 'expected Karpenter module to use the EKS cluster IP family\n' >&2
  exit 1
fi
```

- [ ] **Step 4: Add GitOps IPv6 compatibility assertions**

Append these assertions to `tests/platform_static_test.sh` near the GitOps checks:

```bash
if ! grep -R -q 'alb.ingress.kubernetes.io/ip-address-type: dualstack' gitops; then
  printf 'expected ALB ingresses to request dualstack address type\n' >&2
  exit 1
fi

if ! grep -q '\[::\]:4317' gitops/apps/otel-collector/values.yaml || ! grep -q '\[::\]:4318' gitops/apps/otel-collector/values.yaml; then
  printf 'expected OpenTelemetry Collector OTLP receivers to bind on IPv6-compatible addresses\n' >&2
  exit 1
fi

if ! grep -R -q 'SPARK_LOCAL_IP' gitops/apps/spark-operator gitops/root/templates; then
  printf 'expected Spark IPv6 compatibility configuration to be explicit\n' >&2
  exit 1
fi
```

- [ ] **Step 5: Run static tests and confirm they fail**

Run:

```bash
bash tests/bootstrap_static_test.sh
bash tests/platform_static_test.sh
```

Expected: both fail on the new IPv6 expectations before implementation.

---

### Task 2: Enable Dual-Stack VPC And IPv6 Egress

**Files:**
- Modify: `locals.tf`
- Modify: `network.tf`
- Modify: `outputs.tf`

- [ ] **Step 1: Add IPv6 subnet and router selection locals**

In `locals.tf`, inside `locals { ... }`, add these locals after `private_subnets`:

```hcl
  public_subnet_ipv6_prefixes = [0, 1, 2]

  private_subnet_ipv6_prefixes = [3, 4, 5]

  subnet_router_azs = slice(local.azs, 0, 2)

  subnet_router_primary_az = local.subnet_router_azs[0]

  nat64_prefix = "64:ff9b::/96"
```

- [ ] **Step 2: Enable VPC IPv6 in the module**

In `network.tf`, add these arguments to `module "vpc"` after `private_subnets = local.private_subnets`:

```hcl
  enable_ipv6 = true

  public_subnet_ipv6_prefixes  = local.public_subnet_ipv6_prefixes
  private_subnet_ipv6_prefixes = local.private_subnet_ipv6_prefixes

  public_subnet_assign_ipv6_address_on_creation  = true
  private_subnet_assign_ipv6_address_on_creation = true

  create_egress_only_igw = true
```

Keep this existing line unchanged:

```hcl
  enable_nat_gateway = false
```

- [ ] **Step 3: Add IPv6 outputs**

In `outputs.tf`, add:

```hcl
output "vpc_ipv6_cidr_block" {
  description = "Amazon-provided IPv6 CIDR block associated with the VPC."
  value       = module.vpc.vpc_ipv6_cidr_block
}

output "private_subnet_ipv6_cidr_blocks" {
  description = "IPv6 CIDR blocks assigned to private EKS subnets."
  value       = module.vpc.private_subnets_ipv6_cidr_blocks
}

output "tailscale_subnet_ipv6_route" {
  description = "VPC IPv6 CIDR advertised by the Tailscale subnet routers. Approve this route in the Tailscale admin console."
  value       = module.vpc.vpc_ipv6_cidr_block
}
```

- [ ] **Step 4: Run Terraform formatting**

Run:

```bash
terraform fmt -recursive *.tf
```

Expected: Terraform files format successfully.

---

### Task 3: Configure EKS And Karpenter For IPv6

**Files:**
- Modify: `eks.tf`
- Modify: `karpenter.tf`

- [ ] **Step 1: Add EKS IPv6 module inputs**

In `eks.tf`, inside `module "eks"`, add after `kubernetes_version = var.cluster_version`:

```hcl
  ip_family                  = "ipv6"
  create_cni_ipv6_iam_policy = true
```

- [ ] **Step 2: Keep VPC CNI network policy while allowing IPv6 mode**

Keep the existing VPC CNI add-on configuration, including:

```hcl
        env = {
          ENABLE_PREFIX_DELEGATION = "true"
          WARM_PREFIX_TARGET       = "1"
          ENABLE_NETWORK_POLICY    = "true"
        }
```

Do not add IPv4 service CIDR settings, because EKS IPv6 service CIDR is assigned by EKS.

- [ ] **Step 3: Pass cluster IP family to Karpenter module**

In `karpenter.tf`, add inside `module "karpenter"` after `namespace = "karpenter"`:

```hcl
  cluster_ip_family = module.eks.cluster_ip_family
```

- [ ] **Step 4: Run Terraform formatting**

Run:

```bash
terraform fmt -recursive *.tf
```

Expected: Terraform files format successfully.

---

### Task 4: Convert Subnet Router To Two AZ-Pinned ASGs

**Files:**
- Modify: `tailscale-bootstrap.tf`
- Modify: `outputs.tf`

- [ ] **Step 1: Pass IPv6 and route assignment values to user data**

In `tailscale-bootstrap.tf`, extend the `templatefile` map with:

```hcl
    vpc_ipv6_cidr = module.vpc.vpc_ipv6_cidr_block
    nat64_prefix  = local.nat64_prefix
    private_route_table_ids_by_router_az = jsonencode({
      for az, route_table_ids in local.private_route_table_ids_by_router_az : az => route_table_ids
    })
```

Keep the existing `private_route_table_by_az` value until the bootstrap template no longer uses it.

- [ ] **Step 2: Change ASG count and subnet placement**

In `resource "aws_autoscaling_group" "subnet_router"`, change:

```hcl
  count = var.enable_bootstrap_instance ? 1 : 0

  name                = "${local.name}-subnet-router"
  vpc_zone_identifier = module.vpc.public_subnets
  min_size            = 3
  max_size            = 3
  desired_capacity    = 3
```

to:

```hcl
  count = var.enable_bootstrap_instance ? 2 : 0

  name                = "${local.name}-subnet-router-${local.subnet_router_azs[count.index]}"
  vpc_zone_identifier = [module.vpc.public_subnets[count.index]]
  min_size            = 1
  max_size            = 1
  desired_capacity    = 1
```

- [ ] **Step 3: Make ASG Name tags AZ-specific**

In the ASG `tag` block, change:

```hcl
    value               = "${local.name}-subnet-router"
```

to:

```hcl
    value               = "${local.name}-subnet-router-${local.subnet_router_azs[count.index]}"
```

- [ ] **Step 4: Update subnet-router output**

In `outputs.tf`, replace `output "bootstrap_instance_id"` with:

```hcl
output "subnet_router_asg_names" {
  description = "Subnet router Auto Scaling Group names when enabled."
  value       = [for asg in aws_autoscaling_group.subnet_router : asg.name]
}
```

- [ ] **Step 5: Run formatting**

Run:

```bash
terraform fmt -recursive *.tf
```

Expected: Terraform files format successfully.

---

### Task 5: Add IPv6 Security Group And Route Permissions

**Files:**
- Modify: `bootstrap-iam.tf`

- [ ] **Step 1: Add IPv6 ingress from private subnets**

In `aws_security_group.bootstrap`, add after the existing IPv4 ingress block:

```hcl
  ingress {
    description      = "Allow all IPv6 traffic from private subnets for subnet routing and NAT64"
    from_port        = 0
    to_port          = 0
    protocol         = "-1"
    ipv6_cidr_blocks = module.vpc.private_subnets_ipv6_cidr_blocks
  }
```

- [ ] **Step 2: Add IPv6 egress**

In `aws_security_group.bootstrap`, add after the existing IPv4 egress block:

```hcl
  egress {
    description      = "Allow all IPv6 outbound traffic for subnet routing"
    from_port        = 0
    to_port          = 0
    protocol         = "-1"
    ipv6_cidr_blocks = ["::/0"]
  }
```

- [ ] **Step 3: Keep EC2 route permissions broad enough for IPv6 route replacement**

Keep the existing `ec2:ReplaceRoute` and `ec2:CreateRoute` actions. Do not narrow them to IPv4-only conditions. The same actions are used for routes with `--destination-ipv6-cidr-block`.

- [ ] **Step 4: Run formatting**

Run:

```bash
terraform fmt -recursive *.tf
```

Expected: Terraform files format successfully.

---

### Task 6: Update Bootstrap Script For IPv6 Routing And NAT64/DNS64

**Files:**
- Modify: `templates/bootstrap.sh.tftpl`

- [ ] **Step 1: Add new template variables**

At the top of `templates/bootstrap.sh.tftpl`, after `export VPC_CIDR="${vpc_cidr}"`, add:

```bash
export VPC_IPV6_CIDR="${vpc_ipv6_cidr}"
NAT64_PREFIX="${nat64_prefix}"
RTB_IDS_BY_ROUTER_AZ='${private_route_table_ids_by_router_az}'
```

- [ ] **Step 2: Enable IPv6 forwarding**

Replace the sysctl file content with:

```bash
cat >/etc/sysctl.d/99-tailscale.conf <<'EOF'
net.ipv4.ip_forward = 1
net.ipv6.conf.all.forwarding = 1
EOF
sysctl -p /etc/sysctl.d/99-tailscale.conf
```

- [ ] **Step 3: Replace IPv4 route setup with route-table list handling**

Replace the current single `RTB_ID=$(...)` route block with:

```bash
RTB_IDS=$(echo "$RTB_IDS_BY_ROUTER_AZ" | jq -r --arg az "$AZ" '.[$az][]?')
if [[ -z "$RTB_IDS" ]]; then
  echo "No private route tables assigned to subnet router AZ $AZ"
  exit 1
fi

while IFS= read -r RTB_ID; do
  aws ec2 replace-route \
    --route-table-id "$RTB_ID" \
    --destination-cidr-block 0.0.0.0/0 \
    --network-interface-id "$ENI_ID" \
    --region "$REGION" \
    || aws ec2 create-route \
      --route-table-id "$RTB_ID" \
      --destination-cidr-block 0.0.0.0/0 \
      --network-interface-id "$ENI_ID" \
      --region "$REGION"

  aws ec2 replace-route \
    --route-table-id "$RTB_ID" \
    --destination-ipv6-cidr-block "$NAT64_PREFIX" \
    --network-interface-id "$ENI_ID" \
    --region "$REGION" \
    || aws ec2 create-route \
      --route-table-id "$RTB_ID" \
      --destination-ipv6-cidr-block "$NAT64_PREFIX" \
      --network-interface-id "$ENI_ID" \
      --region "$REGION"
done <<< "$RTB_IDS"
```

- [ ] **Step 4: Advertise IPv6 route through Tailscale**

Change the `tailscale up` route argument to:

```bash
  --advertise-routes="$VPC_CIDR,$VPC_IPV6_CIDR,${vpc_cidr_resolver}/32" \
```

- [ ] **Step 5: Add DNS64 resolver configuration**

After Tailscale startup and before NAT services, add:

```bash
apt-get install -y unbound

cat >/etc/unbound/conf.d/dns64.conf <<EOF
server:
  interface: 169.254.20.10
  access-control: ${vpc_cidr} allow
  do-ip4: yes
  do-ip6: yes
  do-udp: yes
  do-tcp: yes
  dns64-prefix: $NAT64_PREFIX
forward-zone:
  name: "."
  forward-addr: ${vpc_cidr_resolver}
EOF

systemctl enable --now unbound
```

- [ ] **Step 6: Leave NAT64 service creation to Task 7**

Do not add a placeholder NAT64 service in this task. Task 7 selects the supported Ubuntu 24.04 NAT64 implementation and adds the complete service. At the end of Task 6, the bootstrap script should include IPv6 forwarding, IPv4 NAT, DNS64, and NAT64 route-table entries, but not an incomplete NAT64 daemon.

- [ ] **Step 7: Run shell syntax check**

Run:

```bash
bash -n templates/bootstrap.sh.tftpl
```

Expected: syntax check passes.

---

### Task 7: Select And Implement NAT64 On Ubuntu 24.04

**Files:**
- Modify: `templates/bootstrap.sh.tftpl`
- Optionally Create: `docs/superpowers/specs/2026-08-05-nat64-runtime-note.md`

- [ ] **Step 1: Check available NAT64 package options locally**

Run:

```bash
docker run --rm ubuntu:24.04 sh -lc 'apt-get update >/dev/null && apt-cache search "^(tayga|jool)" || true'
```

Expected: command completes. If `tayga` is available, use Task 7 Step 2. If `tayga` is not available but `jool` is available, use Task 7 Step 3.

- [ ] **Step 2: Implement NAT64 with tayga when available**

If `tayga` is available, add this to `templates/bootstrap.sh.tftpl` before creating `nat64.service`:

```bash
apt-get install -y tayga
mkdir -p /var/lib/tayga

cat >/etc/tayga.conf <<EOF
tun-device nat64
ipv4-addr 192.0.2.1
prefix $NAT64_PREFIX
dynamic-pool 192.0.2.0/24
data-dir /var/lib/tayga
EOF

cat >/usr/local/sbin/nat64-setup <<'EOF'
#!/bin/sh
set -eu
/usr/sbin/tayga --mktun || true
/usr/sbin/ip link set nat64 up
/usr/sbin/ip route replace 192.0.2.0/24 dev nat64
/usr/sbin/ip -6 route replace 64:ff9b::/96 dev nat64
/usr/sbin/iptables -t nat -C POSTROUTING -s 192.0.2.0/24 -j MASQUERADE || /usr/sbin/iptables -t nat -A POSTROUTING -s 192.0.2.0/24 -j MASQUERADE
/usr/sbin/tayga
EOF
chmod 0755 /usr/local/sbin/nat64-setup
```

Then add the NAT64 service:

```bash
cat >/etc/systemd/system/nat64.service <<'EOF'
[Unit]
Description=Enable NAT64 translation for IPv6 workloads reaching IPv4-only endpoints
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/nat64-setup
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
```

- [ ] **Step 3: Stop and ask for a narrower NAT64 decision if no package is available**

If neither `tayga` nor a usable packaged NAT64 implementation is available on Ubuntu 24.04, stop execution and report the exact package search output. Do not compile kernel modules or source packages in cloud-init without user approval.

- [ ] **Step 4: Enable NAT64 service after implementation is selected**

After the `nat64.service` definition, add:

```bash
systemctl daemon-reload
systemctl enable --now nat64.service
```

- [ ] **Step 5: Run shell syntax check**

Run:

bash -n templates/bootstrap.sh.tftpl

Expected: syntax check passes.

---

### Task 8: Add GitOps IPv6 Compatibility

**Files:**
- Modify: `gitops/base/templates/ingresses.yaml`
- Modify: `gitops/apps/kube-prometheus-stack/values.yaml`
- Modify: `gitops/apps/spark-history-server/values.yaml`
- Modify: `gitops/apps/otel-collector/values.yaml`
- Modify: `gitops/apps/spark-operator/values.yaml`
- Modify: `gitops/root/templates/applications.yaml`

- [ ] **Step 1: Add dual-stack ALB annotation to base ingresses**

For each Ingress in `gitops/base/templates/ingresses.yaml`, add this annotation under the existing ALB annotations:

```yaml
    alb.ingress.kubernetes.io/ip-address-type: dualstack
```

- [ ] **Step 2: Add dual-stack ALB annotation to chart-owned ingresses**

In `gitops/apps/kube-prometheus-stack/values.yaml` and `gitops/apps/spark-history-server/values.yaml`, add this annotation wherever the chart defines ALB ingress annotations:

```yaml
        alb.ingress.kubernetes.io/ip-address-type: dualstack
```

Use the existing indentation of each file.

- [ ] **Step 3: Update OpenTelemetry receiver binds**

In `gitops/apps/otel-collector/values.yaml`, replace:

```yaml
            endpoint: 0.0.0.0:4317
            endpoint: 0.0.0.0:4318
```

with:

```yaml
            endpoint: "[::]:4317"
            endpoint: "[::]:4318"
```

- [ ] **Step 4: Add Spark IPv6-safe environment configuration**

In `gitops/apps/spark-operator/values.yaml`, add an explicit Spark driver/executor environment value if supported by the chart values schema:

```yaml
spark-operator:
  webhook:
    enable: true
  spark:
    env:
      - name: SPARK_LOCAL_IP
        valueFrom:
          fieldRef:
            fieldPath: status.podIP
```

If the chart does not support `spark.env`, move this value into the root Application values block for Spark workload defaults in `gitops/root/templates/applications.yaml` and preserve the existing `jobNamespaces` value.

- [ ] **Step 5: Preserve Spark Operator namespace watch**

In `gitops/root/templates/applications.yaml`, keep this block intact:

```yaml
        spark-operator:
          spark:
            jobNamespaces:
              - {{ $.Values.global.sparkWorkloadNamespace | quote }}
```

If Step 4 adds Spark environment under the same `spark:` key, merge it without duplicating `spark:`.

- [ ] **Step 6: Render-check Helm templates locally**

Run:

```bash
helm template gitops/base
helm template gitops/apps/spark-operator
helm template gitops/apps/otel-collector
```

Expected: all three charts render without YAML errors.

---

### Task 9: Update Documentation For New Topology

**Files:**
- Modify: `README.md`
- Modify: `AGENTS.md`

- [ ] **Step 1: Update README architecture summary**

In `README.md`, update the opening architecture description to mention IPv6-first EKS, dual-stack VPC, egress-only IGW, and two subnet routers.

Use this text:

```markdown
Production-grade private Amazon EKS platform accessed through Tailscale subnet routers. The VPC is dual-stack, EKS Pods and Services use IPv6, normal IPv6 egress uses an egress-only internet gateway, and IPv4-only egress is translated by the subnet-router layer without AWS NAT Gateway. Infrastructure is created by Terraform. Platform services are reconciled by Argo CD through a GitOps app-of-apps tree. All UIs are exposed through one shared internal dual-stack AWS Application Load Balancer, protected by ACM TLS, with DNS managed by ExternalDNS in Route 53.
```

- [ ] **Step 2: Update README resource table**

In the Terraform resource table, update the VPC and subnet-router rows to:

```markdown
| VPC (dual-stack public/private subnets, IPv6 egress-only IGW, no NAT Gateway) | `network.tf`, `locals.tf` |
| Subnet router ASGs (2 spot instances across 2 AZs, Tailscale + IPv4 NAT + NAT64/DNS64) | `tailscale-bootstrap.tf` |
```

- [ ] **Step 3: Update AGENTS architecture bullets**

In `AGENTS.md`, update bullets that currently say 3 subnet-router instances or IPv4-only CIDR advertisement to describe:

```markdown
- The VPC is dual-stack across three AZs. EKS Pods and Services use IPv6.
- Private subnet IPv6 egress uses an egress-only internet gateway and does not use AWS NAT Gateway.
- The subnet router runs as two spot-backed Auto Scaling Groups in two AZs.
- The third AZ routes IPv4 NAT and NAT64/DNS64 traffic to one fixed subnet-router.
- The subnet routers advertise the VPC IPv4 and IPv6 CIDRs through Tailscale.
```

- [ ] **Step 4: Keep removed paths absent**

Do not add references to Tailscale Kubernetes Operator, Tailscale API server proxy, platform Terraform apply targets, or AWS NAT Gateway.

---

### Task 10: Run Full Validation

**Files:**
- No code changes unless validation reveals a failure.

- [ ] **Step 1: Run shell syntax checks**

Run:

```bash
bash -n tests/platform_static_test.sh
bash -n tests/bootstrap_static_test.sh
bash -n templates/bootstrap.sh.tftpl
```

Expected: all syntax checks pass.

- [ ] **Step 2: Run static tests**

Run:

```bash
bash tests/platform_static_test.sh
bash tests/bootstrap_static_test.sh
```

Expected: both tests pass.

- [ ] **Step 3: Run Terraform formatting check**

Run:

```bash
terraform fmt -check -recursive *.tf
```

Expected: formatting check passes.

- [ ] **Step 4: Run Terraform validate**

Run:

```bash
AWS_PROFILE=victor terraform validate
```

Expected: validation passes. If `terraform.tfvars` contains stale removed variables, report the warning separately and do not edit `terraform.tfvars`.

- [ ] **Step 5: Inspect final diff**

Run:

```bash
git diff -- . ':!terraform.tfvars'
```

Expected: diff only includes intentional IPv6-first changes, tests, docs, and `.gitignore`.

---

## Self-Review

- Spec coverage: The plan covers IPv6 EKS, dual-stack VPC, egress-only IGW, no NAT Gateway, two subnet routers, fixed third-AZ NAT/NAT64 routing, Tailscale IPv6 route advertisement, NAT64/DNS64, ALB dual-stack, Spark-specific review, observability bind review, docs, and validation.
- Placeholder scan: No unfinished `TODO`, `TBD`, or unspecified test commands remain. NAT64 package choice is represented as an explicit execution gate with concrete allowed outcomes.
- Type consistency: Terraform names used by tests match planned resources and locals: `ip_family`, `create_cni_ipv6_iam_policy`, `cluster_ip_family`, `private_route_table_ids_by_router_az`, and `nat64_prefix`.
