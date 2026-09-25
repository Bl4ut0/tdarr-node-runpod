# tdarr-node-runpod

Custom wrapper for `ghcr.io/haveagitgat/tdarr_node:2.85.01` specifically crafted for RunPod.

### Problem Solved
Official Tdarr Node images use `s6-overlay` as their entrypoint (`/init`). On container platforms like RunPod where the host/supervisor runs as PID 1 (or with container-level inits), s6-overlay fatally terminates with:
```
s6-overlay-suexec: fatal: can only run as pid 1
```

### Solution
This wrapper image overrides the entrypoint directly to `/entrypoint.sh`, bypassing `s6-overlay` and invoking `/app/Tdarr_Node/Tdarr_Node` with proper environment variables and dynamic node naming (`runpod-nvenc-<pod_id>`).

Before registering with Tdarr, the entrypoint runs one-frame H.264 and HEVC NVENC probes. It retries for up to one minute to allow RunPod to attach the GPU. Each check tries the inherited CUDA setting and every GPU index and UUID reported by `nvidia-smi`. It also scans every numbered `/dev/nvidiaN` node and reads the driver's GPU metadata to map each exposed device minor to its GPU UUID. Device minor numbers are not CUDA ordinals: for example, `/dev/nvidia4` can correspond to CUDA GPU 0, so the script never passes `4` to `CUDA_VISIBLE_DEVICES` just because that node exists.

Some NVIDIA 570/580 container combinations return the host-wide attached-GPU list to NVENC, even when only one GPU is mounted in the container. `nvenc-device-filter.c` interposes only the NVIDIA RM `GET_ATTACHED_IDS` ioctl and filters the returned IDs by matching PCI domain/bus metadata with mounted `/dev/nvidiaN` device nodes. It does not invent device nodes or expose devices that RunPod did not mount. If the metadata does not resolve a GPU, the filter leaves the response unchanged and the H.264/HEVC startup gate still prevents an unusable GPU-only worker from registering. If neither encoder can initialize on any candidate, the entrypoint exits with an error. The retry count and interval can be set with `NVENC_PROBE_ATTEMPTS` and `NVENC_PROBE_INTERVAL_SECONDS`.

Run `bash tests/entrypoint-test.sh` to exercise the fail-closed startup behavior with mocked encoders and the device-list filter using nonzero device minors. Pull requests run these tests and build the image without publishing it; pushes to `main` publish the image tags used by the RunPod template.
