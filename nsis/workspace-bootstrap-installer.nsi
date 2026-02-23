Unicode True
SetCompressor /SOLID lzma
RequestExecutionLevel user
SilentInstall silent
ShowInstDetails nevershow
Name "LVIE Cdev Workspace Bootstrap"

!include "LogicLib.nsh"

!ifndef OUT_FILE
  !define OUT_FILE "lvie-cdev-workspace-installer.exe"
!endif

!ifndef PAYLOAD_DIR
  !define PAYLOAD_DIR "."
!endif

!ifndef WORKSPACE_ROOT
  !define WORKSPACE_ROOT "C:\dev"
!endif

!ifndef INSTALL_SCRIPT_REL
  !define INSTALL_SCRIPT_REL "scripts\Install-WorkspaceFromManifest.ps1"
!endif

!ifndef MANIFEST_REL
  !define MANIFEST_REL "workspace-governance\workspace-governance.json"
!endif

!ifndef REPORT_REL
  !define REPORT_REL "artifacts\workspace-install-latest.json"
!endif

OutFile "${OUT_FILE}"
InstallDir "$TEMP\lvie-cdev-workspace-installer"
Page instfiles

Section "Install"
  SetOutPath "$INSTDIR"
  File /r "${PAYLOAD_DIR}\*"

  ExecWait '"$SYSDIR\cmd.exe" /c "where pwsh >nul 2>nul"' $0
  ${If} $0 != 0
    SetErrorLevel 9009
    Abort
  ${EndIf}

  ExecWait '"pwsh" -NoProfile -File "$INSTDIR\${INSTALL_SCRIPT_REL}" -WorkspaceRoot "${WORKSPACE_ROOT}" -ManifestPath "$INSTDIR\${MANIFEST_REL}" -Mode Install -ExecutionContext NsisInstall -OutputPath "${WORKSPACE_ROOT}\${REPORT_REL}"' $0
  ${If} $0 != 0
    SetErrorLevel $0
    Abort
  ${EndIf}
SectionEnd
