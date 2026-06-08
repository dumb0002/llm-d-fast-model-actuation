#!/usr/bin/env bash

# Deploys FMA + WVA + llm-d components in the same namespace.
#
# Idempotent: checks each component before deploying, skips if already present.
# Run from the root of the llm-d-fast-model-actuation repository.
# Deploys the version of FMA that is checked out locally.
#
# Prerequisites:
#   - This repo (llm-d-incubation/llm-d-fast-model-actuation) cloned locally
#   - oc CLI authenticated to an OCP cluster with GPU nodes
#   - helm, kubectl, make, git installed
#   - Container images already pushed to registry (see CONTAINER_IMG_REG)
#
# The workload-variant-autoscaler (WVA) repo is auto-cloned to
# $WVA_REPO_PATH if not already present. To use an existing checkout,
# set WVA_REPO_PATH to its path.
#
# Optional environment variables (with defaults):
#   WVA_REPO_PATH      - path to WVA repo (default: ~/.cache/llm-d-fma/workload-variant-autoscaler)
#   WVA_REPO_URL       - WVA git URL (default: https://github.com/llm-d/llm-d-workload-variant-autoscaler)
#   WVA_REPO_REF       - WVA git ref/branch/tag (default: main)
#   NAMESPACE          - target namespace (default: fma-wva-demo)
#   CONTAINER_IMG_REG  - FMA image registry (default: ghcr.io/llm-d-incubation/llm-d-fast-model-actuation)
#   IMAGE_TAG          - FMA image tag (default: v0.6.0-alpha.12)
#   LAUNCHER_IMAGE     - launcher image (default: $CONTAINER_IMG_REG/launcher:$IMAGE_TAG)
#   REQUESTER_IMAGE    - requester image (default: $CONTAINER_IMG_REG/requester:$IMAGE_TAG)
#   MODEL              - vLLM model (default: HuggingFaceTB/SmolLM2-360M-Instruct)
#   GPU_NODE           - node for LPP (default: first node with nvidia.com/gpu.present=true)
#   WVA_IMAGE_REPO     - WVA image repository (default: quay.io/braulio/llm-d-wva)
#   WVA_IMAGE_TAG      - WVA image tag (default: v4)
#   CONTROLLER_INSTANCE - WVA controller instance name (default: fma-wva)
#   MONITORING_NAMESPACE - monitoring namespace (default: openshift-user-workload-monitoring)
#   LLM_D_RELEASE      - llm-d release version (default: v0.7.0)
#   GAIE_VERSION       - GAIE version (default: v1.5.0)
#   HF_TOKEN           - HuggingFace token (optional)
#   DEPLOY_PROMETHEUS  - deploy Prometheus (default: false, uses OpenShift monitoring)
#   DEPLOY_PROMETHEUS_ADAPTER - deploy Prometheus adapter (default: false)

set -euo pipefail

# FMA Configuration
NAMESPACE="${NAMESPACE:-fma-wva-demo}"
CONTAINER_IMG_REG="${CONTAINER_IMG_REG:-ghcr.io/llm-d-incubation/llm-d-fast-model-actuation}"
IMAGE_TAG="${IMAGE_TAG:-v0.6.0-alpha.12}"
LAUNCHER_IMAGE="${LAUNCHER_IMAGE:-${CONTAINER_IMG_REG}/launcher:${IMAGE_TAG}}"
REQUESTER_IMAGE="${REQUESTER_IMAGE:-${CONTAINER_IMG_REG}/requester:${IMAGE_TAG}}"
MODEL="${MODEL:-HuggingFaceTB/SmolLM2-360M-Instruct}"
GPU_NODE="${GPU_NODE:-}"

