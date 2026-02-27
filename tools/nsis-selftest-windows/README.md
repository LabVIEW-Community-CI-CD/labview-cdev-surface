# Windows NSIS Self-Test Runtime

This image is the local runtime for `scripts/Invoke-WindowsContainerNsisSelfTest.ps1`.

## Purpose

- Build the workspace NSIS installer inside a Windows container.
- Run the installer in the same container for smoke validation.
- Validate install report output before the container exits.

## Included tooling

- Base image: `nationalinstruments/labview:2026q1-windows`
- Windows PowerShell (from base image)
- Host-mounted NSIS toolchain (`makensis.exe`)
- Host-prestaged payload containing bundled `runner-cli`

## Host prerequisites

- `C:\Program Files (x86)\NSIS\makensis.exe` available on host (override via wrapper parameters).
- Host `git` and `dotnet` available for payload staging (`Build-RunnerCliBundleFromManifest.ps1` runs on host before container launch).

## Build manually

```powershell
docker build `
  -f .\tools\nsis-selftest-windows\Dockerfile `
  -t labview-cdev-surface-nsis-selftest:local `
  .\tools\nsis-selftest-windows
```
