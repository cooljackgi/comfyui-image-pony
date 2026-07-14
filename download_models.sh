#!/bin/bash
set -e

MODEL_PATH="/comfyui/models/checkpoints/CyberRealistic_Pony_-_v16-0.safetensors"
MODEL_URL="https://civitai.com/api/download/models/2581228"
MODEL_FILENAME="CyberRealistic_Pony_-_v16-0.safetensors"

if [ -f "$MODEL_PATH" ]; then
    echo "[download_models] Model already present — skipping download."
    exit 0
fi

TOKEN="${CIVITAI_API_TOKEN:-${CIVITAI_API_KEY:-}}"
if [ -z "$TOKEN" ]; then
    echo "[download_models] ERROR: CIVITAI_API_TOKEN environment variable is not set." >&2
    echo "[download_models] Add it in RunPod → Endpoint → Edit → Environment Variables." >&2
    exit 1
fi

echo "[download_models] Downloading CyberRealistic Pony v16 ..."
CIVITAI_API_TOKEN="$TOKEN" comfy model download \
    --url "$MODEL_URL" \
    --relative-path models/checkpoints \
    --filename "$MODEL_FILENAME"

echo "[download_models] Download complete."
