#!/usr/bin/env bash
set -euo pipefail

infra_root="."
platform_root="platform"
bootstrap="templates/bootstrap.sh.tftpl"
pod_identity="pod-identity.tf"
network="network.tf"
variables="variables.tf"
outputs="outputs.tf"

if ! grep -q 'attach_aws_lb_controller_policy' "$pod_identity"; then
  printf 'expected AWS Load Balancer Controller Pod Identity\n' >&2
  exit 1
fi

if ! grep -q 'module "aws_load_balancer_controller_pod_identity"' "$pod_identity"; then
  printf 'expected a dedicated AWS Load Balancer Controller Pod Identity module\n' >&2
  exit 1
fi

if ! grep -q 'attach_external_dns_policy' "$pod_identity"; then
  printf 'expected ExternalDNS Pod Identity\n' >&2
  exit 1
fi

if ! grep -q 'module "external_dns_pod_identity"' "$pod_identity"; then
  printf 'expected a dedicated ExternalDNS Pod Identity module\n' >&2
  exit 1
fi

if ! grep -q 'private_zone.*false' "$infra_root/route53-acm.tf"; then
  printf 'expected discovery of an existing public Route 53 hosted zone\n' >&2
  exit 1
fi

for resource in \
  'aws_acm_certificate' \
  'aws_route53_record' \
  'domain_validation_options' \
  'aws_acm_certificate_validation' \
  '*.${trimsuffix(var.route53_domain_name, ".")}' \
  'validation_method = "DNS"'; do
  if ! grep -F -q -- "$resource" "$infra_root/route53-acm.tf"; then
    printf 'expected Route 53/ACM assertion %s\n' "$resource" >&2
    exit 1
  fi
done

old_path_pattern='apiServerProxyConfig|tailscale\.com/loadBalancerClass|tailscale configure kubeconfig'
if ! static_files=$(git ls-files -co --exclude-standard -- '*.tf' 'templates/*.tftpl' 'platform/**'); then
  printf 'unable to list static-check inputs\n' >&2
  exit 1
fi

while IFS= read -r file || [[ -n "$file" ]]; do
  if [[ ! -f "$file" ]]; then
    continue
  fi

  if ! content=$(<"$file"); then
    printf 'unable to read static-check input %s\n' "$file" >&2
    exit 1
  fi

  if [[ "$content" =~ $old_path_pattern ]]; then
    printf 'expected old Tailscale API/UI delivery path to be removed from %s\n' "$file" >&2
    exit 1
  fi
done <<EOF
$static_files
EOF

if ! grep -q 'kubernetes.io/role/internal-elb' "$network"; then
  printf 'expected subnet tagging for internal ALB discovery\n' >&2
  exit 1
fi

if ! grep -q 'route53_domain_name' "$variables" || ! grep -q 'platform_certificate_arn' "$outputs"; then
  printf 'expected Route 53 domain input and ACM output\n' >&2
  exit 1
fi

if ! grep -A4 'variable "default_node_count"' "$variables" | grep -q 'default     = 3'; then
  printf 'expected default EKS node group count to be 3\n' >&2
  exit 1
fi

if grep -R -q 'resource "helm_release"' platform 2>/dev/null; then
  printf 'expected platform Terraform to stop owning Helm releases\n' >&2
  exit 1
fi

if grep -R -q 'resource "kubernetes_' platform 2>/dev/null; then
  printf 'expected platform Terraform to stop owning Kubernetes resources\n' >&2
  exit 1
fi

if ! grep -q 'source.*hashicorp/helm' versions.tf; then
  printf 'expected root Terraform to declare Helm provider for Argo CD bootstrap\n' >&2
  exit 1
fi

if ! grep -q 'variable "enable_argocd_bootstrap"' "$variables"; then
  printf 'expected an explicit phase-2 switch for Terraform Argo CD bootstrap\n' >&2
  exit 1
fi

if ! grep -R -q 'count = var.enable_argocd_bootstrap ? 1 : 0' . --include='*.tf'; then
  printf 'expected Terraform Argo CD bootstrap resources to be gated until Tailscale route approval\n' >&2
  exit 1
fi

if ! grep -R -q 'resource "helm_release" "argocd"' . --include='*.tf'; then
  printf 'expected root Terraform helm_release.argocd bootstrap\n' >&2
  exit 1
fi

if ! grep -R -q 'resource "helm_release" "argocd_root_application"' . --include='*.tf'; then
  printf 'expected root Terraform helm_release.argocd_root_application bootstrap\n' >&2
  exit 1
fi

if grep -q 'variable "admin_password"' "$variables"; then
  printf 'expected admin_password variable to be removed (secrets now managed by Sealed Secrets)\n' >&2
  exit 1
fi

