# labview-cdev-surface

Canonical governance surface for deterministic `C:\dev` workspace provisioning.

Build and gate lanes run with an always-isolated workspace policy:
- `git-worktree` primary provisioning
- detached-clone fallback
- deterministic root selection (`D:\dev` preferred, `C:\dev` fallback)
- git trust bootstrap via `scripts\Ensure-GitSafeDirectories.ps1` (including worktrees)
- cleanup runs under `if: always()` after artifact upload
- published installer defaults remain unchanged (`ci-only-selector`)

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
- `installer install --mode release`
- `installer upgrade`
- `installer rollback`
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

## Integration gate

`integration-gate.yml` provides a single `Integration Gate` context for:
- `push` to `main` and `integration/*`
- `pull_request` targeting `main` and `integration/*`
- manual dispatch

It polls commit check-runs and only passes when these contexts are successful (or intentionally skipped):
- `CI Pipeline`
- `Workspace Installer Contract`
- `Reproducibility Contract`
- `Provenance Contract`
- `Release Race Hardening Drill`

## Installer harness (self-hosted)

`installer-harness-self-hosted.yml` runs deterministic installer qualification on `self-hosted-windows-lv` with dedicated label `installer-harness` for:
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

Set-Location C:\actions-runner-cdev-harness2
.\config.cmd --url https://github.com/LabVIEW-Community-CI-CD/labview-cdev-surface --token $token --name DESKTOP-6Q81H4O-cdev-surface-harness --labels self-hosted,windows,self-hosted-windows-lv,installer-harness --work _work --unattended --replace
Start-Process -FilePath cmd.exe -ArgumentList '/c run.cmd' -WorkingDirectory C:\actions-runner-cdev-harness2 -WindowStyle Minimized
```

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

## Windows container NSIS self-test

Build the NSIS self-test image (optional) and run a full build + silent install in the same Windows container.
The runtime is aligned to `nationalinstruments/labview:2026q1-windows`:

```powershell
pwsh -NoProfile -File .\scripts\Invoke-WindowsContainerNsisSelfTest.ps1 `
  -BuildLocalImage `
  -Image labview-cdev-surface-nsis-selftest:local
```

This wrapper fails fast with `windows_container_mode_required` unless Docker reports `OSType=windows`.
The runtime stages manifest-pinned `cdev-cli` assets before building the installer, then executes the installer in silent mode (`/S`) inside the same container.

Outputs are written under:
- `artifacts\release\windows-container-nsis-selftest`
- `container-report.json`
- `windows-container-nsis-selftest-report.json`

Publish the Windows parity image to GHCR with deterministic tags and pre-publish silent-install gating:
- Workflow: `.github/workflows/publish-windows-nsis-parity-image.yml`
- Trigger mode: manual `workflow_dispatch` (publish contract is still validated by hosted-runner CI)
- Image repo: `ghcr.io/labview-community-ci-cd/labview-cdev-surface-nsis-windows-parity`
- Default tags: `sha-<12-char-commit>`, `2026q1-windows-<yyyymmdd>`
- Optional manual tags: `latest` (`promote_latest=true`) and `additional_tag`

## Linux NSIS parity container

Use the Linux parity runtime aligned to `nationalinstruments/labview:2026q1-linux`:

```powershell
pwsh -NoProfile -File .\scripts\Invoke-LinuxContainerNsisParity.ps1 `
  -BuildLocalImage `
  -Image labview-cdev-surface-nsis-linux-parity:local `
  -DockerContext desktop-linux
```

This lane validates Linux toolchain parity (`labviewcli`, `pwsh`, `dotnet`, `git`, `makensis`) and compiles a minimal NSIS smoke installer.
Installer execution is intentionally skipped on Linux (`windows_installer_not_executable_on_linux`).
The parity image uses an apt-driven dependency model aligned to NI's Linux custom-image guidance (`labview-for-containers/docs/linux-custom-images.md`).