# WVA Configuration
WVA_IMAGE_REPO="${WVA_IMAGE_REPO:-quay.io/braulio/llm-d-wva}"
WVA_IMAGE_TAG="${WVA_IMAGE_TAG:-v4}"
CONTROLLER_INSTANCE="${CONTROLLER_INSTANCE:-fma-wva}"
MONITORING_NAMESPACE="${MONITORING_NAMESPACE:-openshift-user-workload-monitoring}"
LLM_D_RELEASE="${LLM_D_RELEASE:-v0.7.0}"
GAIE_VERSION="${GAIE_VERSION:-v1.5.0}"
HF_TOKEN="${HF_TOKEN:-}"
DEPLOY_PROMETHEUS="${DEPLOY_PROMETHEUS:-false}"
DEPLOY_PROMETHEUS_ADAPTER="${DEPLOY_PROMETHEUS_ADAPTER:-false}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"

# WVA repo: auto-clone if not present. WVA_REPO_PATH may be pre-set to point
# at an existing checkout; otherwise default to a per-user cache directory.
WVA_REPO_PATH="${WVA_REPO_PATH:-$HOME/.cache/llm-d-fma/workload-variant-autoscaler}"
WVA_REPO_URL="${WVA_REPO_URL:-https://github.com/llm-d/llm-d-workload-variant-autoscaler}"
WVA_REPO_REF="${WVA_REPO_REF:-main}"

if [ ! -d "$WVA_REPO_PATH/.git" ]; then
    if [ -d "$WVA_REPO_PATH" ] && [ -n "$(ls -A "$WVA_REPO_PATH" 2>/dev/null)" ]; then
        echo "ERROR: $WVA_REPO_PATH exists but is not a git checkout. Remove it or set WVA_REPO_PATH to a different location." >&2
        exit 1
    fi
    echo "  WVA repo not found at $WVA_REPO_PATH — cloning $WVA_REPO_URL ($WVA_REPO_REF)..."
    mkdir -p "$(dirname "$WVA_REPO_PATH")"
    git clone --depth 1 --branch "$WVA_REPO_REF" "$WVA_REPO_URL" "$WVA_REPO_PATH"
else
    echo "  Using existing WVA repo at $WVA_REPO_PATH"
fi

step_num=0
total_steps=7

step() {
    step_num=$((step_num + 1))
    echo ""
    echo "========================================"
    echo "  Step ${step_num}/${total_steps}: $*"
    echo "========================================"
    echo ""
}


# =========================================================================
# Step 1: Namespace + RBAC
# =========================================================================

step "Namespace, ServiceAccounts, RBAC"

if kubectl get ns "$NAMESPACE" &>/dev/null; then
    echo "  Namespace $NAMESPACE exists"
else
    # Create namespace with OpenShift monitoring label
    kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | \
        kubectl label --local -f - openshift.io/user-monitoring=true -o yaml | \
        kubectl apply -f -
    echo "  Created namespace $NAMESPACE with monitoring enabled"
fi

if kubectl get sa testlauncher -n "$NAMESPACE" &>/dev/null; then
    echo "  SA testlauncher exists"
else
    kubectl create sa testlauncher -n "$NAMESPACE"
    echo "  Created SA testlauncher"
fi

if kubectl get role testlauncher -n "$NAMESPACE" &>/dev/null; then
    echo "  RBAC roles exist"
else
    kubectl apply -n "$NAMESPACE" -f - <<'EOF'
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: testlauncher
rules:
- apiGroups: [""]
  resources: [pods]
  verbs: [get, patch]
EOF
    kubectl create rolebinding testlauncher \
        --role=testlauncher --serviceaccount="${NAMESPACE}:testlauncher" \
        -n "$NAMESPACE" 2>/dev/null || true
    echo "  Created RBAC role and binding"
fi


# =========================================================================
# Step 2: FMA CRDs and Controllers (via deploy_fma.sh)
# =========================================================================

step "FMA CRDs and Controllers"

FMA_CHART="fma"
if kubectl get deployment "${FMA_CHART}-dual-pods-controller" -n "$NAMESPACE" &>/dev/null; then
    echo "  FMA controllers already deployed"