if grep -q 'configs.secret.argocdServerAdminPassword' argocd.tf || grep -q 'bcrypt(var.admin_password)' argocd.tf; then
  printf 'expected Argo CD admin password to be removed from Terraform (now managed by SealedSecret)\n' >&2
  exit 1
fi

if grep -q 'output "admin_password"' "$outputs"; then
  printf 'expected admin_password output to be removed\n' >&2
  exit 1
fi

if ! test -f gitops/root/Chart.yaml || ! test -f gitops/root/templates/applications.yaml; then
  printf 'expected gitops/root Helm chart for app-of-apps\n' >&2
  exit 1
fi

if ! grep -q 'resources-finalizer.argocd.argoproj.io' gitops/root/templates/applications.yaml; then
  printf 'expected child Applications to use the Argo CD resources finalizer for cascade deletion\n' >&2
  exit 1
fi

if ! grep -q 'resources-finalizer.argocd.argoproj.io' charts/argocd-root-application/templates/application.yaml; then
  printf 'expected root Application to use the Argo CD resources finalizer for cascade deletion\n' >&2
  exit 1
fi

if grep -q 'depends_on = \[aws_instance.bootstrap\]' eks.tf; then
  printf 'expected the EKS module not to depend on the bootstrap instance\n' >&2
  exit 1
fi

if grep -q 'depends_on.*autoscaling_group' eks.tf; then
  printf 'expected EKS module not to use module-level depends_on (breaks count propagation in managed node group data sources)\n' >&2
  exit 1
fi

for app in base argocd aws-load-balancer-controller external-dns karpenter karpenter-resources airflow spark-operator kubecost sealed-secrets velero kube-prometheus-stack loki promtail spark-history-server otel-collector; do
  if ! grep -R -q "\"name\" \"${app}\"" gitops/root/templates; then
    printf 'expected root app-of-apps to define %s application\n' "$app" >&2
    exit 1
  fi
done

for app_dir in base argocd aws-load-balancer-controller external-dns karpenter karpenter-resources airflow spark-operator kubecost sealed-secrets velero kube-prometheus-stack loki promtail spark-history-server otel-collector; do
  if ! test -e "gitops/apps/${app_dir}" && ! test -e "gitops/${app_dir}"; then
    printf 'expected GitOps source for %s\n' "$app_dir" >&2
    exit 1
  fi
done

if ! grep -R -q 'argocd.argoproj.io/sync-wave' gitops; then
  printf 'expected GitOps resources to use Argo CD sync waves\n' >&2
  exit 1
fi

if ! grep -R -q 'useHelmHooks: false' gitops/apps/airflow; then
  printf 'expected Airflow Helm hooks to be disabled for Argo CD safety\n' >&2
  exit 1
fi

if grep -q 'adminPassword.*var.admin_password' argocd.tf; then
  printf 'expected the root Application values to stop receiving admin_password\n' >&2
  exit 1
fi

if grep -q 'adminPassword:' charts/argocd-root-application/templates/application.yaml; then
  printf 'expected adminPassword to be removed from the intermediate root Application chart\n' >&2
  exit 1
fi

if ! grep -Fq 'name: global.clusterName' charts/argocd-root-application/templates/application.yaml || \
  ! grep -Fq 'name: global.airflowLogsBucket' charts/argocd-root-application/templates/application.yaml; then
  printf 'expected non-secret global Helm parameters to remain in the root Application\n' >&2
  exit 1
fi

if grep -q 'Values.adminPassword' gitops/root/templates/applications.yaml; then
  printf 'expected Airflow to use SealedSecret instead of adminPassword from values\n' >&2
  exit 1
fi

if ! grep -q 'existingSecret: airflow-admin-credentials' gitops/root/templates/applications.yaml; then
  printf 'expected Airflow createUserJob to reference existing airflow-admin-credentials secret\n' >&2
  exit 1
fi

if ! grep -q 'AIRFLOW__WEBSERVER__EXPOSE_CONFIG' gitops/apps/airflow/values.yaml; then
  printf 'expected Airflow webserver configuration exposure to be enabled\n' >&2
  exit 1
fi

if ! grep -q 'airflow_ebs_cleanup_policy_statements' locals.tf || \
  ! grep -q 'ec2:DescribeVolumes' locals.tf || \
  ! grep -q 'ec2:DeleteVolume' locals.tf; then
  printf 'expected default EBS cleanup permissions for Airflow tasks\n' >&2
  exit 1
fi

if ! grep -q 'local.airflow_ebs_cleanup_policy_statements' pod-identity.tf; then
  printf 'expected Airflow Pod Identity to include default EBS cleanup permissions\n' >&2
  exit 1
fi

if grep -q 'variable "public_subnet_count"' variables.tf || grep -q 'public_subnet_count' locals.tf; then
  printf 'expected public_subnet_count to be removed\n' >&2
  exit 1