Publish the Linux parity image to GHCR with deterministic tags:
- Workflow: `.github/workflows/publish-linux-nsis-parity-image.yml`
- Image repo: `ghcr.io/labview-community-ci-cd/labview-cdev-surface-nsis-linux-parity`
- Default tags: `sha-<12-char-commit>`, `2026q1-linux-<yyyymmdd>`
- Optional manual tags: `latest` (`promote_latest=true`) and `additional_tag`

## Publish Release (Automated Gate)

Use manual workflow dispatch for release publication:
1. Run `.github/workflows/release-with-windows-gate.yml`.
2. Provide a new `release_tag`:
   - Preferred SemVer: `vX.Y.Z` (stable), `vX.Y.Z-rc.N` (prerelease), `vX.Y.Z-canary.N` (canary).
   - Legacy migration compatibility: `v0.YYYYMMDD.N`.
3. Keep `allow_existing_tag=false` (default). Set `true` only for break-glass overwrite operations.
4. Set `prerelease` to match the tag family (`true` for prerelease/canary tags, `false` for stable tags).
5. Keep `allow_gate_override=false` (default).
6. Set `release_channel` explicitly for canary tags (`canary`) to satisfy channel/tag consistency checks.

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
- Signs installer when signing certificate secrets are configured.
- Computes SHA256.
- Runs determinism gates and fails on hash drift.
- Generates `workspace-installer.spdx.json` and `workspace-installer.slsa.json`.
- Generates `release-manifest.json`.
- Creates the GitHub release if missing and binds the tag to the exact workflow commit SHA.
- Uploads installer + SHA + provenance + reproducibility + `release-manifest.json` assets to the release.
- Writes release notes including SHA256 and the install command:

```powershell
lvie-cdev-workspace-installer.exe /S
```

Verify downloaded asset integrity by matching the local hash against the SHA256 value published in the release notes.
Tag immutability policy: existing release tags fail by default to prevent mutable release history.
Fallback entrypoint: `.github/workflows/release-workspace-installer.yml` (wrapper to `_release-workspace-installer-core.yml`).

## Install from Upstream Release (Release Client)

Use the release client runtime for one-command install/upgrade/rollback from release assets:

```powershell
pwsh -NoProfile -File .\scripts\Install-WorkspaceInstallerFromRelease.ps1 `
  -Mode Install `
  -Channel stable
```

Install a specific release tag:

```powershell
pwsh -NoProfile -File .\scripts\Install-WorkspaceInstallerFromRelease.ps1 `
  -Mode Install `
  -Tag v0.1.1
```

Upgrade from the current state file to latest stable:

```powershell
pwsh -NoProfile -File .\scripts\Install-WorkspaceInstallerFromRelease.ps1 `
  -Mode Upgrade `
  -Channel stable
```

Rollback to previous release state:

```powershell
pwsh -NoProfile -File .\scripts\Install-WorkspaceInstallerFromRelease.ps1 `
  -Mode Rollback `
  -RollbackTo previous
```

Validate local release policy file:

```powershell
pwsh -NoProfile -File .\scripts\Install-WorkspaceInstallerFromRelease.ps1 `
  -Mode ValidatePolicy
