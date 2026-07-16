# Tailscale Subnet Router Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace `kubectl` access through the Tailscale Kubernetes API server proxy with VPC subnet routing through the existing bootstrap EC2 instance.

**Architecture:** The bootstrap EC2 instance remains the in-VPC installer for the Tailscale Operator, Argo CD, and the root Argo CD Application. During cloud-init it also installs Tailscale, joins the tailnet with a Terraform-provided auth key, and advertises `var.vpc_cidr` as a subnet route. Local users then access the private EKS endpoint with the normal AWS EKS kubeconfig over the approved Tailscale route.

**Tech Stack:** Terraform, AWS EC2/EKS, Amazon Linux 2023 cloud-init, Tailscale CLI, Helm CLI, Bash static tests.

---

## File Structure

- Modify `variables.tf`: add sensitive `tailscale_subnet_router_auth_key` input.
- Modify `locals.tf`: add `local.tailscale_subnet_router_hostname`; remove API server proxy config from Tailscale Operator values.
- Modify `tailscale-bootstrap.tf`: pass subnet router values into the bootstrap template.
- Modify `templates/bootstrap.sh.tftpl`: install Tailscale and run `tailscale up` before Helm bootstrap work.
- Modify `outputs.tf`: replace API server proxy kubeconfig output with subnet-router-oriented outputs and AWS kubeconfig command.
- Modify `tests/bootstrap_static_test.sh`: add regression checks for subnet router setup and absence of API server proxy kubeconfig guidance.
- Modify `README.md`: document subnet route approval, AWS kubeconfig usage, DNS caveat, and persistent bootstrap instance behavior.

---

### Task 1: Add Static Regression Tests

**Files:**
- Modify: `tests/bootstrap_static_test.sh`

- [ ] **Step 1: Replace `tests/bootstrap_static_test.sh` with tests for existing kubeconfig behavior plus subnet router behavior**

```bash
#!/usr/bin/env bash
set -euo pipefail

bootstrap="templates/bootstrap.sh.tftpl"
locals_tf="locals.tf"
outputs_tf="outputs.tf"
bootstrap_tf="tailscale-bootstrap.tf"

if ! grep -q '^export KUBECONFIG=' "$bootstrap"; then
  printf 'expected bootstrap to export KUBECONFIG before helm/kubectl commands\n' >&2
  exit 1
fi

if ! grep -q -- 'aws eks update-kubeconfig .* --kubeconfig "\$KUBECONFIG"' "$bootstrap"; then
  printf 'expected aws eks update-kubeconfig to write to explicit KUBECONFIG\n' >&2
  exit 1
fi

kubeconfig_line=$(grep -n '^export KUBECONFIG=' "$bootstrap" | cut -d: -f1 | head -n1)
helm_line=$(grep -n '^helm repo add' "$bootstrap" | cut -d: -f1 | head -n1)

if (( kubeconfig_line >= helm_line )); then
  printf 'expected KUBECONFIG export before helm commands\n' >&2
  exit 1
fi

if ! grep -q 'https://tailscale.com/install.sh' "$bootstrap"; then
  printf 'expected bootstrap to install Tailscale on the subnet router instance\n' >&2
  exit 1
fi

if ! grep -q -- '--advertise-routes="\$VPC_CIDR"' "$bootstrap"; then
  printf 'expected bootstrap to advertise the VPC CIDR as a Tailscale subnet route\n' >&2
  exit 1
fi

if ! grep -q -- '--accept-dns=false' "$bootstrap"; then
  printf 'expected subnet router to preserve AWS DNS with --accept-dns=false\n' >&2
  exit 1
fi

if ! grep -q 'tailscale_subnet_router_auth_key' "$bootstrap_tf"; then
  printf 'expected bootstrap Terraform resource to pass the subnet router auth key into user_data\n' >&2
  exit 1
fi

if ! grep -q 'tailscale_subnet_router_hostname' "$locals_tf"; then
  printf 'expected locals to define a subnet router hostname\n' >&2
  exit 1
fi

if grep -q 'apiServerProxyConfig' "$locals_tf"; then
  printf 'expected Tailscale API server proxy config to be removed because this tailnet lacks HTTPS cert support\n' >&2
  exit 1
fi

if grep -q 'tailscale configure kubeconfig' "$outputs_tf"; then
  printf 'expected outputs to stop recommending Tailscale API server proxy kubeconfig\n' >&2
  exit 1
fi

if ! grep -q 'aws eks update-kubeconfig' "$outputs_tf"; then
  printf 'expected outputs to recommend AWS EKS kubeconfig over the subnet route\n' >&2
  exit 1
fi
```

