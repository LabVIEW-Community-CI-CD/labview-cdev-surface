# Local Agent Instructions

## Mission
This repository is the canonical policy and manifest surface for deterministic `C:\dev` workspace governance.

## Authoritative Files
- `workspace-governance.json` is the machine contract for repo remotes, default branches, branch-protection expectations, and `pinned_sha` values.
- `workspace-governance-payload\workspace-governance\*` is the canonical installer payload for writing policy files into `C:\dev`.
- `scripts/Test-WorkspaceManifestBranchDrift.ps1` is the drift detector used by scheduled and on-demand workflows.
- `scripts/Update-WorkspaceManifestPins.ps1` is the SHA refresh updater used by automation.
- `.github/workflows/workspace-sha-drift-signal.yml` is the drift signal workflow.
- `.github/workflows/workspace-sha-refresh-pr.yml` is the auto-PR SHA refresh workflow.

## Safety Rules
- Do not relax fork/org mutation restrictions encoded in `workspace-governance.json`.
- Do not mutate governed default branches directly when branch-protection contracts are missing.
- Prefer automated SHA refresh PRs for `pinned_sha` updates.
- Keep the drift-signal workflow enabled; drift failures are expected release signals.

## Release Signal Contract
- `Workspace SHA Refresh PR` is the primary path for updating `pinned_sha` values.
- On drift, automation must update manifest pins, create/update branch `automation/sha-refresh`, and open or update a PR to `main`.
- `workspace-sha-drift-signal.yml` uses `WORKFLOW_BOT_TOKEN` for cross-repo default-branch SHA reads.
- `workspace-sha-refresh-pr.yml` requires repository secret `WORKFLOW_BOT_TOKEN` for branch mutation and PR operations.
- Refresh CI propagation is PR-event-driven; do not explicitly dispatch `ci.yml` from refresh automation.
- If `WORKFLOW_BOT_TOKEN` is missing or misconfigured, refresh automation must fail fast with explicit remediation.
- Auto-merge is enabled by default for refresh PRs using squash strategy.
- Maintainer review is not required for `labview-cdev-surface` refresh PR merges (`required_approving_review_count = 0`).
- Do not bypass this by weakening checks or disabling scheduled runs.
- Do not use manual no-op pushes as a normal workaround for refresh PR check propagation.
- If automation cannot create or merge the PR due to platform outage, manual refresh is fallback.

## Installer Release Contract
- Primary release publish path is `.github/workflows/release-with-windows-gate.yml`.
- `release-with-windows-gate.yml` must run `repo_guard` and fail outside `LabVIEW-Community-CI-CD/labview-cdev-surface`.
- `release-with-windows-gate.yml` must run Windows acceptance via `./.github/workflows/_windows-labview-image-gate-core.yml` before publish.
- Windows gate runners must be preconfigured in Windows container mode; do not rely on interactive Docker engine switching in CI.
- Windows gate workflow must target labels: `self-hosted`, `windows`, `self-hosted-windows-lv`, `windows-containers`, `user-session`, `cdev-surface-windows-gate`.
- Windows gate image default is `nationalinstruments/labview:2026q1-windows`; optional override via repository variable `LABVIEW_WINDOWS_IMAGE`.
- Windows gate isolation policy:
  - `LABVIEW_WINDOWS_DOCKER_ISOLATION=auto` (default): use `process` for compatible host/image versions and fallback to `hyperv` on mismatch.
  - `LABVIEW_WINDOWS_DOCKER_ISOLATION=process`: strict process isolation only (mismatch is hard fail).
  - `LABVIEW_WINDOWS_DOCKER_ISOLATION=hyperv`: force Hyper-V isolation.
- Publish is hard-blocked when Windows gate fails unless controlled override is explicitly enabled with complete metadata.
- Controlled override requires all of:
  - `allow_gate_override=true`
  - non-empty `override_reason`
  - `override_incident_url` matching GitHub issue/discussion URL format.
- Windows feature-enable troubleshooting contract:
  - Treat `Enable-WindowsOptionalFeature ... -NoRestart` warning output as informational.
  - Verify features in a per-feature loop (single `-FeatureName` per call), never by passing an array directly to `Get-WindowsOptionalFeature -FeatureName`.
  - Report these explicit fields in troubleshooting output: `features_enabled`, `reboot_pending`, `docker_daemon_ready`.
- Override path must emit explicit warning summary and append override disclosure to release notes.
- `.github/workflows/release-workspace-installer.yml` is retained as a dispatch wrapper for diagnostics/fallback and must call `./.github/workflows/_release-workspace-installer-core.yml`.
- `.github/workflows/windows-labview-image-gate.yml` is retained as a dispatch wrapper for diagnostics/fallback and must call `./.github/workflows/_windows-labview-image-gate-core.yml`.
- Publishing mode is manual dispatch only with explicit semantic tag input (`v<major>.<minor>.<patch>`).
- Release tags are immutable by default: existing tags must fail publication unless `allow_existing_tag=true` is explicitly set for break-glass recovery.
- Release creation must bind tag creation to the exact workflow commit SHA (`github.sha`), not a moving branch target.
- Keep fork-first mutation rules when preparing release changes:
  - mutate `origin` (`svelderrainruiz/labview-cdev-surface`) only
  - open PRs to `LabVIEW-Community-CI-CD/labview-cdev-surface:main`
