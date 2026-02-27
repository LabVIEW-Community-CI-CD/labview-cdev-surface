# Release Ops Incident Response Runbook

## Purpose
Deterministic operator response for Scope A hardening controls:
- runner availability monitoring
- cdev-cli fork/upstream sync-guard monitoring
- canary smoke tag hygiene
- SLO gate enforcement
- policy drift detection
- rollback drill readiness

## Inputs
- Surface repository: `LabVIEW-Community-CI-CD/labview-cdev-surface-fork`
- Sync-guard repository: `LabVIEW-Community-CI-CD/labview-cdev-cli`
- Runner root (service mode): `D:\dev\gh-runner-surface-fork`

## Triage
1. Open latest `ops-monitoring` run and inspect `ops-monitoring-report-<run_id>` artifact.
2. Read `reason_codes`.
3. Execute remediation by reason code.
4. If remediation is automatable, dispatch `ops-autoremediate.yml` first and re-check health.
5. Incident issue lifecycle is automated (`create/reopen/comment` on failure, `comment/close` on recovery) by `scripts/Invoke-OpsIncidentLifecycle.ps1`.

Reason code mapping:
- `runner_unavailable`: no online self-hosted runner matched required labels.
- `sync_guard_failed`: latest completed cdev-cli sync-guard run failed.
- `sync_guard_stale`: latest successful sync-guard run exceeded max-age policy.
- `sync_guard_missing`: no sync-guard run found for branch.
- `sync_guard_incomplete`: only in-progress/queued runs exist; no completed run yet.
- `promotion_lineage_invalid`: promotion source/target channel, SemVer core, or commit-SHA lineage check failed.
- `stable_window_override_invalid`: requested stable override violated stable window policy (override disabled, missing reason, reason too short, or reason format mismatch).
- `release_dispatch_report_invalid`: release dispatch metadata was incomplete (for example, missing dispatched `run_id`).
- `release_dispatch_watch_timeout`: dispatched release run did not complete before the configured watch timeout.
- `release_dispatch_watch_failed`: release workflow dispatch completed but run conclusion was not `success`.
- `release_verification_failed`: post-dispatch release verification failed (missing assets or invalid `release-manifest.json` metadata).
- `canary_hygiene_failed`: SemVer canary retention cleanup failed after publish.
- `semver_only_enforcement_violation`: legacy date-window tags still present after SemVer-only enforcement gate.

## Runner Unavailable Remediation
1. Verify repository runner state:

```powershell
gh api repos/LabVIEW-Community-CI-CD/labview-cdev-surface-fork/actions/runners `
  --jq '.runners[] | {name,status,busy,labels:(.labels|map(.name))}'
```

2. On runner host, verify service is running and automatic:

```powershell
Get-Service -Name 'actions.runner.LabVIEW-Community-CI-CD-labview-cdev-surface-fork*' |
  Select-Object Name, Status, StartType
```

3. If stopped, restart:

```powershell
Start-Service -Name 'actions.runner.LabVIEW-Community-CI-CD-labview-cdev-surface-fork*'
```

4. Re-run `ops-monitoring` by dispatch and confirm pass.

## Sync Guard Drift Remediation
1. Dispatch upstream sync guard:

```powershell
gh workflow run fork-upstream-sync-guard --repo LabVIEW-Community-CI-CD/labview-cdev-cli
```

2. Watch result:

```powershell
gh run list --repo LabVIEW-Community-CI-CD/labview-cdev-cli --workflow fork-upstream-sync-guard --limit 1
```

3. If failed due fork/upstream drift, run controlled force-align from cdev-cli repo:

```powershell
Set-Location D:\dev\labview-cdev-cli
pwsh -File .\scripts\Invoke-ControlledForkForceAlign.ps1
```

4. Re-check parity:

```powershell
gh api repos/LabVIEW-Community-CI-CD/labview-cdev-cli/commits/main --jq .sha
gh api repos/svelderrainruiz/labview-cdev-cli/commits/main --jq .sha
```

5. Dispatch auto-remediation workflow (preferred control-plane path):

```powershell
gh workflow run ops-autoremediate.yml -R LabVIEW-Community-CI-CD/labview-cdev-surface-fork
```

## Canary Smoke Tag Hygiene Remediation
Keep latest only for one UTC date key (`YYYYMMDD`):

```powershell
Set-Location D:\dev\labview-cdev-surface-fork
pwsh -File .\scripts\Invoke-CanarySmokeTagHygiene.ps1 `
  -Repository LabVIEW-Community-CI-CD/labview-cdev-surface-fork `
  -DateUtc 20260226 `
  -KeepLatestN 1 `
  -Delete
