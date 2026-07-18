# Private Subnets + NAT Instance Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add three private `/20` subnets, turn the Tailscale subnet-router EC2 into the NAT instance for private egress, and move EKS nodes/Karpenter into private subnets.

**Architecture:** Keep 3 public `/24` subnets (IGW route, subnet-router, EKS control-plane ENIs). Add 3 private `/20` subnets routed through the subnet-router ENI (`source_dest_check=false`, iptables MASQUERADE). EKS node subnets and the `karpenter.sh/discovery` tag move to private subnets. No NAT Gateway.

**Tech Stack:** Terraform (AWS provider ~6, terraform-aws-modules/vpc ~6, eks ~21), AL2023 user_data (iptables-nft), bash static tests.

**Spec:** `docs/superpowers/specs/2026-07-18-private-subnets-nat-instance-design.md`

**Pre-flight warnings (read before apply):**
- The EKS default managed node group will be **replaced** (subnet change forces replacement). Karpenter capacity stays; expect node churn.
- The internal ALB will be **recreated in private subnets** by the AWS Load Balancer Controller after the `internal-elb` tag moves. Route53 names stay the same (ALB DNS name target), but there is a brief endpoint change.
- The existing subnet-router has `lifecycle { ignore_changes = [user_data] }`, so the new NAT rules **will not reach it via Terraform**. Task 7 applies them manually over SSH.

---

### Task 1: Failing static tests for private network layer

**Files:**
- Modify: `tests/platform_static_test.sh` (append at end)
- Modify: `tests/bootstrap_static_test.sh` (append at end)

- [ ] **Step 1: Append network assertions to `tests/platform_static_test.sh`**

```bash
if ! grep -q 'cidrsubnet(var.vpc_cidr, 4, index + 1)' locals.tf; then
  printf 'expected private /20 subnets via cidrsubnet newbits 4 netnum index+1\n' >&2
  exit 1
fi

if ! grep -q 'private_subnets = local.private_subnets' network.tf; then
  printf 'expected VPC module to create private subnets\n' >&2
  exit 1
fi

if ! grep -A3 'private_subnet_tags' network.tf | grep -q 'kubernetes.io/role/internal-elb'; then
  printf 'expected internal-elb tag on private subnets\n' >&2
  exit 1
fi

if ! grep -A3 'private_subnet_tags' network.tf | grep -q 'karpenter.sh/discovery'; then
  printf 'expected karpenter discovery tag on private subnets\n' >&2
  exit 1
fi

if grep -A3 'public_subnet_tags' network.tf | grep -q 'internal-elb\|karpenter.sh/discovery'; then
  printf 'expected internal-elb and karpenter discovery tags removed from public subnets\n' >&2
  exit 1
fi

if grep -q 'enable_nat_gateway = true' network.tf; then
  printf 'expected no AWS NAT Gateway (subnet-router is the NAT instance)\n' >&2
  exit 1
fi

if ! grep -q 'resource "aws_route" "private_nat_instance"' network.tf; then
  printf 'expected private default route through the subnet-router ENI\n' >&2
  exit 1
fi

if ! grep -q 'network_interface_id   = aws_instance.bootstrap\[0\].primary_network_interface_id' network.tf; then
  printf 'expected private default route to target the bootstrap primary ENI\n' >&2
  exit 1
fi

if ! grep -q 'route_table_ids = module.vpc.private_route_table_ids' network.tf; then
  printf 'expected S3 gateway endpoint attached to private route tables\n' >&2
  exit 1
fi

if ! grep -q 'source_dest_check *= *false' tailscale-bootstrap.tf; then
  printf 'expected source_dest_check=false on the NAT instance\n' >&2
  exit 1
fi

if ! grep -q 'subnet_ids               = module.vpc.private_subnets' eks.tf; then
  printf 'expected EKS subnet_ids to use private subnets\n' >&2
  exit 1
fi

if ! grep -q 'control_plane_subnet_ids = module.vpc.public_subnets' eks.tf; then
  printf 'expected EKS control plane to stay on public subnets\n' >&2
  exit 1
fi

if ! grep -q '      subnet_ids = module.vpc.private_subnets' eks.tf; then
  printf 'expected default node group to use private subnets\n' >&2
  exit 1
fi
```

