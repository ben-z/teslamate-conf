FROM nginxinc/nginx-unprivileged:1.29-alpine@sha256:0c79d56aee561a1d81c63f00eee5fb5fe29279560cdc55e91425133104c7fbe6
ARG SOURCE_SHA
LABEL org.opencontainers.image.source="https://github.com/ben-z/teslamate-conf" \
      org.opencontainers.image.revision="${SOURCE_SHA}"
COPY --chown=101:101 nginx.conf /etc/nginx/conf.d/default.conf
USER root
RUN test "${#SOURCE_SHA}" = 40 \
    && ! printf '%s' "$SOURCE_SHA" | grep -q '[^0-9a-f]' \
    && mkdir -p /opt/release \
    && printf '{"version":"%s"}\n' "$SOURCE_SHA" > /opt/release/version.json
USER 101:101
# The image entrypoint edits configuration; this configuration is already complete.
ENTRYPOINT ["nginx", "-g", "daemon off;"]
