#!/bin/bash
set -euo pipefail

MODEL_DIR="/comfyui/models/checkpoints"
MODEL_FILENAME="CyberRealistic_Pony_-_v16-0.safetensors"
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
}

validate_model_file() {
    if [ ! -f "$MODEL_PATH" ]; then
        return 1
    fi

    local size
    size=$(stat -c%s "$MODEL_PATH" 2>/dev/null || echo 0)
    if [ "$size" -lt "$MIN_MODEL_BYTES" ]; then
        log "Model file exists but is too small (${size} bytes). Removing corrupted file."
        rm -f "$MODEL_PATH"
        return 1
    fi

    return 0
}

ensure_free_disk_space() {
    local available_mb
    available_mb=$(df -Pm "$MODEL_DIR" | awk 'NR==2 {print $4}')
    if [ -z "$available_mb" ]; then
        log "WARNING: Could not read free disk space. Continuing."
        return 0
    fi

    if [ "$available_mb" -lt "$REQUIRED_FREE_MB" ]; then
        log "ERROR: Not enough disk space for model download."
        log "ERROR: Available ${available_mb} MB, required at least ${REQUIRED_FREE_MB} MB."
        log "ERROR: Increase endpoint container disk size in RunPod Serverless settings."
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

    log "Trying S3 download first: s3://${bucket}/${key}"

    if ! python3 -c "import boto3" >/dev/null 2>&1; then
        log "Installing boto3 for S3 download support..."
        python3 -m pip install --no-cache-dir boto3 >/dev/null
    fi

    python3 - "$bucket" "$key" "$MODEL_PATH" "$endpoint" "$region" "$access_key" "$secret_key" "$session_token" <<'PY'
import sys
import boto3
from botocore.exceptions import ClientError

bucket, key, target, endpoint, region, access_key, secret_key, session_token = sys.argv[1:9]

kwargs = {
    "region_name": region or None,
    "endpoint_url": endpoint or None,
    "aws_access_key_id": access_key or None,
    "aws_secret_access_key": secret_key or None,
}
if session_token:
    kwargs["aws_session_token"] = session_token

# Remove Nones so boto3 can use sensible defaults if needed.
kwargs = {k: v for k, v in kwargs.items() if v is not None}

s3 = boto3.client("s3", **kwargs)

# Fail early if the object is missing or inaccessible.
s3.head_object(Bucket=bucket, Key=key)
s3.download_file(bucket, key, target)
PY

    return 0
}

mkdir -p "$MODEL_DIR"

if validate_model_file; then
    log "Model already present and valid. Skipping download."
    exit 0
fi

cleanup_partial_files
ensure_free_disk_space

if download_from_s3; then
    if validate_model_file; then
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

log "Downloading model from Civitai fallback..."
CIVITAI_API_TOKEN="$TOKEN" comfy model download \
    --url "$MODEL_URL" \
    --relative-path models/checkpoints \
    --filename "$MODEL_FILENAME"

if ! validate_model_file; then
    log "ERROR: Civitai download finished but file validation failed."
    exit 1
fi

log "Download complete."
