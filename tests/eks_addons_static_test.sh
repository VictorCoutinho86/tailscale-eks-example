#!/usr/bin/env bash
set -euo pipefail

eks="eks.tf"

expected_versions=(
  'v1.23.2-eksbuild.3'
  'v1.4.0-eksbuild.4'
  'v1.14.7-eksbuild.11'
  'v1.37.0-eksbuild.22'
  'v1.67.1-eksbuild.1'
)

for expected in "${expected_versions[@]}"; do
  if ! grep -Eq "addon_version[[:space:]]*=[[:space:]]*\"${expected}\"" "$eks"; then
    printf 'expected pinned EKS addon version: %s\n' "$expected" >&2
    exit 1
  fi
done

if grep -q 'most_recent' "$eks"; then
  printf 'expected every EKS addon to use an explicit addon_version\n' >&2
  exit 1
fi

printf 'EKS addon version pins are present\n'