- [ ] **Step 2: Run the static test and verify it fails before implementation**

Run:

```bash
rtk bash tests/bootstrap_static_test.sh
```

Expected: FAIL with the first missing subnet router assertion, such as `expected bootstrap to install Tailscale on the subnet router instance`.

- [ ] **Step 3: Commit the failing test**

```bash
rtk git add tests/bootstrap_static_test.sh
rtk git commit -m "test: cover tailscale subnet router bootstrap"
```

---

### Task 2: Add Terraform Inputs, Locals, and Template Wiring

**Files:**
- Modify: `variables.tf`
- Modify: `locals.tf`
- Modify: `tailscale-bootstrap.tf`

- [ ] **Step 1: Add the subnet router auth key variable to `variables.tf` after `tailscale_oauth_client_secret`**

```hcl
variable "tailscale_subnet_router_auth_key" {
  description = "Tailscale auth key used by the bootstrap EC2 instance to join the tailnet and advertise the VPC subnet route."
  type        = string
  sensitive   = true
}
```

- [ ] **Step 2: Add the subnet router hostname local and remove API server proxy config from `locals.tf`**

Replace the hostname locals block with:

```hcl
  tailscale_operator_hostname      = coalesce(var.tailscale_operator_hostname, "${local.name}-operator")
  tailscale_subnet_router_hostname = "${local.name}-subnet-router"
  argocd_tailscale_hostname        = coalesce(var.argocd_tailscale_hostname, "${local.name}-argocd")
  airflow_tailscale_hostname       = coalesce(var.airflow_tailscale_hostname, "${local.name}-airflow")
  kubecost_tailscale_hostname      = coalesce(var.kubecost_tailscale_hostname, "${local.name}-kubecost")
```

Replace `local.tailscale_operator_values_yaml` with:

```hcl
  tailscale_operator_values_yaml = yamlencode({
    oauth = {
      clientId     = var.tailscale_oauth_client_id
      clientSecret = var.tailscale_oauth_client_secret
    }
    operatorConfig = {
      hostname = local.tailscale_operator_hostname
    }
  })
```

- [ ] **Step 3: Pass subnet router values into `templatefile` in `tailscale-bootstrap.tf`**

Replace the `user_data = templatefile(...)` map with:

```hcl
  user_data = templatefile("${path.module}/templates/bootstrap.sh.tftpl", {
    aws_region                         = var.aws_region
    cluster_name                       = module.eks.cluster_name
    cluster_version                    = var.cluster_version
    vpc_cidr                           = var.vpc_cidr
    tailscale_subnet_router_auth_key   = var.tailscale_subnet_router_auth_key
    tailscale_subnet_router_hostname   = local.tailscale_subnet_router_hostname
    tailscale_operator_values_yaml     = local.tailscale_operator_values_yaml
    argocd_chart_version               = var.argocd_chart_version
    argocd_values_yaml                 = local.argocd_values_yaml
    argocd_tailscale_service_yaml      = local.argocd_tailscale_service_yaml
    argocd_root_application_yaml       = local.argocd_root_application_yaml
  })
```

- [ ] **Step 4: Run Terraform formatting and validation for this task**

Run:

```bash
rtk terraform fmt -check *.tf
rtk terraform validate
```

Expected: both commands exit 0. The static test still fails until the bootstrap script is updated.