- Do not add push-triggered or scheduled release publishing in this repository.
- Phase-1 release policy is unsigned installer with mandatory SHA256 provenance in release notes.

## Installer Build Contract
- `CI Pipeline` (GitHub-hosted) is the required merge check.
- Self-hosted contract lanes are opt-in via repository variable `ENABLE_SELF_HOSTED_CONTRACTS=true`.
- If no self-hosted runner is configured, self-hosted lanes must remain skipped and non-blocking.
- When self-hosted lanes are enabled, `CI Pipeline` must include `Workspace Installer Contract`.
- The contract job must stage deterministic payload inputs from `workspace-governance-payload`, bundle `runner-cli` from manifest-pinned icon-editor SHA, and build `lvie-cdev-workspace-installer.exe` with NSIS on self-hosted Windows.
- The job must publish the built installer as a workflow artifact.
- CI workflow-level concurrency must deduplicate same workflow/ref execution across PR, push, and manual dispatch events.
- Self-hosted artifact uploads must use deterministic two-attempt retry and fail only when both attempts fail.
- When self-hosted lanes are enabled, `CI Pipeline` must also include:
  - `Reproducibility Contract` (bit-for-bit hash checks for runner-cli and installer).
  - `Provenance Contract` (SPDX/SLSA generation + hash-link validation).
- Keep default-branch required checks unchanged until branch-protection contract is intentionally updated.

## Installer Runtime Gate Contract
- Installer runtime (`scripts/Install-WorkspaceFromManifest.ps1`) must fail fast if bundled `runner-cli` integrity checks fail.
- Installer runtime must enforce LabVIEW 2020 capability gates in this order:
  - `runner-cli ppl build` on 32-bit LabVIEW 2020.
  - `runner-cli ppl build` on 64-bit LabVIEW 2020.
  - `runner-cli vipc assert/apply/assert` and `runner-cli vip build` on 64-bit LabVIEW 2020.
- Installer runtime must require `-ExecutionContext NsisInstall` (or explicit local exercise context) for authoritative post-actions in `Install` mode.
- Installer runtime must surface phase-level terminal feedback (clone, payload sync, runner-cli validation, PPL gate, VIP harness gate, governance audit).
- Installer runtime report must emit `ppl_capability_checks` (per bitness) and ordered `post_action_sequence` evidence.
- Branch-protection-only governance failures remain audit-only; runner-cli/PPL/VIP capability failures are hard-stop failures.

## Post-Gate Docker Extension
- After installer runtime gates are consistently green, add a Docker Desktop Windows-image lane that runs installer + `runner-cli ppl build` inside the LabVIEW-enabled image.
- The Docker extension lane must run only after installer contract success and fail on runner-cli command/capability drift.
- Use local Docker Desktop Linux iteration first to accelerate agent feedback loops before Windows-image qualification.
- Local Linux iteration entrypoint: `scripts/Invoke-DockerDesktopLinuxIteration.ps1`.

## Supply-Chain Contracts
- Reproducibility is strict: bundle/installer outputs must remain bit-for-bit stable for identical manifest pins and source epoch.
- Provenance artifacts are mandatory on release:
  - `workspace-installer.spdx.json`
  - `workspace-installer.slsa.json`
  - `reproducibility-report.json`
- Release mode remains manual tag dispatch only; no auto-publish.

## Canary Policy
- `nightly-supplychain-canary.yml` is the scheduled drift and reproducibility signal.
- Canary failures must update a single tracking issue; do not disable canary to bypass failures.

## Local Iteration Contract
- Refine NSIS flow locally first on machines with NSIS installed.
- Use `scripts/Invoke-WorkspaceInstallerIteration.ps1` for repeatable agent runs:
  - `-Mode fast` for quick build/bundle iterations.
  - `-Mode full` for isolated smoke install validation.
  - `-Watch` to auto-rerun on contract file changes without manual restarts.
- Use `scripts/Invoke-DockerDesktopLinuxIteration.ps1 -DockerContext desktop-linux` for Docker Desktop Linux command-surface checks (`runner-cli --help`, `runner-cli ppl --help`) before full Windows LabVIEW image runs.
- If Docker Desktop Linux context is unavailable, confirm `Microsoft-Hyper-V-All`, `VirtualMachinePlatform`, and `Microsoft-Windows-Subsystem-Linux` are enabled, then reboot before retrying.
- Use `scripts/Test-RunnerCliBundleDeterminism.ps1` and `scripts/Test-WorkspaceInstallerDeterminism.ps1` locally before proposing release-tag publication.
- Keep local iteration artifacts under `artifacts\release\iteration`.

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