- [ ] **Step 2: Append NAT assertions to `tests/bootstrap_static_test.sh`**

```bash
if ! grep -q 'MASQUERADE' "$bootstrap"; then
  printf 'expected bootstrap template to configure NAT masquerade\n' >&2
  exit 1
fi

if ! grep -q 'nat-masquerade.service' "$bootstrap"; then
  printf 'expected bootstrap template to persist NAT masquerade via systemd\n' >&2
  exit 1
fi

if ! grep -q 'protocol    = "-1"' bootstrap-iam.tf; then
  printf 'expected bootstrap security group to allow forwarded traffic\n' >&2
  exit 1
fi
```

- [ ] **Step 3: Run tests to verify they fail**

Run: `rtk bash tests/platform_static_test.sh`
Expected: FAIL with "expected private /20 subnets via cidrsubnet newbits 4 netnum index+1"

- [ ] **Step 4: Commit**

```bash
git add tests/platform_static_test.sh tests/bootstrap_static_test.sh
git commit -m "test: add static assertions for private subnets and nat instance"
```

---

### Task 2: Private subnets in locals.tf

**Files:**
- Modify: `locals.tf:14-16`

- [ ] **Step 1: Add `private_subnets` local after `public_subnets`**

```hcl
  public_subnets = [
    for index, _ in local.azs : cidrsubnet(var.vpc_cidr, 8, index)
  ]

  private_subnets = [
    for index, _ in local.azs : cidrsubnet(var.vpc_cidr, 4, index + 1)
  ]
```

(`cidrsubnet("10.0.0.0/16", 4, 1..3)` → `10.0.16.0/20`, `10.0.32.0/20`, `10.0.48.0/20` — no overlap with public `/24`s.)

- [ ] **Step 2: Run tests — first assertion should pass now, next should fail**

Run: `rtk bash tests/platform_static_test.sh`
Expected: FAIL with "expected VPC module to create private subnets"

- [ ] **Step 3: Commit**

```bash
git add locals.tf
git commit -m "feat: define private /20 subnet cidrs"
```

---

### Task 3: VPC module private subnets, tags, NAT route, S3 endpoint

**Files:**
- Modify: `network.tf`

- [ ] **Step 1: Update the `vpc` module block**

```hcl
module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 6.0"

  name = local.name
  cidr = var.vpc_cidr
  azs  = local.azs

  public_subnets  = local.public_subnets
  private_subnets = local.private_subnets

  enable_dns_hostnames = true
  enable_dns_support   = true

  enable_nat_gateway = false

  map_public_ip_on_launch = true

  public_subnet_tags = {
    "kubernetes.io/role/elb" = "1"
  }

  private_subnet_tags = {
    "kubernetes.io/role/internal-elb" = "1"
    "karpenter.sh/discovery"          = local.name
  }

  tags = local.tags
}
```

- [ ] **Step 2: Add the private default route through the NAT instance (end of `network.tf`)**

```hcl
resource "aws_route" "private_nat_instance" {
  count = var.enable_bootstrap_instance ? length(module.vpc.private_route_table_ids) : 0

  route_table_id         = module.vpc.private_route_table_ids[count.index]
  destination_cidr_block = "0.0.0.0/0"
  network_interface_id   = aws_instance.bootstrap[0].primary_network_interface_id
}
```

- [ ] **Step 3: Move the S3 gateway endpoint to private route tables**

In the `vpc_endpoints` module block, change:

```hcl
      route_table_ids = module.vpc.private_route_table_ids
```

- [ ] **Step 4: Run tests — network assertions pass, NAT-instance assertions fail**

Run: `rtk bash tests/platform_static_test.sh`
Expected: FAIL with "expected source_dest_check=false on the NAT instance"

- [ ] **Step 5: Commit**

```bash
git add network.tf
git commit -m "feat: add private subnets routed through the subnet-router nat instance"
```

---

### Task 4: NAT instance configuration (EC2 + security group + user data)

**Files:**
- Modify: `tailscale-bootstrap.tf`
- Modify: `bootstrap-iam.tf:16-62`
- Modify: `templates/bootstrap.sh.tftpl`

