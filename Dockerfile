FROM ghcr.io/haveagitgat/tdarr_node:2.85.01

LABEL org.opencontainers.image.source=https://github.com/Bl4ut0/tdarr-node-runpod
LABEL org.opencontainers.image.description="Tdarr Node optimized for RunPod (bypasses s6-overlay PID 1 constraint)"
LABEL org.opencontainers.image.licenses=MIT

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

# Bypass s6-overlay init system to allow execution under RunPod container supervisors
ENTRYPOINT ["/entrypoint.sh"]