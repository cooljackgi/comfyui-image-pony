#!/bin/bash
set -e

echo "=== [start_wrapper] Downloading models if needed ==="
/download_models.sh

echo "=== [start_wrapper] Starting ComfyUI worker ==="
exec /start.sh
