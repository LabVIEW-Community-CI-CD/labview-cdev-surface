# Local Agent Instructions

## Mission
This repository is the canonical policy and manifest surface for deterministic `C:\dev` workspace governance.

## Authoritative Files
- `workspace-governance.json` is the machine contract for repo remotes, default branches, branch-protection expectations, and `pinned_sha` values.
- `scripts/Test-WorkspaceManifestBranchDrift.ps1` is the drift detector used by scheduled and manual workflows.
- `.github/workflows/workspace-sha-drift-signal.yml` is the release-signal workflow.

## Safety Rules
- Do not relax fork/org mutation restrictions encoded in `workspace-governance.json`.
- Do not mutate governed default branches directly when branch-protection contracts are missing.
- Update `pinned_sha` values only through PRs from feature branches.
- Keep the drift-signal workflow enabled; drift failures are expected release signals.

## Release Signal Contract
- If `Workspace SHA Drift Signal` fails on org `main`, create a fork feature branch in `svelderrainruiz/labview-cdev-surface`, update `pinned_sha`, and create a PR from fork to org.
- Do not bypass this by weakening checks or disabling scheduled runs.
- Do not use auto-PR bot behavior for SHA refresh in this repository; keep drift-to-PR manual.

## Installer Release Contract
- The NSIS workspace installer is published as a GitHub release asset from `.github/workflows/release-workspace-installer.yml`.
- Publishing mode is manual dispatch only with explicit semantic tag input (`v<major>.<minor>.<patch>`).
- Keep fork-first mutation rules when preparing release changes:
  - mutate `origin` (`svelderrainruiz/labview-cdev-surface`) only
  - open PRs to `LabVIEW-Community-CI-CD/labview-cdev-surface:main`
- Do not add push-triggered or scheduled release publishing in this repository.
- Phase-1 release policy is unsigned installer with mandatory SHA256 provenance in release notes.

## Installer Build Contract
- `CI Pipeline` must include `Workspace Installer Contract`.
- The contract job must stage deterministic payload inputs and build `lvie-cdev-workspace-installer.exe` with NSIS on self-hosted Windows.
- The job must publish the built installer as a workflow artifact.
- Keep default-branch required checks unchanged until branch-protection contract is intentionally updated.

## Local Verification
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
