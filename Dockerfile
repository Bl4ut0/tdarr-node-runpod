FROM ghcr.io/haveagitgat/tdarr_node:2.85.01

LABEL org.opencontainers.image.source=https://github.com/Bl4ut0/tdarr-node-runpod
LABEL org.opencontainers.image.description="Tdarr Node optimized for RunPod"
LABEL org.opencontainers.image.licenses=MIT

ENV NVIDIA_VISIBLE_DEVICES=all
ENV NVIDIA_DRIVER_CAPABILITIES=all

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

# Bypass s6-overlay init system to allow execution under RunPod container supervisors
ENTRYPOINT ["/bin/bash", "/entrypoint.sh"]
