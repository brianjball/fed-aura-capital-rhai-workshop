#!/bin/bash
# Verify OpenShell deployment.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/common.sh"

NAMESPACE="${NAMESPACE:-wksp-user1}"
PASSED=0
FAILED=0

check() {
    local name="$1"
    shift
    if "$@" &>/dev/null; then
        info "PASS: $name"
        PASSED=$((PASSED + 1))
    else
        error "FAIL: $name"
        FAILED=$((FAILED + 1))
    fi
}

echo "============================================"
echo " Verify OpenShell Deployment"
echo "============================================"
echo ""

step "OpenShell checks"
check "Agent Sandbox CRD exists" oc get crd sandboxes.agents.x-k8s.io
check "OpenShell namespace exists" oc get ns "$NAMESPACE"
check "Gateway pod running" oc -n "$NAMESPACE" wait --for=condition=Ready pod -l app.kubernetes.io/name=openshell --timeout=10s
check "Gateway service exists" oc -n "$NAMESPACE" get svc openshell
check "Gateway route exists" oc -n "$NAMESPACE" get route openshell-gw

step "RHOAI MLflow checks"
OCP_TOKEN=$(oc whoami -t 2>/dev/null || true)
if [ -n "$OCP_TOKEN" ]; then
    if [ -f "$SCRIPT_DIR/.env" ]; then
        source "$SCRIPT_DIR/.env"
    fi
    MLF_URI="${MLFLOW_TRACKING_URI:-https://mlflow.redhat-ods-applications.svc.cluster.local:8443/mlflow}"
    MLF_CODE=$(curl -sk -o /dev/null -w "%{http_code}" -H "Authorization: Bearer $OCP_TOKEN" "${MLF_URI}/health" 2>/dev/null)
    if [ "$MLF_CODE" = "200" ]; then
        info "PASS: RHOAI MLflow health (HTTP 200)"
        PASSED=$((PASSED + 1))
    else
        error "FAIL: RHOAI MLflow health (HTTP $MLF_CODE)"
        FAILED=$((FAILED + 1))
    fi
else
    info "SKIP: RHOAI MLflow (no OCP token)"
fi

echo ""
echo "Results: $PASSED passed, $FAILED failed"
if [ "$FAILED" -gt 0 ]; then
    exit 1
fi