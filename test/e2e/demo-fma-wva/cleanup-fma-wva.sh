#!/usr/bin/env bash

# Tears down resources created by demo-fma-wva-ocp.sh (FMA + WVA + llm-d).
#
# By default removes FMA objects, WVA objects, HPA, and FMA controllers but keeps
# the namespace, CRDs, EPP, and WVA controller.
# Set FULL_CLEANUP=true to also remove namespace, node labels, WVA controller,
# and the namespace-scoped EPP.
#
# Prerequisites:
#   - oc/kubectl authenticated
#   - helm  (used on the default path to uninstall the FMA Helm release)
#   - jq    (used on the default path to surgically strip dual-pods finalizers
#            from pods, preserving any other finalizers)
#   - git   (only required when FULL_CLEANUP=true, to clone the WVA repo)
#
# When FULL_CLEANUP=true, the workload-variant-autoscaler (WVA) repo is
# auto-cloned to $WVA_REPO_PATH if not already present. To use an existing
# checkout, set WVA_REPO_PATH to its path.
#
# Optional environment variables:
#   NAMESPACE          - target namespace (default: fma-wva-demo)
#   FULL_CLEANUP       - if "true", also delete namespace, node labels, WVA controller, EPP (default: false)
#   WVA_REPO_PATH      - path to WVA repo (default: ~/.cache/llm-d-fma/workload-variant-autoscaler)
#   WVA_REPO_URL       - WVA git URL (default: https://github.com/llm-d/llm-d-workload-variant-autoscaler)
#   WVA_REPO_REF       - WVA git ref/branch/tag (default: main)

set -euo pipefail

NAMESPACE="${NAMESPACE:-fma-wva-demo}"
FULL_CLEANUP="${FULL_CLEANUP:-false}"

echo "========================================="
echo "  FMA + WVA Demo Cleanup"
echo "========================================="
echo ""
echo "  Namespace:          $NAMESPACE"
echo "  Full cleanup:       $FULL_CLEANUP"
echo ""

# Skip if namespace doesn't exist
if ! kubectl get ns "$NAMESPACE" &>/dev/null; then
    echo "  Namespace $NAMESPACE not found — nothing to do in-namespace."
    SKIP_NS_OPS=true
else
    SKIP_NS_OPS=false
fi

# Helper: strip ONLY dual-pods.llm-d.ai/* finalizers from pods in the namespace,
# preserving any other finalizers (sidecars, operators, etc.) 
strip_dual_pods_finalizers() {
    local pods
    pods=$(kubectl get pods -n "$NAMESPACE" -o name 2>/dev/null || true)
    [ -z "$pods" ] && return 0
    while read -r pod; do
        [ -z "$pod" ] && continue
        # Build the new finalizer list: keep everything except dual-pods.llm-d.ai/*.
        # If jq returns nothing (no finalizers at all) skip the patch.
        local new_fin
        new_fin=$(kubectl get "$pod" -n "$NAMESPACE" -o json 2>/dev/null \
            | jq -c '[.metadata.finalizers[]? | select(startswith("dual-pods.llm-d.ai/") | not)]' 2>/dev/null) || continue
        # Only patch if the pod actually has a dual-pods finalizer to strip.
        local had_fma
        had_fma=$(kubectl get "$pod" -n "$NAMESPACE" -o json 2>/dev/null \
            | jq -r '[.metadata.finalizers[]? | select(startswith("dual-pods.llm-d.ai/"))] | length' 2>/dev/null) || continue
        if [ "${had_fma:-0}" -gt 0 ]; then
            echo "  Removing dual-pods finalizers from $pod (preserving $((${#new_fin} > 2 ? 1 : 0)) others)"
            # An empty array [] tells kubectl "remove all" via merge patch; that's
            # the desired behavior when the only finalizers were dual-pods ones.
            kubectl patch "$pod" -n "$NAMESPACE" --type=merge \
                -p "{\"metadata\":{\"finalizers\":${new_fin}}}" 2>/dev/null || true
        fi
    done <<< "$pods"
}

