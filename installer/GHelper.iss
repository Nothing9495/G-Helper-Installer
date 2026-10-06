; G-Helper installer.
;
; Built by installer/build.ps1, which passes the version and publish folder:
;   ISCC /DMyAppVersion=0.286 /DMyPublishDir=<dir> /O<outdir> GHelper.iss
;
; OutputBaseFilename below is a contract with app/AutoUpdate/AutoUpdateControl.cs,
; which downloads an asset named exactly "GHelper-{tag}-Setup.exe". Change both
; together or the in-app update silently stops finding new releases.

#ifndef MyAppVersion
  #define MyAppVersion "0.286"
#endif

#ifndef MyPublishDir
  #define MyPublishDir "..\app\bin\installer\win-x64"
#endif

#define MyAppName      "G-Helper"
#define MyAppExe       "GHelper.exe"
#define MyAppPublisher "Nothing9495"
#define MyRepoURL      "https://github.com/Nothing9495/G-Helper-Installer"
#define PawnIOUrl      "https://pawnio.eu/"

[Setup]
AppId={{2545904B-00B1-4430-8341-2C4AB78F1593}
AppName={#MyAppName}
AppVersion={#MyAppVersion}
AppVerName={#MyAppName}
AppPublisher={#MyAppPublisher}
AppPublisherURL={#MyRepoURL}
AppSupportURL={#MyRepoURL}/issues
AppUpdatesURL={#MyRepoURL}/releases

DefaultDirName={autopf}\G-Helper
DefaultGroupName={#MyAppName}
DisableProgramGroupPage=yes
OutputDir=..\dist
OutputBaseFilename=GHelper-v{#MyAppVersion}-Setup
SetupIconFile=favicon-installer.ico
UninstallDisplayIcon={app}\{#MyAppExe}

Compression=lzma2/max
SolidCompression=yes

WizardStyle=modern
MinVersion=10.0
PrivilegesRequired=admin
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
DisableStartupPrompt=yes
VersionInfoVersion={#MyAppVersion}
VersionInfoProductVersion={#MyAppVersion}

; G-Helper announces its shutdown through a named event, not a mutex, so AppMutex
; is unusable here. Restart Manager still finds it via its open file handles.
CloseApplications=yes
RestartApplications=no
SetupLogging=yes

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"
Name: "chinesesimplified"; MessagesFile: "compiler:Languages\ChineseSimplified.isl"

[CustomMessages]
TAdditional=Additional options:
TAddStartup=Add G-Helper to startup so it runs when you sign in.
TDisableSvc=Disable ASUS services (Armoury Crate and friends).
TDesktopIcon=Create a desktop shortcut.
TPawnIO=Open the PawnIO driver download page (required for undervolting and power limit tuning).
TRunNow=Run G-Helper now

StartupTaskFailed=G-Helper could not confirm that its startup task was created. The installation finished, but automatic startup may not work. Please check Task Scheduler for a task named GHelper_* and retry from within G-Helper if needed.

UOptionsRestoreSvc=G-Helper can re-enable and start the ASUS services that it disabled. Do you want that done before it is removed?
UOptionsDeleteConfig=Delete all G-Helper settings and logs, including the files under your user profile and ProgramData?

chinesesimplified.TAdditional=附加选项：
chinesesimplified.TAddStartup=添加 G-Helper 到开机启动，登录后自动运行。
chinesesimplified.TDisableSvc=禁用 ASUS 服务（Armoury Crate 等）。
chinesesimplified.TDesktopIcon=创建桌面快捷方式。
chinesesimplified.TPawnIO=打开 PawnIO 驱动下载页面（欠压与功耗限制调校需要该驱动）。
chinesesimplified.TRunNow=立即运行 G-Helper

chinesesimplified.StartupTaskFailed=G-Helper 未能确认开机启动任务已创建。安装本身已完成，但开机自启可能不生效。请在任务计划程序中检查名为 GHelper_* 的任务，必要时在 G-Helper 界面内重试。

chinesesimplified.UOptionsRestoreSvc=G-Helper 可以重新启用并启动它曾禁用的 ASUS 服务。是否在移除前执行？
chinesesimplified.UOptionsDeleteConfig=是否删除 G-Helper 的全部设置与日志，包括用户目录与 ProgramData 下的文件？

; Only autostart is selected on a fresh install; the rest are explicitly off so a
; silent install never disables services, opens a browser or adds a shortcut.
[Tasks]
Name: "autostart";   Description: "{cm:TAddStartup}";  GroupDescription: "{cm:TAdditional}"; Flags: checkedonce
Name: "disablesvc";  Description: "{cm:TDisableSvc}";  Flags: unchecked
Name: "pawnio";      Description: "{cm:TPawnIO}";      Flags: unchecked
Name: "desktopicon"; Description: "{cm:TDesktopIcon}"; GroupDescription: "{cm:TAdditional}"; Flags: unchecked

; ignoreversion is mandatory: the payload is a loose self-contained publish of
; several hundred files, and without it an upgrade overwrites nothing.
[Files]
Source: "{#MyPublishDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs
Source: "..\LICENSE";       DestDir: "{app}"; Flags: ignoreversion

[Icons]
Name: "{autoprograms}\{#MyAppName}"; Filename: "{app}\{#MyAppExe}"
Name: "{autodesktop}\{#MyAppName}";  Filename: "{app}\{#MyAppExe}"; Tasks: desktopicon

[Run]
; postinstall puts this on the Finished page, unambiguously after CurStepChanged,
; so it cannot race task creation. skipifsilent keeps /SILENT from popping the
; tray icon. nowait because G-Helper never exits on its own.
Filename: "{app}\{#MyAppExe}"; Description: "{cm:TRunNow}"; Flags: nowait postinstall skipifsilent

[Code]

function RunGHelper(const Params: String): Boolean;
var
  Code: Longint;
begin
  { Exit code ignored on purpose: the installer verifies the outcome rather than
    trusting G-Helper to report its own success. }
  Result := Exec(ExpandConstant('{app}\{#MyAppExe}'), Params, ExpandConstant('{app}'),
    SW_HIDE, ewWaitUntilTerminated, Code);
end;

function GHelperTaskExists: Boolean;
var
  Code: Longint;
begin
  { The wildcard avoids reconstructing the "GHelper_<SID>" task name in Inno. }
  Result := Exec(ExpandConstant('{sys}\cmd.exe'),
    '/C powershell -NoProfile -Command "if (Get-ScheduledTask -TaskName ''GHelper*'' -ErrorAction SilentlyContinue) {exit 0} else {exit 1}"',
    '', SW_HIDE, ewWaitUntilTerminated, Code) and (Code = 0);
end;

{ Graceful first so the tray icon and lighting tear down cleanly, then a forced
  kill if that did not finish in three seconds. Wait-Process returns at once when
  nothing is running, so an install with no live instance pays no delay. }
procedure StopRunningGHelper;
var
  Code: Longint;
begin
  Exec(ExpandConstant('{sys}\WindowsPowerShell\v1.0\powershell.exe'),
    '-NoProfile -ExecutionPolicy Bypass -Command "try { [System.Threading.EventWaitHandle]::OpenExisting(''Global\GHelperApp-Exit'').Set() } catch {}; Wait-Process -Name GHelper -Timeout 3 -ErrorAction SilentlyContinue; if (Get-Process -Name GHelper -ErrorAction SilentlyContinue) { Stop-Process -Name GHelper -Force }"',
    '', SW_HIDE, ewWaitUntilTerminated, Code);
end;

function PrepareToInstall(var NeedsRestart: Boolean): String;
begin
  StopRunningGHelper;
  Result := '';  { non empty would abort Setup and show that text }
end;

{ Driven from here rather than a Run entry so the verification is unambiguously
  ordered after task creation. Cost: --disable-services starts one PowerShell per
  ASUS service, with no progress bar while it does. }
procedure CurStepChanged(CurStep: TSetupStep);
var
  Code: Longint;
begin
  if CurStep <> ssPostInstall then Exit;

  if WizardIsTaskSelected('autostart') then RunGHelper('--install-startup');
  if WizardIsTaskSelected('disablesvc') then RunGHelper('--disable-services');

  { PawnIO is an external driver and is deliberately not bundled. }
  if WizardIsTaskSelected('pawnio') then
    Exec(ExpandConstant('{sys}\rundll32.exe'),
      'url.dll,FileProtocolHandler ' + '{#PawnIOUrl}', '', SW_SHOWNORMAL, ewNoWait, Code);

  { Warn but never abort. The WizardSilent guard matters: MsgBox is not suppressed
    under /SILENT or /VERYSILENT and would hang with nobody left to dismiss it. }
  if (not WizardSilent) and WizardIsTaskSelected('autostart') and (not GHelperTaskExists()) then
    MsgBox(CustomMessage('StartupTaskFailed'), mbError, MB_OK);
end;

procedure CurUninstallStepChanged(CurUninstallStep: TUninstallStep);
begin
  { usAppMutexCheck is the earliest uninstaller step and still precedes every file
    removal, which is when the exe has to be gone. usUninstall below still needs
    it on disk for the CLI calls. }
  if CurUninstallStep = usAppMutexCheck then StopRunningGHelper;

  if CurUninstallStep <> usUninstall then Exit;

  { Unconditional, otherwise a task outlives the exe it points at. }
  RunGHelper('--uninstall-startup');

  { UninstallSilent, not WizardSilent: the latter raises during uninstall. }
  if UninstallSilent then Exit;

  { Services first, because that step reads the config wiped below. }
  if MsgBox(CustomMessage('UOptionsRestoreSvc'), mbConfirmation, MB_YESNO) = IDYES then
    RunGHelper('--enable-services');

  if MsgBox(CustomMessage('UOptionsDeleteConfig'), mbConfirmation, MB_YESNO) = IDYES then
  begin
    DelTree(ExpandConstant('{userappdata}\GHelper'), True, True, True);
    DelTree(ExpandConstant('{commonappdata}\GHelper'), True, True, True);
  end;
end;