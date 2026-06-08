# FMA + WVA Demo on OpenShift

Two scripts to deploy and tear down a full FMA + WVA + llm-d stack in a single
OpenShift namespace.

| Script | Purpose |
|---|---|
| `demo-fma-wva-ocp.sh` | Deploy FMA controllers, WVA, EPP/Gateway, and demo workload |
| `cleanup-fma-wva.sh` | Tear it all back down |

The workload-variant-autoscaler (WVA) repo is cloned automatically — no need
to pre-clone or set `WVA_REPO_PATH`.

## Prerequisites

- `oc` authenticated to an OpenShift cluster with GPU nodes
- `helm`, `kubectl`, `make`, `git`, `jq`, `yq` ([mikefarah/yq](https://github.com/mikefarah/yq)) on `$PATH`

## Deploy

Default deploy (uses namespace `fma-wva-demo`):

```shell
./test/e2e/demo-fma-wva/demo-fma-wva-ocp.sh
```

Pick your own namespace:

```shell
NAMESPACE=my-fma-demo ./test/e2e/demo-fma-wva/demo-fma-wva-ocp.sh
```

The script is idempotent — re-running it skips components that already exist.
On first run it clones the WVA repo to
`~/.cache/llm-d-fma/workload-variant-autoscaler` and reuses it on subsequent
runs.

## Tear down

By default cleans up FMA / WVA objects but leaves the namespace, CRDs,
WVA controller, and EPP/Gateway in place:

```shell
NAMESPACE=my-fma-demo ./test/e2e/demo-fma-wva/cleanup-fma-wva.sh
```

Full cleanup (also removes namespace, node labels, WVA controller, EPP):

```shell
FULL_CLEANUP=true NAMESPACE=my-fma-demo \
  ./test/e2e/demo-fma-wva/cleanup-fma-wva.sh
```

CRDs (Gateway API, GAIE, FMA, WVA) are never removed — they may be shared
across namespaces. Delete them by hand if you want a complete wipe.

## Common environment variables

| Variable | Default | Used by |
|---|---|---|
| `NAMESPACE` | `fma-wva-demo` | both |
| `FULL_CLEANUP` | `false` | cleanup |
| `WVA_REPO_PATH` | `~/.cache/llm-d-fma/workload-variant-autoscaler` | both |
| `WVA_REPO_URL` | `https://github.com/llm-d/llm-d-workload-variant-autoscaler` | both |
| `WVA_REPO_REF` | `main` | both |
| `CONTAINER_IMG_REG` | `ghcr.io/llm-d-incubation/llm-d-fast-model-actuation` | deploy |
| `IMAGE_TAG` | `v0.6.0-alpha.12` | deploy |
| `MODEL` | `HuggingFaceTB/SmolLM2-360M-Instruct` | deploy |
| `GPU_NODE` | first node with `nvidia.com/gpu.present=true` | deploy |
| `HF_TOKEN` | (unset) | deploy (if model is gated) |

See the script headers for the complete list.

## Examples

Pin a specific WVA version:

```shell
WVA_REPO_REF=v0.3.0 ./test/e2e/demo-fma-wva/demo-fma-wva-ocp.sh
```

Use a WVA fork:

```shell
WVA_REPO_URL=https://github.com/myorg/wva-fork \
WVA_REPO_REF=feature-branch \
  ./test/e2e/demo-fma-wva/demo-fma-wva-ocp.sh
```

Deploy a different model:

```shell
MODEL=meta-llama/Llama-3.1-8B-Instruct \
HF_TOKEN=hf_xxx \
  ./test/e2e/demo-fma-wva/demo-fma-wva-ocp.sh
```

Use an existing WVA checkout instead of the auto-clone:

```shell
WVA_REPO_PATH=/path/to/my/wva-checkout \
  ./test/e2e/demo-fma-wva/demo-fma-wva-ocp.sh
```

## Troubleshooting

**`VariantAutoscaling` shows `METRICSREADY=False`**
WVA needs traffic to compute saturation. With zero requests, all `vllm:*`
saturation metrics stay at 0 and WVA correctly reports "no signal." Send
some inference requests through the gateway and wait one reconcile cycle
(~30s).

**Launcher pod missing the `llm-d.ai/variant` label**
The `llm-d.ai/variant` label is applied from
`InferenceServerConfig.spec.modelServerConfig.labels` when a requester binds
to a launcher. Unbound (idle) launchers won't carry it. Check the ISC, and
verify the launcher is bound (has the `dual-pods.llm-d.ai/dual` label set).
Don't add the label to `LauncherConfig.spec.podTemplate.metadata.labels` —
it will collide with ISC-applied labels during binding.

**Cleanup says "WVA_REPO_PATH directory does not exist" with a weird path**
You probably typed `WVA_REPO_PATH=` twice on the command line. Set it once,
or unset it and let the script auto-clone.
