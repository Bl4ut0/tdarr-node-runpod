#!/bin/bash
set -e

if [ -z "${nodeName:-}" ] || [ "${nodeName}" = "runpod-nvenc-node" ]; then
  POD_SUFFIX="${RUNPOD_POD_ID:-${HOSTNAME}}"
  export nodeName="runpod-nvenc-${POD_SUFFIX}"
fi

echo "=================================================="
echo "Starting Tdarr Node for RunPod"
echo "Node Name:   ${nodeName}"
echo "Server URL:  ${serverURL:-Not set}"
echo "Node Type:   ${nodeType:-unmapped}"
echo "GPU Workers: ${transcodegpuWorkers:-1}"
echo "CPU Workers: ${transcodecpuWorkers:-0}"
echo "=================================================="

echo "--- NVIDIA Diagnostic ---"
nvidia-smi || echo "nvidia-smi failed or not found"
echo "--- Testing NVENC with tdarr-ffmpeg ---"
tdarr-ffmpeg -hide_banner -f lavfi -i nullsrc=s=256x256:d=1 -c:v h264_nvenc -f null - || true
echo "---------------------------------------"

exec /app/Tdarr_Node/Tdarr_Node "$@"

