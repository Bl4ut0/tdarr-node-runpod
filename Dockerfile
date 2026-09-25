FROM gcc:11.5.0-bullseye AS nvenc-filter-build
WORKDIR /src
COPY nvenc-device-filter.c ./nvenc-device-filter.c
RUN gcc -shared -fPIC -O2 -Wall -Wextra -o /nvenc-device-filter.so nvenc-device-filter.c -ldl

FROM ghcr.io/haveagitgat/tdarr_node:2.85.01

LABEL org.opencontainers.image.source=https://github.com/Bl4ut0/tdarr-node-runpod
LABEL org.opencontainers.image.description="Tdarr Node optimized for RunPod"
LABEL org.opencontainers.image.licenses=MIT

ENV NVIDIA_VISIBLE_DEVICES=all
ENV NVIDIA_DRIVER_CAPABILITIES=all

COPY entrypoint.sh /entrypoint.sh
COPY --from=nvenc-filter-build /nvenc-device-filter.so /usr/local/lib/nvenc-device-filter.so
RUN chmod +x /entrypoint.sh

# Bypass s6-overlay init system to allow execution under RunPod container supervisors
ENTRYPOINT ["/bin/bash", "/entrypoint.sh"]