- [ ] **Step 5: Commit Terraform wiring**

```bash
rtk git add variables.tf locals.tf tailscale-bootstrap.tf
rtk git commit -m "feat: wire tailscale subnet router inputs"
```

---

### Task 3: Install and Configure Tailscale Subnet Router in Bootstrap Script

**Files:**
- Modify: `templates/bootstrap.sh.tftpl`

- [ ] **Step 1: Add subnet router environment exports near the existing bootstrap exports**

Replace lines 6-10 with:

```bash
export AWS_REGION="${aws_region}"
export CLUSTER_NAME="${cluster_name}"
export CLUSTER_VERSION="${cluster_version}"
export VPC_CIDR="${vpc_cidr}"
export TAILSCALE_SUBNET_ROUTER_AUTH_KEY="${tailscale_subnet_router_auth_key}"
export TAILSCALE_SUBNET_ROUTER_HOSTNAME="${tailscale_subnet_router_hostname}"
install -d -m 0700 /var/lib/eks-bootstrap
export KUBECONFIG="/var/lib/eks-bootstrap/kubeconfig"
```

- [ ] **Step 2: Install and start Tailscale before installing Helm/kubectl**

Insert this block immediately after the existing `dnf install -y curl-minimal tar gzip unzip jq awscli` line:

```bash
curl -fsSL https://tailscale.com/install.sh | sh
systemctl enable --now tailscaled

tailscale up \
  --auth-key="$TAILSCALE_SUBNET_ROUTER_AUTH_KEY" \
  --hostname="$TAILSCALE_SUBNET_ROUTER_HOSTNAME" \
  --advertise-routes="$VPC_CIDR" \
  --accept-dns=false
unset TAILSCALE_SUBNET_ROUTER_AUTH_KEY
```

- [ ] **Step 3: Run the bootstrap static test and shell syntax check**

Run:

```bash
rtk bash tests/bootstrap_static_test.sh
rtk bash -n templates/bootstrap.sh.tftpl
```

Expected: both commands exit 0.

- [ ] **Step 4: Run Terraform validation**

Run:

```bash
rtk terraform validate
```

Expected: command exits 0.

- [ ] **Step 5: Commit bootstrap script change**

```bash
rtk git add templates/bootstrap.sh.tftpl
rtk git commit -m "feat: configure bootstrap subnet router"
```

---

### Task 4: Update Outputs and Documentation

**Files:**
- Modify: `outputs.tf`
- Modify: `README.md`

- [ ] **Step 1: Replace API server proxy outputs in `outputs.tf`**

Replace lines 26-34 with:

```hcl
output "tailscale_operator_hostname" {
  description = "Tailscale Operator hostname used for in-cluster Tailscale Services."
  value       = local.tailscale_operator_hostname
}

output "tailscale_subnet_router_hostname" {
  description = "Tailscale subnet router hostname that advertises the VPC CIDR."
  value       = local.tailscale_subnet_router_hostname
}

output "tailscale_subnet_route" {
  description = "VPC CIDR advertised by the Tailscale subnet router. Approve this route in the Tailscale admin console."
  value       = var.vpc_cidr
}

output "aws_kubeconfig_command" {
  description = "Command to configure kubeconfig for the private EKS endpoint after the Tailscale subnet route is approved."
  value       = "aws eks update-kubeconfig --region ${var.aws_region} --name ${module.eks.cluster_name}"
}
```

- [ ] **Step 2: Update the README tfvars example**

Replace the credentials block with:

```hcl
tailscale_oauth_client_id          = "tskey-client-example"
tailscale_oauth_client_secret      = "tskey-secret-example"
tailscale_subnet_router_auth_key   = "tskey-auth-example"

# Required after this repository is published.
argocd_repo_url = "https://github.com/VictorCoutinho86/tailscale-eks-example.git"
```

- [ ] **Step 3: Replace the README access section**

Replace lines 106-123 with:

