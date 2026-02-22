# Organization-Level Agent Instructions (C:\dev)

## Ownership and Scope
- `svelderrainruiz` owns and maintains the `LabVIEW-Community-CI-CD` organization.
- This parent file is authoritative for cross-repo remote and CI safety under `C:\dev`.
- Machine-readable source of truth: `C:\dev\workspace-governance.json`.
- Repository-level `AGENTS.md` files may add stricter rules, but must not loosen or override this file.

## Repository Map
| Path | Repo Identity | Canonical Remote Owner | Fork Status | Allowed Mutation Target | Required `gh -R` |
| --- | --- | --- | --- | --- | --- |
| `C:\dev\labview-icon-editor` | Icon Editor working checkout | `svelderrainruiz/labview-icon-editor-org` | Personal fork workflow | `origin` only (`svelderrainruiz/labview-icon-editor-org`) | `svelderrainruiz/labview-icon-editor-org` |
| `C:\dev\labview-icon-editor-org` | Icon Editor alternate checkout | `svelderrainruiz/labview-icon-editor-org` | Personal fork workflow | `origin` only (`svelderrainruiz/labview-icon-editor-org`) | `svelderrainruiz/labview-icon-editor-org` |
| `C:\dev\labview-icon-editor-upstream` | Icon Editor org checkout | `LabVIEW-Community-CI-CD/labview-icon-editor` | Org-path workflow | `origin` (`LabVIEW-Community-CI-CD/labview-icon-editor`) | `LabVIEW-Community-CI-CD/labview-icon-editor` |
| `C:\dev\labview-for-containers` | Containers org checkout | `LabVIEW-Community-CI-CD/labview-for-containers` | Org-path workflow | `origin` (`LabVIEW-Community-CI-CD/labview-for-containers`) | `LabVIEW-Community-CI-CD/labview-for-containers` |
| `C:\dev\labview-for-containers-org` | Containers fork checkout | `svelderrainruiz/labview-for-containers-org` | Personal fork workflow | `origin` only (`svelderrainruiz/labview-for-containers-org`) | `svelderrainruiz/labview-for-containers-org` |
| `C:\dev\labview-icon-editor-codex-skills` | Codex Skills fork checkout | `svelderrainruiz/labview-icon-editor-codex-skills` | Personal fork workflow | `origin` only (`svelderrainruiz/labview-icon-editor-codex-skills`) | `svelderrainruiz/labview-icon-editor-codex-skills` |
| `C:\dev\labview-icon-editor-codex-skills-upstream` | Codex Skills org checkout | `LabVIEW-Community-CI-CD/labview-icon-editor-codex-skills` | Org-path workflow | `origin` (`LabVIEW-Community-CI-CD/labview-icon-editor-codex-skills`) | `LabVIEW-Community-CI-CD/labview-icon-editor-codex-skills` |
| `C:\dev\labview-cdev-surface` | CDev Surface fork checkout | `svelderrainruiz/labview-cdev-surface` | Personal fork workflow | `origin` only (`svelderrainruiz/labview-cdev-surface`) | `svelderrainruiz/labview-cdev-surface` |
| `C:\dev\labview-cdev-surface-upstream` | CDev Surface org checkout | `LabVIEW-Community-CI-CD/labview-cdev-surface` | Org-path workflow | `origin` (`LabVIEW-Community-CI-CD/labview-cdev-surface`) | `LabVIEW-Community-CI-CD/labview-cdev-surface` |

## Remote Safety Rules
- Authorization model: allowlisted mutation targets only.
- Icon Editor fork checkouts (`C:\dev\labview-icon-editor`, `C:\dev\labview-icon-editor-org`):
  - Allowed mutation target: `origin` (`svelderrainruiz/labview-icon-editor-org`).
  - `upstream` must resolve to `LabVIEW-Community-CI-CD/labview-icon-editor` and is read-only.
  - Forbidden mutation targets: `LabVIEW-Community-CI-CD/labview-icon-editor` (for fork mutation workflow) and `ni/labview-icon-editor`.
- Icon Editor org checkout (`C:\dev\labview-icon-editor-upstream`):
  - Allowed mutation target: `origin` (`LabVIEW-Community-CI-CD/labview-icon-editor`).
  - Forbidden mutation target: `ni/labview-icon-editor`.
- Containers org checkout (`C:\dev\labview-for-containers`):
  - Allowed mutation target: `origin` (`LabVIEW-Community-CI-CD/labview-for-containers`).
  - Normal push and CI operations are allowed, subject to branch protections and repository policy.
