# Ops Runtime Container

This container is the portable Docker package for local ops exercises.

Default image:
- `ghcr.io/labview-community-ci-cd/labview-cdev-surface-ops:v1`

Base image (digest pinned):
- `ghcr.io/labview-community-ci-cd/labview-cdev-cli-runtime@sha256:0506e8789680ce1c941ca9f005b75d804150aed6ad36a5ac59458b802d358423`

Build locally:

```powershell
docker build -f .\tools\ops-runtime\Dockerfile -t labview-cdev-surface-ops:local .\tools\ops-runtime
```

Run the release control-plane local harness with this package:

```powershell
pwsh -NoProfile -File .\scripts\Invoke-ReleaseControlPlaneLocalDocker.ps1 `
  -BuildLocalImage `
  -LocalTag labview-cdev-surface-ops:local `
  -Mode Validate `
  -DryRun `
  -RunContractTests
```
