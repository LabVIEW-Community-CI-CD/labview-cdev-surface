# Local Agent Instructions

## Mission
This repository is the canonical policy and manifest surface for deterministic `C:\dev` workspace governance.
Build and gate lanes must run in isolated workspaces on every run (`D:\dev` preferred, `C:\dev` fallback).

## Authoritative Files
- `workspace-governance.json` is the machine contract for repo remotes, default branches, branch-protection expectations, and `pinned_sha` values.
- `workspace-governance-payload\workspace-governance\*` is the canonical installer payload for writing policy files into `C:\dev`.
- `scripts/Test-WorkspaceManifestBranchDrift.ps1` is the drift detector used by scheduled and on-demand workflows.
- `scripts/Update-WorkspaceManifestPins.ps1` is the SHA refresh updater used by automation.
- `.github/workflows/workspace-sha-drift-signal.yml` is the drift signal workflow.
- `.github/workflows/workspace-sha-refresh-pr.yml` is the auto-PR SHA refresh workflow.

## CLI Orchestration Contract
- Preferred operator interface is `Invoke-CdevCli.ps1` from the bundled cdev CLI payload.
- Required CLI command surface (stable tokens):
  - `repos doctor`
  - `installer exercise`
  - `installer install --mode release`
  - `installer upgrade`
  - `installer rollback`
  - `installer status`
  - `postactions collect`
  - `linux deploy-ni`
- Linux deploy defaults must stay documented as:
  - Docker context `desktop-linux`
  - Image `nationalinstruments/labview:latest-linux`
- Direct script entrypoints remain supported for fallback and debugging, but policy/docs/tests must stay CLI-first.

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
- Build workspace isolation policy is mandatory for gate/build lanes:
  - always-isolated
  - `git-worktree` primary, detached-clone fallback
  - deterministic root selection: `D:\dev` preferred, `C:\dev` fallback
  - run `scripts\Ensure-GitSafeDirectories.ps1` before repo operations (include worktrees; emit JSON report)
  - cleanup after artifact upload must run under `if: always()`
  - release artifact default policy token: `ci-only-selector`
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
- Publishing mode is manual dispatch only with dual-mode tag support:
  - preferred SemVer tags (`v<major>.<minor>.<patch>`, `v<major>.<minor>.<patch>-rc.<n>`, `v<major>.<minor>.<patch>-canary.<n>`)
  - legacy migration tags (`v0.YYYYMMDD.N`)
- Release channel metadata is supported via `release_channel` input (`stable`, `prerelease`, `canary`); default is derived from `prerelease`.
- Release workflow must enforce deterministic channel/tag consistency and fail with `[channel_tag_mismatch]` when `release_tag`, `prerelease`, and `release_channel` disagree.
- Release workflow must emit deterministic `[tag_migration_warning]` when legacy date-window tags are used.
- Release tags are immutable by default: existing tags must fail publication unless `allow_existing_tag=true` is explicitly set for break-glass recovery.
- Release creation must bind tag creation to the exact workflow commit SHA (`github.sha`), not a moving branch target.
- Keep fork-first mutation rules when preparing release changes:
  - mutate `origin` (`svelderrainruiz/labview-cdev-surface`) only
  - open PRs to `LabVIEW-Community-CI-CD/labview-cdev-surface:main`
- Do not add push-triggered or scheduled release publishing in this repository.
- Release packaging must publish:
  - `lvie-cdev-workspace-installer.exe`
  - `lvie-cdev-workspace-installer.exe.sha256`
  - `reproducibility-report.json`
  - `workspace-installer.spdx.json`
  - `workspace-installer.slsa.json`
  - `release-manifest.json`
- Installer signing policy is Authenticode dual-mode transition:
  - dual-mode start: `2026-03-15T00:00:00Z`
  - canary enforce date: `2026-05-15T00:00:00Z`
  - stable/prerelease enforce date (`grace_end_utc`): `2026-07-01T00:00:00Z`

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