- Containers fork checkout (`C:\dev\labview-for-containers-org`):
  - Allowed mutation target: `origin` (`svelderrainruiz/labview-for-containers-org`).
  - `upstream` must resolve to `LabVIEW-Community-CI-CD/labview-for-containers` and is read-only.
  - Forbidden mutation targets: `LabVIEW-Community-CI-CD/labview-for-containers` (for mutation) and `ni/labview-for-containers`.
- Codex Skills fork checkout (`C:\dev\labview-icon-editor-codex-skills`):
  - Allowed mutation target: `origin` (`svelderrainruiz/labview-icon-editor-codex-skills`).
  - `upstream` must resolve to `LabVIEW-Community-CI-CD/labview-icon-editor-codex-skills` and is read-only.
  - Forbidden mutation target: `LabVIEW-Community-CI-CD/labview-icon-editor-codex-skills` (for fork mutation workflow).
- Codex Skills org checkout (`C:\dev\labview-icon-editor-codex-skills-upstream`):
  - Allowed mutation target: `origin` (`LabVIEW-Community-CI-CD/labview-icon-editor-codex-skills`).
  - Forbidden mutation target: `svelderrainruiz/labview-icon-editor-codex-skills` (for org mutation workflow).
- CDev Surface fork checkout (`C:\dev\labview-cdev-surface`):
  - Allowed mutation target: `origin` (`svelderrainruiz/labview-cdev-surface`).
  - `upstream` must resolve to `LabVIEW-Community-CI-CD/labview-cdev-surface` and is read-only.
  - Forbidden mutation targets: `LabVIEW-Community-CI-CD/labview-cdev-surface` (for fork mutation workflow) and `ni/labview-cdev-surface`.
- CDev Surface org checkout (`C:\dev\labview-cdev-surface-upstream`):
  - Allowed mutation target: `origin` (`LabVIEW-Community-CI-CD/labview-cdev-surface`).
  - Forbidden mutation target: `ni/labview-cdev-surface`.

## CI Trigger Rules
- Icon Editor fork workflow:
  - Default trigger: push-based CI on `svelderrainruiz/labview-icon-editor-org` branches.
  - Required `gh` repo pin: `-R svelderrainruiz/labview-icon-editor-org`.
  - If manual dispatch is permission-blocked, use push-trigger fallback on fork branch.
- Icon Editor org workflow (`C:\dev\labview-icon-editor-upstream`):
  - Use repository-standard CI triggers on `LabVIEW-Community-CI-CD/labview-icon-editor`.
  - Required `gh` repo pin: `-R LabVIEW-Community-CI-CD/labview-icon-editor`.
- Containers org-path workflow (`C:\dev\labview-for-containers`):
  - Use repository-standard CI triggers on `LabVIEW-Community-CI-CD/labview-for-containers`.
  - Required `gh` repo pin: `-R LabVIEW-Community-CI-CD/labview-for-containers`.
- Containers fork workflow (`C:\dev\labview-for-containers-org`):
  - Default trigger: push-based CI on `svelderrainruiz/labview-for-containers-org` branches.
  - Required `gh` repo pin: `-R svelderrainruiz/labview-for-containers-org`.
  - Do not dispatch/rerun against `upstream` for fork mutation workflows.
- Codex Skills fork workflow (`C:\dev\labview-icon-editor-codex-skills`):
  - Default trigger: push-based CI on `svelderrainruiz/labview-icon-editor-codex-skills` branches.
  - Required `gh` repo pin: `-R svelderrainruiz/labview-icon-editor-codex-skills`.
  - Do not dispatch/rerun against `upstream` for fork mutation workflows.
- Codex Skills org workflow (`C:\dev\labview-icon-editor-codex-skills-upstream`):
  - Use repository-standard CI triggers on `LabVIEW-Community-CI-CD/labview-icon-editor-codex-skills`.
  - Required `gh` repo pin: `-R LabVIEW-Community-CI-CD/labview-icon-editor-codex-skills`.
- CDev Surface fork workflow (`C:\dev\labview-cdev-surface`):
  - Default trigger: push-based CI on `svelderrainruiz/labview-cdev-surface` branches.
  - Required `gh` repo pin: `-R svelderrainruiz/labview-cdev-surface`.
  - Do not dispatch/rerun against `upstream` for fork mutation workflows.
- CDev Surface org workflow (`C:\dev\labview-cdev-surface-upstream`):
  - Use repository-standard CI triggers on `LabVIEW-Community-CI-CD/labview-cdev-surface`.
  - Required `gh` repo pin: `-R LabVIEW-Community-CI-CD/labview-cdev-surface`.
