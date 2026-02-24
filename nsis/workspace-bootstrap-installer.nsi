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

!ifndef LAUNCH_LOG_REL
  !define LAUNCH_LOG_REL "artifacts\workspace-installer-launch.log"
!endif

!ifndef REQUIRED_LABVIEW_YEAR
  !define REQUIRED_LABVIEW_YEAR "2020"
!endif

!ifndef X86_NIPKG_ENV
  !define X86_NIPKG_ENV "LVIE_LABVIEW_X86_NIPKG_INSTALL_CMD"
!endif

OutFile "${OUT_FILE}"
InstallDir "$TEMP\lvie-cdev-workspace-installer"
Page instfiles

Section "Install"
  SetOutPath "$INSTDIR"
  File /r "${PAYLOAD_DIR}\*"
  CreateDirectory "${WORKSPACE_ROOT}\artifacts"

  StrCpy $1 "$SYSDIR\WindowsPowerShell\v1.0\powershell.exe"
  IfFileExists "$1" powershell_resolved 0
  StrCpy $1 "$WINDIR\System32\WindowsPowerShell\v1.0\powershell.exe"
  IfFileExists "$1" powershell_resolved 0
  StrCpy $1 "$WINDIR\SysWOW64\WindowsPowerShell\v1.0\powershell.exe"
  IfFileExists "$1" powershell_resolved 0
  FileOpen $2 "${WORKSPACE_ROOT}\${LAUNCH_LOG_REL}" a
  FileWrite $2 "powershell_resolution_error=windows_powershell_not_found$\r$\n"
  FileClose $2
  SetErrorLevel 195
  Abort
  powershell_resolved:

  FileOpen $2 "${WORKSPACE_ROOT}\${LAUNCH_LOG_REL}" w
  FileWrite $2 "workspace_root=${WORKSPACE_ROOT}$\r$\n"
  FileWrite $2 "install_script=$INSTDIR\${INSTALL_SCRIPT_REL}$\r$\n"
  FileWrite $2 "manifest=$INSTDIR\${MANIFEST_REL}$\r$\n"
  FileWrite $2 "report=${WORKSPACE_ROOT}\${REPORT_REL}$\r$\n"
  FileWrite $2 "powershell_exe=$1$\r$\n"
  FileWrite $2 "required_labview_year=${REQUIRED_LABVIEW_YEAR}$\r$\n"
  FileClose $2

  StrCpy $3 "C:\Program Files\National Instruments\LabVIEW ${REQUIRED_LABVIEW_YEAR}\LabVIEW.exe"
  StrCpy $4 "C:\Program Files (x86)\National Instruments\LabVIEW ${REQUIRED_LABVIEW_YEAR}\LabVIEW.exe"
  ReadEnvStr $7 "LVIE_GATE_SINGLE_PPL_BITNESS"
  FileOpen $2 "${WORKSPACE_ROOT}\${LAUNCH_LOG_REL}" a
  FileWrite $2 "required_labview_x64_exe=$3$\r$\n"
  FileWrite $2 "required_labview_x86_exe=$4$\r$\n"
  FileWrite $2 "single_ppl_bitness=$7$\r$\n"
  FileClose $2

  ${If} $7 == "64"
    FileOpen $2 "${WORKSPACE_ROOT}\${LAUNCH_LOG_REL}" a
    FileWrite $2 "x86_bootstrap_skipped=true$\r$\n"
    FileClose $2
    Goto labview_x86_ready
  ${EndIf}

  IfFileExists "$4" labview_x86_ready 0
  ReadEnvStr $5 "${X86_NIPKG_ENV}"
  FileOpen $2 "${WORKSPACE_ROOT}\${LAUNCH_LOG_REL}" a
  FileWrite $2 "missing_labview_x86=true$\r$\n"
  FileWrite $2 "x86_nipkg_env=${X86_NIPKG_ENV}$\r$\n"
  FileWrite $2 "x86_nipkg_cmd=$5$\r$\n"
  FileClose $2
  StrCpy $6 "0"
  ${If} $5 == ""
    StrCpy $5 "$\"C:\Program Files\National Instruments\NI Package Manager\nipkg.exe$\" install --accept-eulas --yes --include-recommended ni-labview-${REQUIRED_LABVIEW_YEAR}-core-x86-en"
    StrCpy $6 "1"
    FileOpen $2 "${WORKSPACE_ROOT}\${LAUNCH_LOG_REL}" a
    FileWrite $2 "x86_nipkg_status=using_default_command$\r$\n"
    FileWrite $2 "x86_nipkg_cmd=$5$\r$\n"
    FileClose $2
  ${EndIf}
  ExecWait '"$SYSDIR\cmd.exe" /c "$5 >> "${WORKSPACE_ROOT}\${LAUNCH_LOG_REL}" 2>&1"' $0
  FileOpen $2 "${WORKSPACE_ROOT}\${LAUNCH_LOG_REL}" a
  FileWrite $2 "x86_nipkg_exit_code=$0$\r$\n"
  FileClose $2
  ${If} $0 != 0
    ${If} $6 == "1"
      StrCpy $5 "$\"C:\Program Files\National Instruments\NI Package Manager\nipkg.exe$\" install --accept-eulas --yes --include-recommended ni-labview-${REQUIRED_LABVIEW_YEAR}-core-en-x86"
      FileOpen $2 "${WORKSPACE_ROOT}\${LAUNCH_LOG_REL}" a
      FileWrite $2 "x86_nipkg_fallback_cmd=$5$\r$\n"
      FileClose $2
      ExecWait '"$SYSDIR\cmd.exe" /c "$5 >> "${WORKSPACE_ROOT}\${LAUNCH_LOG_REL}" 2>&1"' $0
      FileOpen $2 "${WORKSPACE_ROOT}\${LAUNCH_LOG_REL}" a
      FileWrite $2 "x86_nipkg_fallback_exit_code=$0$\r$\n"
      FileClose $2
    ${EndIf}
    ${If} $0 != 0
      SetErrorLevel $0
      Abort
    ${EndIf}
  ${EndIf}
  IfFileExists "$4" labview_x86_ready 0
  SetErrorLevel 194
  Abort
  labview_x86_ready:

  ExecWait '"$SYSDIR\cmd.exe" /c ""$1" -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "$INSTDIR\${INSTALL_SCRIPT_REL}" -WorkspaceRoot "${WORKSPACE_ROOT}" -ManifestPath "$INSTDIR\${MANIFEST_REL}" -Mode Install -InstallerExecutionContext NsisInstall -OutputPath "${WORKSPACE_ROOT}\${REPORT_REL}" >> "${WORKSPACE_ROOT}\${LAUNCH_LOG_REL}" 2>&1"' $0
  FileOpen $2 "${WORKSPACE_ROOT}\${LAUNCH_LOG_REL}" a
  FileWrite $2 "exit_code=$0$\r$\n"
  FileClose $2
  ${If} $0 != 0
    SetErrorLevel $0
    Abort
  ${EndIf}
SectionEnd
