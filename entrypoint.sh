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
      ln -sf "${FIRST_DEV}" "/dev/nvidia${i}" 2>/dev/null || true
    fi
  done
fi

echo "--- Aligned Devices ---"
ls -la /dev/nvidia* 2>&1 || echo "ls /dev/nvidia* failed"

# Test NVENC across combinations of CUDA_VISIBLE_DEVICES
WORKING_CUDA_DEV=""
for dev in "" "0" "1"; do
  echo "--- Testing hevc_nvenc with CUDA_VISIBLE_DEVICES='${dev}' ---"
  if [ -z "$dev" ]; then
    unset CUDA_VISIBLE_DEVICES
  else
    export CUDA_VISIBLE_DEVICES="$dev"
  fi
  if tdarr-ffmpeg -hide_banner -f lavfi -i nullsrc=s=256x256:d=1 -c:v hevc_nvenc -f null - 2>&1; then
    echo "SUCCESS with CUDA_VISIBLE_DEVICES='${dev}'!"
    WORKING_CUDA_DEV="$dev"
    break
  else
    echo "Failed with CUDA_VISIBLE_DEVICES='${dev}'"
  fi
done

if [ -n "$WORKING_CUDA_DEV" ]; then
  echo "Setting persistent CUDA_VISIBLE_DEVICES=${WORKING_CUDA_DEV}"
  export CUDA_VISIBLE_DEVICES="${WORKING_CUDA_DEV}"
else
  echo "Testing h264_nvenc default..."
  tdarr-ffmpeg -hide_banner -f lavfi -i nullsrc=s=256x256:d=1 -c:v h264_nvenc -f null - 2>&1 || true
fi
echo "---------------------------------------"

exec /app/Tdarr_Node/Tdarr_Node "$@"
