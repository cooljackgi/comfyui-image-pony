# clean base image containing only comfyui, comfy-cli and comfyui-manager
FROM runpod/worker-comfyui:5.8.4-base

# Build-time tokens for gated downloads. They are not persisted in the final image.
# Accept both names to avoid CI/build arg mismatches.
ARG CIVITAI_API_TOKEN=""
ARG CIVITAI_API_KEY=""

# install custom nodes into comfyui
# RUN # Could not resolve custom node: SwarmSaveImageWS
# RUN # Could not resolve custom node: SwarmKSampler

# download models into comfyui
RUN TOKEN="${CIVITAI_API_TOKEN:-$CIVITAI_API_KEY}"; \
    BACKOFFS="60 300 900 1800 3600"; \
    for i in 1 2 3 4 5; do \
      CIVITAI_API_TOKEN="$TOKEN" comfy model download \
        --url 'https://civitai.com/api/download/models/2581228' \
        --relative-path models/checkpoints \
        --filename 'CyberRealistic_Pony_-_v16-0.safetensors' \
      && break; \
      if [ $i -eq 5 ]; then \
        echo "model-download failed after 5 attempts" >&2; exit 1; \
      fi; \
      SLEEP=$(echo $BACKOFFS | cut -d ' ' -f $i); \
      echo "model-download attempt $i failed; retrying in $SLEEP seconds" >&2; \
      sleep $SLEEP; \
    done
