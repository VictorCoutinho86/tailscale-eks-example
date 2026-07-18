#!/usr/bin/env bash
set -euo pipefail

if ! grep -q 'resource "terraform_data" "private_subnet_nat_precondition"' network.tf; then
  printf 'expected private subnet NAT precondition resource\n' >&2
  exit 1
fi

if ! grep -A8 'resource "terraform_data" "private_subnet_nat_precondition"' network.tf | grep -q 'condition     = var.enable_bootstrap_instance'; then
  printf 'expected private subnet NAT precondition to require the bootstrap instance\n' >&2
  exit 1
fi
