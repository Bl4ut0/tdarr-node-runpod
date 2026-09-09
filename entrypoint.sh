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

echo "--- Devices Diagnostic ---"
ls -la /dev/nvidia* 2>&1 || echo "ls /dev/nvidia* failed"
grep -i nvidia /proc/devices 2>&1 || echo "no nvidia in /proc/devices"

echo "--- Checking /dev/nvidia-uvm ---"
if [ ! -e /dev/nvidia-uvm ]; then
  echo "/dev/nvidia-uvm is missing! Attempting creation..."
  UVM_MAJOR=$(grep nvidia-uvm /proc/devices | awk '{print $1}')
  if [ -n "$UVM_MAJOR" ]; then
    echo "Found nvidia-uvm major $UVM_MAJOR, running mknod..."
    mknod -m 666 /dev/nvidia-uvm c $UVM_MAJOR 0 2>&1 || echo "mknod /dev/nvidia-uvm failed"
    mknod -m 666 /dev/nvidia-uvm-tools c $UVM_MAJOR 1 2>&1 || echo "mknod /dev/nvidia-uvm-tools failed"
  else
    echo "nvidia-uvm not found in /proc/devices, trying nvidia-modprobe..."
    nvidia-modprobe -c 0 -u 2>&1 || echo "nvidia-modprobe failed"
  fi
else
  echo "/dev/nvidia-uvm already exists."
fi

echo "--- NVIDIA Libraries ---"
ldconfig -p | grep -E "libcuda|libnvidia" || echo "no nvidia libs in ldconfig"

echo "--- Testing NVENC with tdarr-ffmpeg ---"
tdarr-ffmpeg -hide_banner -f lavfi -i nullsrc=s=256x256:d=1 -c:v h264_nvenc -f null - 2>&1 || true
echo "---------------------------------------"

exec /app/Tdarr_Node/Tdarr_Node "$@"