else
    echo "  Deploying FMA CRDs and controllers via deploy_fma.sh..."
    (
        cd "$REPO_ROOT"
        FMA_NAMESPACE="$NAMESPACE" \
        FMA_CHART_INSTANCE_NAME="$FMA_CHART" \
        CONTAINER_IMG_REG="$CONTAINER_IMG_REG" \
        IMAGE_TAG="$IMAGE_TAG" \
        NODE_VIEW_CLUSTER_ROLE=create/please \
        RUNTIME_CLASS_NAME=nvidia \
        HELM_EXTRA_ARGS="--set launcherPopulator.enabled=true" \
        "$SCRIPT_DIR/../deploy_fma.sh"
    )
fi

echo "  Verifying FMA CRDs..."
kubectl get crd | grep fma.llm-d.ai || echo "  WARNING: FMA CRDs not found"

echo "  Verifying FMA controllers..."
# `kubectl get -l ...` exits 0 with empty output when nothing matches, so we
# check for non-empty `-o name` output to detect missing resources reliably.
if kubectl get deployment -n "$NAMESPACE" -l app.kubernetes.io/part-of=fma -o name 2>/dev/null | grep -q .; then
    kubectl get deployment -n "$NAMESPACE" -l app.kubernetes.io/part-of=fma
else
    echo "  WARNING: FMA controllers not found"
fi


# =========================================================================
# Step 3: WVA Deployment (via make deploy-wva-on-openshift)
# =========================================================================

step "WVA Deployment"

if [ -n "$(kubectl get deployment -n "$NAMESPACE" -l control-plane=controller-manager -o name 2>/dev/null)" ]; then
    echo "  WVA controller already deployed"
else
    echo "  Deploying WVA to namespace $NAMESPACE..."
    (
        cd "$WVA_REPO_PATH"
        export HF_TOKEN="$HF_TOKEN"
        export DEPLOY_PROMETHEUS="$DEPLOY_PROMETHEUS"
        export DEPLOY_PROMETHEUS_ADAPTER="$DEPLOY_PROMETHEUS_ADAPTER"
        export LLMD_NS="$NAMESPACE"
        export WVA_NS="$NAMESPACE"
        export MONITORING_NAMESPACE="$MONITORING_NAMESPACE"
        export CONTROLLER_INSTANCE="$CONTROLLER_INSTANCE"
        export WVA_IMAGE_REPO="$WVA_IMAGE_REPO"
        export WVA_IMAGE_TAG="$WVA_IMAGE_TAG"
        export IMG="${WVA_IMAGE_REPO}:${WVA_IMAGE_TAG}"
        
        echo "  Running: make deploy-wva-on-openshift"
        make deploy-wva-on-openshift
    )
    echo "  WVA deployed successfully"
fi

echo "  Verifying WVA deployment..."
if kubectl get deployment -n "$NAMESPACE" -l control-plane=controller-manager -o name 2>/dev/null | grep -q .; then
    kubectl get deployment -n "$NAMESPACE" -l control-plane=controller-manager
else
    echo "  WARNING: WVA controller not found"
fi


# =========================================================================
# Step 4: llm-d EPP Installation (via install-epp.sh)
# =========================================================================

step "llm-d EPP Installation"

if [ -n "$(kubectl get inferencepool -n "$NAMESPACE" -o name 2>/dev/null)" ]; then
    echo "  llm-d EPP already deployed"
else
    echo "  Deploying llm-d EPP to namespace $NAMESPACE..."
    (
        cd "$WVA_REPO_PATH"
        export LLMD_NS="$NAMESPACE"
        export ENVIRONMENT=openshift
        export LLM_D_RELEASE="$LLM_D_RELEASE"
        export GAIE_VERSION="$GAIE_VERSION"
        
        echo "  Running: ./deploy/install-epp.sh"
        ./deploy/install-epp.sh
    )
    echo "  llm-d EPP deployed successfully"
