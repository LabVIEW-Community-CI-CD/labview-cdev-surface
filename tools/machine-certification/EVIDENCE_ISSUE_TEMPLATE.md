# Self-Hosted Certification Evidence Issue Template

Use this template to drive Codex orchestration from an issue URL.

## Setup Catalog
- legacy-2020-desktop-linux
- legacy-2020-desktop-windows

## Desired Outcome
All listed setups complete `self-hosted-machine-certification.yml` with `certified=true`.

<!-- CERT_CONFIG_START -->
{
  "workflow_file": "self-hosted-machine-certification.yml",
  "ref": "cert/self-hosted-machine-certification-evidence",
  "trigger_mode": "auto",
  "recorder_name": "cdev-certification-recorder",
  "require_local_ref_sync": true,
  "required_script_paths": [
    "scripts/Invoke-MachineCertificationFromIssue.ps1",
    "scripts/Start-SelfHostedMachineCertification.ps1",
    "scripts/Assert-InstallerHarnessMachinePreflight.ps1",
    "scripts/Invoke-EndToEndPortMatrixLocal.ps1"
  ],
  "setup_names": [
    "legacy-2020-desktop-linux",
    "legacy-2020-desktop-windows"
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
7. Ensure upstream runners include setup-specific collision-guard labels.
8. Ensure Docker context auto-switch is enabled for each setup (`switch_docker_context=true`).
9. Ensure Docker Desktop auto-start is enabled for each setup (`start_docker_desktop_if_needed=true`).

## Evidence
| Setup | Machine | Run URL | Conclusion | Artifact URL | Certified |
|---|---|---|---|---|---|
| legacy-2020-desktop-linux | pending | pending | pending | pending | pending |
| legacy-2020-desktop-windows | pending | pending | pending | pending | pending |

## Failure Classification
- runner_label_mismatch
- missing_labview_installation
- docker_context_switch_failed
- docker_context_unreachable
- port_contract_failure
- workflow_dependency_missing
- branch_drift_missing_script
- runner_label_collision_guard_unconfigured