```

Dry-run before deletion:

```powershell
pwsh -File .\scripts\Invoke-CanarySmokeTagHygiene.ps1 `
  -Repository LabVIEW-Community-CI-CD/labview-cdev-surface-fork `
  -DateUtc 20260226 `
  -KeepLatestN 1
```

## Autonomous Control Plane Dispatch
Run full autonomous cycle manually:

```powershell
gh workflow run release-control-plane.yml -R LabVIEW-Community-CI-CD/labview-cdev-surface-fork `
  -f mode=FullCycle `
  -f auto_remediate=true `
  -f dry_run=false
```

Force stable promotion outside window (audited emergency path):

```powershell
gh workflow run release-control-plane.yml -R LabVIEW-Community-CI-CD/labview-cdev-surface-fork `
  -f mode=FullCycle `
  -f force_stable_promotion_outside_window=true `
  -f force_stable_promotion_reason="CHG-1234: emergency promotion after incident remediation" `
  -f auto_remediate=true `
  -f dry_run=false
```

Out-of-window override automatically opens incident title `Release Control Plane Stable Override Alert` and uploads `release-control-plane-override-audit.json`.

Run validation-only health/policy gate:

```powershell
gh workflow run release-control-plane.yml -R LabVIEW-Community-CI-CD/labview-cdev-surface-fork `
  -f mode=Validate `
  -f dry_run=true
```

## Release Verification Failure Remediation
Use this when `reason_code=release_verification_failed` from `release-control-plane`.

1. Download control-plane report and capture target tag:

```powershell
gh run download <release_control_plane_run_id> `
  -R LabVIEW-Community-CI-CD/labview-cdev-surface-fork `
  -D .\tmp-rcp-report
Get-Content .\tmp-rcp-report\release-control-plane-report-<run_id>\release-control-plane-report.json -Raw
```

2. Verify release asset contract for the failed tag:

```powershell
gh release view <tag> -R LabVIEW-Community-CI-CD/labview-cdev-surface-fork `
  --json tagName,isPrerelease,publishedAt,targetCommitish,assets,url
```

3. Verify `release-manifest.json` fields:

```powershell
gh release download <tag> -R LabVIEW-Community-CI-CD/labview-cdev-surface-fork `
  -p release-manifest.json -D .\tmp-release-manifest
Get-Content .\tmp-release-manifest\release-manifest.json -Raw
```

Expected minimum:
- `release_tag` equals `<tag>`
- `channel` matches release-control-plane mode/channel
- `provenance.assets` contains:
  - `workspace-installer.spdx.json`
  - `workspace-installer.slsa.json`
  - `reproducibility-report.json`

4. Re-run canary cycle after remediation:

```powershell
gh workflow run release-control-plane.yml -R LabVIEW-Community-CI-CD/labview-cdev-surface-fork `
  -f mode=CanaryCycle `
  -f auto_remediate=true `
  -f dry_run=false
```

## SLO Gate Dispatch
Run strict SLO gate with default 7-day window:

```powershell
gh workflow run ops-slo-gate.yml -R LabVIEW-Community-CI-CD/labview-cdev-surface-fork
```

The workflow runs bounded self-healing by default. Disable it for diagnostics:

```powershell
gh workflow run ops-slo-gate.yml -R LabVIEW-Community-CI-CD/labview-cdev-surface-fork `
  -f auto_self_heal=false
```

