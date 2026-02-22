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

  StrCpy $1 ""
  IfFileExists "$PROGRAMFILES64\PowerShell\7\pwsh.exe" 0 +2
    StrCpy $1 "$PROGRAMFILES64\PowerShell\7\pwsh.exe"
  ${If} $1 == ""
    IfFileExists "$PROGRAMFILES\PowerShell\7\pwsh.exe" 0 +2
      StrCpy $1 "$PROGRAMFILES\PowerShell\7\pwsh.exe"
  ${EndIf}
  ${If} $1 == ""
    StrCpy $1 "pwsh"
  ${EndIf}

  ExecWait '"$1" -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "$INSTDIR\${INSTALL_SCRIPT_REL}" -WorkspaceRoot "${WORKSPACE_ROOT}" -ManifestPath "$INSTDIR\${MANIFEST_REL}" -Mode Install -ExecutionContext NsisInstall -OutputPath "${WORKSPACE_ROOT}\${REPORT_REL}"' $0
  ${If} $0 != 0
    SetErrorLevel $0
    Abort
  ${EndIf}
SectionEnd
