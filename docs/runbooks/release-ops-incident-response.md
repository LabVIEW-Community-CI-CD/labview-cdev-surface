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
  -f sync_guard_max_age_hours=12
```

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

## Evidence to Attach to Incident
- `ops-monitoring-report.json`
- `canary-smoke-tag-hygiene-report.json`
- sync guard run URL
- parity SHAs (upstream and fork)
