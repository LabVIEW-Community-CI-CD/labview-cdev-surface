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
  "ref": "main",
  "recorder_name": "cdev-certification-recorder",
  "setup_names": [
    "legacy-2020-desktop-linux",
    "legacy-2020-desktop-windows"
  ]
}
<!-- CERT_CONFIG_END -->

## Evidence
| Setup | Run URL | Conclusion | Artifact URL | Certified |
|---|---|---|---|---|
| legacy-2020-desktop-linux | pending | pending | pending | pending |
| legacy-2020-desktop-windows | pending | pending | pending | pending |

## Failure Classification
- runner_label_mismatch
- missing_labview_installation
- docker_context_unreachable
- port_contract_failure
- workflow_dependency_missing
