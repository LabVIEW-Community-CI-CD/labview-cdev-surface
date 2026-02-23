# labview-cdev-surface

Canonical governance surface for deterministic `C:\dev` workspace provisioning.

This repository owns:
- `workspace-governance.json` (machine-readable remote/branch/commit contract)
- `workspace-governance-payload\workspace-governance\*` (canonical payload copied into `C:\dev` by installer runtime)
- `AGENTS.md` (human policy contract)
- validation scripts in `scripts/`
- drift and contract workflows in `.github/workflows/`

## Core release signal

`Workspace SHA Drift Signal` runs on a schedule and on demand. It fails when any governed repo default branch SHA differs from its `pinned_sha` in `workspace-governance.json`.

`Workspace SHA Refresh PR` is the default remediation workflow. It updates `pinned_sha` values, reuses branch `automation/sha-refresh`, and creates or updates a single refresh PR to `main`.

Auto-refresh policy:
1. Auto-merge is enabled by default for refresh PRs with squash strategy.
2. Maintainer approval is not required for `labview-cdev-surface` refresh merges (`required_approving_review_count = 0`).
3. Required status checks remain strict (`CI Pipeline`, `Workspace Installer Contract`, `Reproducibility Contract`, `Provenance Contract`).
4. `workspace-sha-drift-signal.yml` uses `WORKFLOW_BOT_TOKEN` for cross-repo default-branch SHA reads.
5. `workspace-sha-refresh-pr.yml` requires repository secret `WORKFLOW_BOT_TOKEN` for branch mutation and PR operations.
6. If `WORKFLOW_BOT_TOKEN` is missing or misconfigured, refresh automation fails fast with an explicit error.
7. Refresh CI propagation is PR-event-driven; refresh automation does not explicitly dispatch `ci.yml`.
8. Manual refresh PR flow is fallback only for platform outages, not routine check propagation.

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
The workflow uses concurrency dedupe keyed by workflow/repo/ref to avoid duplicate active runs on the same branch.

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

Artifact upload reliability:
1. Self-hosted artifact uploads run with deterministic two-attempt retry behavior.
2. Operator escalation is required only when both upload attempts fail.

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

## Publish Release (Automated Gate)

Use manual workflow dispatch for release publication:
1. Run `.github/workflows/release-with-windows-gate.yml`.
2. Provide a new `release_tag` in semantic format (for example, `v0.1.1`).
3. Keep `allow_existing_tag=false` (default). Set `true` only for break-glass overwrite operations.
4. Set `prerelease` as needed.
5. Keep `allow_gate_override=false` (default).

Automated flow:
1. `repo_guard` verifies release runs only in `LabVIEW-Community-CI-CD/labview-cdev-surface`.
2. `windows_gate` runs Windows-container installer acceptance.
3. `gate_policy` hard-blocks publish on gate failure.
4. `release_publish` runs only when gate policy succeeds.

Controlled override (exception only):
1. Set `allow_gate_override=true`.
2. Provide non-empty `override_reason`.
3. Provide `override_incident_url` pointing to a GitHub issue/discussion.
4. Workflow appends an "Override Disclosure" section to release notes.

Release packaging still:
- Builds `lvie-cdev-workspace-installer.exe`.
- Computes SHA256.
- Runs determinism gates and fails on hash drift.
- Generates `workspace-installer.spdx.json` and `workspace-installer.slsa.json`.
- Creates the GitHub release if missing and binds the tag to the exact workflow commit SHA.
- Uploads installer + SHA + provenance + reproducibility report assets to the release.
- Writes release notes including SHA256 and the install command:

```powershell
lvie-cdev-workspace-installer.exe /S
```

Verify downloaded asset integrity by matching the local hash against the SHA256 value published in the release notes.
Tag immutability policy: existing release tags fail by default to prevent mutable release history.
Fallback entrypoint: `.github/workflows/release-workspace-installer.yml` (wrapper to `_release-workspace-installer-core.yml`).

## Nightly canary

`nightly-supplychain-canary.yml` runs on a nightly schedule and on demand. It executes:
1. Docker Desktop Linux iteration (`desktop-linux` context).
2. Runner-cli determinism checks (`win-x64` and `linux-x64`).
3. Installer determinism check.

On failure, it updates a single tracking issue (`Nightly Supply-Chain Canary Failure`) with the failing run link.

## Windows LabVIEW image gate

`windows-labview-image-gate.yml` is dispatch-only and wraps `./.github/workflows/_windows-labview-image-gate-core.yml` for standalone diagnostics.  
The core gate requires the runner to already be in Windows container mode (non-interactive CI does not switch Docker engine), then pulls `nationalinstruments/labview:latest-windows`, installs the NSIS workspace installer in-container, runs bundled `runner-cli ppl build` and `runner-cli vip build`, and verifies PPL + VIP output presence.
