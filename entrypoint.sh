#!/bin/bash
set -Eeuo pipefail

if [ -z "${nodeName:-}" ] || [ "${nodeName}" = "runpod-nvenc-node" ]; then
  POD_SUFFIX="${RUNPOD_POD_ID:-${HOSTNAME:-unknown}}"
  export nodeName="runpod-nvenc-${POD_SUFFIX}"
fi

echo "Starting Tdarr Node for RunPod: ${nodeName}"
echo "Server URL: ${serverURL:-Not set}"
echo "Node Type: ${nodeType:-unmapped}"
echo "GPU Workers: ${transcodegpuWorkers:-1}"
echo "CPU Workers: ${transcodecpuWorkers:-0}"

# RunPod may attach the GPU shortly after the container starts. Never register
# this node with Tdarr until both encoders can initialize a real GPU.
probe_attempts="${NVENC_PROBE_ATTEMPTS:-12}"
probe_interval="${NVENC_PROBE_INTERVAL_SECONDS:-5}"
if ! [[ "${probe_attempts}" =~ ^[1-9][0-9]*$ ]] ||
   ! [[ "${probe_interval}" =~ ^[0-9]+$ ]]; then
  echo "Invalid NVENC probe retry settings" >&2
  exit 2
fi

probe_log="$(mktemp)"
trap 'rm -f "${probe_log}"' EXIT
node_binary="${TDARR_NODE_BINARY:-/app/Tdarr_Node/Tdarr_Node}"
original_cuda_visible_devices="${CUDA_VISIBLE_DEVICES-}"
had_cuda_visible_devices="${CUDA_VISIBLE_DEVICES+x}"

probe_encoder() {
  local encoder="$1"
  tdarr-ffmpeg -hide_banner -loglevel error \
    -f lavfi -i nullsrc=s=256x256:d=1 -frames:v 1 \
    -c:v "${encoder}" -f null - >"${probe_log}" 2>&1
}

for ((attempt = 1; attempt <= probe_attempts; attempt++)); do
  echo "NVENC readiness check ${attempt}/${probe_attempts}"
  if command -v nvidia-smi >/dev/null 2>&1; then
    nvidia-smi -L || true
  fi

  # Keep the previous ordinal fallback for RunPod hosts with a non-zero CUDA
  # device index, but start Tdarr only after both encoders pass on that index.
  for candidate in inherited 0 1; do
    if [ "${candidate}" = inherited ]; then
      if [ -n "${had_cuda_visible_devices}" ]; then
        export CUDA_VISIBLE_DEVICES="${original_cuda_visible_devices}"
      else
        unset CUDA_VISIBLE_DEVICES
      fi
    else
      export CUDA_VISIBLE_DEVICES="${candidate}"
    fi

    echo "Testing CUDA_VISIBLE_DEVICES=${CUDA_VISIBLE_DEVICES:-<unset>}"
    if probe_encoder h264_nvenc && probe_encoder hevc_nvenc; then
      echo "H.264 and HEVC NVENC ready; registering Tdarr node"
      rm -f "${probe_log}"
      exec "${node_binary}" "$@"
    fi
  done

  if ((attempt < probe_attempts)); then
    sleep "${probe_interval}"
  fi
done

echo "NVENC unavailable after ${probe_attempts} checks; Tdarr node was not started" >&2
cat "${probe_log}" >&2
exit 1
