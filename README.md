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