if [ "$SKIP_NS_OPS" = "false" ]; then
    # 1. Loadgen pod (if exists)
    echo "--- Cleaning up loadgen ---"
    kubectl delete pod fma-loadgen -n "$NAMESPACE" --ignore-not-found 2>/dev/null

    # 2. WVA HPA first — stops WVA from scaling
    echo "--- Deleting WVA HPA ---"
    kubectl delete hpa wva-fma-hpa -n "$NAMESPACE" --ignore-not-found 2>/dev/null

    # 3. WVA VariantAutoscaling — stops WVA controller from managing the deployment
    echo "--- Deleting WVA VariantAutoscaling ---"
    kubectl delete variantautoscaling wva-fma-va -n "$NAMESPACE" --ignore-not-found 2>/dev/null

    # 4. Deployment — stops recreating requester pods
    echo "--- Deleting Deployment ---"
    kubectl delete deployment fma-requester -n "$NAMESPACE" --ignore-not-found 2>/dev/null

    # 5. Give the controller a moment to process pending bind/unbind events
    echo "--- Waiting for controller to drain (10s) ---"
    sleep 10

    # 6. Strip finalizers — must happen BEFORE we delete controllers, otherwise
    # finalizer removal is never processed and pods (and the namespace) hang
    echo "--- Stripping dual-pods finalizers from pods ---"
    strip_dual_pods_finalizers

    # 7. FMA objects (CRs) — deleting the LPP triggers launcher pod cleanup by the controller
    echo "--- Deleting FMA objects ---"
    kubectl delete launcherpopulationpolicy lpp-fma -n "$NAMESPACE" --ignore-not-found 2>/dev/null
    kubectl delete launcherconfig lc-fma -n "$NAMESPACE" --ignore-not-found 2>/dev/null
    kubectl delete inferenceserverconfig isc-smol -n "$NAMESPACE" --ignore-not-found 2>/dev/null

    # 8. PodMonitor
    echo "--- Deleting PodMonitor ---"
    kubectl delete podmonitor fma-launcher-monitor -n "$NAMESPACE" --ignore-not-found 2>/dev/null

    echo "--- Waiting for controller to clean up resources (10s) ---"
    sleep 10

    # 9. FMA controllers (Helm release)
    echo "--- Uninstalling FMA controllers ---"
    helm uninstall fma -n "$NAMESPACE" 2>/dev/null || true

fi

# 10. Cluster-scoped FMA resources
echo "--- Deleting cluster-scoped FMA resources ---"
kubectl delete clusterrolebinding fma-node-view --ignore-not-found 2>/dev/null
kubectl delete clusterrole fma-node-view --ignore-not-found 2>/dev/null
kubectl delete clusterrolebinding "${NAMESPACE}-${NAMESPACE}-epp" --ignore-not-found 2>/dev/null
kubectl delete clusterrole "${NAMESPACE}-${NAMESPACE}-epp" --ignore-not-found 2>/dev/null

