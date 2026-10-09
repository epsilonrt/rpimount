; rpimount installer (Inno Setup 6). Per-user installation only, no administrator rights needed to install.
; Build: ISCC.exe installer\rpimount.iss /DAppVersion=1.2.3   (see also installer\build.ps1)

#ifndef AppVersion
  #define AppVersion "0.0.0"
#endif
#define AppName "rpimount"
#define AppExe "{sys}\WindowsPowerShell\v1.0\powershell.exe"

[Setup]
AppId={{524261C3-485A-4BC7-BF49-71052E92CD9C}
AppName={#AppName}
AppVersion={#AppVersion}
AppPublisher=Pascal JEAN (epsilonrt)
AppPublisherURL=https://github.com/epsilonrt/rpimount
AppSupportURL=https://github.com/epsilonrt/rpimount/issues
DefaultDirName={autopf}\{#AppName}
DefaultGroupName={#AppName}
DisableProgramGroupPage=yes
PrivilegesRequired=lowest
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
LicenseFile=..\LICENSE
SetupIconFile=..\assets\rpimount.ico
UninstallDisplayIcon={app}\assets\rpimount.ico
OutputDir=Output
OutputBaseFilename=rpimount-setup-{#AppVersion}
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
; No language prompt: follow the Windows display language (French on a French Windows), English otherwise
ShowLanguageDialog=no
LanguageDetectionMethod=uilanguage

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"
Name: "french"; MessagesFile: "compiler:Languages\French.isl"

[CustomMessages]
english.PrereqTitle=Prerequisites
english.PrereqDesc=rpimount needs WSL, usbipd and at least one WSL2 distribution.
english.PrereqWsl=WSL
english.PrereqUsbipd=usbipd-win
english.PrereqDistro=WSL2 distribution
english.PrereqOk=available
english.PrereqMissing=MISSING
english.PrereqRecheck=Check again
english.PrereqToDo=What to do (run the commands in an administrator console, then click "Check again"):
english.PrereqFixWsl=WSL:  wsl --install --no-distribution   (then restart Windows)
english.PrereqFixUsbipd=usbipd:  winget install usbipd   (or download it from https://github.com/dorssel/usbipd-win/releases)
english.PrereqFixDistro=Distribution:  wsl --install -d Debian
english.PrereqBlocked=The prerequisites are not all available. Install the missing items, then click "Check again".
english.DesktopIcon=Create a &desktop icon
english.LaunchApp=Start rpimount
french.PrereqTitle=Prérequis
french.PrereqDesc=rpimount nécessite WSL, usbipd et au moins une distribution WSL2.
french.PrereqWsl=WSL
french.PrereqUsbipd=usbipd-win
french.PrereqDistro=Distribution WSL2
french.PrereqOk=disponible
french.PrereqMissing=ABSENT
french.PrereqRecheck=Revérifier
french.PrereqToDo=À faire (commandes à lancer dans une console administrateur, puis cliquer sur « Revérifier ») :
french.PrereqFixWsl=WSL :  wsl --install --no-distribution   (puis redémarrer Windows)
french.PrereqFixUsbipd=usbipd :  winget install usbipd   (ou téléchargement sur https://github.com/dorssel/usbipd-win/releases)
french.PrereqFixDistro=Distribution :  wsl --install -d Debian
french.PrereqBlocked=Les prérequis ne sont pas tous disponibles. Installez les éléments manquants, puis cliquez sur « Revérifier ».
french.DesktopIcon=Créer une icône sur le &bureau
french.LaunchApp=Lancer rpimount

[Tasks]
Name: "desktopicon"; Description: "{cm:DesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"; Flags: unchecked

[Files]
Source: "..\rpimount.ps1"; DestDir: "{app}"; Flags: ignoreversion
Source: "..\lang\*.json"; DestDir: "{app}\lang"; Flags: ignoreversion
Source: "..\assets\rpimount.ico"; DestDir: "{app}\assets"; Flags: ignoreversion
Source: "..\test\test-tree.sh"; DestDir: "{app}\test"; Flags: ignoreversion
Source: "..\LICENSE"; DestDir: "{app}"; Flags: ignoreversion
Source: "..\README.md"; DestDir: "{app}"; Flags: ignoreversion
Source: "check-prereqs.ps1"; Flags: dontcopy

[Icons]
; The AppUserModelID matches the one set by the script, so the taskbar button keeps the icon
Name: "{autoprograms}\{#AppName}"; Filename: "{#AppExe}"; Parameters: "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File ""{app}\rpimount.ps1"""; WorkingDir: "{app}"; IconFilename: "{app}\assets\rpimount.ico"; AppUserModelID: "epsilonrt.rpimount"; Flags: runminimized
Name: "{autodesktop}\{#AppName}"; Filename: "{#AppExe}"; Parameters: "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File ""{app}\rpimount.ps1"""; WorkingDir: "{app}"; IconFilename: "{app}\assets\rpimount.ico"; AppUserModelID: "epsilonrt.rpimount"; Tasks: desktopicon; Flags: runminimized

[Run]
Filename: "{#AppExe}"; Parameters: "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File ""{app}\rpimount.ps1"""; WorkingDir: "{app}"; Description: "{cm:LaunchApp}"; Flags: nowait postinstall skipifsilent unchecked runminimized

[Code]
var
  PrereqPage: TWizardPage;
  LblWsl, LblUsbipd, LblDistro: TNewStaticText;
  MemoFix: TNewMemo;
  BtnRecheck: TNewButton;
  PrereqMask: Integer;

// Run the bundled check script; its exit code is a bit mask of the missing prerequisites
function RunPrereqChecks: Integer;
var
  ResultCode: Integer;
begin
  ExtractTemporaryFile('check-prereqs.ps1');
  if Exec(ExpandConstant('{sys}\WindowsPowerShell\v1.0\powershell.exe'),
          '-NoProfile -ExecutionPolicy Bypass -File "' + ExpandConstant('{tmp}\check-prereqs.ps1') + '"',
          '', SW_HIDE, ewWaitUntilTerminated, ResultCode) then
    Result := ResultCode
  else
    Result := 7;   // PowerShell could not even start: report everything as missing
end;

function StatusText(Bit: Integer): String;
begin
  if (PrereqMask and Bit) = 0 then
    Result := CustomMessage('PrereqOk')
  else
    Result := CustomMessage('PrereqMissing');
end;

procedure RefreshPrereqs;
var
  Todo: String;
begin
  WizardForm.Cursor := crHourGlass;
  try
    PrereqMask := RunPrereqChecks;
  finally
    WizardForm.Cursor := crDefault;
  end;
  LblWsl.Caption := CustomMessage('PrereqWsl') + ' : ' + StatusText(1);
  LblUsbipd.Caption := CustomMessage('PrereqUsbipd') + ' : ' + StatusText(2);
  LblDistro.Caption := CustomMessage('PrereqDistro') + ' : ' + StatusText(4);

  Todo := '';
  if (PrereqMask and 1) <> 0 then Todo := Todo + CustomMessage('PrereqFixWsl') + #13#10;
  if (PrereqMask and 2) <> 0 then Todo := Todo + CustomMessage('PrereqFixUsbipd') + #13#10;
  if (PrereqMask and 4) <> 0 then Todo := Todo + CustomMessage('PrereqFixDistro') + #13#10;
  MemoFix.Lines.Text := Todo;
  MemoFix.Visible := (PrereqMask <> 0);
  if WizardForm.CurPageID = PrereqPage.ID then
    WizardForm.NextButton.Enabled := (PrereqMask = 0);
end;

procedure RecheckClick(Sender: TObject);
begin
  RefreshPrereqs;
end;

procedure InitializeWizard;
var
  Top: Integer;
begin
  PrereqPage := CreateCustomPage(wpLicense, CustomMessage('PrereqTitle'), CustomMessage('PrereqDesc'));
  Top := 0;

  LblWsl := TNewStaticText.Create(PrereqPage);
  LblWsl.Parent := PrereqPage.Surface;
  LblWsl.Top := Top; LblWsl.Left := 0;
  Top := Top + ScaleY(22);

  LblUsbipd := TNewStaticText.Create(PrereqPage);
  LblUsbipd.Parent := PrereqPage.Surface;
  LblUsbipd.Top := Top; LblUsbipd.Left := 0;
  Top := Top + ScaleY(22);

  LblDistro := TNewStaticText.Create(PrereqPage);
  LblDistro.Parent := PrereqPage.Surface;
  LblDistro.Top := Top; LblDistro.Left := 0;
  Top := Top + ScaleY(30);

  BtnRecheck := TNewButton.Create(PrereqPage);
  BtnRecheck.Parent := PrereqPage.Surface;
  BtnRecheck.Caption := CustomMessage('PrereqRecheck');
  BtnRecheck.Top := Top; BtnRecheck.Left := 0;
  BtnRecheck.Width := ScaleX(120); BtnRecheck.Height := ScaleY(26);
  BtnRecheck.OnClick := @RecheckClick;
  Top := Top + ScaleY(40);

  // Read-only memo so that the commands can be selected and copied
  MemoFix := TNewMemo.Create(PrereqPage);
  MemoFix.Parent := PrereqPage.Surface;
  MemoFix.Top := Top; MemoFix.Left := 0;
  MemoFix.Width := PrereqPage.SurfaceWidth;
  MemoFix.Height := PrereqPage.SurfaceHeight - Top;
  MemoFix.ReadOnly := True;
  MemoFix.ScrollBars := ssVertical;
  MemoFix.Visible := False;
end;

procedure CurPageChanged(CurPageID: Integer);
begin
  if CurPageID = PrereqPage.ID then
    RefreshPrereqs;
end;

function NextButtonClick(CurPageID: Integer): Boolean;
begin
  Result := True;
  if CurPageID = PrereqPage.ID then
    if PrereqMask <> 0 then
    begin
      MsgBox(CustomMessage('PrereqBlocked'), mbError, MB_OK);
      Result := False;
    end;
end;