Run with explicit thresholds:

```powershell
gh workflow run ops-slo-gate.yml -R LabVIEW-Community-CI-CD/labview-cdev-surface-fork `
  -f lookback_days=7 `
  -f min_success_rate_pct=100 `
  -f sync_guard_max_age_hours=12 `
  -f warning_min_success_rate_pct=99.5 `
  -f critical_min_success_rate_pct=99
```

SLO report severity fields:
- `alert_severity` (`none|warning|critical`)
- `alert_thresholds.warning_min_success_rate_pct`
- `alert_thresholds.critical_min_success_rate_pct`
- `alert_thresholds.warning_reason_codes`
- `alert_thresholds.critical_reason_codes`

## Policy Drift Check Dispatch
Run control-plane policy drift check:

```powershell
gh workflow run ops-policy-drift-check.yml -R LabVIEW-Community-CI-CD/labview-cdev-surface-fork
```

## Rollback Drill Dispatch
Run deterministic rollback drill on canary lane:

```powershell
gh workflow run release-rollback-drill.yml -R LabVIEW-Community-CI-CD/labview-cdev-surface-fork `
  -f channel=canary `
  -f required_history_count=2
```

The workflow performs bounded self-healing by default for `rollback_candidate_missing` by dispatching one canary release and then re-checking rollback readiness. Disable for diagnostics:

```powershell
gh workflow run release-rollback-drill.yml -R LabVIEW-Community-CI-CD/labview-cdev-surface-fork `
  -f channel=canary `
  -f required_history_count=2 `
  -f auto_self_heal=false
```

## Release Race-Hardening Drill Dispatch
Run collision-retry verification drill on the canary release lane:

```powershell
gh workflow run release-race-hardening-drill.yml -R LabVIEW-Community-CI-CD/labview-cdev-surface-fork `
  -f auto_remediate=true `
  -f keep_latest_canary_n=1 `
  -f watch_timeout_minutes=120
```

Run the same drill directly from the repo:

```powershell
Set-Location D:\dev\labview-cdev-surface-fork
pwsh -File .\scripts\Invoke-ReleaseRaceHardeningDrill.ps1 `
  -Repository LabVIEW-Community-CI-CD/labview-cdev-surface-fork `
  -Branch main `
  -AutoRemediate:$true `
  -KeepLatestCanaryN 1 `
  -WatchTimeoutMinutes 120
```

Expected pass evidence in `release-race-hardening-drill-report.json`:
- `reason_code=drill_passed`
- `evidence.collision_observed=true`
- `evidence.collision_signals` includes at least one collision marker (`collision_retries_ge_1`, `attempt_status_collision_*`, or `dispatch_status_collision_*`)
- `artifacts.control_plane_report_artifact` is `release-control-plane-report-<run_id>`
- `evidence.release_verification_status=pass`

Deterministic drill failure reason codes:
- `control_plane_collision_not_observed`
- `control_plane_report_download_failed`
- `control_plane_report_missing`
- `control_plane_run_failed`
- incident title on failure/recovery: `Release Race Hardening Drill Alert`

Weekly summary artifact review:

```powershell
gh run list -R LabVIEW-Community-CI-CD/labview-cdev-surface-fork `
  --workflow release-race-hardening-drill.yml `
  --limit 1

gh run download <release_race_hardening_run_id> `
  -R LabVIEW-Community-CI-CD/labview-cdev-surface-fork `
  -n release-race-hardening-weekly-summary-<run_id> `
  -D .\tmp-race-hardening-summary

