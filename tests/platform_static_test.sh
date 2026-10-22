#!/usr/bin/env bash
set -euo pipefail

assert_contains() {
  local file=$1
  local text=$2
  if ! grep -Fq -- "$text" "$file"; then
    printf 'expected %s in %s\n' "$text" "$file" >&2
    exit 1
  fi
}

assert_absent() {
  local file=$1
  local text=$2
  if grep -Fq -- "$text" "$file"; then
    printf 'expected %s to be absent from %s\n' "$text" "$file" >&2
    exit 1
  fi
}

assert_contains pod-identity.tf 'module "aws_load_balancer_controller_pod_identity"'
assert_contains pod-identity.tf 'module "external_dns_pod_identity"'
assert_contains route53-acm.tf 'private_zone = false'
assert_contains network.tf 'kubernetes.io/role/internal-elb'
assert_contains variables.tf 'variable "enable_argocd_bootstrap"'
assert_contains outputs.tf 'output "airflow_db_address"'
assert_contains argocd.tf 'resource "helm_release" "argocd"'
assert_contains argocd.tf 'resource "helm_release" "argocd_root_application"'
assert_contains argocd.tf 'name  = "configs.secret.createSecret"'
assert_contains argocd.tf 'value = "true"'
assert_contains gitops/apps/argocd/values.yaml 'createSecret: false'
assert_contains charts/argocd-root-application/templates/application.yaml 'resources-finalizer.argocd.argoproj.io'
assert_contains gitops/root/templates/applications.yaml 'resources-finalizer.argocd.argoproj.io'
assert_contains gitops/root/templates/applications.yaml 'toYaml $.Values.global'
assert_contains gitops/base/templates/ingresses.yaml 'alb.ingress.kubernetes.io/ip-address-type: dualstack'
assert_contains gitops/base/templates/ingresses.yaml 'alb.ingress.kubernetes.io/target-type: ip'
assert_contains gitops/base/templates/network-policies.yaml 'name: allow-alb-argocd-server'
assert_contains gitops/base/templates/network-policies.yaml 'name: allow-alb-airflow-api-server'
assert_contains gitops/apps/airflow/values.yaml 'metadataSecretName: airflow-db-credentials'
assert_contains gitops/apps/external-dns/values.yaml 'policy: sync'
assert_contains gitops/root/templates/applications.yaml 'policy: sync'
assert_contains gitops/root/templates/applications.yaml 'preserveResourcesOnDeletion: false'
assert_contains charts/argocd-root-application/templates/application.yaml 'preserveResourcesOnDeletion: false'
assert_contains gitops/apps/airflow/values.yaml 'useHelmHooks: false'
assert_contains gitops/apps/spark-operator/values.yaml 'enable: true'
assert_contains gitops/root/templates/applications.yaml 'ServerSideApply=true'
assert_contains gitops/apps/kubecost/values.yaml '  mcp:'
assert_contains gitops/apps/kubecost/values.yaml '    enabled: false'
assert_contains README.md 'Terraform `>= 1.11.0`'
assert_contains README.md 'airflow_db_password'
assert_contains README.md 'airflow-secrets.tf'
assert_contains README.md 'no automated backup'
assert_contains AGENTS.md 'Kubernetes version `1.37`'
assert_contains AGENTS.md 'password_wo'

for documentation in README.md AGENTS.md; do
  if grep -Eiq 'Grafana|Prometheus|Loki|Alloy|OpenTelemetry|OTel|Velero|CloudNativePG|CNPG|Sealed Secrets|monitoring\.<domain>' "$documentation"; then
    printf 'expected current documentation to omit retired platform services: %s\n' "$documentation" >&2
    exit 1
  fi
done

for app in base argocd aws-load-balancer-controller external-dns karpenter karpenter-resources airflow spark-operator kubecost; do
  assert_contains gitops/root/templates/applications.yaml "\"name\" \"$app\""
done

for app in sealed-secrets velero cloudnative-pg kube-prometheus-stack loki alloy airflow-db otel-collector; do
  assert_absent gitops/root/templates/applications.yaml "\"name\" \"$app\""
  if test -e "gitops/apps/$app"; then
    printf 'expected retired GitOps directory to be removed: %s\n' "$app" >&2
    exit 1
  fi
done

for file in velero.tf database.tf gitops/base/templates/alert-rules.yaml gitops/base/templates/servicemonitors.yaml; do
  if test -e "$file"; then
    printf 'expected retired file to be removed: %s\n' "$file" >&2
    exit 1
  fi
done

for retired in cnpgBackupBucket veleroBucket lokiBucket; do
  assert_absent argocd.tf "$retired"
  assert_absent charts/argocd-root-application/templates/application.yaml "$retired"
  assert_absent charts/argocd-root-application/values.yaml "$retired"
  assert_absent gitops/root/values.yaml "$retired"
done

assert_absent observability.tf 'aws_s3_bucket.loki'
assert_absent observability.tf 'module "loki_pod_identity"'
assert_absent gitops/base/templates/namespaces.yaml 'sealed-secrets'
assert_absent gitops/base/templates/namespaces.yaml 'monitoring'
assert_absent gitops/base/templates/network-policies.yaml 'cnpg-system'
assert_absent gitops/base/templates/network-policies.yaml 'monitoring'
assert_absent gitops/base/templates/pdbs.yaml 'sealed-secrets'
if test -e gitops/apps/argocd/templates/argocd-secret-sealed.yaml; then
  printf 'expected Argo CD sealed secret template to be removed\n' >&2
  exit 1
fi

if grep -R -n -E 'SealedSecret|sealedsecrets\.bitnami\.com|kubeseal|seal-secrets\.sh' \
  --exclude-dir=.git --exclude-dir=docs --exclude='*.tgz' gitops scripts 2>/dev/null; then
  printf 'expected native Kubernetes Secrets instead of Sealed Secrets\n' >&2
  exit 1
fi

printf 'platform structure matches the retained-service architecture\n'