## Release Client Runtime Contract
- `scripts/Install-WorkspaceInstallerFromRelease.ps1` is the canonical release-client runtime fallback for install/upgrade/rollback operations.
- Runtime modes must remain:
  - `Install`
  - `Upgrade`
  - `Rollback`
  - `Status`
  - `ValidatePolicy`
- Runtime must enforce policy allowlist on release source repositories before download.
- Runtime failure model must preserve deterministic reason codes:
  - `source_blocked`
  - `asset_missing`
  - `hash_mismatch`
  - `signature_missing`
  - `signature_invalid`
  - `provenance_invalid`
  - `installer_exit_nonzero`
  - `install_report_missing`
- Runtime must verify `release-manifest.json`, installer SHA256, Authenticode status (with channel-aware enforcement), SPDX/SLSA linkage, and installer smoke report presence.
- Release-client state/report policy files:
  - `C:\dev\workspace-governance\release-policy.json`
  - `C:\dev\artifacts\workspace-release-state.json`
  - `C:\dev\artifacts\workspace-release-client-latest.json`
- Allowed installer release repositories default to:
  - `LabVIEW-Community-CI-CD/labview-cdev-surface`
  - `svelderrainruiz/labview-cdev-surface`
- cdev-cli fork/upstream full-sync alignment metadata is required in `installer_contract.release_client.cdev_cli_sync`:
  - primary repo: `svelderrainruiz/labview-cdev-cli`
  - mirror repo: `LabVIEW-Community-CI-CD/labview-cdev-cli`
  - strategy: `fork-and-upstream-full-sync`
- Runtime image metadata is required in `installer_contract.release_client.runtime_images`:
  - cdev-cli runtime canonical repository: `ghcr.io/labview-community-ci-cd/labview-cdev-cli-runtime`
  - cdev-cli runtime source repo: `LabVIEW-Community-CI-CD/labview-cdev-cli`
  - cdev-cli runtime source commit: `8fef6f9192d81a14add28636c1100c109ae5e977`
  - cdev-cli runtime digest: `sha256:0506e8789680ce1c941ca9f005b75d804150aed6ad36a5ac59458b802d358423`
  - ops runtime repository: `ghcr.io/labview-community-ci-cd/labview-cdev-surface-ops`
  - ops runtime base repository/digest: `ghcr.io/labview-community-ci-cd/labview-cdev-cli-runtime@sha256:0506e8789680ce1c941ca9f005b75d804150aed6ad36a5ac59458b802d358423`

## Installer Runtime Gate Contract
- Installer runtime (`scripts/Install-WorkspaceFromManifest.ps1`) must fail fast if bundled `runner-cli` integrity checks fail.
- Installer runtime must enforce LabVIEW 2020 capability gates in this order:
  - `runner-cli ppl build` on 32-bit LabVIEW 2020.
  - `runner-cli ppl build` on 64-bit LabVIEW 2020.
  - `runner-cli vipc assert/apply/assert` and `runner-cli vip build` on 64-bit LabVIEW 2020.
- Installer runtime must require `-InstallerExecutionContext NsisInstall` (or explicit local exercise context) for authoritative post-actions in `Install` mode.
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

## Ops Monitoring Policy
- `.github/workflows/ops-monitoring.yml` is the authoritative hourly ops snapshot workflow.
- It must run `scripts/Invoke-OpsMonitoringSnapshot.ps1` and fail with deterministic reason codes when runner or sync-guard health drifts.
- Incident lifecycle automation for ops workflows must run through `scripts/Invoke-OpsIncidentLifecycle.ps1`.
- Failure-path issue behavior: create if missing, reopen if closed, or comment if already open.
- Recovery-path issue behavior: comment and close when the latest matching issue is open.
- Ops snapshot reason codes must remain explicit:
  - `runner_unavailable`
  - `sync_guard_failed`
  - `sync_guard_stale`
  - `sync_guard_missing`
  - `sync_guard_incomplete`
