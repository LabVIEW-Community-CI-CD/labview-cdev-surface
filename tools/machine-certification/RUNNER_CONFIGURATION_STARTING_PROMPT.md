# Runner Configuration Starting Prompt

Use this prompt with Codex to configure and certify a new self-hosted machine from a single GitHub issue.

```
Use issue-driven self-hosted machine certification for LabVIEW cdev surface.

Inputs:
- Issue URL: <paste issue URL>

Execution contract:
0. Bootstrap:
   - Checkout repository at issue `ref`.
   - Verify local `HEAD` equals remote head SHA of `ref`.
   - Validate `required_script_paths` from issue config.
   - Emit `CERT_SESSION_START` marker comment and detect stale open sessions.
   - If any are missing, stop with `branch_drift_missing_script`.
   - Do **not** implement missing scripts in this flow.
1. Read the issue config block between <!-- CERT_CONFIG_START --> and <!-- CERT_CONFIG_END -->.
2. Run `scripts/Invoke-MachineCertificationFromIssue.ps1 -IssueUrl <url>`.
3. Wait for all dispatched runs to complete.
4. Post a comment on the issue with:
   - setup name
   - machine name
   - run URL
   - conclusion
   - certification artifact URL
   - recorder identity marker from `recorder_name` in issue config
5. If any setup fails, classify root cause under one of:
   - runner_label_mismatch
   - runner_label_collision_guard_unconfigured
   - missing_labview_installation
   - docker_context_switch_failed
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
```

## Notes
- Setup names come from `tools/machine-certification/setup-profiles.json`.
- `trigger_mode=auto` attempts dispatch first and falls back to rerunning the latest run on `ref` when workflow dispatch is unavailable pre-merge.
- `require_local_ref_sync=true` fails closed if local checkout is stale versus issue `ref`.
- Certification automation switches Docker Desktop context per setup before preflight when `switch_docker_context=true`.
- Certification automation can start Docker Desktop automatically when `start_docker_desktop_if_needed=true`.
- On upstream repos, setup collision-guard labels are enforced to avoid runner pickup collisions.
- `recorder_name` must be different from repository owner.
- This prompt is intentionally issue-first: Codex can execute end-to-end from issue URL only.