fi

echo "  Verifying llm-d EPP..."
if kubectl get inferencepool -n "$NAMESPACE" -o name 2>/dev/null | grep -q .; then
    kubectl get inferencepool -n "$NAMESPACE"
else
    echo "  WARNING: InferencePool not found"
fi
if kubectl get gateway -n "$NAMESPACE" -o name 2>/dev/null | grep -q .; then
    kubectl get gateway -n "$NAMESPACE"
else
    echo "  WARNING: Gateway not found"
fi


# =========================================================================
# Step 5: FMA-specific objects (ISC, LauncherConfig, LPP, Deployment)
# =========================================================================

step "FMA-specific objects (ISC, LauncherConfig, LPP, Deployment)"

# Pick a GPU node for the LPP
if [ -z "$GPU_NODE" ]; then
    GPU_NODE=$(kubectl get nodes -l nvidia.com/gpu.present=true \
        -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
    if [ -z "$GPU_NODE" ]; then
        echo "  ERROR: No GPU node found. Set GPU_NODE manually." >&2
        exit 1
    fi
fi
echo "  Using GPU node: $GPU_NODE"

# Label the chosen node for LPP selector
kubectl label node "$GPU_NODE" fma-poc=true --overwrite=true 2>/dev/null
echo "  Labeled $GPU_NODE with fma-poc=true"

if kubectl get inferenceserverconfig isc-smol -n "$NAMESPACE" &>/dev/null; then
    echo "  FMA objects already exist"
else
    echo "  Creating FMA objects..."
    kubectl apply -n "$NAMESPACE" -f - <<EOF
apiVersion: fma.llm-d.ai/v1alpha1
kind: InferenceServerConfig
metadata:
  name: isc-smol
spec:
  modelServerConfig:
    port: 8000
    options: "--model ${MODEL} --enable-sleep-mode"
    env_vars:
      VLLM_USE_V1: "1"
      VLLM_SERVER_DEV_MODE: "1"
      VLLM_LOGGING_LEVEL: "DEBUG"
    labels:
      llm-d.ai/inference-serving: "true"
      llm-d.ai/guide: "optimized-baseline"
      llm-d.ai/model: "SmolLM2-360M-Instruct"
      llm-d.ai/variant: wva-fma-va
    annotations:
      description: "FMA ISC - ${MODEL}"
  launcherConfigName: lc-fma
---
apiVersion: fma.llm-d.ai/v1alpha1
kind: LauncherConfig
metadata:
  name: lc-fma
spec:
  maxInstances: 1
  podTemplate:
    spec:
      runtimeClassName: nvidia
      serviceAccountName: testlauncher
      containers:
        - name: inference-server
          image: ${LAUNCHER_IMAGE}
          imagePullPolicy: Always
          command:
          - /app/launcher.py
          - --host=0.0.0.0
          - --log-level=info
          - --port=8001
          env:
          - name: HF_HOME
            value: "/tmp"
          - name: VLLM_CACHE_ROOT
            value: "/tmp"
          - name: FLASHINFER_WORKSPACE_BASE
            value: "/tmp"
          - name: TRITON_CACHE_DIR
            value: "/tmp"
          - name: XDG_CACHE_HOME
            value: "/tmp"
          - name: XDG_CONFIG_HOME
            value: "/tmp"
---
apiVersion: fma.llm-d.ai/v1alpha1
kind: LauncherPopulationPolicy
metadata:
  name: lpp-fma
spec:
  enhancedNodeSelector:
    labelSelector:
      matchLabels:
        fma-poc: "true"
        nvidia.com/gpu.present: "true"
  countForLauncher:
    - launcherConfigName: lc-fma
      launcherCount: 1
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: fma-requester
  labels:
    app: fma-requester
spec:
  replicas: 1
  selector:
    matchLabels:
      app: fma-requester
  template:
    metadata:
      labels:
        app: fma-requester
        llm-d.ai/variant: wva-fma-va
      annotations:
        dual-pods.llm-d.ai/admin-port: "8081"
        dual-pods.llm-d.ai/inference-server-config: "isc-smol"
    spec:
      runtimeClassName: nvidia
      containers:
        - name: inference-server
          image: ${REQUESTER_IMAGE}
          imagePullPolicy: Always
          ports:
          - name: probes
            containerPort: 8080
          - name: spi
            containerPort: 8081
          readinessProbe:
            httpGet:
              path: /ready
              port: 8080
            initialDelaySeconds: 2
            periodSeconds: 5
          resources:
            limits:
              nvidia.com/gpu: "1"
              cpu: "200m"
              memory: 250Mi
EOF
    echo "  FMA objects created"
fi

# Create PodMonitor for FMA launcher pods
if kubectl get podmonitor fma-launcher-monitor -n "$NAMESPACE" &>/dev/null; then
    echo "  PodMonitor for FMA launchers already exists"
else
    echo "  Creating PodMonitor for FMA launcher pods..."


kubectl apply -f - <<EOF
apiVersion: monitoring.coreos.com/v1
kind: PodMonitor
metadata:
  name: fma-launcher-monitor
  namespace: ${NAMESPACE}
  labels:
    app: llm-inference
spec:
  selector:
    matchLabels:
      llm-d.ai/guide: "optimized-baseline"
  podMetricsEndpoints:
  - interval: 30s
    path: /metrics
    relabelings:
    # Only scrape the inference-server container (not state-change-reflector etc.)
    - action: keep
      regex: inference-server
      sourceLabels: [__meta_kubernetes_pod_container_name]
    # Force address to <pod-ip>:8000 — the launcher's vLLM /metrics port.
    - action: replace
      regex: (.+)
      replacement: \$1:8000
      sourceLabels: [__meta_kubernetes_pod_ip]
      targetLabel: __address__
    # Surface the variant label so WVA can correlate metrics to the VA.
    - action: replace
      sourceLabels: [__meta_kubernetes_pod_label_llm_d_ai_variant]
      targetLabel: llm_d_ai_variant
EOF
    echo "  PodMonitor created"
fi


# =========================================================================
# Step 6: WVA Objects (VariantAutoscaling, HPA)
# =========================================================================

step "WVA Objects (VariantAutoscaling, HPA)"

# Wait for FMA requester deployment to be created
echo "  Waiting for FMA requester to be ready..."
kubectl wait --for=condition=Available deployment/fma-requester -n "$NAMESPACE" --timeout=120s 2>/dev/null || \
    echo "  WARNING: FMA requester deployment not ready yet"

if kubectl get variantautoscaling wva-fma-va -n "$NAMESPACE" &>/dev/null; then
    echo "  WVA objects already exist"
else
    echo "  Creating WVA VariantAutoscaling..."
    kubectl apply -f - <<EOF
apiVersion: llmd.ai/v1alpha1
kind: VariantAutoscaling
metadata:
  labels:
    wva.llmd.ai/controller-instance: ${CONTROLLER_INSTANCE}
    inference.optimization/acceleratorName: nvidia-gpu
  name: wva-fma-va
  namespace: ${NAMESPACE}
spec:
  maxReplicas: 2
  minReplicas: 0
  modelID: ${MODEL}
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: fma-requester
  variantCost: "10.0"
EOF
    echo "  VariantAutoscaling created"
fi

if kubectl get hpa wva-fma-hpa -n "$NAMESPACE" &>/dev/null; then
    echo "  WVA HPA already exists"
else
    echo "  Creating WVA HorizontalPodAutoscaler..."
    kubectl apply -f - <<EOF
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: wva-fma-hpa
  namespace: ${NAMESPACE}
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: fma-requester
  maxReplicas: 6
  #minReplicas: 0  # Scale to zero is an alpha feature
  behavior:
    scaleUp:
      stabilizationWindowSeconds: 0  # Tune based on your needs
      policies:
      - type: Pods
        value: 10
        periodSeconds: 15
    scaleDown:
      stabilizationWindowSeconds: 0  # Tune based on your needs
      policies:
      - type: Pods
        value: 10
        periodSeconds: 15
  metrics:
  - type: External
    external:
      metric:
        name: wva_desired_replicas
        selector:
          matchLabels:
            variant_name: wva-fma-va
            exported_namespace: ${NAMESPACE}
            controller_instance: ${CONTROLLER_INSTANCE}
      target:
        type: AverageValue
        averageValue: "1"
EOF
    echo "  HPA created"
fi


# =========================================================================
# Step 7: Validation
# =========================================================================

step "Validation"

echo "  Waiting for requester and launcher pods..."
kubectl wait --for=condition=Ready pod \
    -l app=fma-requester -n "$NAMESPACE" --timeout=300s 2>/dev/null || true

echo ""
echo "  --- FMA Controllers ---"
kubectl get deployment -n "$NAMESPACE" -l app.kubernetes.io/part-of=fma 2>/dev/null || true

echo ""
echo "  --- WVA Controller ---"
kubectl get deployment -n "$NAMESPACE" -l control-plane=controller-manager 2>/dev/null || true

echo ""
echo "  --- FMA Pods ---"
kubectl get pods -n "$NAMESPACE" \
    -L dual-pods.llm-d.ai/dual,dual-pods.llm-d.ai/sleeping 2>/dev/null || true

echo ""
echo "  --- FMA CRDs ---"
kubectl get crd | grep fma.llm-d.ai 2>/dev/null || true

echo ""
echo "  --- FMA Custom Resources ---"
kubectl get inferenceserverconfig,launcherconfig,launcherpopulationpolicy -n "$NAMESPACE" 2>/dev/null || true

echo ""
echo "  --- WVA Custom Resources ---"
kubectl get variantautoscaling,hpa -n "$NAMESPACE" 2>/dev/null || true

echo ""
echo "  --- Monitoring Resources ---"
kubectl get podmonitor,servicemonitor -n "$NAMESPACE" 2>/dev/null || true

echo ""
echo "  --- llm-d EPP Resources ---"
kubectl get inferencepool,gateway,httproute -n "$NAMESPACE" 2>/dev/null || true

echo ""
echo "========================================"
echo "  Deployment Complete!"
echo "========================================"
echo ""
echo "  Namespace:           $NAMESPACE"
echo "  GPU Node:            $GPU_NODE"
echo "  Model:               $MODEL"
echo "  Controller Instance: $CONTROLLER_INSTANCE"
echo ""
echo "  Components installed:"
echo "    ✓ FMA CRDs and Controllers"
echo "    ✓ WVA Controller (${WVA_IMAGE_REPO}:${WVA_IMAGE_TAG})"
echo "    ✓ llm-d EPP (Gateway API + InferencePool)"
echo "    ✓ FMA objects (ISC, LauncherConfig, LPP, Deployment, PodMonitor)"
echo "    ✓ WVA objects (VariantAutoscaling, HPA)"
echo ""
echo "  Next steps:"
echo "    - Check WVA metrics: kubectl get --raw /apis/external.metrics.k8s.io/v1beta1"
echo "    - Check HPA status: kubectl get hpa wva-fma-hpa -n $NAMESPACE"
echo "    - Monitor pods: kubectl get pods -n $NAMESPACE -w"
echo "    - View WVA logs: kubectl logs -n $NAMESPACE -l control-plane=controller-manager"
echo "    - View FMA logs: kubectl logs -n $NAMESPACE -l app.kubernetes.io/part-of=fma"
echo ""