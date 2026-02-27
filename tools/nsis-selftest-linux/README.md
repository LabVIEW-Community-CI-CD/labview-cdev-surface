# Linux NSIS Parity Runtime

This image mirrors the containerized NSIS self-test posture on Linux, aligned to `nationalinstruments/labview:2026q1-linux`.

## Purpose

- Provide a Linux parity runtime that includes LabVIEW base image context plus NSIS, git, dotnet, and PowerShell.
- Exercise deterministic toolchain probes and NSIS smoke compile from the same runtime used for Linux parity lanes.
- Emit machine-readable parity reports via `scripts/Invoke-LinuxContainerNsisParity.ps1`.
- Keep dependency installation apt-driven for Ubuntu 22.04 parity, consistent with NI container guidance in `docs/linux-custom-images.md`.

## Included tooling

- Base image: `nationalinstruments/labview:2026q1-linux`
- Microsoft apt feed (`packages.microsoft.com/ubuntu/22.04/prod`)
- `.NET SDK` via `dotnet-sdk-8.0` (apt)
- `PowerShell` via `powershell` (apt)
- `git`, `jq`, `nsis`
- LabVIEW-supporting Linux dependencies kept explicit: `desktop-file-utils`, `gtk-update-icon-cache`, `libglu1-mesa`, `libx11-6`, `libxinerama1`, `xvfb`

## Build manually

```powershell
docker build `
  -f .\tools\nsis-selftest-linux\Dockerfile `
  -t labview-cdev-surface-nsis-linux-parity:local `
  .\tools\nsis-selftest-linux
```
