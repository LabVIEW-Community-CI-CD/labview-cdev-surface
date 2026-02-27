FROM ghcr.io/labview-community-ci-cd/labview-cdev-cli-runtime@sha256:0506e8789680ce1c941ca9f005b75d804150aed6ad36a5ac59458b802d358423

ENTRYPOINT []

RUN pwsh -NoLogo -NoProfile -Command "Set-PSRepository -Name PSGallery -InstallationPolicy Trusted; Install-Module -Name Pester -Scope AllUsers -Force -MinimumVersion 5.5.0"

WORKDIR /workspace
