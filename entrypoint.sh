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

echo "--- Initial Devices ---"
ls -la /dev/nvidia* 2>&1 || echo "ls /dev/nvidia* failed"

# Align device nodes: ensure /dev/nvidia0 through /dev/nvidia7 exist
NV_DEVS=(/dev/nvidia[0-9]*)
if [ -e "${NV_DEVS[0]}" ]; then
  FIRST_DEV="${NV_DEVS[0]}"
  echo "Found GPU device node: ${FIRST_DEV}"
  for i in $(seq 0 7); do
    if [ ! -e "/dev/nvidia${i}" ]; then
      echo "Linking /dev/nvidia${i} -> ${FIRST_DEV}"
      ln -sf "${FIRST_DEV}" "/dev/nvidia${i}" 2>/dev/null || true
    fi
  done
fi

echo "--- Aligned Devices ---"
ls -la /dev/nvidia* 2>&1 || echo "ls /dev/nvidia* failed"

echo "--- Testing NVENC with tdarr-ffmpeg (default) ---"
tdarr-ffmpeg -hide_banner -f lavfi -i nullsrc=s=256x256:d=1 -c:v h264_nvenc -f null - 2>&1 || true

echo "--- Testing NVENC with tdarr-ffmpeg (-gpu 0) ---"
tdarr-ffmpeg -hide_banner -gpu 0 -f lavfi -i nullsrc=s=256x256:d=1 -c:v h264_nvenc -f null - 2>&1 || true

echo "--- Testing NVENC with tdarr-ffmpeg (-gpu 1) ---"
tdarr-ffmpeg -hide_banner -gpu 1 -f lavfi -i nullsrc=s=256x256:d=1 -c:v h264_nvenc -f null - 2>&1 || true
echo "---------------------------------------"

exec /app/Tdarr_Node/Tdarr_Node "$@"
