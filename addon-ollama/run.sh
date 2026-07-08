#!/usr/bin/env bash
# Ollama GPU-AI add-on entrypoint.
set -euo pipefail

echo "[ollama-addon] starting; probing GPU visibility inside container"

if command -v nvidia-smi >/dev/null 2>&1 && nvidia-smi -L >/dev/null 2>&1; then
	echo "[ollama-addon] NVIDIA GPU visible:"
	nvidia-smi -L || true
elif [ -e /dev/kfd ] && [ -d /dev/dri ]; then
	echo "[ollama-addon] AMD ROCm compute node (/dev/kfd) + render node visible"
elif [ -d /dev/dri ]; then
	echo "[ollama-addon] Intel/other DRI render node visible (/dev/dri)"
else
	echo "[ollama-addon] WARNING: no GPU device visible; falling back to CPU"
fi

# Persist models on the HA /share mapping (map: share:rw in config.yaml) so
# multi-GB model downloads survive add-on rebuilds and updates.
export OLLAMA_MODELS="${OLLAMA_MODELS:-/share/ollama}"
mkdir -p "$OLLAMA_MODELS"

export OLLAMA_HOST="${OLLAMA_HOST:-0.0.0.0}"
echo "[ollama-addon] launching: ollama serve on ${OLLAMA_HOST}:11434"
exec ollama serve
