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
mkdir -p "${test_dir}/bin" "${test_dir}/dev"
touch "${test_dir}/dev/nvidia4"

cat > "${test_dir}/bin/nvidia-smi" <<'MOCK_NVIDIA_SMI'
#!/usr/bin/env bash
case "$*" in
  *--query-gpu=index*) printf '%s\n' "${MOCK_GPU_INDEXES:-0}" ;;
  *--query-gpu=uuid*) printf '%s\n' "${MOCK_GPU_UUIDS:-GPU-TEST-UUID}" ;;
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
    [[ "${CUDA_VISIBLE_DEVICES:-}" = 4 ]]
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
    NVENC_PROBE_ATTEMPTS=1 \
    NVENC_PROBE_INTERVAL_SECONDS=0 \
    NVIDIA_DEVICE_DIR="${test_dir}/dev" \
    TDARR_NODE_BINARY="${test_dir}/bin/Tdarr_Node" \
    PATH="${test_dir}/bin:${PATH}" \
    bash "${repo_dir}/entrypoint.sh" > "${test_dir}/output" 2>&1 || exit_code=$?

  if [[ "${exit_code}" -ne "${expected_exit}" ]]; then
    cat "${test_dir}/output" >&2
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
  fi
  echo "PASS ${mode}"
}

run_case no_gpu 1 none
run_case no_hevc 1 none
run_case uuid 0 GPU-TEST-UUID
run_case slot_4 0 4