- [ ] **Step 1: Disable source/destination check in `tailscale-bootstrap.tf`**

Add inside `resource "aws_instance" "bootstrap"`, after `associate_public_ip_address = true`:

```hcl
  source_dest_check = false
```

- [ ] **Step 2: Replace the bootstrap security group rules in `bootstrap-iam.tf`**

Replace the existing `ingress` (SSH) block and all three `egress` blocks with:

```hcl
  ingress {
    description = "Allow all traffic from the VPC for NAT forwarding and SSH debug"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = [var.vpc_cidr]
  }

  egress {
    description = "Allow all outbound traffic for NAT forwarding"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
```

- [ ] **Step 3: Append NAT masquerade to `templates/bootstrap.sh.tftpl` (end of file)**

```bash
cat >/etc/systemd/system/nat-masquerade.service <<EOF
[Unit]
Description=Enable NAT masquerade for private subnet egress
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/bin/sh -c '/usr/sbin/iptables -t nat -C POSTROUTING -s $VPC_CIDR ! -d $VPC_CIDR -j MASQUERADE || /usr/sbin/iptables -t nat -A POSTROUTING -s $VPC_CIDR ! -d $VPC_CIDR -j MASQUERADE'
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now nat-masquerade.service
```

Notes: unquoted `EOF` expands `$VPC_CIDR` at boot time into the unit file; the `-C || -A` pair makes the service idempotent; matching `! -d $VPC_CIDR` (instead of `-o eth0`) is interface-agnostic (AL2023 Nitro names the NIC `ens5`).

- [ ] **Step 4: Run tests — NAT assertions pass, EKS assertions fail**

Run: `rtk bash tests/bootstrap_static_test.sh && rtk bash tests/platform_static_test.sh`
Expected: bootstrap test PASS; platform test FAIL with "expected EKS subnet_ids to use private subnets"

- [ ] **Step 5: Commit**

```bash
git add tailscale-bootstrap.tf bootstrap-iam.tf templates/bootstrap.sh.tftpl
git commit -m "feat: configure subnet-router as nat instance for private subnets"
```

---

### Task 5: EKS nodes on private subnets

**Files:**
- Modify: `eks.tf:13-15` and `eks.tf:72`

- [ ] **Step 1: Update module inputs**

```hcl
  vpc_id                   = module.vpc.vpc_id
  subnet_ids               = module.vpc.private_subnets
  control_plane_subnet_ids = module.vpc.public_subnets
```

- [ ] **Step 2: Update the default node group**

```hcl
      subnet_ids = module.vpc.private_subnets
```

- [ ] **Step 3: Run all static tests**

Run: `rtk bash -n tests/platform_static_test.sh && rtk bash -n tests/bootstrap_static_test.sh && rtk bash -n templates/bootstrap.sh.tftpl && rtk bash tests/platform_static_test.sh && rtk bash tests/bootstrap_static_test.sh`
Expected: all PASS, no output

- [ ] **Step 4: Commit**

```bash
git add eks.tf
git commit -m "feat: move eks worker subnets to private subnets"
```

---

### Task 6: Terraform validation and plan review

- [ ] **Step 1: Format and validate**

Run: `rtk terraform fmt *.tf && rtk terraform validate`
Expected: `Success! The configuration is valid.`

- [ ] **Step 2: Plan and inspect**

Run: `rtk terraform plan -out=tfplan`

Verify in the plan:
- 3 new `aws_subnet` private resources + route tables/associations.
- `aws_route.private_nat_instance[0..2]` created.
- `module.eks.module.eks_managed_node_group["default"].aws_eks_node_group.this[0]` **replaced** (expected — subnet change).
- `aws_instance.bootstrap[0]` **not replaced** (only SG/source_dest updates; user_data ignored).
- No `aws_nat_gateway` resources.
- S3 endpoint route table association moves to private route tables.

Run: `terraform show -json tfplan | jq -r '.resource_changes[] | select((.change.actions|join(","))!="no-op" and .mode=="managed") | [.address, (.change.actions|join(","))] | @tsv'`

- [ ] **Step 3: Commit**

```bash
git add -A
git commit -m "chore: validate private subnets and nat instance plan"
```

---

