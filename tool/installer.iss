#ifndef AppVersion
  #define AppVersion "1.0.0"
#endif

[Setup]
AppId={{7D2B4E1A-5C3F-4A89-B6E0-9F1D2C3A4B5E}
AppName=gravadoC
AppVersion={#AppVersion}
AppPublisher=gravadoC
DefaultDirName={autopf}\gravadoC
DefaultGroupName=gravadoC
OutputDir=..\dist
OutputBaseFilename=gravadoC-Setup-{#AppVersion}
SetupIconFile=..\windows\runner\resources\app_icon.ico
UninstallDisplayIcon={app}\gravadoC.exe
Compression=lzma2/ultra64
SolidCompression=yes
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
PrivilegesRequired=lowest
PrivilegesRequiredOverridesAllowed=dialog
WizardStyle=modern

[Languages]
Name: "brazilianportuguese"; MessagesFile: "compiler:Languages\BrazilianPortuguese.isl"

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"; Flags: unchecked

[Files]
Source: "..\dist\gravadoC\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{group}\gravadoC"; Filename: "{app}\gravadoC.exe"
Name: "{autodesktop}\gravadoC"; Filename: "{app}\gravadoC.exe"; Tasks: desktopicon

[Run]
Filename: "{app}\gravadoC.exe"; Description: "{cm:LaunchProgram,gravadoC}"; Flags: nowait postinstall skipifsilent
