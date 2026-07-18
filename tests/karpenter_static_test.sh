#!/usr/bin/env bash
set -euo pipefail

node_class="gitops/apps/karpenter-resources/chart/templates/ec2nodeclass.yaml"
node_pools="gitops/apps/karpenter-resources/chart/templates/nodepools.yaml"

if ! grep -q '^  name: spark$' "$node_class"; then
  printf 'expected a dedicated Spark EC2NodeClass\n' >&2
  exit 1
fi

if ! grep -A20 '^  name: spark$' "$node_class" | grep -q 'Name: {{ printf "%s-spark" .Values.clusterName | quote }}'; then
  printf 'expected Spark EC2NodeClass to tag instances with a Spark Name\n' >&2
  exit 1
fi

if ! grep -A35 '^  name: spark$' "$node_pools" | grep -q '^        name: spark$'; then
  printf 'expected Spark NodePool to reference the dedicated Spark EC2NodeClass\n' >&2
  exit 1
fi