### Task 7: Apply NAT rules on the existing subnet-router (manual, required)

The running instance ignores `user_data` changes, so after `terraform apply` you must configure NAT on it once.

- [ ] **Step 1: Get the instance public IP**

```bash
aws ec2 describe-instances \
  --profile victor --region us-east-1 \
  --filters "Name=tag:Name,Values=tailscale-eks-example-bootstrap" \
  --query 'Reservations[].Instances[].PublicIpAddress' --output text
```

- [ ] **Step 2: Apply and persist the masquerade rule over SSH**

```bash
ssh ec2-user@<PUBLIC_IP> 'sudo /usr/sbin/iptables -t nat -C POSTROUTING -s 10.0.0.0/16 ! -d 10.0.0.0/16 -j MASQUERADE 2>/dev/null || sudo /usr/sbin/iptables -t nat -A POSTROUTING -s 10.0.0.0/16 ! -d 10.0.0.0/16 -j MASQUERADE'

ssh ec2-user@<PUBLIC_IP> 'sudo tee /etc/systemd/system/nat-masquerade.service >/dev/null <<EOF
[Unit]
Description=Enable NAT masquerade for private subnet egress
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/bin/sh -c '"'"'/usr/sbin/iptables -t nat -C POSTROUTING -s 10.0.0.0/16 ! -d 10.0.0.0/16 -j MASQUERADE || /usr/sbin/iptables -t nat -A POSTROUTING -s 10.0.0.0/16 ! -d 10.0.0.0/16 -j MASQUERADE'"'"'
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
sudo systemctl daemon-reload && sudo systemctl enable nat-masquerade.service'
```

- [ ] **Step 3: Verify the rule**

```bash
ssh ec2-user@<PUBLIC_IP> 'sudo /usr/sbin/iptables -t nat -L POSTROUTING -n -v | grep MASQUERADE'
```

Expected: one MASQUERADE rule matching `10.0.0.0/16 !10.0.0.0/16`.

---

### Task 8: Runtime verification after apply

- [ ] **Step 1: Nodes land in private subnets**

```bash
kubectl get nodes -o wide
```

Expected: new default node group nodes have IPs in `10.0.16.0/20`, `10.0.32.0/20`, or `10.0.48.0/20`.

- [ ] **Step 2: Private egress works through the NAT instance**

```bash
kubectl run egress-test --rm -it --image=alpine/curl:8.17.0 --restart=Never -- curl -fsSI https://aws.amazon.com | head -1
```

Expected: `HTTP/2 200` (or any 2xx/3xx).

- [ ] **Step 3: Internal ALB moves to private subnets**

```bash
kubectl -n kube-system get ingress 2>/dev/null; kubectl get ingress -A
aws elbv2 describe-load-balancers --profile victor --region us-east-1 \
  --query 'LoadBalancers[?Scheme==`internal`].{DNS:DNSName,Subnets:AvailabilityZones[].SubnetId}' --output table
```

Expected: ALB subnets are the new private subnet IDs.

- [ ] **Step 4: Karpenter provisions into private subnets**

```bash
kubectl get nodeclaims -o wide 2>/dev/null || kubectl get nodes -L karpenter.sh/nodepool -o wide
```

Expected: Karpenter nodes have private-subnet IPs.

---

### Task 9: Update AGENTS.md

**Files:**
- Modify: `AGENTS.md`

- [ ] **Step 1: Update architecture bullets**

Replace "VPC and public subnets." with "VPC with public `/24` subnets (subnet-router, EKS control-plane ENIs) and private `/20` subnets (EKS nodes, Karpenter, internal ALB)."
Replace "Public subnet tags for both `kubernetes.io/role/elb` and `kubernetes.io/role/internal-elb`." with "`kubernetes.io/role/elb` on public subnets; `kubernetes.io/role/internal-elb` and `karpenter.sh/discovery` on private subnets."
Add: "The persistent Tailscale subnet-router EC2 instance is also the NAT instance for private subnet egress (`source_dest_check=false`, iptables MASQUERADE; no AWS NAT Gateway)."

- [ ] **Step 2: Commit**

```bash
git add AGENTS.md
git commit -m "docs: update agents context for private subnets and nat instance"
```
