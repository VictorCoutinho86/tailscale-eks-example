# GitOps Chart Fixes Design

## Context

Four platform charts managed by the Argo CD app-of-apps tree are broken or misconfigured:

1. **Sealed Secrets**: the chart repository `https://bitnami-labs.github.io/sealed-secrets` was discontinued and returns 404, so Argo CD cannot build chart dependencies.
2. **Airflow**: chart 1.22.0 (Airflow 3.2.2) generates `fernetKey`, `jwtSecret`, and `apiSecretKey` with `randAlphaNum` when unset. Argo CD renders charts client-side with `helm template`, so every sync produces new keys — constant drift and rotating encryption keys.
3. **Kubecost**: the `cost-analyzer` 2.x line is deprecated; the repository moved to `https://kubecost.github.io/kubecost/` with chart `kubecost` 3.2.1. In 3.x, `clusterId` moves to `global.clusterId`, the bundled Prometheus subchart is gone, and `finopsagent` is a default-enabled dependency.
4. **Spark Operator**: its CRDs are ~1.6MB; client-side apply exceeds the 262144-byte `last-applied-configuration` annotation limit.

## Goals

- Fix Sealed Secrets dependency resolution with the current repository `https://bitnami.github.io/sealed-secrets` and chart 2.19.1.
- Pin static Airflow `fernetKey`, `jwtSecret`, and `apiSecretKey` values so renders are deterministic.
- Migrate Kubecost to chart `kubecost` 3.2.1 from the new repository with updated values structure.
- Fix Spark Operator CRD application with `ServerSideApply=true`.
- Vendor chart tgz files and `Chart.lock` for all wrapper charts, consistent with the existing pattern.

## Non-Goals

- External secrets management for the Airflow keys (Sealed Secrets sealing requires a live cluster cert; out of scope for this fix).
- Kubecost AWS CUR/cloud integration (`values-eks-cost-monitoring.yaml`).
- Airflow chart or Spark Operator chart version upgrades beyond the fixes above.

## Design

### Sealed Secrets

- `gitops/apps/sealed-secrets/Chart.yaml`: repository `https://bitnami.github.io/sealed-secrets`, version `2.19.1`.
- Run `helm dependency update` to vendor `charts/sealed-secrets-2.19.1.tgz` and create `Chart.lock`.

### Airflow

- `gitops/apps/airflow/values.yaml`: set explicit static values under `airflow:`:
  - `fernetKey`: 32 url-safe base64-encoded bytes (cryptography Fernet format).
  - `jwtSecret`: static random string.
  - `apiSecretKey`: static random string.
- Values are documented as dev/example keys with a comment stating they must be rotated and externally managed for production use.
- `webserverSecretKey` stays unset: deprecated in Airflow 3.x.

### Kubecost

- `gitops/apps/kubecost/Chart.yaml`: dependency name `kubecost`, version `3.2.1`, repository `https://kubecost.github.io/kubecost/`.
- `gitops/apps/kubecost/values.yaml`: prefix changes from `cost-analyzer:` to `kubecost:`.
- Root app-of-apps kubecost values block becomes `kubecost.global.clusterId` only; the old `cost-analyzer.prometheus...` block is removed.
- `helm dependency update` vendors the kubecost tgz plus its default-enabled `finops-agent` subchart.
- The only bitnami image in 3.2.1 (`bitnami/kubectl`) is used by an optional helm test that Argo CD never runs; no action needed.

### Spark Operator

- `gitops/root/templates/applications.yaml`: add `ServerSideApply=true` to the spark-operator Application `syncOptions` via a conditional on the app name.

### Static Tests

Extend `tests/platform_static_test.sh` to assert:

- Sealed Secrets Chart.yaml points to `https://bitnami.github.io/sealed-secrets` at 2.19.1 with a vendored tgz.
- Kubecost Chart.yaml uses repo `https://kubecost.github.io/kubecost/`, chart `kubecost` 3.2.1, with vendored tgz.
- Airflow values contain non-empty `fernetKey`, `jwtSecret`, and `apiSecretKey`.
- Root app-of-apps includes `ServerSideApply=true` for spark-operator.
- No chart references the discontinued `bitnami-labs.github.io` or `kubecost.github.io/cost-analyzer` repositories.

## Testing

- `helm dependency build` + `helm template` for each changed wrapper chart.
- `rtk bash tests/platform_static_test.sh`
- `rtk bash tests/bootstrap_static_test.sh`
- Runtime check after sync: sealed-secrets, kubecost, spark-operator, and airflow Applications reach `Synced`/`Healthy`.

## Risks

- Kubecost 3.x is a major version upgrade; existing 2.x data (if any was ever synced) is not migrated. Acceptable: the app never became healthy.
- Static Airflow keys in git are fine for this example repo but must be treated as disposable dev credentials.
- `finops-agent` subchart adds one more vendored artifact; `helm dependency build` must succeed offline from vendored tgz files.