- Failure path must upload `ops-monitoring-report.json` and update a single issue titled `Ops Monitoring Alert`.
- Release-control-plane health checks must use release-runner labels only (`self-hosted`, `windows`, `self-hosted-windows-lv`) when invoking `Invoke-OpsMonitoringSnapshot.ps1` from:
  - `scripts/Invoke-ReleaseControlPlane.ps1`
  - `scripts/Invoke-OpsAutoRemediation.ps1`
  - `scripts/Exercise-ReleaseControlPlaneLocal.ps1`
- `.github/workflows/ops-monitoring.yml` remains strict-default and must keep Docker Desktop parity visibility labels in its default snapshot path (`windows-containers`, `user-session`, `cdev-surface-windows-gate`).
- `.github/workflows/canary-smoke-tag-hygiene.yml` is the canary smoke tag retention workflow.
- It must run `scripts/Invoke-CanarySmokeTagHygiene.ps1` and enforce deterministic keep-latest behavior for dual-mode canary tags:
  - legacy date-window tags (`v0.YYYYMMDD.N`)
  - SemVer canary tags (`vX.Y.Z-canary.N`)
- Hygiene workflow default mode must be `auto` so both tag families are processed during migration.
- `.github/workflows/ops-autoremediate.yml` is the deterministic remediation workflow and must run `scripts/Invoke-OpsAutoRemediation.ps1`.
- Auto-remediation reason codes must remain explicit:
  - `already_healthy`
  - `remediated`
  - `manual_intervention_required`
  - `no_automatable_action`
  - `remediation_failed`
- `.github/workflows/release-control-plane.yml` is the autonomous release orchestrator and must run `scripts/Invoke-ReleaseControlPlane.ps1`.
- Control-plane mode contract:
  - `Validate`
  - `CanaryCycle`
  - `PromotePrerelease`
  - `PromoteStable`
  - `FullCycle`
- Channel tag windows are deterministic for `v0.YYYYMMDD.N`:
  - canary: `1-49`
  - prerelease: `50-79`
  - stable: `80-99`
- Release-control-plane currently emits legacy date-window tags and must include deterministic migration warnings in execution reports.
- Promotion must gate on source release integrity (required assets + source commit equals branch head).
- `.github/workflows/weekly-ops-slo-report.yml` must publish machine-readable SLO evidence generated by `scripts/Write-OpsSloReport.ps1`.
- `.github/workflows/ops-slo-gate.yml` must enforce deterministic SLO gate policy using `scripts/Invoke-OpsSloSelfHealing.ps1`.
- SLO self-healing reason codes must remain explicit:
  - `already_healthy`
  - `remediated`
  - `auto_remediation_disabled`
  - `remediation_execution_failed`
  - `remediation_verify_failed`
  - `slo_self_heal_runtime_error`
- Underlying SLO evaluator `scripts/Test-OpsSloGate.ps1` reason codes must remain explicit:
  - `workflow_missing_runs`
  - `workflow_failure_detected`
  - `workflow_success_rate_below_threshold`
  - `sync_guard_missing`
  - `sync_guard_stale`
  - `slo_gate_runtime_error`
- `.github/workflows/ops-policy-drift-check.yml` must run `scripts/Test-ReleaseControlPlanePolicyDrift.ps1`.
- Policy drift reason codes must remain explicit:
  - `manifest_missing`
  - `payload_manifest_missing`
  - `release_client_missing`
  - `release_client_drift`
  - `runtime_images_missing`
  - `ops_control_plane_policy_missing`
  - `ops_control_plane_self_healing_missing`
  - `policy_drift_runtime_error`
- `.github/workflows/release-rollback-drill.yml` must run `scripts/Invoke-RollbackDrillSelfHealing.ps1`.
- Rollback self-healing reason codes must remain explicit:
  - `already_ready`
  - `remediated`
  - `auto_remediation_disabled`
  - `no_automatable_action`
  - `remediation_execution_failed`
  - `remediation_verify_failed`
  - `rollback_self_heal_runtime_error`
