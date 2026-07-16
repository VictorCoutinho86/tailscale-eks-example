#!/usr/bin/env bash
set -euo pipefail

bootstrap="templates/bootstrap.sh.tftpl"

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