```

Release client contract paths:
- Policy: `C:\dev\workspace-governance\release-policy.json`
- State: `C:\dev\artifacts\workspace-release-state.json`
- Latest report: `C:\dev\artifacts\workspace-release-client-latest.json`

Default allowed installer release repositories:
- `LabVIEW-Community-CI-CD/labview-cdev-surface`
- `svelderrainruiz/labview-cdev-surface`

Fork/upstream cdev-cli synchronization policy starts with full sync metadata:
- Primary CLI repo: `svelderrainruiz/labview-cdev-cli`
- Mirror repo: `LabVIEW-Community-CI-CD/labview-cdev-cli`
- Strategy: `fork-and-upstream-full-sync`

Runtime image metadata is codified in `installer_contract.release_client.runtime_images`:
- cdev-cli runtime canonical repository: `ghcr.io/labview-community-ci-cd/labview-cdev-cli-runtime`
- cdev-cli runtime source repo/commit: `LabVIEW-Community-CI-CD/labview-cdev-cli` @ `8fef6f9192d81a14add28636c1100c109ae5e977`
- cdev-cli runtime digest: `sha256:0506e8789680ce1c941ca9f005b75d804150aed6ad36a5ac59458b802d358423`
- ops runtime repository: `ghcr.io/labview-community-ci-cd/labview-cdev-surface-ops`
- ops runtime base repository/digest: `ghcr.io/labview-community-ci-cd/labview-cdev-cli-runtime@sha256:0506e8789680ce1c941ca9f005b75d804150aed6ad36a5ac59458b802d358423`

Release channel metadata can be set during publish with workflow input `release_channel` (`stable`, `prerelease`, `canary`).

## Ops monitoring and hygiene

`ops-monitoring.yml` is scheduled hourly and supports manual dispatch. It runs `scripts/Invoke-OpsMonitoringSnapshot.ps1` and fails on:
- runner availability drift (`runner_unavailable`)
- cdev-cli sync-guard drift/failure (`sync_guard_failed`, `sync_guard_stale`, `sync_guard_missing`, `sync_guard_incomplete`)

Control-plane runner health is intentionally decoupled from Docker Desktop parity labels:
- `scripts/Invoke-ReleaseControlPlane.ps1` and `scripts/Invoke-OpsAutoRemediation.ps1` call ops monitoring with release-runner labels only (`self-hosted`, `windows`, `self-hosted-windows-lv`).
- `ops-monitoring.yml` keeps strict defaults for Docker Desktop Windows gate visibility (`self-hosted`, `windows`, `self-hosted-windows-lv`, `windows-containers`, `user-session`, `cdev-surface-windows-gate`).

Incident lifecycle is deterministic and shared by ops workflows via `scripts/Invoke-OpsIncidentLifecycle.ps1`:
- failure: create/reopen/comment the workflow-specific incident issue
- recovery: comment and close the open incident issue

Every run uploads `ops-monitoring-report.json`.

`canary-smoke-tag-hygiene.yml` is scheduled daily and supports manual dispatch. It runs `scripts/Invoke-CanarySmokeTagHygiene.ps1` in dual-mode:
- `legacy_date_window`: keeps latest `v0.YYYYMMDD.N` canary smoke tag(s) for the selected UTC date.
- `semver`: keeps latest SemVer canary tags (`vX.Y.Z-canary.N`).
- `auto` (default): applies both policies in one deterministic pass.

`ops-autoremediate.yml` is scheduled hourly and supports manual dispatch. It runs `scripts/Invoke-OpsAutoRemediation.ps1` to:
- auto-dispatch and verify cdev-cli sync-guard when sync drift is detected
- re-evaluate health after remediation
- fail with deterministic reason codes when manual intervention is still required

`release-control-plane.yml` is the autonomous orchestrator. It runs `scripts/Invoke-ReleaseControlPlane.ps1` with modes:
- `CanaryCycle`
- `PromotePrerelease`
- `PromoteStable`
- `FullCycle`
- `Validate`

Control-plane behavior:
1. Runs ops health gate and optional auto-remediation.
2. Dispatches release workflow with deterministic SemVer channel tags:
   - canary: `vX.Y.Z-canary.N`
   - prerelease: `vX.Y.Z-rc.N` (promoted from latest semver canary)
   - stable: `vX.Y.Z` (promoted from latest semver prerelease during policy window)
3. Verifies run completion and promotion source integrity (`assets + source commit == branch head`).
4. Performs post-dispatch release verification (`required assets + release-manifest channel/tag/provenance checks`).
5. Verifies promotion lineage for `PromotePrerelease` and `PromoteStable` (`source/target channel + SemVer core + commit SHA`).
6. Applies canary smoke tag hygiene with `tag_family=semver` after canary publish.
7. Reads SemVer gate policy from `installer_contract.release_client.ops_control_plane_policy.tag_strategy.semver_only_enforce_utc` (default `2026-07-01T00:00:00Z`).
8. Reads stable promotion window policy from `installer_contract.release_client.ops_control_plane_policy.stable_promotion_window` (default: full-cycle Mondays only, override allowed with audited reason).
9. Supports manual emergency override for FullCycle stable promotion via workflow_dispatch inputs:
   - `force_stable_promotion_outside_window=true`
   - `force_stable_promotion_reason=<structured reason with ticket/change reference, validated by policy regex>`
10. Emits explicit override audit artifact `release-control-plane-override-audit.json` for every run.
11. Auto-opens incident title `Release Control Plane Stable Override Alert` whenever decision code is `stable_window_override_applied`.
12. Emits deterministic migration warnings when legacy `v0.YYYYMMDD.N` tags are still present before the gate and fails with `semver_only_enforcement_violation` after the gate.

Top-level release-control-plane deterministic failure reason codes include:
- `ops_health_gate_failed`
- `ops_unhealthy`
- `promotion_source_missing`
- `promotion_source_not_prerelease`
- `promotion_source_asset_missing`
- `promotion_source_not_at_head`
- `promotion_lineage_invalid`
- `stable_window_override_invalid`
- `release_dispatch_watch_failed`
- `release_verification_failed`
- `canary_hygiene_failed`
- `semver_only_enforcement_violation`
- `control_plane_runtime_error`

`weekly-ops-slo-report.yml` emits machine-readable weekly SLO evidence via `scripts/Write-OpsSloReport.ps1`.

`ops-slo-gate.yml` is scheduled daily and supports manual dispatch. It runs `scripts/Invoke-OpsSloSelfHealing.ps1` to enforce:
- 7-day lookback by default
- 100% success-rate target for `ops-monitoring`, `ops-autoremediate`, and `release-control-plane`
- max sync-guard success age of 12 hours
- bounded self-healing by dispatching `ops-autoremediate.yml` and re-verifying SLO status
- deterministic reason codes on failure:
  - `auto_remediation_disabled`
  - `remediation_verify_failed`
  - `slo_self_heal_runtime_error`

Underlying SLO evaluator `scripts/Test-OpsSloGate.ps1` still emits deterministic `reason_codes`:
- `workflow_missing_runs`
- `workflow_failure_detected`
- `workflow_success_rate_below_threshold`
- `sync_guard_missing`
- `sync_guard_stale`

`ops-policy-drift-check.yml` is scheduled hourly and supports manual dispatch. It runs `scripts/Test-ReleaseControlPlanePolicyDrift.ps1` and fails on:
- root/payload release-client policy drift
- missing runtime image metadata
- missing control-plane policy metadata
- deterministic reason codes on failure:
  - `release_client_drift`
  - `runtime_images_missing`
  - `ops_control_plane_policy_missing`
  - `ops_control_plane_self_healing_missing`
  - `ops_control_plane_guardrails_missing`
  - `ops_control_plane_stable_window_missing`
  - `ops_control_plane_stable_window_reason_pattern_missing`
  - `ops_control_plane_stable_window_reason_example_missing`

`release-rollback-drill.yml` is scheduled daily and supports manual dispatch. It runs `scripts/Invoke-RollbackDrillSelfHealing.ps1` to validate deterministic rollback readiness:
- channel-scoped latest/previous release candidates
- required release assets for rollback safety (`installer`, `.sha256`, `reproducibility-report.json`, SPDX/SLSA, `release-manifest.json`)
- bounded self-healing for `rollback_candidate_missing` by dispatching one canary release and re-verifying rollback readiness
- deterministic reason codes on failure:
  - `auto_remediation_disabled`
  - `no_automatable_action`
  - `remediation_verify_failed`
  - `rollback_self_heal_runtime_error`

Underlying rollback evaluator `scripts/Invoke-ReleaseRollbackDrill.ps1` still emits deterministic `reason_codes`:
- `rollback_candidate_missing`
- `rollback_assets_missing`

`release-race-hardening-drill.yml` runs on:
- weekly schedule
- manual dispatch

It runs `scripts/Invoke-ReleaseRaceHardeningDrill.ps1` to prove release-tag collision handling under parallel dispatch pressure:
- dispatches a contender `release-workspace-installer.yml` run at predicted next SemVer canary tag
- dispatches `release-control-plane.yml` in `CanaryCycle` mode immediately after
- watches both runs and downloads `release-control-plane-report-<run_id>` artifact
- requires collision evidence in control-plane execution (`collision_retries >= 1` and/or collision attempt statuses)
- requires release verification evidence from control-plane report (`release_verification.status=pass`)
- deterministic failure reason codes include:
  - `control_plane_collision_not_observed`
  - `control_plane_report_download_failed`
  - `control_plane_report_missing`
  - `control_plane_run_failed`

Operational behavior:
- uploads `release-race-hardening-drill-report.json`
- emits weekly-review artifact `release-race-hardening-weekly-summary.json`
- uses incident lifecycle automation (`Invoke-OpsIncidentLifecycle.ps1`) with issue title `Release Race Hardening Drill Alert` on failure/recovery

`release-race-hardening-gate.yml` provides the required branch-protection context (`Release Race Hardening Drill`) for:
- `push` to `main` and `integration/*`
- `pull_request` targeting `main` and `integration/*`

It runs `scripts/Test-ReleaseRaceHardeningGate.ps1` and fails when:
- no recent successful drill run exists
- latest drill report is missing or not `reason_code=drill_passed`
- latest drill report does not include collision evidence

`branch-protection-drift-check.yml` continuously validates release branch-protection policy via `scripts/Test-ReleaseBranchProtectionPolicy.ps1` and reports drift for:
- `main`
- `integration/*`

Use `scripts/Set-ReleaseBranchProtectionPolicy.ps1` to deterministically apply/repair required check contracts.
Branch-protection workflows prefer `WORKFLOW_BOT_TOKEN` when available and deterministically fall back to `github.token`.

`release-guardrails-autoremediate.yml` is scheduled hourly and supports manual dispatch. It runs `scripts/Invoke-ReleaseGuardrailsSelfHealing.ps1` to:
- evaluate branch-protection drift and release race-hardening freshness in one pass
- auto-apply branch-protection policy via `Set-ReleaseBranchProtectionPolicy.ps1` when mismatch/missing rules are detected
- auto-dispatch `release-race-hardening-drill.yml` when drill freshness is missing or stale, then re-verify gate health
- fail with deterministic reason codes:
  - `already_healthy`
  - `remediated`
  - `auto_remediation_disabled`
  - `no_automatable_action`
  - `remediation_execution_failed`
  - `remediation_verify_failed`
  - `guardrails_self_heal_runtime_error`

Guardrails policy is codified in `installer_contract.release_client.ops_control_plane_policy.self_healing.guardrails`:
- `remediation_workflow`
- `race_drill_workflow`
- `watch_timeout_minutes`
- `verify_after_remediation`
- `race_gate_max_age_hours`

Incident lifecycle title for this lane is `Release Guardrails Auto-Remediation Alert`.

## Local Docker package for control-plane exercise

Run the local Docker harness (safe default, validate + dry-run):

```powershell
pwsh -NoProfile -File .\scripts\Invoke-ReleaseControlPlaneLocalDocker.ps1 `
  -Repository LabVIEW-Community-CI-CD/labview-cdev-surface-fork `
  -Branch main `
  -Mode Validate `
  -DryRun `
  -RunContractTests
```

This executes `scripts/Exercise-ReleaseControlPlaneLocal.ps1` in the portable ops container image and writes artifacts under:
- `artifacts\release-control-plane-local`
- Default container image: `ghcr.io/labview-community-ci-cd/labview-cdev-surface-ops:v1`
- 2-image hierarchy:
  - Base: `ghcr.io/labview-community-ci-cd/labview-cdev-cli-runtime@sha256:0506e8789680ce1c941ca9f005b75d804150aed6ad36a5ac59458b802d358423`
  - Derived ops runtime: `ghcr.io/labview-community-ci-cd/labview-cdev-surface-ops`

For offline or container runtime fallback on the host:
- add `-HostFallback`

## Publish Ops Runtime Image

`publish-ops-runtime-image.yml` publishes the portable ops runtime container to:
- `ghcr.io/labview-community-ci-cd/labview-cdev-surface-ops`

Deterministic tags:
- `sha-<12-char-commit>`
- `v1-YYYYMMDD`
- `v1` (when `promote_v1=true`)

Ops runtime build policy:
- Base image is digest-pinned to canonical cdev-cli runtime:
  - `ghcr.io/labview-community-ci-cd/labview-cdev-cli-runtime@sha256:0506e8789680ce1c941ca9f005b75d804150aed6ad36a5ac59458b802d358423`
- Canonical consumer path remains org namespace:
  - `ghcr.io/labview-community-ci-cd/labview-cdev-surface-ops`

Manual publish:

```powershell
gh workflow run publish-ops-runtime-image.yml `
  -R LabVIEW-Community-CI-CD/labview-cdev-surface-fork `
  -f promote_v1=true
```

Runbook for incidents:
- `docs/runbooks/release-ops-incident-response.md`

## Nightly canary

`nightly-supplychain-canary.yml` runs on a nightly schedule and on demand. It executes:
1. Docker Desktop Linux iteration (`desktop-linux` context).
2. Runner-cli determinism checks (`win-x64` and `linux-x64`).
3. Installer determinism check.

On failure, it updates a single tracking issue (`Nightly Supply-Chain Canary Failure`) with the failing run link.

## Windows LabVIEW image gate

`windows-labview-image-gate.yml` is dispatch-only and wraps `./.github/workflows/_windows-labview-image-gate-core.yml` for standalone diagnostics.  
The core gate requires the runner to already be in Windows container mode (non-interactive CI does not switch Docker engine), validates host/image OS-version compatibility via `docker manifest inspect --verbose`, then pulls `nationalinstruments/labview:2026q1-windows` by default (override with repo variable `LABVIEW_WINDOWS_IMAGE`), installs the NSIS workspace installer in-container, runs bundled `runner-cli ppl build` and `runner-cli vip build`, and verifies PPL + VIP output presence.
The core gate is pinned to dedicated labels so it runs only on the intended user-session runner lane: `self-hosted`, `windows`, `self-hosted-windows-lv`, `windows-containers`, `user-session`, `cdev-surface-windows-gate`.
Isolation behavior is controlled by `LABVIEW_WINDOWS_DOCKER_ISOLATION`:
1. `auto` (default): process isolation when host/image OS versions match, automatic Hyper-V fallback on mismatch.
2. `process`: strict process isolation only (mismatch fails).
3. `hyperv`: force Hyper-V isolation.

### Windows feature troubleshooting reporting

When validating `Microsoft-Hyper-V` and `Containers` feature setup for Docker Desktop:
1. Classify `Enable-WindowsOptionalFeature ... -NoRestart` warning output as informational.
2. Verify features with a per-feature loop (single `-FeatureName` per call), not by passing an array directly.
3. Emit these explicit reporting fields: `features_enabled`, `reboot_pending`, `docker_daemon_ready`.
