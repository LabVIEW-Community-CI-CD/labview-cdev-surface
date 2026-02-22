# labview-cdev-surface

Canonical governance surface for deterministic `C:\dev` workspace provisioning.

This repository owns:
- `workspace-governance.json` (machine-readable remote/branch/commit contract)
- `workspace-governance-payload\workspace-governance\*` (canonical payload copied into `C:\dev` by installer runtime)
- `workspace-governance-payload\tools\cdev-cli\*` (bundled control-plane CLI assets for offline deterministic operation)
- `AGENTS.md` (human policy contract)
- validation scripts in `scripts/`
- drift and contract workflows in `.github/workflows/`

## CLI-first control plane

Preferred operator interface:

```powershell
pwsh -NoProfile -File C:\dev\tools\cdev-cli\win-x64\cdev-cli\scripts\Invoke-CdevCli.ps1 help
```

Core commands:
- `repos doctor`
- `installer exercise`
- `postactions collect`
- `linux deploy-ni --docker-context desktop-linux --image nationalinstruments/labview:latest-linux`

The NSIS payload bundles pinned CLI assets for both `win-x64` and `linux-x64` and release preflight verifies their hashes against `workspace-governance.json`.

## Core release signal

`Workspace SHA Drift Signal` runs on a schedule and on demand. It fails when any governed repo default branch SHA differs from its `pinned_sha` in `workspace-governance.json`.

`Workspace SHA Refresh PR` is the default remediation workflow. It updates `pinned_sha` values, reuses branch `automation/sha-refresh`, and creates or updates a single refresh PR to `main`.

Auto-refresh policy:
1. Auto-merge is enabled by default for refresh PRs with squash strategy.
2. Maintainer approval is not required for `labview-cdev-surface` refresh merges (`required_approving_review_count = 0`).
3. Required status checks remain strict (`CI Pipeline`, `Workspace Installer Contract`, `Reproducibility Contract`, `Provenance Contract`).
4. `workspace-sha-refresh-pr.yml` requires repository secret `WORKFLOW_BOT_TOKEN` for branch mutation, PR operations, and workflow dispatch.
5. If `WORKFLOW_BOT_TOKEN` is missing or misconfigured, refresh automation fails fast with an explicit error.
6. Manual refresh PR flow is fallback only for platform outages, not routine check propagation.

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

## Local NSIS refinement (fast iteration)

Run a fast local iteration (build + transfer bundle, skip smoke install):

```powershell
pwsh -NoProfile -File .\scripts\Invoke-WorkspaceInstallerIteration.ps1 `
  -Mode fast `
  -Iterations 1
```

Prerequisites for full installer qualification:
- LabVIEW 2020 (32-bit and 64-bit) installed for PPL capability.
- LabVIEW 2020 (64-bit) installed for VIP capability.
- `g-cli`, `git`, `gh`, `pwsh`, and `dotnet` available on PATH.
- NSIS installed at `C:\Program Files (x86)\NSIS` (or pass an override).

Run a full local qualification (build + isolated smoke install + bundle):

```powershell
pwsh -NoProfile -File .\scripts\Invoke-WorkspaceInstallerIteration.ps1 `
  -Mode full `
  -Iterations 1
```

Watch mode for agent iteration without manual reruns:

```powershell
pwsh -NoProfile -File .\scripts\Invoke-WorkspaceInstallerIteration.ps1 `
  -Mode fast `
  -Watch `
  -PollSeconds 10 `
  -MaxRuns 10
```

## Build in CI

`CI Pipeline` always runs on GitHub-hosted Linux and is the required merge check.

Self-hosted contract jobs are opt-in via repository variable `ENABLE_SELF_HOSTED_CONTRACTS=true`.
If no self-hosted runner is configured, these jobs stay skipped and do not block merge policy.

When enabled, `Workspace Installer Contract` compiles:
- `lvie-cdev-workspace-installer.exe`

The job stages a deterministic workspace payload, builds a manifest-pinned `runner-cli` bundle, and validates that NSIS build tooling can produce the installer on the self-hosted Windows lane.
Installer runtime is a hard gate for post-install capability in this order:
1. `runner-cli ppl build` with LabVIEW 2020 x86.
2. `runner-cli ppl build` with LabVIEW 2020 x64.
3. `runner-cli vipc assert/apply/assert` and `runner-cli vip build` with LabVIEW 2020 x64.

Additional supply-chain contract jobs:
- `Reproducibility Contract`: validates bit-for-bit determinism for `runner-cli` bundles (`win-x64`, `linux-x64`) and installer output.
- `Provenance Contract`: generates and validates SPDX + SLSA provenance artifacts linked to installer/bundle/manifest hashes.

## Integration gate

`integration-gate.yml` provides a single `Integration Gate` context for `integration/*` branches (and manual dispatch).  
It polls commit statuses and only passes when these contexts are successful:
- `CI Pipeline`
- `Workspace Installer Contract`
- `Reproducibility Contract`
- `Provenance Contract`

