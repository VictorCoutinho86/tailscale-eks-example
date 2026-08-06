# Architecture Documentation Refresh Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Refresh README, AGENTS, and the generated architecture diagram so they accurately describe the current IPv6-first EKS platform.

**Architecture:** This is a documentation-only change. The README and AGENTS files keep their current structure, while `docs/architecture_diagram.py` is updated to show the current two-router IPv6/NAT64 topology and then regenerated into `docs/architecture.png`.

**Tech Stack:** Markdown, Python 3.14 script metadata, `diagrams`, `uv`, shell static tests.

---

## File Structure

- Modify `README.md`: keep the existing user-facing structure and ensure the architecture summary matches the refreshed diagram.
- Modify `AGENTS.md`: keep the existing agent-facing operational structure and ensure it names the refreshed diagram and current routing model accurately.
- Modify `docs/architecture_diagram.py`: update diagram nodes and edges to represent the current architecture.
- Regenerate `docs/architecture.png`: generated image from `docs/architecture_diagram.py`.

---

### Task 1: Update Architecture Diagram Source

**Files:**
- Modify: `docs/architecture_diagram.py`

- [ ] **Step 1: Replace stale topology labels**

Update the public subnet cluster to replace the old single `Subnet router ASG\n3 spot instances\nTailscale + NAT` node with two-router wording:

```python
with Cluster("Public subnets /24\n3 AZs"):
    subnet_router_asg = EC2("2 subnet-router ASGs\nUbuntu 24.04 spot\nTailscale + NAT64")
    eks_api = EKS("EKS private\nAPI endpoint")
```

- [ ] **Step 2: Add current IPv6/NAT64 infrastructure nodes**

Inside the AWS VPC cluster, add nodes for egress-only IGW, private route tables, and NAT64/DNS64 before the private subnet cluster closes:

```python
egress_only_igw = Endpoint("Egress-only IGW\nIPv6 internet egress")
private_route_tables = PrivateSubnet("Private route tables\nIPv4 default + NAT64")
nat64_dns64 = Endpoint("NAT64/DNS64\ntayga + Unbound")
```

- [ ] **Step 3: Update private workload and ALB labels**

Ensure private subnet labels reflect IPv6 Pods/Services, dual-stack ALB, and Nitro-oriented Karpenter nodes:

```python
default_nodes = EKS("Default node group\nIPv6 Pods")
karpenter_nodes = EKS("Karpenter nodes\nNitro instances")
spark_nodes = EKS("Spark NodePool\nr family + NVMe")
internal_alb = PublicSubnet("Internal dual-stack ALB\nHTTPS host routing\nTLS 1.2+")
```

- [ ] **Step 4: Update routing edges**

Replace the stale NAT routing edge with explicit current routing:

```python
subnet_router_asg >> Edge(label="self-configures\nreplace-route") >> private_route_tables
private_route_tables >> Edge(label="0.0.0.0/0\nIPv4 NAT") >> subnet_router_asg
private_route_tables >> Edge(label="64:ff9b::/96\nNAT64") >> nat64_dns64 >> subnet_router_asg
default_nodes >> Edge(label="IPv6 egress") >> egress_only_igw
karpenter_nodes >> Edge(label="IPv6 egress") >> egress_only_igw
```

- [ ] **Step 5: Fix observability edge wording**

Change the OTel edge from traces to logs:

```python
otel >> Edge(label="OTLP logs") >> loki
```

- [ ] **Step 6: Fix ExternalDNS record label**

Change the DNS edge so it does not imply only A records:

```python
external_dns >> Edge(label="upserts DNS/TXT") >> route53
```

---

### Task 2: Update README and AGENTS Wording

**Files:**
- Modify: `README.md`
- Modify: `AGENTS.md`

- [ ] **Step 1: Confirm README architecture paragraph includes diagram concepts**

Ensure the first paragraph in `README.md` includes all of these exact ideas in concise prose:

```text
two Tailscale subnet routers in two AZs
VPC is dual-stack across three AZs
EKS Pods and Services use IPv6
normal IPv6 egress uses an egress-only internet gateway
IPv4-only egress is translated by the subnet-router layer without AWS NAT Gateway
third AZ sends IPv4 NAT and NAT64/DNS64 traffic to one fixed router
Ubuntu 24.04 subnet-router also runs local Unbound as a DNS64 fallback and diagnostic resolver with tayga for NAT64
shared internal dual-stack AWS Application Load Balancer
```

- [ ] **Step 2: Add a compact README diagram legend if needed**

If the diagram alone is ambiguous, add this short text after the regenerate command:

```markdown
The diagram shows three traffic planes: tailnet access to private endpoints through subnet-router routes, IPv6 workload egress through the egress-only internet gateway, and IPv4/NAT64 fallback through the Ubuntu subnet-router ASGs.
```

- [ ] **Step 3: Confirm AGENTS architecture bullets match diagram concepts**

Ensure `AGENTS.md` keeps these current facts under `Current Architecture` or `Root Terraform Responsibilities`:

```text
two spot-backed Auto Scaling Groups in two AZs
third AZ routes IPv4 NAT and NAT64/DNS64 traffic to one fixed subnet-router
subnet routers advertise the VPC IPv4 and IPv6 CIDRs through Tailscale
private subnet IPv6 egress uses an egress-only internet gateway
shared internal dual-stack AWS Application Load Balancer
```

---

### Task 3: Regenerate and Validate

**Files:**
- Modify generated: `docs/architecture.png`

- [ ] **Step 1: Regenerate the diagram**

Run:

```bash
uv run --script docs/architecture_diagram.py
```

Expected: command exits 0 and updates `docs/architecture.png`.

- [ ] **Step 2: Run static docs/platform checks**

Run:

```bash
bash tests/platform_static_test.sh
bash tests/bootstrap_static_test.sh
```

Expected: both commands exit 0.

- [ ] **Step 3: Run syntax/format checks**

Run:

```bash
python -m py_compile docs/architecture_diagram.py
terraform fmt -check -recursive *.tf
git diff --check
```

Expected: all commands exit 0. `terraform fmt` should not change files because this plan does not modify Terraform.

---

## Self-Review

- Spec coverage: the plan updates README, AGENTS, `docs/architecture_diagram.py`, and regenerates `docs/architecture.png` as requested.
- Scope check: the plan is documentation-only and does not change infrastructure or GitOps behavior.
- Placeholder scan: no TBD/TODO/fill-in placeholders are present.
- Type consistency: file paths and command names match repository conventions.
