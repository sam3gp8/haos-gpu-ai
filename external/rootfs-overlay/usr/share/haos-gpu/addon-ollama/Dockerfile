# =============================================================================
# Ollama GPU-AI Universal add-on
#
# The official ollama/ollama image already bundles the NVIDIA CUDA runtime and
# (via ollama/ollama:rocm) the AMD ROCm runtime, and detects the GPU at launch.
# That is exactly the container-side responsibility in this architecture: the
# HOST provides drivers + device nodes; the CONTAINER provides the compute
# runtime.
#
# BUILD_FROM is overridable so you can pick the vendor-matched base:
#   NVIDIA / default : ollama/ollama:latest
#   AMD              : ollama/ollama:rocm
#   Intel            : an IPEX-LLM / SYCL llama.cpp base (Ollama's Intel path is
#                      still maturing; see external/package/haos-compute-intel/NOTES.md)
# =============================================================================
ARG BUILD_FROM=ollama/ollama:latest
FROM ${BUILD_FROM}

# Home Assistant add-on contract: a simple long-running entrypoint.
COPY run.sh /run.sh
RUN chmod +x /run.sh

# The base image sets its own ENTRYPOINT; override so our script owns PID 1.
ENTRYPOINT []
CMD [ "/run.sh" ]
