# Runner Configuration Starting Prompt

Use this prompt with Codex to configure and certify a new self-hosted machine from a single GitHub issue.

```
Use issue-driven self-hosted machine certification for LabVIEW cdev surface.

Inputs:
- Issue URL: <paste issue URL>

Execution contract:
0. Bootstrap:
   - Checkout repository at issue `ref`.
   - Validate `required_script_paths` from issue config.
   - If any are missing, stop with `branch_drift_missing_script`.
   - Do **not** implement missing scripts in this flow.
1. Read the issue config block between <!-- CERT_CONFIG_START --> and <!-- CERT_CONFIG_END -->.
2. Run `scripts/Invoke-MachineCertificationFromIssue.ps1 -IssueUrl <url>`.
3. Wait for all dispatched runs to complete.
4. Post a comment on the issue with:
   - setup name
   - run URL
   - conclusion
   - certification artifact URL
   - recorder identity marker from `recorder_name` in issue config
5. If any setup fails, classify root cause under one of:
   - runner_label_mismatch
   - missing_labview_installation
   - docker_context_unreachable
   - port_contract_failure
   - workflow_dependency_missing
6. Propose exact remediation commands and rerun only failed setups.
7. Do not mark setup as certified unless run conclusion is success and certification report has `certified=true`.
```

## Issue Config Block Shape

```json
{
  "workflow_file": "self-hosted-machine-certification.yml",
  "ref": "cert/self-hosted-machine-certification-evidence",
  "trigger_mode": "auto",
  "recorder_name": "cdev-certification-recorder",
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
```

## Notes
- Setup names come from `tools/machine-certification/setup-profiles.json`.
- `trigger_mode=auto` attempts dispatch first and falls back to rerunning the latest run on `ref` when workflow dispatch is unavailable pre-merge.
- `recorder_name` must be different from repository owner.
- This prompt is intentionally issue-first: Codex can execute end-to-end from issue URL only.
