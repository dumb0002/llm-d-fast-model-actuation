# FMA + WVA Demo on OpenShift

Two scripts to deploy and tear down a full FMA + WVA + llm-d stack in a single
OpenShift namespace.

| Script | Purpose |
|---|---|
| `demo-fma-wva-ocp.sh` | Deploy FMA controllers, WVA, EPP/Gateway, and demo workload |
| `cleanup-fma-wva.sh` | Tear it all back down |

The workload-variant-autoscaler (WVA) repo is cloned automatically — no need
to pre-clone or pass `--wva-repo-path`.

Both scripts use a standard CLI flag interface. Run either with `--help`
for the full list of options.

## Versioning

FMA and WVA release independently, so incompatibilities are possible. The
defaults pin a known-good pair: FMA `--image-tag v0.6.0-alpha.12` + WVA
`--wva-repo-ref main`. If you change one, test the pair.

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
./test/e2e/demo-fma-wva/demo-fma-wva-ocp.sh --namespace my-fma-demo
```

The script is idempotent — re-running it skips components that already exist.
On first run it clones the WVA repo to `.wva-checkout/` at the repo root and
reuses it on subsequent runs. Pass `--wva-repo-path PATH` to use a different
location (e.g., a shared checkout outside this repo).

## Tear down

By default cleans up FMA / WVA objects but leaves the namespace, CRDs,
WVA controller, and EPP/Gateway in place:

```shell
./test/e2e/demo-fma-wva/cleanup-fma-wva.sh --namespace my-fma-demo
```

Full cleanup (also removes namespace, node labels, WVA controller, EPP):

```shell
./test/e2e/demo-fma-wva/cleanup-fma-wva.sh --namespace my-fma-demo --full-cleanup
```

CRDs (Gateway API, GAIE, FMA, WVA) are never removed — they may be shared
across namespaces. Delete them by hand if you want a complete wipe.

## Common flags

| Flag | Default | Used by |
|---|---|---|
| `-n`, `--namespace NAME` | `fma-wva-demo` | both |
| `-f`, `--full-cleanup` | (off) | cleanup |
| `--wva-repo-path PATH` | `<repo-root>/.wva-checkout` | both |
| `--wva-repo-url URL` | `https://github.com/llm-d/llm-d-workload-variant-autoscaler` | both |
| `--wva-repo-ref REF` | `main` | both |
| `--container-img-reg URL` | `ghcr.io/llm-d-incubation/llm-d-fast-model-actuation` | deploy |
| `--image-tag TAG` | `v0.6.0-alpha.12` | deploy |
| `--model NAME` | `HuggingFaceTB/SmolLM2-360M-Instruct` | deploy |
| `--gpu-node NODE` | first node with `nvidia.com/gpu.present=true` | deploy |
| `--hf-token TOKEN` | (unset) | deploy (if model is gated) |

Run `./demo-fma-wva-ocp.sh --help` or `./cleanup-fma-wva.sh --help` for the
complete list. Equivalent environment variables (uppercase, underscored —
e.g., `NAMESPACE`, `IMAGE_TAG`, `WVA_REPO_PATH`) are also accepted for
backward compatibility, but flags take precedence.

## Examples

Pin a specific WVA version:

```shell
./test/e2e/demo-fma-wva/demo-fma-wva-ocp.sh --wva-repo-ref v0.3.0
```

Use a WVA fork:

```shell
./test/e2e/demo-fma-wva/demo-fma-wva-ocp.sh \
  --wva-repo-url https://github.com/myorg/wva-fork \
  --wva-repo-ref feature-branch
```

Deploy a different model:

```shell
./test/e2e/demo-fma-wva/demo-fma-wva-ocp.sh \
  --model meta-llama/Llama-3.1-8B-Instruct \
  --hf-token hf_xxx
```

Use an existing WVA checkout instead of the auto-clone:

```shell
./test/e2e/demo-fma-wva/demo-fma-wva-ocp.sh \
  --wva-repo-path /path/to/my/wva-checkout
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

**Unknown flag error**
The scripts reject unknown flags. Check spelling and run with `--help` for
the canonical flag names.
