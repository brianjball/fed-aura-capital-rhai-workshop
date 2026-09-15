#!/bin/bash
# Teardown: Remove OpenShell and all associated resources.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/common.sh"

NAMESPACE="${NAMESPACE:-wksp-user1}"
DELETE_CRDS="${1:-}"

echo "============================================"
echo " Teardown OpenShell"
echo "============================================"
echo ""

step "Delete OpenShell Helm release"
helm uninstall openshell --namespace "$NAMESPACE" 2>/dev/null || warn "Helm release not found"

step "Delete OpenShell Route and secrets"
oc -n "$NAMESPACE" delete route openshell-gw 2>/dev/null || true
oc -n "$NAMESPACE" delete secret openshell-jwt-keys 2>/dev/null || true
oc -n "$NAMESPACE" delete pvc openshell-data-openshell-0 2>/dev/null || true

step "Delete SCC binding"
oc adm policy remove-scc-from-user privileged -z openshell-sandbox -n "$NAMESPACE" 2>/dev/null || true

if [ "$DELETE_CRDS" = "--crd" ]; then
    step "Delete Agent Sandbox operator"
    oc -n openshift-operators delete subscription agent-sandbox-operator 2>/dev/null || true
    csv=$(oc -n openshift-operators get csv -o name 2>/dev/null | grep agent-sandbox || true)
    if [ -n "$csv" ]; then
        oc -n openshift-operators delete "$csv" 2>/dev/null || true
    fi
fi

echo ""
info "Teardown complete."