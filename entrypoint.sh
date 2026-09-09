#!/usr/bin/env bash
set -Eeuo pipefail

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

# Optional quick connectivity sanity check
if [ -n "${serverURL:-}" ] && [ -n "${apiKey:-}" ]; then
  echo "Validating connection to Tdarr server..."
  if curl -fsS --connect-timeout 5 --max-time 10 \
    -H "x-api-key: ${apiKey}" \
    -H "Content-Type: application/json" \
    --data '{"data":{"collection":"SettingsGlobalJSONDB","mode":"getById","docID":"globalsettings"}}' \
    "${serverURL}/api/v2/cruddb" > /dev/null 2>&1; then
    echo "✓ Tdarr server reachable & API key authorized."
  else
    echo "⚠ Warning: Could not reach Tdarr server at ${serverURL}, continuing startup..."
  fi
fi

echo "Executing /app/Tdarr_Node/Tdarr_Node..."
exec /app/Tdarr_Node/Tdarr_Node "$@"