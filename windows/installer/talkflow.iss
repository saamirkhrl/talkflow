; talkflow for Windows: a per-user installer (no administrator rights).
;
; Built by .github/workflows/windows.yml:
;   iscc /DAppVersion=0.1.4 /DArch=x64 /DSourceDir=<publish folder> windows\installer\talkflow.iss
; producing talkflow-windows-<arch>-setup.exe. The publish folder holds
; talkflow.exe and engine\ (whisper-server.exe and its DLLs).
;
; Installs to %LOCALAPPDATA%\Programs\talkflow. Uninstalling (Windows Apps >
; Uninstall, or talkflow's Settings > Uninstall) removes the program, the speech
; engine, %LOCALAPPDATA%\talkflow (models, logs, downloads), the startup entry
; and saved API keys, and keeps %APPDATA%\talkflow (stats, settings), so a
; reinstall picks up where the user left off.

#ifndef AppVersion
  #define AppVersion "0.0.0"
#endif
#ifndef Arch
  #define Arch "x64"
#endif
#ifndef SourceDir
  #error SourceDir must point at the published app folder
#endif

[Setup]
AppId={{6C8E2F4B-7A1D-4E3F-9B52-0D7C1A9E4F21}
AppName=talkflow
AppVersion={#AppVersion}
AppVerName=talkflow {#AppVersion}
AppPublisher=talkflow
AppPublisherURL=https://talkflow.live
AppSupportURL=https://github.com/saamirkhrl/talkflow/issues
AppUpdatesURL=https://talkflow.live/download/windows
DefaultDirName={localappdata}\Programs\talkflow
DisableDirPage=yes
DisableProgramGroupPage=yes
DisableReadyPage=yes
PrivilegesRequired=lowest
#if Arch == "arm64"
ArchitecturesAllowed=arm64
ArchitecturesInstallIn64BitMode=arm64
#else
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
#endif
MinVersion=10.0.17763
OutputBaseFilename=talkflow-windows-{#Arch}-setup
SetupIconFile=..\Talkflow\Assets\talkflow.ico
UninstallDisplayIcon={app}\talkflow.exe
UninstallDisplayName=talkflow
WizardStyle=modern
Compression=lzma2/max
SolidCompression=yes
CloseApplications=force
RestartApplications=no
LicenseFile=..\..\LICENSE

[Files]
Source: "{#SourceDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{userprograms}\talkflow"; Filename: "{app}\talkflow.exe"; Comment: "Hold a key, speak, let go"

[Run]
Filename: "{app}\talkflow.exe"; Description: "Open talkflow"; Flags: nowait postinstall skipifsilent
; The in-app updater runs this installer with /SILENT /LAUNCH=1 and has already quit.
Filename: "{app}\talkflow.exe"; Parameters: "--background"; Flags: nowait; Check: RelaunchAfterUpdate

[UninstallRun]
; Stops talkflow and its speech engine, removes saved API keys and the startup
; entry, and deletes %LOCALAPPDATA%\talkflow. Never touches %APPDATA%\talkflow.
Filename: "{app}\talkflow.exe"; Parameters: "--uninstall-cleanup"; Flags: runhidden waituntilterminated; RunOnceId: "talkflowCleanup"

[UninstallDelete]
Type: filesandordirs; Name: "{localappdata}\talkflow"
Type: filesandordirs; Name: "{app}"

[Code]
function RelaunchAfterUpdate: Boolean;
begin
  Result := WizardSilent and (ExpandConstant('{param:LAUNCH|0}') = '1');
end;