Get-Content .\tmp-race-hardening-summary\release-race-hardening-weekly-summary.json -Raw
```

## Release Race-Hardening Gate Verification
This gate provides required check context `Release Race Hardening Drill` for `main` and `integration/*` PR/push lanes.

Manual gate dispatch:

```powershell
gh workflow run release-race-hardening-gate.yml -R LabVIEW-Community-CI-CD/labview-cdev-surface-fork `
  -f source_branch=main `
  -f max_age_hours=168
```

Local gate check:

```powershell
Set-Location D:\dev\labview-cdev-surface-fork
pwsh -File .\scripts\Test-ReleaseRaceHardeningGate.ps1 `
  -Repository LabVIEW-Community-CI-CD/labview-cdev-surface-fork `
  -SourceBranch main `
  -MaxAgeHours 168
```

Expected gate failure reason codes include:
- `drill_run_missing`
- `drill_run_stale`
- `drill_reason_code_invalid`
- `drill_collision_evidence_missing`

## Branch Protection Drift + Apply
Continuous drift monitor:

```powershell
gh workflow run branch-protection-drift-check.yml -R LabVIEW-Community-CI-CD/labview-cdev-surface-fork
```

Token policy for branch-protection workflows:
- require repository secret `WORKFLOW_BOT_TOKEN`
- workflows fail fast with `workflow_bot_token_missing` when the secret is unavailable
- token must include repository administration permissions for branch-protection GraphQL read/apply operations

Branch-protection query failure reason codes:
- `branch_protection_query_failed`
- `branch_protection_authentication_missing`
- `branch_protection_authz_denied`

Local policy verify:

```powershell
pwsh -File .\scripts\Test-ReleaseBranchProtectionPolicy.ps1 `
  -Repository LabVIEW-Community-CI-CD/labview-cdev-surface-fork
```

Deterministic apply/repair:

```powershell
pwsh -File .\scripts\Set-ReleaseBranchProtectionPolicy.ps1 `
  -Repository LabVIEW-Community-CI-CD/labview-cdev-surface-fork
```

Branch-protection drift incident title:
- `Branch Protection Drift Alert`

## Release Guardrails Auto-Remediation
Dispatch autonomous guardrails remediation:

```powershell
gh workflow run release-guardrails-autoremediate.yml -R LabVIEW-Community-CI-CD/labview-cdev-surface-fork `
  -f race_gate_max_age_hours=168 `
  -f auto_self_heal=true `
  -f max_attempts=1 `
  -f drill_watch_timeout_minutes=120
```

Run the same remediation path locally:

```powershell
Set-Location D:\dev\labview-cdev-surface-fork
pwsh -File .\scripts\Invoke-ReleaseGuardrailsSelfHealing.ps1 `
  -Repository LabVIEW-Community-CI-CD/labview-cdev-surface-fork `
  -Branch main `
  -RaceGateMaxAgeHours 168 `
  -AutoSelfHeal:$true `
  -MaxAttempts 1 `
  -DrillWatchTimeoutMinutes 120
```

Deterministic guardrails reason codes:
- `already_healthy`
- `remediated`
- `auto_remediation_disabled`
- `no_automatable_action`
- `remediation_execution_failed`
- `remediation_verify_failed`
- `guardrails_self_heal_runtime_error`

When `reason_code=no_automatable_action` or `reason_code=remediation_verify_failed`, inspect `remediation_hints` in `release-guardrails-autoremediate-report.json` for deterministic next actions.

Guardrails incident title:
- `Release Guardrails Auto-Remediation Alert`

## Workflow Bot Token Drill
Dispatch token-health drill:

```powershell
gh workflow run workflow-bot-token-drill.yml -R LabVIEW-Community-CI-CD/labview-cdev-surface-fork
```

Deterministic token drill reason codes:
- `token_missing`
- `token_invalid`
- `token_scope_insufficient`
- `token_health_runtime_error`

Token drill incident title:
- `Workflow Bot Token Health Alert`

## Evidence to Attach to Incident
- `ops-monitoring-report.json`
- `canary-smoke-tag-hygiene-report.json`
- `release-control-plane-override-audit.json` (when override is requested/applied)
- `release-race-hardening-drill-report.json`
- `release-race-hardening-weekly-summary.json`
- `release-race-hardening-gate-report.json`
- `branch-protection-drift-report.json`
- `release-guardrails-autoremediate-report.json`
- `workflow-bot-token-drill-report.json`
- sync guard run URL
- parity SHAs (upstream and fork)
