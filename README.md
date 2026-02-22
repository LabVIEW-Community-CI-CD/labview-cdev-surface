# labview-cdev-surface

Canonical governance surface for deterministic `C:\dev` workspace provisioning.

This repository owns:
- `workspace-governance.json` (machine-readable remote/branch/commit contract)
- `AGENTS.md` (human policy contract)
- validation scripts in `scripts/`
- drift and contract workflows in `.github/workflows/`

## Core release signal

`Workspace SHA Drift Signal` runs on a schedule and on demand. It fails when any governed repo default branch SHA differs from its `pinned_sha` in `workspace-governance.json`.

Failure is the signal to open a PR that updates the manifest SHAs (manual fork-to-org flow).

Manual flow:
1. Create a feature branch in `svelderrainruiz/labview-cdev-surface`.
2. Update `workspace-governance.json` `pinned_sha` values.
3. Open a PR from the fork branch to `LabVIEW-Community-CI-CD/labview-cdev-surface:main`.
4. Do not rely on auto-PR bot behavior for this process.

## Local checks

```powershell
pwsh -NoProfile -File .\scripts\Test-WorkspaceManifestBranchDrift.ps1 `
  -ManifestPath .\workspace-governance.json `
  -OutputPath .\artifacts\workspace-drift\workspace-drift-report.json
```

```powershell
pwsh -NoProfile -File .\scripts\Test-PolicyContracts.ps1 `
  -WorkspaceRoot C:\dev `
  -FailOnWarning
```

## Build in CI

`CI Pipeline` includes the `Workspace Installer Contract` job, which compiles:
- `lvie-cdev-workspace-installer.exe`

The job stages a deterministic workspace payload and validates that NSIS build tooling can produce the installer on the self-hosted Windows lane.

## Publish release asset

Use manual workflow dispatch for release publication:
1. Run `.github/workflows/release-workspace-installer.yml`.
2. Provide `release_tag` in semantic format (for example, `v0.1.0`).
3. Set `prerelease` as needed.

The workflow:
- Builds `lvie-cdev-workspace-installer.exe`
- Computes SHA256
- Creates the GitHub release if missing
- Uploads installer asset to the release
- Writes release notes including SHA256 and the install command:

```powershell
lvie-cdev-workspace-installer.exe /S
```

Verify downloaded asset integrity by matching the local hash against the SHA256 value published in the release notes.
