#!/usr/bin/env bash
set -Eeuo pipefail

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${repo_dir}"
test_dir="$(mktemp -d ./tests/.tmp.XXXXXX)"
case "${test_dir}" in
  ./tests/.tmp.*) ;;
  *) echo "Unexpected test directory: ${test_dir}" >&2; exit 1 ;;
esac
trap 'rm -rf "${test_dir}"' EXIT
mkdir -p "${test_dir}/bin" "${test_dir}/dev" \
  "${test_dir}/gpu-info/GPU-MOCK" "${test_dir}/gpu-info/GPU-MOCK-67"
touch "${test_dir}/dev/nvidia4" "${test_dir}/dev/nvidia67"
cat > "${test_dir}/gpu-info/GPU-MOCK/information" <<'MOCK_GPU_INFO'
GPU UUID: GPU-TEST-UUID
Device Minor: 4
MOCK_GPU_INFO
cat > "${test_dir}/gpu-info/GPU-MOCK-67/information" <<'MOCK_GPU_INFO_67'
GPU UUID: GPU-TEST-UUID-67
Device Minor: 67
MOCK_GPU_INFO_67

cat > "${test_dir}/bin/nvidia-smi" <<'MOCK_NVIDIA_SMI'
#!/usr/bin/env bash
case "$*" in
  *--query-gpu=index,uuid*) printf '0, GPU-TEST-UUID\n' ;;
  *--query-gpu=index*)
    printf '%s\n' "${MOCK_GPU_INDEXES:-0}"
    ;;
  *--query-gpu=uuid*)
    printf '%s\n' "${MOCK_GPU_UUIDS:-GPU-TEST-UUID}"
    ;;
  -L) printf 'GPU 0: Mock GPU (UUID: GPU-TEST-UUID)\n' ;;
  *) exit 1 ;;
esac
MOCK_NVIDIA_SMI

cat > "${test_dir}/bin/tdarr-ffmpeg" <<'MOCK_FFMPEG'
#!/usr/bin/env bash
printf '%s|%s\n' "${CUDA_VISIBLE_DEVICES:-<unset>}" "$*" >> "${MOCK_TRACE}"
case "${MOCK_MODE}" in
  no_gpu) exit 1 ;;
  no_hevc)
    [[ " $* " != *hevc_nvenc* ]]
    ;;
  slot_4)
    [[ "${CUDA_VISIBLE_DEVICES:-}" = 0 && -e "${MOCK_DEVICE_DIR}/nvidia4" ]]
    ;;
  slot_67)
    [[ "${CUDA_VISIBLE_DEVICES:-}" = GPU-TEST-UUID-67 && -e "${MOCK_DEVICE_DIR}/nvidia67" ]]
    ;;
  uuid)
    [[ "${CUDA_VISIBLE_DEVICES:-}" = GPU-TEST-UUID ]]
    ;;
esac
MOCK_FFMPEG

cat > "${test_dir}/bin/Tdarr_Node" <<'MOCK_NODE'
#!/usr/bin/env bash
printf '%s\n' "${CUDA_VISIBLE_DEVICES:-<unset>}" > "${MOCK_NODE_MARKER}"
MOCK_NODE
chmod +x "${test_dir}/bin/nvidia-smi" "${test_dir}/bin/tdarr-ffmpeg" "${test_dir}/bin/Tdarr_Node"

run_case() {
  local mode="$1"
  local expected_exit="$2"
  local expected_device="$3"
  rm -f "${test_dir}/node-started" "${test_dir}/trace"
  local exit_code=0
  MOCK_MODE="${mode}" \
    MOCK_TRACE="${test_dir}/trace" \
    MOCK_NODE_MARKER="${test_dir}/node-started" \
    MOCK_DEVICE_DIR="${test_dir}/dev" \
    NVENC_PROBE_ATTEMPTS=1 \
    NVENC_PROBE_INTERVAL_SECONDS=0 \
    NVIDIA_DEVICE_DIR="${test_dir}/dev" \
    NVIDIA_GPU_INFO_DIR="${test_dir}/gpu-info" \
    TDARR_NODE_BINARY="${test_dir}/bin/Tdarr_Node" \
    PATH="${test_dir}/bin:${PATH}" \
    "${bash_bin}" "${repo_dir}/entrypoint.sh" > "${test_dir}/output" 2>&1 || exit_code=$?

  if [[ "${exit_code}" -ne "${expected_exit}" ]]; then
    cat "${test_dir}/output" >&2
    [ ! -f "${test_dir}/trace" ] || cat "${test_dir}/trace" >&2
    echo "${mode}: expected exit ${expected_exit}, got ${exit_code}" >&2
    exit 1
  fi
  if [[ "${expected_device}" = none ]]; then
    [[ ! -e "${test_dir}/node-started" ]] || {
      echo "${mode}: Tdarr node started without NVENC" >&2
      exit 1
    }
  else
    [[ "$(cat "${test_dir}/node-started")" = "${expected_device}" ]] || {
      echo "${mode}: Tdarr node used the wrong CUDA device" >&2
      exit 1
    }
    if [[ "${mode}" = slot_4 ]]; then
      if grep -q '^4|' "${test_dir}/trace"; then
        echo "${mode}: device minor 4 was incorrectly used as a CUDA ordinal" >&2
        exit 1
      fi
    fi
  fi
  echo "PASS ${mode}"
}

bash_bin="${BASH:-bash}"
run_case no_gpu 1 none
run_case no_hevc 1 none
run_case uuid 0 GPU-TEST-UUID
run_case slot_4 0 0
run_case slot_67 0 GPU-TEST-UUID-67

if command -v "${CC:-cc}" >/dev/null 2>&1; then
  "${CC:-cc}" -std=c11 -Wall -Wextra -DNVENC_FIX_TEST \
    "${repo_dir}/nvenc-device-filter.c" -o "${test_dir}/nvenc-filter-test"
  "${test_dir}/nvenc-filter-test"
else
  echo "SKIP NVENC device filter unit test (no C compiler available)"
fi
