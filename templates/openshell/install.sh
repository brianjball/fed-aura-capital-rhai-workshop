#!/bin/bash
# Deploy OpenShell gateway on OpenShift (no authentication).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/common.sh"

NAMESPACE="${NAMESPACE:-wksp-user1}"
OPENSHELL_VERSION="${OPENSHELL_VERSION:-}"

VERSION_FLAG=""
if [ -n "$OPENSHELL_VERSION" ]; then
    VERSION_FLAG="--version $OPENSHELL_VERSION"
fi

echo "============================================"
echo " OpenShell Gateway Deployment"
echo "============================================"
echo ""
echo " Namespace: $NAMESPACE"
echo ""

check_prereqs

install_agent_sandbox_operator
create_openshell_namespace "$NAMESPACE"
grant_privileged_scc "$NAMESPACE"

step "Create JWT signing secret"
create_jwt_secret "$NAMESPACE"

adopt_cluster_scoped_resources "$NAMESPACE"

step "Install OpenShell Helm chart"
# shellcheck disable=SC2086
helm upgrade --install openshell oci://ghcr.io/nvidia/openshell/helm-chart \
    --namespace "$NAMESPACE" \
    $VERSION_FLAG \
    -f "$SCRIPT_DIR/manifests/openshell/values.yaml"

wait_for_rollout statefulset openshell "$NAMESPACE" 300

step "Configure gateway auth (no OIDC)"
oc -n "$NAMESPACE" get configmap openshell-config -o jsonpath='{.data.gateway\.toml}' > /tmp/gw-config-$$.toml
if ! grep -q 'allow_unauthenticated_users' /tmp/gw-config-$$.toml; then
    printf '\n[openshell.gateway.auth]\nallow_unauthenticated_users = true\n' >> /tmp/gw-config-$$.toml
    oc create configmap openshell-config --from-file=gateway.toml=/tmp/gw-config-$$.toml \
        -n "$NAMESPACE" --dry-run=client -o yaml | oc apply -f -
    oc delete pod openshell-0 -n "$NAMESPACE"
    wait_for_rollout statefulset openshell "$NAMESPACE" 120
fi
rm -f /tmp/gw-config-$$.toml

step "Expose gateway via Route"
oc -n "$NAMESPACE" apply -f "$SCRIPT_DIR/manifests/openshell/route.yaml"
sleep 2
GW_ROUTE=$(oc -n "$NAMESPACE" get route openshell-gw -o jsonpath='{.spec.host}' 2>/dev/null || echo "pending")

if [ "${ENABLE_TLS:-false}" = "true" ]; then
    step "Enable passthrough TLS (cert-manager)"
    APPS_DOMAIN=$(detect_apps_domain)
    setup_gateway_tls "$NAMESPACE" "$APPS_DOMAIN"
    GW_ROUTE=$(oc -n "$NAMESPACE" get route openshell-gw -o jsonpath='{.spec.host}' 2>/dev/null || echo "pending")
    GW_PROTO="https"
    GW_INSECURE_FLAG="--gateway-insecure"
else
    GW_PROTO="http"
    GW_INSECURE_FLAG=""
fi

echo ""
echo "============================================"
echo " Setup complete!"
echo "============================================"
echo ""
echo " Gateway URL: ${GW_PROTO}://$GW_ROUTE"
echo ""
echo " Next steps:"
echo ""
echo "   1. Register gateway:"
echo "      openshell gateway add ${GW_PROTO}://$GW_ROUTE $GW_INSECURE_FLAG \\"
echo "          --name openshift"
echo ""
echo "   2. Create a sandbox:"
echo "      openshell sandbox create --name test -- echo 'Hello from OpenShell!'"
echo ""