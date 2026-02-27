FROM nationalinstruments/labview:2026q1-linux

SHELL ["/bin/bash", "-o", "pipefail", "-c"]

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        apt-transport-https \
        ca-certificates \
        curl \
        desktop-file-utils \
        gpg \
        gtk-update-icon-cache \
        libglu1-mesa \
        libx11-6 \
        libxinerama1 \
        xvfb \
    && mkdir -p /etc/apt/keyrings \
    && curl -fsSL https://packages.microsoft.com/keys/microsoft.asc | gpg --dearmor -o /etc/apt/keyrings/microsoft.gpg \
    && chmod go+r /etc/apt/keyrings/microsoft.gpg \
    && echo "deb [arch=amd64 signed-by=/etc/apt/keyrings/microsoft.gpg] https://packages.microsoft.com/ubuntu/22.04/prod jammy main" > /etc/apt/sources.list.d/microsoft-prod.list \
    && apt-get update \
    && apt-get install -y --no-install-recommends \
        dotnet-sdk-8.0 \
        git \
        jq \
        nsis \
        powershell \
        unzip \
        xz-utils \
        zip \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /workspace