- Underlying rollback evaluator `scripts/Invoke-ReleaseRollbackDrill.ps1` reason codes must remain explicit:
  - `rollback_candidate_missing`
  - `rollback_assets_missing`
  - `rollback_drill_runtime_error`
- Operational incident handling runbook is `docs/runbooks/release-ops-incident-response.md`.

## Integration Gate Policy
- `.github/workflows/integration-gate.yml` is the integration-branch aggregator workflow.
- It must gate on required contexts: `CI Pipeline`, `Workspace Installer Contract`, `Reproducibility Contract`, `Provenance Contract`.
- Keep this as a distinct check context (`Integration Gate`) for branch-protection phase-in after promotion criteria are met.

## Installer Harness Execution Contract
- `.github/workflows/installer-harness-self-hosted.yml` is the authoritative self-hosted installer harness workflow.
- Trigger path is `integration/*` branch push with `workflow_dispatch` fallback for targeted refs.
- Required runner labels: `self-hosted`, `windows`, `self-hosted-windows-lv`, `installer-harness`.
- Canonical runner roots for this machine:
  - `C:\actions-runner-cdev`
  - `C:\actions-runner-cdev-2`
  - `C:\actions-runner-cdev-harness2`
- Service-runner account remains `NT AUTHORITY\NETWORK SERVICE`; harness jobs may run on the interactive runner label and are validated via `-AllowInteractiveRunner`.
- The workflow must run baseline + machine preflight before executing the installer harness iteration:
  - `scripts/Assert-InstallerHarnessRunnerBaseline.ps1`
  - `scripts/Assert-InstallerHarnessMachinePreflight.ps1`
- Required report artifacts:
  - `iteration-summary.json`
  - `exercise-report.json`
  - `C:\dev-smoke-lvie\artifacts\workspace-install-latest.json`
  - `lvie-cdev-workspace-installer-bundle.zip`
  - `harness-validation-report.json`
- Required post-action pass checks in smoke report:
  - `ppl_capability_checks.32`
  - `ppl_capability_checks.64`
  - `vip_package_build_check`
- Promotion policy: keep `Installer Harness` non-required until 3 consecutive integration green runs and at least 1 workflow_dispatch green run, then promote to required context.

## Local Iteration Contract
- Refine NSIS flow locally first on machines with NSIS installed.
- Use `scripts/Invoke-WorkspaceInstallerIteration.ps1` for repeatable agent runs:
  - `-Mode fast` for quick build/bundle iterations.
  - `-Mode full` for isolated smoke install validation.
  - `-Watch` to auto-rerun on contract file changes without manual restarts.
- Use `scripts/Invoke-DockerDesktopLinuxIteration.ps1 -DockerContext desktop-linux` for Docker Desktop Linux command-surface checks (`runner-cli --help`, `runner-cli ppl --help`) before full Windows LabVIEW image runs.
- Use `scripts/Invoke-WindowsContainerNsisSelfTest.ps1` to build the workspace NSIS installer and run silent install (`/S`) inside the same Windows container with `ContainerSmoke` execution context; this image is aligned to `nationalinstruments/labview:2026q1-windows` and fails fast with `windows_container_mode_required` if Docker is not in Windows container mode.
- Use `scripts/Invoke-LinuxContainerNsisParity.ps1 -DockerContext desktop-linux` for parity checks aligned to `nationalinstruments/labview:2026q1-linux`; this lane compiles NSIS smoke output but does not execute Windows installers on Linux.
- Use `scripts/Invoke-ReleaseControlPlaneLocalDocker.ps1` for local containerized release-control-plane exercise (`Validate` + `DryRun` default).
- Portable ops runtime image hierarchy is required:
  - base image: `ghcr.io/labview-community-ci-cd/labview-cdev-cli-runtime@sha256:0506e8789680ce1c941ca9f005b75d804150aed6ad36a5ac59458b802d358423`
  - derived image: `ghcr.io/labview-community-ci-cd/labview-cdev-surface-ops`
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
