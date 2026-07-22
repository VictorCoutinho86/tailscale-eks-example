#!/usr/bin/env bash
set -euo pipefail

# seal-secrets.sh — Generate and encrypt secrets for the platform using kubeseal.
#
# Prerequisites:
#   1. kubectl configured for the target cluster
#   2. kubeseal installed (https://github.com/bitnami-labs/sealed-secrets)
#   3. Sealed Secrets controller running in the cluster
#
# Usage: bash scripts/seal-secrets.sh

SEALED_SECRETS_NS="kube-system"
SEALED_SECRETS_CONTROLLER="sealed-secrets"

echo "==> Checking prerequisites..."
command -v kubeseal >/dev/null 2>&1 || { echo "ERROR: kubeseal not found. Install: brew install kubeseal"; exit 1; }
command -v kubectl >/dev/null 2>&1 || { echo "ERROR: kubectl not found"; exit 1; }
command -v htpasswd >/dev/null 2>&1 || { echo "ERROR: htpasswd not found (needed for bcrypt)"; exit 1; }

echo "==> Fetching Sealed Secrets controller certificate from ${SEALED_SECRETS_NS}/${SEALED_SECRETS_CONTROLLER}..."
kubeseal --fetch-cert \
  --controller-name "${SEALED_SECRETS_CONTROLLER}" \
  --controller-namespace "${SEALED_SECRETS_NS}" \
  > /tmp/sealed-secrets-cert.pem

seal() {
  local namespace="$1" name="$2" key="$3" value="$4"
  echo "    ${namespace}/${name} :: ${key}"
  echo -n "$value" | kubeseal --raw --name "$name" --namespace "$namespace" --scope namespace-wide --cert /tmp/sealed-secrets-cert.pem
}

echo ""
echo "==> Sealing Airflow secrets..."

AIRFLOW_NS="airflow"

AIRFLOW_FERNET_KEY=$(python3 -c "import base64, os; print(base64.urlsafe_b64encode(os.urandom(32)).decode().rstrip('='))")
echo "# Generated fernet key (store securely if needed): ${AIRFLOW_FERNET_KEY}"

AIRFLOW_JWT_SECRET=$(python3 -c "import secrets; print(secrets.token_urlsafe(48))")
AIRFLOW_API_SECRET_KEY=$(python3 -c "import secrets; print(secrets.token_urlsafe(24))")
AIRFLOW_ADMIN_PASSWORD=$(python3 -c "import secrets; print(secrets.token_urlsafe(16))")
ARGOCD_ADMIN_PASSWORD=$(python3 -c "import secrets; print(secrets.token_urlsafe(16))")
ARGOCD_BCRYPT=$(htpasswd -bnBC 10 "" "${ARGOCD_ADMIN_PASSWORD}" | tr -d ':\n')
ARGOCD_SECRET_KEY=$(python3 -c "import secrets; print(secrets.token_hex(32))")
ARGOCD_PASSWORD_MTIME=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

cat > gitops/apps/airflow/templates/fernet-key-sealed-secret.yaml <<EOF
apiVersion: bitnami.com/v1alpha1
kind: SealedSecret
metadata:
  name: airflow-fernet-key
  namespace: ${AIRFLOW_NS}
  annotations:
    sealedsecrets.bitnami.com/namespace-wide: "true"
spec:
  encryptedData:
    fernet-key: $(seal "$AIRFLOW_NS" "airflow-fernet-key" "fernet-key" "$AIRFLOW_FERNET_KEY")
  template:
    metadata:
      name: airflow-fernet-key
      namespace: ${AIRFLOW_NS}
      labels:
        tier: airflow
        app.kubernetes.io/part-of: airflow
    type: Opaque
EOF

cat > gitops/apps/airflow/templates/jwt-sealed-secret.yaml <<EOF
apiVersion: bitnami.com/v1alpha1
kind: SealedSecret
metadata:
  name: airflow-jwt-secret
  namespace: ${AIRFLOW_NS}
  annotations:
    sealedsecrets.bitnami.com/namespace-wide: "true"
spec:
  encryptedData:
    jwt-secret: $(seal "$AIRFLOW_NS" "airflow-jwt-secret" "jwt-secret" "$AIRFLOW_JWT_SECRET")
  template:
    metadata:
      name: airflow-jwt-secret
      namespace: ${AIRFLOW_NS}
      labels:
        tier: airflow
        app.kubernetes.io/part-of: airflow
    type: Opaque
EOF

cat > gitops/apps/airflow/templates/api-secret-key-sealed-secret.yaml <<EOF
apiVersion: bitnami.com/v1alpha1
kind: SealedSecret
metadata:
  name: airflow-api-secret-key
  namespace: ${AIRFLOW_NS}
  annotations:
    sealedsecrets.bitnami.com/namespace-wide: "true"
spec:
  encryptedData:
    api-secret-key: $(seal "$AIRFLOW_NS" "airflow-api-secret-key" "api-secret-key" "$AIRFLOW_API_SECRET_KEY")
  template:
    metadata:
      name: airflow-api-secret-key
      namespace: ${AIRFLOW_NS}
      labels:
        tier: airflow
        app.kubernetes.io/part-of: airflow
    type: Opaque
EOF

cat > gitops/apps/airflow/templates/admin-password-sealed-secret.yaml <<EOF
apiVersion: bitnami.com/v1alpha1
kind: SealedSecret
metadata:
  name: airflow-admin-credentials
  namespace: ${AIRFLOW_NS}
  annotations:
    sealedsecrets.bitnami.com/namespace-wide: "true"
spec:
  encryptedData:
    admin-password: $(seal "$AIRFLOW_NS" "airflow-admin-credentials" "admin-password" "$AIRFLOW_ADMIN_PASSWORD")
  template:
    metadata:
      name: airflow-admin-credentials
      namespace: ${AIRFLOW_NS}
      labels:
        tier: airflow
        app.kubernetes.io/part-of: airflow
    type: Opaque
EOF

echo ""
echo "==> Sealing Argo CD secret..."

cat > gitops/apps/argocd/templates/argocd-secret-sealed.yaml <<EOF
apiVersion: bitnami.com/v1alpha1
kind: SealedSecret
metadata:
  name: argocd-secret
  namespace: argocd
  annotations:
    sealedsecrets.bitnami.com/namespace-wide: "true"
spec:
  encryptedData:
    admin.password: $(seal "argocd" "argocd-secret" "admin.password" "$ARGOCD_BCRYPT")
    admin.passwordMtime: $(seal "argocd" "argocd-secret" "admin.passwordMtime" "$ARGOCD_PASSWORD_MTIME")
    server.secretkey: $(seal "argocd" "argocd-secret" "server.secretkey" "$ARGOCD_SECRET_KEY")
  template:
    metadata:
      name: argocd-secret
      namespace: argocd
      labels:
        app.kubernetes.io/component: server
        app.kubernetes.io/name: argocd-secret
        app.kubernetes.io/part-of: argocd
    type: Opaque
EOF

rm -f /tmp/sealed-secrets-cert.pem

echo ""
echo "==> Done!"
echo ""
echo "Generated passwords (store securely):"
echo "  Airflow admin:  ${AIRFLOW_ADMIN_PASSWORD}"
echo "  Argo CD admin:  ${ARGOCD_ADMIN_PASSWORD}"
echo ""
echo "SealedSecret manifests updated. Verify with: git diff gitops/"
echo ""
echo "After commit, Argo CD will sync and the Sealed Secrets controller"
echo "will decrypt and create the target Kubernetes Secrets."