## Installer harness (self-hosted)

`installer-harness-self-hosted.yml` runs deterministic installer qualification on `self-hosted-windows-lv` for:
- `push` to `integration/*`
- `workflow_dispatch` (optional `ref` override)

The harness run sequence:
1. Runner baseline lock (`Assert-InstallerHarnessRunnerBaseline.ps1`)
2. Machine preflight pack (`Assert-InstallerHarnessMachinePreflight.ps1`)
3. Full local iteration (`Invoke-WorkspaceInstallerIteration.ps1 -Mode full -Iterations 1`)
4. Report validation for smoke post-actions:
   - `ppl_capability_checks.32 == pass`
   - `ppl_capability_checks.64 == pass`
   - `vip_package_build_check == pass`

Published evidence artifacts include:
- `iteration-summary.json`
- `exercise-report.json`
- `workspace-install-latest.json` (smoke)
- `lvie-cdev-workspace-installer-bundle.zip`
- `harness-validation-report.json`

Promotion policy:
1. Keep `Installer Harness` non-required initially.
2. Promote to required check after 3 consecutive green integration runs and at least 1 green manual dispatch run.

Runner drift recovery (only when baseline lock fails):

```powershell
$token = gh api -X POST repos/LabVIEW-Community-CI-CD/labview-cdev-surface/actions/runners/registration-token --jq .token

Set-Location C:\actions-runner-cdev
.\config.cmd --url https://github.com/LabVIEW-Community-CI-CD/labview-cdev-surface --token $token --name DESKTOP-6Q81H4O-cdev-surface --labels self-hosted,windows,self-hosted-windows-lv --work _work --unattended --replace --runasservice

Set-Location C:\actions-runner-cdev-2
.\config.cmd --url https://github.com/LabVIEW-Community-CI-CD/labview-cdev-surface --token $token --name DESKTOP-6Q81H4O-cdev-surface-2 --labels self-hosted,windows,self-hosted-windows-lv,windows-containers --work _work --unattended --replace --runasservice
```

## Post-gate extension (Docker Desktop Windows image)

After the installer hard gate is consistently green, extend CI with a Docker Desktop Windows-image lane that:
1. Installs the workspace via `lvie-cdev-workspace-installer.exe /S`.
2. Uses bundled `runner-cli` from the installed workspace.
3. Runs `runner-cli ppl build` and `runner-cli vip build` on the LabVIEW-enabled Windows image.
4. Fails the lane on command-surface regressions or PPL/VIP capability loss.

## Fast Docker Desktop Linux iteration

Use local Docker Desktop Linux mode to iterate faster on runner-cli command-surface and policy contracts before running the full Windows LabVIEW image lane:

```powershell
pwsh -NoProfile -File .\scripts\Invoke-DockerDesktopLinuxIteration.ps1 `
  -DockerContext desktop-linux `
  -Runtime linux-x64 `
  -Image mcr.microsoft.com/powershell:7.4-ubuntu-22.04
```

This lane bundles manifest-pinned `runner-cli` for `linux-x64`, runs `runner-cli --help` and `runner-cli ppl --help` inside the container, and optionally executes core Pester contract tests.
If Docker Desktop cannot start, verify Windows virtualization features are enabled (`Microsoft-Hyper-V-All`, `VirtualMachinePlatform`, `Microsoft-Windows-Subsystem-Linux`) and reboot after feature changes.

## Publish release asset

Use manual workflow dispatch for release publication:
1. Run `.github/workflows/release-workspace-installer.yml`.
2. Provide `release_tag` in semantic format (for example, `v0.1.0`).
3. Set `prerelease` as needed.

The workflow:
- Builds `lvie-cdev-workspace-installer.exe`
- Computes SHA256
- Runs determinism gates and fails on hash drift
- Generates `workspace-installer.spdx.json` and `workspace-installer.slsa.json`
- Creates the GitHub release if missing
- Uploads installer + SHA + provenance + reproducibility report assets to the release
- Writes release notes including SHA256 and the install command:

```powershell
lvie-cdev-workspace-installer.exe /S
```

Verify downloaded asset integrity by matching the local hash against the SHA256 value published in the release notes.

## Nightly canary

`nightly-supplychain-canary.yml` runs on a nightly schedule and on demand. It executes:
1. Docker Desktop Linux iteration (`desktop-linux` context).
2. Runner-cli determinism checks (`win-x64` and `linux-x64`).
3. Installer determinism check.

On failure, it updates a single tracking issue (`Nightly Supply-Chain Canary Failure`) with the failing run link.

## Windows LabVIEW image gate

`windows-labview-image-gate.yml` is dispatch-only in phase 1 and targets a dedicated self-hosted Windows runner with Windows containers.  
It pulls `nationalinstruments/labview:latest-windows`, installs the NSIS workspace installer in-container, runs bundled `runner-cli ppl build` and `runner-cli vip build`, and verifies PPL + VIP output presence.
