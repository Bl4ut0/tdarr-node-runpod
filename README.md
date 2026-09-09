# tdarr-node-runpod

Custom wrapper for `ghcr.io/haveagitgat/tdarr_node:2.85.01` specifically crafted for RunPod.

### Problem Solved
Official Tdarr Node images use `s6-overlay` as their entrypoint (`/init`). On container platforms like RunPod where the host/supervisor runs as PID 1 (or with container-level inits), s6-overlay fatally terminates with:
```
s6-overlay-suexec: fatal: can only run as pid 1
```

### Solution
This wrapper image overrides the entrypoint directly to `/entrypoint.sh`, bypassing `s6-overlay` and invoking `/app/Tdarr_Node/Tdarr_Node` with proper environment variables and dynamic node naming (`runpod-nvenc-<pod_id>`).