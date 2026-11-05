FROM postgres:17.5-bookworm@sha256:864831322bf2520e7d03d899b01b542de6de9ece6fe29c89f19dc5e1d5568ccf
USER root
RUN apt-get update && apt-get install -y --no-install-recommends python3 ca-certificates \
    && rm -rf /var/lib/apt/lists/*
ARG SOURCE_SHA
LABEL org.opencontainers.image.source="https://github.com/ben-z/teslamate-conf" \
      org.opencontainers.image.revision="${SOURCE_SHA}"
COPY backup.py /opt/backup.py
USER 999:999
ENTRYPOINT ["python3", "/opt/backup.py"]