if [ "$FULL_CLEANUP" = "true" ]; then
    echo ""
    echo "--- Full cleanup ---"

    # Resolve WVA repo (auto-clone if not present). Fail loudly only if the
    # path can't be obtained at all, so the WVA/EPP undeploy steps don't get
    # silently skipped while the summary lies about success.
    WVA_REPO_PATH="${WVA_REPO_PATH:-$HOME/.cache/llm-d-fma/workload-variant-autoscaler}"
    WVA_REPO_URL="${WVA_REPO_URL:-https://github.com/llm-d/llm-d-workload-variant-autoscaler}"
    WVA_REPO_REF="${WVA_REPO_REF:-main}"

    if [ ! -d "$WVA_REPO_PATH/.git" ]; then
        if [ -d "$WVA_REPO_PATH" ] && [ -n "$(ls -A "$WVA_REPO_PATH" 2>/dev/null)" ]; then
            echo "  ERROR: $WVA_REPO_PATH exists but is not a git checkout."
            echo "  Remove it or set WVA_REPO_PATH to a different location."
            exit 1
        fi
        echo "  WVA repo not found at $WVA_REPO_PATH — cloning $WVA_REPO_URL ($WVA_REPO_REF)..."
        mkdir -p "$(dirname "$WVA_REPO_PATH")"
        if ! git clone --depth 1 --branch "$WVA_REPO_REF" "$WVA_REPO_URL" "$WVA_REPO_PATH"; then
            echo "  ERROR: Failed to clone WVA repo from $WVA_REPO_URL ($WVA_REPO_REF)."
            exit 1
        fi
    else
        echo "  Using existing WVA repo at $WVA_REPO_PATH"
    fi

    # Remove node label
    echo "  Removing fma-poc label from nodes..."
    kubectl get nodes -l fma-poc=true -o name 2>/dev/null | while read -r node; do
        kubectl label "$node" fma-poc- 2>/dev/null || true
    done

    # Undeploy WVA controller — runs even if the namespace was already deleted,
    # because install.sh creates cluster-scoped RBAC that needs to be removed.
    echo "  Undeploying WVA controller..."
    (
        cd "$WVA_REPO_PATH"
        WVA_NS="$NAMESPACE" \
        LLMD_NS="$NAMESPACE" \
        ENVIRONMENT=openshift \
        UNDEPLOY=true \
        ./deploy/install.sh || true
    )

    # Undeploy EPP/Gateway — same rationale as WVA above.
    echo "  Undeploying EPP and Gateway..."
    (
        cd "$WVA_REPO_PATH"
        LLMD_NS="$NAMESPACE" \
        ENVIRONMENT=openshift \
        UNDEPLOY=true \
        ./deploy/install-epp.sh || true
    )

    # Delete namespace last (removes everything else in it)
    if [ "$SKIP_NS_OPS" = "false" ]; then
        echo "  Deleting namespace $NAMESPACE..."
        kubectl delete ns "$NAMESPACE" --ignore-not-found --timeout=120s 2>/dev/null || true

        # If still hung, strip namespace finalizers as a last resort
        if kubectl get ns "$NAMESPACE" &>/dev/null; then
            echo "  Namespace still present — stripping finalizers as last resort..."
            kubectl get ns "$NAMESPACE" -o json 2>/dev/null \
                | jq '.spec.finalizers = []' \
                | kubectl replace --raw "/api/v1/namespaces/$NAMESPACE/finalize" -f - 2>/dev/null || true
        fi
    fi

    echo ""
    echo "  Full cleanup complete."
    echo "  NOTE: CRDs (Gateway API, GAIE, FMA, WVA) are NOT removed — they may be cluster-shared."
else
    echo ""
    echo "  Cleanup complete. Namespace $NAMESPACE preserved."
    echo "  WVA controller, EPP, and Gateway are still in place."
    echo "  Run with FULL_CLEANUP=true to also remove the namespace, WVA controller, and EPP/Gateway."
fi

echo ""
echo "========================================="
echo "  Cleanup Summary"
echo "========================================="
echo ""
if [ "$FULL_CLEANUP" = "true" ]; then
    echo "  ✓ Removed FMA objects, WVA objects, and controllers"
    echo "  ✓ Removed WVA controller and EPP/Gateway"
    echo "  ✓ Removed namespace $NAMESPACE"
    echo "  ✓ Removed node labels"
else
    echo "  ✓ Removed FMA objects and WVA objects"
    echo "  ✓ Removed FMA controllers"
    echo "  ⚠ Preserved namespace $NAMESPACE"
    echo "  ⚠ Preserved WVA controller and EPP/Gateway"
    echo ""
    echo "  To perform full cleanup:"
    echo "    FULL_CLEANUP=true ./cleanup-fma-wva.sh"
    echo "  (set WVA_REPO_PATH if you have an existing WVA checkout to reuse)"
fi
echo ""