- Drift runbook for cdev-surface:
  - Default refresh path is `.github/workflows/workspace-sha-refresh-pr.yml`.
  - Automation updates `pinned_sha`, reuses branch `automation/sha-refresh`, opens or updates one PR, and enables squash auto-merge.
  - If automation fails, use manual fallback branch + PR flow.

## Branch Protection Gate
- Default-branch mutation is blocked when required branch protection is missing or contract-mismatched.
- Blocked operations include push, workflow dispatch, and workflow rerun targeting governed default branches.
- If blocked, only feature-branch mutation + PR flow is allowed until branch-protection checks pass.

Governed default branches:
- `svelderrainruiz/labview-icon-editor-org:develop`
- `LabVIEW-Community-CI-CD/labview-icon-editor:develop`
- `svelderrainruiz/labview-for-containers-org:main`
- `LabVIEW-Community-CI-CD/labview-for-containers:main`
- `svelderrainruiz/labview-icon-editor-codex-skills:main`
- `LabVIEW-Community-CI-CD/labview-icon-editor-codex-skills:main`
- `svelderrainruiz/labview-cdev-surface:main`
- `LabVIEW-Community-CI-CD/labview-cdev-surface:main`

Minimum contract requirements for governed default branches:
- Branch is protected.
- Required status checks are enabled and strict.
- Required PR review protection is enabled.
- Force pushes are disabled.
- Deletions are disabled.

Required status check contexts:
- `svelderrainruiz/labview-icon-editor-org:develop` -> `Pipeline Contract`, `Governance Contract`
- `LabVIEW-Community-CI-CD/labview-icon-editor:develop` -> `Pipeline Contract`, `Governance Contract`
- `svelderrainruiz/labview-for-containers-org:main` -> `run-labview-cli`, `run-labview-cli-windows`, `Governance Contract`
- `LabVIEW-Community-CI-CD/labview-for-containers:main` -> validate current org contract (`run-labview-cli`, `run-labview-cli-windows`, `stabilization-2026-certification-gate`)
- `svelderrainruiz/labview-icon-editor-codex-skills:main` -> `CI Pipeline`, `Workspace Installer Contract`
- `LabVIEW-Community-CI-CD/labview-icon-editor-codex-skills:main` -> `CI Pipeline`, `Workspace Installer Contract`
- `svelderrainruiz/labview-cdev-surface:main` -> `CI Pipeline`
- `LabVIEW-Community-CI-CD/labview-cdev-surface:main` -> `CI Pipeline`

Review requirements:
- For fresh fork/org repos in this workspace: minimum `required_approving_review_count >= 1`.
- For `LabVIEW-Community-CI-CD/labview-for-containers:main`: validate existing org policy as-is unless maintainers intentionally change it.
- `labview-cdev-surface` is an exception in this cycle: allow `required_approving_review_count = 0` for both fork and org repos.

## Preflight Checks
- Run workspace contract checks before mutating operations:
  - `pwsh -NoProfile -File C:\dev\scripts\Assert-WorkspaceGovernance.ps1 -WorkspaceRoot C:\dev -ManifestPath C:\dev\workspace-governance.json -Mode Audit -OutputPath C:\dev\artifacts\workspace-governance-latest.json`
  - `pwsh -NoProfile -File C:\dev\scripts\Test-PolicyContracts.ps1 -WorkspaceRoot C:\dev -FailOnWarning`
- Required path checks:
  - `C:\dev\labview-icon-editor`
  - `C:\dev\labview-icon-editor-org`
  - `C:\dev\labview-icon-editor-upstream`
  - `C:\dev\labview-for-containers`
  - `C:\dev\labview-for-containers-org`
  - `C:\dev\labview-icon-editor-codex-skills`
  - `C:\dev\labview-icon-editor-codex-skills-upstream`
  - `C:\dev\labview-cdev-surface`
  - `C:\dev\labview-cdev-surface-upstream`

Deterministic installer policy (`lvie-cdev-workspace-installer.exe`):
- Source of truth is bundled `workspace-governance.json` and `AGENTS.md` payload.
- Installer must enforce commit-level checkout lock using `pinned_sha` for every managed repo.
- Existing path drift is a hard stop: remote mismatch or `HEAD != pinned_sha` fails install.
- Branch protection checks during install are audit-only (non-blocking for install completion).
- Mutation safety remains enforced by this file and governance scripts after install.

- If preflight fails, do not run mutating `git` or `gh` commands until remotes and policy targets are corrected.