```markdown
## Access

The EKS API endpoint is private. Local `kubectl` access uses the Tailscale subnet router running on the bootstrap EC2 instance, not the Tailscale Kubernetes API server proxy.

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
```

- [ ] **Step 4: Replace the bootstrap cleanup section**

Replace lines 143-149 with:

```markdown
## Bootstrap Instance and Subnet Router

The bootstrap EC2 instance is persistent in this design because it also acts as the Tailscale subnet router for private EKS API access.

Do not set `enable_bootstrap_instance=false` unless another subnet router advertises the VPC CIDR. Removing the bootstrap instance removes the subnet route and breaks local `kubectl` access to the private endpoint.
```

- [ ] **Step 5: Replace the README notes that mention API server proxy**

Replace line 189 with:

```markdown
- The EKS public API endpoint is disabled; access is through the Tailscale subnet route to the private endpoint.
```

- [ ] **Step 6: Replace the runtime validation block**

Replace lines 237-240 with:

```bash
tailscale status
tailscale ping $(terraform output -raw tailscale_subnet_router_hostname)
aws eks update-kubeconfig --profile victor --region $(terraform output -raw aws_region) --name $(terraform output -raw cluster_name)
kubectl get nodes
kubectl -n tailscale get pods
```

- [ ] **Step 7: Run static and Terraform validation**

Run:

```bash
rtk bash tests/bootstrap_static_test.sh
rtk terraform fmt -check *.tf
rtk terraform validate
```

Expected: all commands exit 0.

- [ ] **Step 8: Commit outputs and README changes**

```bash
rtk git add outputs.tf README.md
rtk git commit -m "docs: document subnet router access"
```

---

### Task 5: Final Verification and Handoff

**Files:**
- Verify: repository working tree

- [ ] **Step 1: Run full static validation**

Run:

```bash
rtk bash tests/bootstrap_static_test.sh
rtk bash -n templates/bootstrap.sh.tftpl
rtk terraform fmt -check -recursive
rtk terraform validate
rtk helm template platform-root gitops/root
```

Expected: all commands exit 0.

- [ ] **Step 2: Check git state and recent commits**

Run:

```bash
rtk git status --short --branch
rtk git log --oneline -8
```

Expected: working tree clean, branch ahead by the new documentation and implementation commits until pushed.

- [ ] **Step 3: Push commits**

Run:

```bash
rtk git push
```

Expected: `master -> master` push succeeds.

- [ ] **Step 4: Runtime apply instructions for the user**

Tell the user to add this to local `terraform.tfvars`:

```hcl
tailscale_subnet_router_auth_key = "tskey-auth-example"
```

Then tell the user to run:

```bash
rtk terraform apply
```

After apply replaces the bootstrap instance, tell the user to approve `terraform output -raw tailscale_subnet_route` for `terraform output -raw tailscale_subnet_router_hostname` in the Tailscale Admin Console.

- [ ] **Step 5: Runtime validation after route approval**

Run after the route is approved:

```bash
rtk tailscale status
rtk tailscale ping $(terraform output -raw tailscale_subnet_router_hostname)
rtk aws eks update-kubeconfig --profile victor --region $(terraform output -raw aws_region) --name $(terraform output -raw cluster_name)
rtk kubectl get pods -A
```

Expected: subnet router appears in `tailscale status`, `tailscale ping` reaches it, kubeconfig updates, and `kubectl get pods -A` lists cluster pods without `tailscale configure kubeconfig`.

---

## Self-Review

- Spec coverage: The plan adds the auth key variable, installs Tailscale on the bootstrap EC2 instance, advertises `var.vpc_cidr`, stops recommending API server proxy kubeconfig, documents route approval, documents DNS caveat, and keeps Helm bootstrap in cloud-init instead of `helm_release`.
- Placeholder scan: The plan contains no unresolved placeholders or unspecified implementation steps.
- Type/name consistency: The plan consistently uses `tailscale_subnet_router_auth_key`, `local.tailscale_subnet_router_hostname`, `tailscale_subnet_router_hostname`, and `tailscale_subnet_route`.