fi

if ! grep -q 'slice(data.aws_availability_zones.available.names, 0, 3)' locals.tf; then
  printf 'expected exactly 3 Availability Zones\n' >&2
  exit 1
fi

if ! grep -q 'cidrsubnet(var.vpc_cidr, 8, index)' locals.tf; then
  printf 'expected /24 public subnet calculation with cidrsubnet newbits 8\n' >&2
  exit 1
fi

if ! grep -q 'repository: https://bitnami.github.io/sealed-secrets' gitops/apps/sealed-secrets/Chart.yaml; then
  printf 'expected sealed-secrets to use the current bitnami.github.io repository\n' >&2
  exit 1
fi

if ! grep -q 'version: 2.19.1' gitops/apps/sealed-secrets/Chart.yaml; then
  printf 'expected sealed-secrets chart pinned to 2.19.1\n' >&2
  exit 1
fi

if ! test -f gitops/apps/sealed-secrets/charts/sealed-secrets-2.19.1.tgz; then
  printf 'expected vendored sealed-secrets 2.19.1 chart tgz\n' >&2
  exit 1
fi

if ! grep -q 'repository: https://kubecost.github.io/kubecost/' gitops/apps/kubecost/Chart.yaml; then
  printf 'expected kubecost to use the current kubecost.github.io/kubecost repository\n' >&2
  exit 1
fi

if ! grep -q 'name: kubecost' gitops/apps/kubecost/Chart.yaml || ! grep -q 'version: 3.2.1' gitops/apps/kubecost/Chart.yaml; then
  printf 'expected kubecost chart dependency pinned to kubecost 3.2.1\n' >&2
  exit 1
fi

if ! test -f gitops/apps/kubecost/charts/kubecost-3.2.1.tgz; then
  printf 'expected vendored kubecost 3.2.1 chart tgz\n' >&2
  exit 1
fi

for key in fernetKey jwtSecret apiSecretKey; do
  if grep -E "^  ${key}:" gitops/apps/airflow/values.yaml >/dev/null; then
    printf 'expected airflow values to stop defining plaintext %s (now managed by SealedSecret)\n' "$key" >&2
    exit 1
  fi
done

for sealed in fernet-key-sealed-secret jwt-sealed-secret api-secret-key-sealed-secret admin-password-sealed-secret; do
  if ! test -f "gitops/apps/airflow/templates/${sealed}.yaml"; then
    printf 'expected airflow wrapper chart to render SealedSecret %s\n' "$sealed" >&2
    exit 1
  fi
done

for old_secret in fernet-key-secret jwt-secret api-secret-key-secret; do
  if test -f "gitops/apps/airflow/templates/${old_secret}.yaml"; then
    printf 'expected old plaintext Secret template %s to be replaced by SealedSecret\n' "$old_secret" >&2
    exit 1
  fi
done

if ! grep -q 'sealedsecrets.bitnami.com/namespace-wide' gitops/apps/airflow/templates/fernet-key-sealed-secret.yaml; then
  printf 'expected SealedSecret to use namespace-wide scope\n' >&2
  exit 1
fi

if ! grep -B3 'ServerSideApply=true' gitops/root/templates/applications.yaml | grep -q 'spark-operator'; then
  printf 'expected spark-operator Application to use ServerSideApply=true for large CRDs\n' >&2
  exit 1
fi

if ! test -f gitops/apps/argocd/templates/argocd-secret-sealed.yaml; then
  printf 'expected Argo CD admin SealedSecret\n' >&2
  exit 1
fi

if ! grep -q 'createSecret: false' gitops/apps/argocd/values.yaml; then
  printf 'expected Argo CD chart to disable secret creation (managed by SealedSecret)\n' >&2
  exit 1
fi

if ! test -f scripts/seal-secrets.sh; then
  printf 'expected seal-secrets.sh helper script\n' >&2
  exit 1
fi

if ! grep -B3 'ServerSideApply=true' gitops/root/templates/applications.yaml | grep -q 'spark-operator'; then
  printf 'expected spark-operator Application to use ServerSideApply=true for large CRDs\n' >&2
  exit 1
fi

if ! grep -q 'eq $app.name "spark-operator"' gitops/root/templates/applications.yaml || \
  ! grep -q 'jobNamespaces:' gitops/root/templates/applications.yaml || \
  ! grep -q 'global.sparkWorkloadNamespace' gitops/root/templates/applications.yaml; then
  printf 'expected Spark Operator to watch the configured Spark workload namespace\n' >&2
  exit 1
fi

if ! grep -q 'karpenter.k8s.aws/instance-hypervisor' gitops/apps/karpenter-resources/chart/templates/nodepools.yaml; then
  printf 'expected Spark NodePool to require Nitro instances for NVMe compatibility\n' >&2
  exit 1
