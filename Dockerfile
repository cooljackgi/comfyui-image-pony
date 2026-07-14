# clean base image containing only comfyui, comfy-cli and comfyui-manager
FROM runpod/worker-comfyui:5.8.4-base

# Copy runtime model download script and wrapper.
# The Civitai token is NOT a build-arg — it must be set as a RunPod
# *Environment Variable* (Endpoint → Edit → Environment Variables):
#   CIVITAI_API_TOKEN = <your token>
# The model is downloaded the first time the container starts.
COPY download_models.sh /download_models.sh
COPY start_wrapper.sh /start_wrapper.sh
RUN chmod +x /download_models.sh /start_wrapper.sh

CMD ["/start_wrapper.sh"]
