# tdarr-node-runpod

Custom wrapper for `ghcr.io/haveagitgat/tdarr_node:2.85.01` specifically crafted for RunPod.

### Problem Solved
Official Tdarr Node images use `s6-overlay` as their entrypoint (`/init`). On container platforms like RunPod where the host/supervisor runs as PID 1 (or with container-level inits), s6-overlay fatally terminates with:
```
s6-overlay-suexec: fatal: can only run as pid 1
```

### Solution
This wrapper image overrides the entrypoint directly to `/entrypoint.sh`, bypassing `s6-overlay` and invoking `/app/Tdarr_Node/Tdarr_Node` with proper environment variables and dynamic node naming (`runpod-nvenc-<pod_id>`).

Before registering with Tdarr, the entrypoint runs one-frame H.264 and HEVC NVENC probes. It retries for up to one minute to allow RunPod to attach the GPU. Each check tries the inherited CUDA setting, every GPU index and UUID reported by `nvidia-smi`, and every numbered `/dev/nvidiaN` device node exposed to the container. This handles GPU device nodes whose slot suffix is non-zero and GPUs addressed by UUID. If neither encoder can initialize on any candidate, it exits with an error instead of starting a GPU-only worker without a usable GPU. The retry count and interval can be set with `NVENC_PROBE_ATTEMPTS` and `NVENC_PROBE_INTERVAL_SECONDS`.

Run `bash tests/entrypoint-test.sh` to exercise the fail-closed startup behavior with mocked encoders. Pull requests run this test and build the image without publishing it; pushes to `main` publish the image tags used by the RunPod template.