fi

if grep -q 'karpenter.k8s.aws/instance-local-nvme' gitops/apps/karpenter-resources/chart/templates/nodepools.yaml; then
  printf 'expected Spark NodePool not to require local NVMe storage\n' >&2
  exit 1
fi

if ! grep -q 'nodes: "90%"' gitops/apps/karpenter-resources/chart/templates/nodepools.yaml || \
  ! grep -q '"Empty"' gitops/apps/karpenter-resources/chart/templates/nodepools.yaml || \
  ! grep -q '"Underutilized"' gitops/apps/karpenter-resources/chart/templates/nodepools.yaml; then
  printf 'expected Spark NodePool to allow 90 percent disruption for idle nodes\n' >&2
  exit 1
fi

if ! grep -q 'resources: \["pods"\]' gitops/base/templates/rbac.yaml || \
  ! grep -q 'verbs: \["get", "list", "watch", "patch"\]' gitops/base/templates/rbac.yaml; then
  printf 'expected airflow-task to patch Spark driver pods\n' >&2
  exit 1
fi

if grep -R -q 'bitnami-labs.github.io\|kubecost.github.io/cost-analyzer' gitops; then
  printf 'expected discontinued chart repositories to be removed from gitops tree\n' >&2
  exit 1
fi

if ! grep -q 'name: kubecost-frontend' gitops/base/templates/ingresses.yaml; then
  printf 'expected kubecost ingress to target the kubecost 3.x frontend service\n' >&2
  exit 1
fi

if ! grep -A2 'networkCosts:' gitops/apps/kubecost/values.yaml | grep -q 'enabled: true'; then
  printf 'expected kubecost network-costs daemonset to be enabled\n' >&2
  exit 1
fi

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

if grep -q 'resource "aws_route" "private_nat_instance"' network.tf; then
  printf 'expected per-AZ NAT routes to be managed by cloud-init, not Terraform aws_route\n' >&2
  exit 1
fi

if ! grep -q 'route_table_ids = module.vpc.private_route_table_ids' network.tf; then
  printf 'expected S3 gateway endpoint attached to private route tables\n' >&2
  exit 1
fi

if ! grep -q 'modify-instance-attribute.*--no-source-dest-check' "$bootstrap"; then
  printf 'expected cloud-init to disable source/dest check via AWS CLI\n' >&2
  exit 1
fi

if ! grep -q 'replace-route' "$bootstrap"; then
  printf 'expected cloud-init to configure per-AZ NAT route via replace-route\n' >&2
  exit 1
fi

if ! grep -q 'private_route_table_by_az' "$bootstrap"; then
  printf 'expected cloud-init to receive AZ-to-route-table mapping\n' >&2
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

if ! grep -q 'resource "aws_kms_key" "eks_secrets"' kms.tf; then
  printf 'expected KMS key for EKS secrets encryption\n' >&2
  exit 1
fi

if ! grep -q 'enable_key_rotation *= *true' kms.tf; then
  printf 'expected KMS key rotation enabled\n' >&2
  exit 1
fi

if ! grep -q 'create_kms_key *= *false' eks.tf; then
  printf 'expected EKS module to use external KMS key\n' >&2
  exit 1
fi

if ! grep -q 'encryption_config' eks.tf; then
  printf 'expected EKS cluster encryption config\n' >&2
  exit 1
fi

if ! test -f backend.tf; then
  printf 'expected S3 backend configuration\n' >&2
  exit 1
fi

if ! grep -q 'use_lockfile *= *true' backend.tf; then
  printf 'expected S3 backend with native locking\n' >&2
  exit 1
fi

if ! test -f gitops/base/templates/pdbs.yaml; then
  printf 'expected PodDisruptionBudget manifests\n' >&2
  exit 1
fi

if ! test -f gitops/base/templates/alert-rules.yaml; then
  printf 'expected alerting rules\n' >&2
  exit 1
fi

if ! test -f gitops/base/templates/network-policies.yaml; then
  printf 'expected network policies\n' >&2
  exit 1
fi

if ! grep -q 'ENABLE_NETWORK_POLICY.*true' eks.tf; then
  printf 'expected VPC CNI network policy enabled\n' >&2
  exit 1
fi

if ! grep -q 'ssl-policy.*TLS13' gitops/base/templates/ingresses.yaml; then
  printf 'expected TLS 1.2 minimum policy on all ingresses\n' >&2
  exit 1
fi

if ! test -f velero.tf; then
  printf 'expected Velero Terraform infrastructure\n' >&2
  exit 1
fi

if ! test -f observability.tf; then
  printf 'expected observability Terraform infrastructure\n' >&2
  exit 1
fi
