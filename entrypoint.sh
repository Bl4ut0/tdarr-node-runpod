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

nvidia_device_dir="${NVIDIA_DEVICE_DIR:-/dev}"
nvidia_gpu_info_dir="${NVIDIA_GPU_INFO_DIR:-/proc/driver/nvidia/gpus}"
declare -a cuda_candidates=()

add_cuda_candidate() {
  local candidate="$1"
  local existing
  [ -n "${candidate}" ] || return 0
  for existing in "${cuda_candidates[@]:-}"; do
    [ "${existing}" = "${candidate}" ] && return 0
  done
  cuda_candidates+=("${candidate}")
}

# Try the configured visibility first, then discover every NVIDIA GPU index
# and UUID reported by the driver. The proc metadata scan below also finds
# exposed GPUs mounted at nonzero device minors such as /dev/nvidia4.
if [ -n "${had_cuda_visible_devices}" ]; then
  add_cuda_candidate "${original_cuda_visible_devices}"
else
  add_cuda_candidate inherited
fi

if command -v nvidia-smi >/dev/null 2>&1; then
  while IFS= read -r candidate; do
    candidate="${candidate//[[:space:]]/}"
    add_cuda_candidate "${candidate}"
  done < <(nvidia-smi --query-gpu=index --format=csv,noheader,nounits 2>/dev/null || true)

  while IFS= read -r candidate; do
    candidate="${candidate//[[:space:]]/}"
    add_cuda_candidate "${candidate}"
  done < <(nvidia-smi --query-gpu=uuid --format=csv,noheader 2>/dev/null || true)
fi

# /dev/nvidiaN uses the driver's device minor, which may differ from CUDA's
# visible ordinal. Match every proc GPU entry to its mounted device node and
# probe the UUID; never use the device minor as a CUDA ordinal.
for info_path in "${nvidia_gpu_info_dir}"/*/information; do
  [ -r "${info_path}" ] || continue
  device_minor="$(awk -F: '/^[[:space:]]*Device Minor:/ { gsub(/[[:space:]]/, "", $2); print $2; exit }' "${info_path}")"
  gpu_uuid="$(awk -F: '/^[[:space:]]*GPU UUID:/ { sub(/^[[:space:]]*/, "", $2); print $2; exit }' "${info_path}")"
  [ -n "${device_minor}" ] || continue
  [ -e "${nvidia_device_dir}/nvidia${device_minor}" ] || continue
  add_cuda_candidate "${gpu_uuid}"
  echo "Mapped exposed /dev/nvidia${device_minor} to ${gpu_uuid:-an NVIDIA GPU UUID unavailable}"
done

if [ "${#cuda_candidates[@]}" -eq 0 ]; then
  add_cuda_candidate inherited
fi

# On affected NVIDIA drivers, NVENC sees the host-wide attached-GPU list even
# inside a single-GPU container. This narrowly scoped ioctl interposer filters
# that list using PCI bus metadata and the /dev/nvidiaN nodes mounted here.
nvenc_filter_library="${NVENC_DEVICE_FILTER_LIBRARY:-/usr/local/lib/nvenc-device-filter.so}"
export NVENC_FIX_DEVICE_DIR="${nvidia_device_dir}"
export NVENC_FIX_GPU_INFO_DIR="${nvidia_gpu_info_dir}"
if [ -r "${nvenc_filter_library}" ]; then
  if [ -n "${LD_PRELOAD:-}" ]; then
    export LD_PRELOAD="${nvenc_filter_library}:${LD_PRELOAD}"
  else
    export LD_PRELOAD="${nvenc_filter_library}"
  fi
  echo "Loaded container GPU enumeration filter: ${nvenc_filter_library}"
else
  echo "Container GPU enumeration filter missing at ${nvenc_filter_library}; NVENC readiness checks remain fail-closed" >&2
fi

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

  # CUDA accepts both visible ordinals and GPU UUIDs. Probe all values found
  # above so GPU numbering and /dev/nvidiaN suffixes do not have to start at 0.
  for candidate in "${cuda_candidates[@]}"; do
    if [ "${candidate}" = inherited ]; then
      if [ -n "${had_cuda_visible_devices}" ]; then
        export CUDA_VISIBLE_DEVICES="${original_cuda_visible_devices}"
      else
        unset CUDA_VISIBLE_DEVICES
      fi
    else
      export CUDA_VISIBLE_DEVICES="${candidate}"
    fi

    echo "Testing CUDA_VISIBLE_DEVICES=${CUDA_VISIBLE_DEVICES:-<unset>} (candidate=${candidate})"
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
