# Self-Hosted Certification Evidence Issue Template

Use this template to drive Codex orchestration from an issue URL.

## Setup Catalog
- legacy-2020-desktop-linux
- legacy-2020-desktop-windows
- host-2026-desktop-linux
- host-2026-desktop-windows

## Desired Outcome
All listed setups complete `self-hosted-machine-certification.yml` with `certified=true`, including a successful MassCompile certification report.

<!-- CERT_CONFIG_START -->
{
  "workflow_file": "self-hosted-machine-certification.yml",
  "ref": "cert/self-hosted-machine-certification-evidence",
  "trigger_mode": "auto",
  "recorder_name": "cdev-certification-recorder",
  "actor_key_strategy": "machine+setup",
  "actor_lock_mode": "fail-closed",
  "require_local_ref_sync": true,
  "required_script_paths": [
    "scripts/Invoke-MachineCertificationFromIssue.ps1",
    "scripts/Start-SelfHostedMachineCertification.ps1",
    "scripts/Assert-InstallerHarnessMachinePreflight.ps1",
    "scripts/Invoke-MassCompileCertification.ps1",
    "scripts/Invoke-EndToEndPortMatrixLocal.ps1"
  ],
  "setup_names": [
    "legacy-2020-desktop-linux",
    "legacy-2020-desktop-windows",
    "host-2026-desktop-linux",
    "host-2026-desktop-windows"
  ]
}
<!-- CERT_CONFIG_END -->

When merged to `main`, change `ref` to `main`.

## Bootstrap (Required)
1. Checkout the repository at `ref` from config before executing any command.
2. Verify local `HEAD` equals the remote head SHA of `ref`.
3. Validate `required_script_paths` exist.
4. Post `CERT_SESSION_START` and detect stale open sessions before dispatch.
5. If any required script is missing, stop and classify as `branch_drift_missing_script`.
6. Do not author replacement scripts from scratch in this flow.
7. Enforce actor lock using `actor_key=<machine>::<setup>` and stop on stale actor sessions/runs when `actor_lock_mode=fail-closed`.
8. If actor lock fails, post explicit stale-session closure comment before rerun:
   - `[cdev-certification-recorder] CERT_SESSION_END id=<stale-session-id>`
   - `- status: reconciled`
   - `- reason: <operator reason>`
9. Ensure upstream runners include setup-specific collision-guard labels and actor-specific labels (`cert-actor-<machine>-<setup>`).
10. Ensure Docker context auto-switch is enabled for each setup (`switch_docker_context=true`).
11. Ensure Docker Desktop auto-start is enabled for each setup (`start_docker_desktop_if_needed=true`).

## Evidence
| Setup | Machine | Run URL | Conclusion | Artifact URL | Certified |
|---|---|---|---|---|---|
| legacy-2020-desktop-linux | pending | pending | pending | pending | pending |
| legacy-2020-desktop-windows | pending | pending | pending | pending | pending |
| host-2026-desktop-linux | pending | pending | pending | pending | pending |
| host-2026-desktop-windows | pending | pending | pending | pending | pending |

## Failure Classification
- runner_label_mismatch
- missing_labview_installation
- docker_context_switch_failed
- docker_context_unreachable
- port_contract_failure
- masscompile_certification_failed
- workflow_dependency_missing
- branch_drift_missing_script
- runner_label_collision_guard_unconfigured
- actor_lock_violation
