#!/bin/bash
set -euo pipefail

MODEL_FILENAME="CyberRealistic_Pony_-_v16-0.safetensors"
RUNTIME_MODEL_DIR="/comfyui/models/checkpoints"
RUNTIME_MODEL_PATH="${RUNTIME_MODEL_DIR}/${MODEL_FILENAME}"

# RunPod Serverless network volumes are mounted at /runpod-volume.
PERSISTENT_MODEL_DIR="/runpod-volume/models/checkpoints"
MODEL_DIR="$RUNTIME_MODEL_DIR"
if [ -d "/runpod-volume" ]; then
    mkdir -p "$PERSISTENT_MODEL_DIR" || true
    if [ -w "$PERSISTENT_MODEL_DIR" ]; then
        MODEL_DIR="$PERSISTENT_MODEL_DIR"
    fi
fi
MODEL_PATH="${MODEL_DIR}/${MODEL_FILENAME}"

MODEL_URL="https://civitai.com/api/download/models/2581228"

# Rough sanity checks for an SDXL checkpoint file.
MIN_MODEL_BYTES=6000000000
REQUIRED_FREE_MB=9000

log() {
    echo "[download_models] $*"
}

cleanup_partial_files() {
    rm -f "${MODEL_PATH}.part" "${MODEL_PATH}.tmp" "${MODEL_PATH}.incomplete"
    rm -f "${RUNTIME_MODEL_PATH}.part" "${RUNTIME_MODEL_PATH}.tmp" "${RUNTIME_MODEL_PATH}.incomplete"
}

validate_model_file() {
    local candidate="$1"
    if [ ! -f "$candidate" ]; then
        return 1
    fi

    local size
    size=$(stat -c%s "$candidate" 2>/dev/null || echo 0)
    if [ "$size" -lt "$MIN_MODEL_BYTES" ]; then
        log "Model file exists but is too small (${size} bytes): ${candidate}. Removing corrupted file."
        rm -f "$candidate"
        return 1
    fi

    return 0
}

ensure_runtime_link() {
    mkdir -p "$RUNTIME_MODEL_DIR"

    if [ "$MODEL_PATH" = "$RUNTIME_MODEL_PATH" ]; then
        return 0
    fi

    rm -f "$RUNTIME_MODEL_PATH"
    ln -s "$MODEL_PATH" "$RUNTIME_MODEL_PATH"
}

ensure_free_disk_space() {
    local available_mb
    available_mb=$(df -Pm "$MODEL_DIR" | awk 'NR==2 {print $4}')
    if [ -z "$available_mb" ]; then
        log "WARNING: Could not read free disk space for ${MODEL_DIR}. Continuing."
        return 0
    fi

    if [ "$available_mb" -lt "$REQUIRED_FREE_MB" ]; then
        log "ERROR: Not enough disk space for model download in ${MODEL_DIR}."
        log "ERROR: Available ${available_mb} MB, required at least ${REQUIRED_FREE_MB} MB."
        log "ERROR: Increase endpoint container/network volume size in RunPod settings."
        exit 1
    fi
}

download_from_s3() {
    local bucket="${S3_BUCKET:-}"
    local key="${S3_KEY:-models/checkpoints/${MODEL_FILENAME}}"
    local endpoint="${S3_ENDPOINT_URL:-}"
    local region="${AWS_DEFAULT_REGION:-us-ca-2}"
    local access_key="${AWS_ACCESS_KEY_ID:-}"
    local secret_key="${AWS_SECRET_ACCESS_KEY:-}"
    local session_token="${AWS_SESSION_TOKEN:-}"

    if [ -z "$bucket" ]; then
        return 1
    fi

    if [ -z "$access_key" ] || [ -z "$secret_key" ]; then
        log "S3_BUCKET is set, but AWS_ACCESS_KEY_ID/AWS_SECRET_ACCESS_KEY are missing."
        return 1
    fi

    log "Trying S3 download first: s3://${bucket}/${key} -> ${MODEL_PATH}"

    if ! python3 -c "import boto3" >/dev/null 2>&1; then
        log "Installing boto3 for S3 download support..."
        python3 -m pip install --no-cache-dir boto3 >/dev/null
    fi

    python3 - "$bucket" "$key" "$MODEL_PATH" "$endpoint" "$region" "$access_key" "$secret_key" "$session_token" <<'PY'
import sys
import boto3

bucket, key, target, endpoint, region, access_key, secret_key, session_token = sys.argv[1:9]

kwargs = {
    "region_name": region or None,
    "endpoint_url": endpoint or None,
    "aws_access_key_id": access_key or None,
    "aws_secret_access_key": secret_key or None,
}
if session_token:
    kwargs["aws_session_token"] = session_token

kwargs = {k: v for k, v in kwargs.items() if v is not None}

s3 = boto3.client("s3", **kwargs)
s3.head_object(Bucket=bucket, Key=key)
s3.download_file(bucket, key, target)
PY

    return 0
}

download_from_civitai() {
    local token="$1"
    local target="$2"

    python3 - "$MODEL_URL" "$token" "$target" <<'PY'
import os
import sys
import requests

url, token, target = sys.argv[1:4]
part = f"{target}.part"
headers = {"Authorization": f"Bearer {token}"}

with requests.get(url, headers=headers, stream=True, allow_redirects=True, timeout=180) as r:
    r.raise_for_status()
    content_type = (r.headers.get("content-type") or "").lower()
    if "text/html" in content_type:
        raise RuntimeError("Civitai returned HTML instead of a model file (auth/permission issue).")

    with open(part, "wb") as f:
        for chunk in r.iter_content(chunk_size=1024 * 1024):
            if chunk:
                f.write(chunk)

os.replace(part, target)
PY
}

mkdir -p "$MODEL_DIR" "$RUNTIME_MODEL_DIR"

if validate_model_file "$MODEL_PATH"; then
    log "Model already present and valid: ${MODEL_PATH}"
    ensure_runtime_link
    exit 0
fi

# Backward compatibility: if model exists only in runtime dir, migrate it to
# persistent volume when available.
if [ "$MODEL_PATH" != "$RUNTIME_MODEL_PATH" ] && validate_model_file "$RUNTIME_MODEL_PATH"; then
    log "Found valid model in runtime dir. Moving to persistent volume."
    mv -f "$RUNTIME_MODEL_PATH" "$MODEL_PATH"
    ensure_runtime_link
    exit 0
fi

cleanup_partial_files
ensure_free_disk_space

if download_from_s3; then
    if validate_model_file "$MODEL_PATH"; then
        ensure_runtime_link
        log "Model downloaded successfully from S3."
        exit 0
    fi
    log "S3 download completed but model validation failed. Falling back to Civitai."
fi

TOKEN="${CIVITAI_API_TOKEN:-${CIVITAI_API_KEY:-}}"
if [ -z "$TOKEN" ]; then
    log "ERROR: CIVITAI_API_TOKEN environment variable is not set."
    log "ERROR: Add it in RunPod -> Endpoint -> Edit -> Environment Variables."
    exit 1
fi

log "Downloading model from Civitai fallback directly to ${MODEL_PATH} ..."
download_from_civitai "$TOKEN" "$MODEL_PATH"

if ! validate_model_file "$MODEL_PATH"; then
    log "ERROR: Civitai download finished but file validation failed."
    exit 1
fi

ensure_runtime_link
log "Download complete."
