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
- If `Workspace SHA Drift Signal` fails, create a PR that updates `pinned_sha` values to the intended default-branch SHAs.
- Do not bypass this by weakening checks or disabling scheduled runs.

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
