<#
.SYNOPSIS
    PS-VHDX : convertit un répertoire en disque virtuel VHDX par clic droit dans l'Explorateur.

.DESCRIPTION
    -Install    : copie le script dans %LOCALAPPDATA%\PS-VHDX et ajoute « Convertir en VHDX (PS-VHDX) »
                  au menu contextuel des dossiers (HKCU, sans droits administrateur) :
                    - menu classique (« Afficher plus d'options » sous Windows 11) ;
                    - nouveau menu de Windows 11 (premier clic droit), si le poste le permet.
    -Uninstall  : retire les deux entrées de menu.
    -Path <dir> : crée <dossier>.vhdx à côté du dossier source (dynamique, GPT, NTFS),
                  y copie le contenu par robocopy (ACL, attributs, horodatages), puis démonte.
    -EnableDeveloperMode : avec -Install, en administrateur, active le mode développeur de
                  Windows pour ouvrir l'accès au nouveau menu sans certificat.

    Ne nécessite pas Hyper-V : création par diskpart, montage par Mount-DiskImage.
    La conversion s'élève automatiquement en administrateur (UAC).

    NOUVEAU MENU DE WINDOWS 11 (v1.2 : aucun binaire dans le script)
    Ce menu n'accepte que les applications empaquetées. Le script contient, en clair, le code C#
    d'un petit serveur COM hors processus (IExplorerCommand). À l'installation, Windows PowerShell
    5.1 le compile sur le poste (Add-Type, compilateur C# de .NET Framework 4.x) en
    %LOCALAPPDATA%\PS-VHDX\shell\psvhdx-shell.exe, dessine les logos du paquet (System.Drawing),
    puis enregistre un paquet d'identité MSIX avec emplacement externe qui déclare ce serveur
    (com:ExeServer). Deux voies d'enregistrement, choisies automatiquement :
      - mode développeur de Windows actif : enregistrement direct du manifeste, sans certificat
        ni droits administrateur ;
      - sinon SDK Windows présent (makeappx, signtool) : paquet signé par un certificat auto-signé,
        approuvé dans « Personnes autorisées » de l'ordinateur (une invite UAC ; le magasin de
        l'utilisateur ne suffit pas, erreur 0x800B0109), clé privée détruite après signature.
    Windows 11 x64 uniquement. Sans l'une des deux voies, seul le menu classique est installé.
    Le serveur lit sa commande, son libellé et son icône dans HKCU\Software\PS-VHDX\Shell.

.EXAMPLE
    .\PS-VHDX.ps1 -Install
    .\PS-VHDX.ps1 -Install -EnableDeveloperMode     # en administrateur
    .\PS-VHDX.ps1 -Path "D:\Projets\Archive2025"

.NOTES
    Projet : PS-VHDX (gamme PS-* de CL SASU)
    Version : 1.2
    Compatible Windows PowerShell 5.1 et PowerShell 7.
    Généré par le modèle claude-opus-5-5
#>
[CmdletBinding(DefaultParameterSetName = 'Convert')]
param(
    [Parameter(ParameterSetName = 'Convert', Position = 0)] [string] $Path,
    [Parameter(ParameterSetName = 'Install')]   [switch] $Install,
    [Parameter(ParameterSetName = 'Install')]   [switch] $EnableDeveloperMode,
    [Parameter(ParameterSetName = 'Uninstall')] [switch] $Uninstall,
    [Parameter(ParameterSetName = 'Convert')]   [double] $Marge = 1.25,
    [Parameter(ParameterSetName = 'Convert')]   [switch] $NoPause
)

$ErrorActionPreference = 'Stop'
$AppName  = 'PS-VHDX'
$Version  = '1.2'
$Label    = 'Convertir en VHDX (PS-VHDX)'
$MenuKeys = @("HKCU:\Software\Classes\Directory\shell\$AppName", "HKCU:\Software\Classes\Directory\Background\shell\$AppName")
$InstDir  = Join-Path $env:LOCALAPPDATA $AppName
$InstFile = Join-Path $InstDir 'PS-VHDX.ps1'

# Nouveau menu de Windows 11
$SHELL_PKG_NAME  = 'CLSASU.PSVHDX.Shell'
$SHELL_PUBLISHER = 'CN=PSVHDX-Shell'
$SHELL_PKG_VER   = '1.2.0.0'
$SHELL_CLSID     = '5C09FA0F-EE54-477A-BA60-6F6BAFD6657A'
$SHELL_EXE       = 'psvhdx-shell.exe'
$SHELL_ICON      = '%SystemRoot%\System32\imageres.dll,-30'
$SHELL_OLD_FILES = @('psvhdx-shell11.dll', 'psvhdx-launch11.exe', 'psvhdx.ico')   # restes de la v1.1
$SHELL_REGKEY    = 'HKCU:\Software\PS-VHDX\Shell'
$ShellDir        = Join-Path $InstDir 'shell'
$ShellPkgDir     = Join-Path $InstDir 'shell-pkg'


function Write-Etape([string]$Texte) { Write-Host ("[{0}] {1}" -f (Get-Date -Format 'HH:mm:ss'), $Texte) -ForegroundColor Cyan }
function Format-Taille([double]$o) {
    if ($o -ge 1TB) { '{0:N2} To' -f ($o / 1TB) } elseif ($o -ge 1GB) { '{0:N2} Go' -f ($o / 1GB) }
    elseif ($o -ge 1MB) { '{0:N1} Mo' -f ($o / 1MB) } else { '{0:N0} o' -f $o }
}
function Test-IsAdmin {
    ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)
}
function ConvertTo-PsLiteral([string]$s) { "'" + $s.Replace("'", "''") + "'" }
function Get-VhdxCommand([string]$Arg) {
    "powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"$InstFile`" -Path `"$Arg`""
}

# ================================================================ Extension compilée sur le poste
function Get-Sha256Text([string]$Text) {
    $h = [System.Security.Cryptography.SHA256]::Create()
    try { -join ($h.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($Text)) | ForEach-Object { $_.ToString('x2') }) } finally { $h.Dispose() }
}
# Vrai si psvhdx-shell.exe existe et provient du code C# de CE script
# (empreinte du source gardée dans shell\source.sha256).
function Test-ShellBuilt {
    $exe   = Join-Path $ShellDir $SHELL_EXE
    $stamp = Join-Path $ShellDir 'source.sha256'
    if (-not (Test-Path -LiteralPath $exe) -or -not (Test-Path -LiteralPath $stamp)) { return $false }
    try { ([System.IO.File]::ReadAllText($stamp)).Trim() -eq (Get-Sha256Text $SHELL_CS) } catch { $false }
}
function Stop-ShellServer {
    Get-Process -Name ([System.IO.Path]::GetFileNameWithoutExtension($SHELL_EXE)) -ErrorAction SilentlyContinue |
        Stop-Process -Force -ErrorAction SilentlyContinue
}
# Compile le code C# ($SHELL_CS, en fin de script) par Windows PowerShell 5.1 :
# son Add-Type utilise le compilateur de .NET Framework, présent sur tout
# Windows 10 et 11, et produit un exécutable qui tourne sans PowerShell 7.
function Build-ShellExe {
    foreach ($d in @($ShellDir, $ShellPkgDir, (Join-Path $ShellPkgDir 'Assets'))) {
        if (-not (Test-Path -LiteralPath $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
    }
    foreach ($o in $SHELL_OLD_FILES) {
        $f = Join-Path $ShellDir $o
        if (Test-Path -LiteralPath $f) { Remove-Item -LiteralPath $f -Force -ErrorAction SilentlyContinue }
    }
    if (Test-ShellBuilt) { return }
    Stop-ShellServer
    $cs  = Join-Path $ShellDir 'psvhdx-shell.cs'
    $exe = Join-Path $ShellDir $SHELL_EXE
    $tmp = "$exe.new"
    [System.IO.File]::WriteAllText($cs, $SHELL_CS, (New-Object System.Text.UTF8Encoding($true)))
    if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Force }
    $r = Invoke-WinPS ("Add-Type -Path {0} -OutputAssembly {1} -OutputType WindowsApplication -ReferencedAssemblies System.Windows.Forms" -f (ConvertTo-PsLiteral $cs), (ConvertTo-PsLiteral $tmp))
    if ($r.Code -ne 0 -or -not (Test-Path -LiteralPath $tmp)) { throw "compilation de l'extension du menu impossible : $($r.Out)" }
    Move-Item -LiteralPath $tmp -Destination $exe -Force
    [System.IO.File]::WriteAllText((Join-Path $ShellDir 'source.sha256'), (Get-Sha256Text $SHELL_CS))
}
# Logos exigés par le manifeste MSIX, dessinés sur le poste (dossier et disque).
function New-ShellAssets {
    $a = Join-Path $ShellPkgDir 'Assets'
    $want = @{ 'Square150x150Logo.png' = 150; 'Square44x44Logo.png' = 44; 'StoreLogo.png' = 50 }
    $todo = @($want.Keys | Where-Object { -not (Test-Path -LiteralPath (Join-Path $a $_)) })
    if (-not $todo.Count) { return }
    $lines = foreach ($n in $todo) { "New-Logo {0} {1}" -f $want[$n], (ConvertTo-PsLiteral (Join-Path $a $n)) }
    $r = Invoke-WinPS (@'
Add-Type -AssemblyName System.Drawing
function New-Logo([int]$s, [string]$p) {
    $k = $s / 256.0
    $b = New-Object System.Drawing.Bitmap $s, $s
    $g = [System.Drawing.Graphics]::FromImage($b)
    $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $g.Clear([System.Drawing.Color]::Transparent)
    $c = { param($r, $v, $bl) New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb($r, $v, $bl)) }
    $g.FillRectangle((& $c 224 163 37), [single](18 * $k), [single](34 * $k), [single](96 * $k), [single](40 * $k))
    $g.FillRectangle((& $c 245 185 66), [single](18 * $k), [single](66 * $k), [single](206 * $k), [single](96 * $k))
    $g.FillRectangle((& $c 59 130 246), [single](60 * $k), [single](112 * $k), [single](180 * $k), [single](128 * $k))
    $pen = New-Object System.Drawing.Pen ([System.Drawing.Color]::FromArgb(191, 219, 254)), ([single][Math]::Max(1, 6 * $k))
    $g.DrawEllipse($pen, [single](128 * $k), [single](136 * $k), [single](44 * $k), [single](44 * $k))
    $g.FillRectangle((& $c 191 219 254), [single](84 * $k), [single](206 * $k), [single](132 * $k), [single][Math]::Max(1, 14 * $k))
    $b.Save($p, [System.Drawing.Imaging.ImageFormat]::Png)
    $pen.Dispose(); $g.Dispose(); $b.Dispose()
}
'@ + "`n" + ($lines -join "`n"))
    if ($r.Code -ne 0) { throw "logos du paquet : $($r.Out)" }
}

# ================================================================ Menu classique
function Install-ClassicMenu {
    foreach ($k in $MenuKeys) {
        $arg = if ($k -like '*\Background\*') { '%V' } else { '%1' }
        New-Item -Path $k -Force | Out-Null
        Set-ItemProperty -LiteralPath $k -Name '(default)' -Value $Label
        Set-ItemProperty -LiteralPath $k -Name 'Icon' -Value $SHELL_ICON
        New-Item -Path "$k\command" -Force | Out-Null
        Set-ItemProperty -LiteralPath "$k\command" -Name '(default)' -Value (Get-VhdxCommand $arg)
    }
}
function Uninstall-ClassicMenu {
    foreach ($k in $MenuKeys) { if (Test-Path -LiteralPath $k) { Remove-Item -LiteralPath $k -Recurse -Force } }
}

# ================================================================ Nouveau menu de Windows 11
function Test-ModernSupported {
    try {
        $arch = $env:PROCESSOR_ARCHITEW6432
        if (-not $arch) { $arch = $env:PROCESSOR_ARCHITECTURE }
        ([Environment]::OSVersion.Version.Build -ge 22000 -and $arch -eq 'AMD64')
    } catch { $false }
}
function Test-DevMode {
    try { (Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\AppModelUnlock' -Name AllowDevelopmentWithoutDevLicense -ErrorAction Stop).AllowDevelopmentWithoutDevLicense -eq 1 } catch { $false }
}
function Find-WinSdkTool([string]$Name) {
    foreach ($root in @("${env:ProgramFiles(x86)}\Windows Kits\10\bin", "$env:ProgramFiles\Windows Kits\10\bin")) {
        if (-not (Test-Path -LiteralPath $root)) { continue }
        $vers = @(Get-ChildItem -LiteralPath $root -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -match '^10\.' } | Sort-Object { [version]$_.Name } -Descending)
        foreach ($v in $vers) { $p = Join-Path $v.FullName "x64\$Name"; if (Test-Path -LiteralPath $p) { return $p } }
        $p = Join-Path $root "x64\$Name"; if (Test-Path -LiteralPath $p) { return $p }
    }
    $c = Get-Command $Name -ErrorAction SilentlyContinue
    if ($c) { return $c.Source }
    $null
}
# Les cmdlets Appx et PKI passent par Windows PowerShell, quelle que soit
# l'édition qui exécute PS-VHDX (le module Appx n'est pas pris en charge
# nativement par PowerShell 7). Le texte revient en base64 de l'UTF-8 pour
# garder les accents (la console de Windows PowerShell écrit en page OEM).
function Invoke-WinPS([string]$Script) {
    $ErrorActionPreference = 'Continue'
    $exe = Join-Path $env:SystemRoot 'Sysnative\WindowsPowerShell\v1.0\powershell.exe'
    if (-not (Test-Path -LiteralPath $exe)) { $exe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe' }
    $wrap = @"
`$ProgressPreference = 'SilentlyContinue'
`$__c = 0
try {
    `$__t = (& {
`$ErrorActionPreference = 'Stop'
$Script
} 2>&1 | Out-String)
} catch { `$__c = 1; `$__t = `$_.Exception.Message }
[Console]::Out.Write('PSVHDX64:' + [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes([string]`$__t)))
exit `$__c
"@
    $enc = [Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($wrap))
    $out = (& $exe -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -OutputFormat Text -EncodedCommand $enc 2>$null) | Out-String
    $code = $LASTEXITCODE
    $i = $out.LastIndexOf('PSVHDX64:')
    $txt = $out.Trim()
    if ($i -ge 0) { try { $txt = [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String(($out.Substring($i + 9) -replace '\s', ''))).Trim() } catch {} }
    @{ Code = $code; Out = $txt }
}
# Action en administrateur (une invite UAC si besoin).
function Invoke-Admin([string]$Script, [string]$What) {
    if (Test-IsAdmin) {
        try { & ([scriptblock]::Create("`$ErrorActionPreference = 'Stop'`n" + $Script)) | Out-Null } catch { throw "$What : $($_.Exception.Message)" }
        return
    }
    $res = Join-Path $InstDir 'admin-result.txt'
    if (Test-Path -LiteralPath $res) { Remove-Item -LiteralPath $res -Force -ErrorAction SilentlyContinue }
    $wrap = @"
`$ErrorActionPreference = 'Stop'
try {
$Script
    exit 0
} catch {
    try { [System.IO.File]::WriteAllText($(ConvertTo-PsLiteral $res), `$_.Exception.Message) } catch {}
    exit 1
}
"@
    $exe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $al  = @('-NoLogo', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden', '-EncodedCommand', [Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($wrap)))
    try { $p = Start-Process -FilePath $exe -ArgumentList $al -Verb RunAs -WindowStyle Hidden -Wait -PassThru }
    catch { throw "$What : autorisation administrateur refusée ou impossible ($($_.Exception.Message))" }
    if ($p.ExitCode -ne 0) {
        $m = ''; try { $m = [System.IO.File]::ReadAllText($res).Trim() } catch {}
        throw "$What : échec en administrateur (code $($p.ExitCode)) $m"
    }
}
function Get-MachineCerts {
    $s = New-Object System.Security.Cryptography.X509Certificates.X509Store('TrustedPeople', 'LocalMachine')
    try {
        $s.Open([System.Security.Cryptography.X509Certificates.OpenFlags]::ReadOnly)
        @($s.Certificates | Where-Object { $_.Subject -eq $SHELL_PUBLISHER } | ForEach-Object { $_.Thumbprint })
    } catch { @() } finally { $s.Close() }
}
function Write-ShellConfig {
    New-Item -Path $SHELL_REGKEY -Force | Out-Null
    Set-ItemProperty -LiteralPath $SHELL_REGKEY -Name 'Command' -Value (Get-VhdxCommand '%1')
    Set-ItemProperty -LiteralPath $SHELL_REGKEY -Name 'Label'   -Value $Label
    Set-ItemProperty -LiteralPath $SHELL_REGKEY -Name 'Icon'    -Value $SHELL_ICON
}
function Write-ShellManifest {
    $x = { param($v) [System.Security.SecurityElement]::Escape([string]$v) }
    $manifest = @"
<?xml version="1.0" encoding="utf-8"?>
<Package xmlns="http://schemas.microsoft.com/appx/manifest/foundation/windows10"
  xmlns:uap="http://schemas.microsoft.com/appx/manifest/uap/windows10"
  xmlns:uap10="http://schemas.microsoft.com/appx/manifest/uap/windows10/10"
  xmlns:rescap="http://schemas.microsoft.com/appx/manifest/foundation/windows10/restrictedcapabilities"
  xmlns:desktop4="http://schemas.microsoft.com/appx/manifest/desktop/windows10/4"
  xmlns:desktop5="http://schemas.microsoft.com/appx/manifest/desktop/windows10/5"
  xmlns:com="http://schemas.microsoft.com/appx/manifest/com/windows10"
  IgnorableNamespaces="uap uap10 rescap desktop4 desktop5 com">
  <Identity Name="$SHELL_PKG_NAME" Publisher="$(& $x $SHELL_PUBLISHER)" Version="$SHELL_PKG_VER" ProcessorArchitecture="neutral" />
  <Properties>
    <DisplayName>PS-VHDX</DisplayName>
    <PublisherDisplayName>CL SASU</PublisherDisplayName>
    <Logo>Assets\StoreLogo.png</Logo>
    <uap10:AllowExternalContent>true</uap10:AllowExternalContent>
  </Properties>
  <Resources>
    <Resource Language="fr-fr" />
  </Resources>
  <Dependencies>
    <TargetDeviceFamily Name="Windows.Desktop" MinVersion="10.0.19041.0" MaxVersionTested="10.0.26100.0" />
  </Dependencies>
  <Capabilities>
    <rescap:Capability Name="runFullTrust" />
    <rescap:Capability Name="unvirtualizedResources" />
  </Capabilities>
  <Applications>
    <Application Id="PSVHDX" Executable="$SHELL_EXE" uap10:TrustLevel="mediumIL" uap10:RuntimeBehavior="win32App">
      <uap:VisualElements AppListEntry="none" DisplayName="PS-VHDX" Description="PS-VHDX : dossier vers disque virtuel VHDX" BackgroundColor="transparent" Square150x150Logo="Assets\Square150x150Logo.png" Square44x44Logo="Assets\Square44x44Logo.png" />
      <Extensions>
        <desktop4:Extension Category="windows.fileExplorerContextMenus">
          <desktop4:FileExplorerContextMenus>
            <desktop5:ItemType Type="Directory">
              <desktop5:Verb Id="PsVhdxConvert" Clsid="$SHELL_CLSID" />
            </desktop5:ItemType>
            <desktop5:ItemType Type="Directory\Background">
              <desktop5:Verb Id="PsVhdxConvertHere" Clsid="$SHELL_CLSID" />
            </desktop5:ItemType>
          </desktop4:FileExplorerContextMenus>
        </desktop4:Extension>
        <com:Extension Category="windows.comServer">
          <com:ComServer>
            <com:ExeServer Executable="$SHELL_EXE" Arguments="-Embedding" DisplayName="PS-VHDX">
              <com:Class Id="$SHELL_CLSID" />
            </com:ExeServer>
          </com:ComServer>
        </com:Extension>
      </Extensions>
    </Application>
  </Applications>
</Package>
"@
    [System.IO.File]::WriteAllText((Join-Path $ShellPkgDir 'AppxManifest.xml'), $manifest, (New-Object System.Text.UTF8Encoding($false)))
}
# État : unsupported, absent, outdated, ok. Voie : devmode, sdk ou none.
function Get-ModernState {
    $r = @{ State = 'unsupported'; Route = 'none'; Version = '' }
    if (-not (Test-ModernSupported)) { return $r }
    if (Test-DevMode) { $r.Route = 'devmode' }
    elseif ((Find-WinSdkTool 'makeappx.exe') -and (Find-WinSdkTool 'signtool.exe')) { $r.Route = 'sdk' }
    $q = Invoke-WinPS ("`$p = Get-AppxPackage -Name {0} -ErrorAction SilentlyContinue | Select-Object -First 1; if (`$p) {{ [string]`$p.Version }}" -f (ConvertTo-PsLiteral $SHELL_PKG_NAME))
    $v = @($q.Out -split "`r?`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ -match '^\d+(\.\d+){3}$' } | Select-Object -Last 1)
    $r.Version = if ($v.Count) { [string]$v[0] } else { '' }
    if (-not $r.Version) { $r.State = 'absent' }
    elseif ($r.Version -ne $SHELL_PKG_VER -or -not (Test-ShellBuilt)) { $r.State = 'outdated' }
    else { $r.State = 'ok' }
    $r
}
function Install-ModernMenu {
    $st = Get-ModernState
    if ($st.State -eq 'unsupported') { return $st }
    Write-ShellConfig
    if ($st.State -eq 'ok') { return $st }
    if ($st.Route -eq 'none') { throw "activez le mode développeur de Windows (.\PS-VHDX.ps1 -Install -EnableDeveloperMode, en administrateur) ou installez le SDK Windows (makeappx, signtool)" }
    Write-Host "    Compilation de l'extension du menu sur le poste (Windows PowerShell, .NET Framework)."
    Build-ShellExe
    New-ShellAssets
    Write-ShellManifest
    $pkgName = ConvertTo-PsLiteral $SHELL_PKG_NAME
    $pub     = ConvertTo-PsLiteral $SHELL_PUBLISHER
    $ext     = ConvertTo-PsLiteral $ShellDir
    if ($st.Route -eq 'sdk') {
        $msix = Join-Path $InstDir ("psvhdx-shell-{0}.msix" -f $SHELL_PKG_VER)
        $cer  = Join-Path $InstDir 'psvhdx-shell.cer'
        # 1. Certificat de signature (compte de l'utilisateur), réutilisé tant qu'il a sa clé.
        $a = Invoke-WinPS @"
foreach (`$o in @(Get-ChildItem Cert:\CurrentUser\TrustedPeople | Where-Object { `$_.Subject -eq $pub })) { Remove-Item -LiteralPath `$o.PSPath }
`$c = Get-ChildItem Cert:\CurrentUser\My | Where-Object { `$_.Subject -eq $pub -and `$_.HasPrivateKey -and `$_.NotAfter -gt (Get-Date).AddDays(30) } | Select-Object -First 1
if (-not `$c) { `$c = New-SelfSignedCertificate -Type Custom -Subject $pub -KeyUsage DigitalSignature -KeyExportPolicy NonExportable -FriendlyName 'PS-VHDX, menu de Windows 11' -CertStoreLocation 'Cert:\CurrentUser\My' -TextExtension @('2.5.29.37={text}1.3.6.1.5.5.7.3.3', '2.5.29.19={text}') -NotAfter (Get-Date).AddYears(10) }
[System.IO.File]::WriteAllBytes($(ConvertTo-PsLiteral $cer), `$c.RawData)
'THUMB:' + `$c.Thumbprint
"@
        if ($a.Code -ne 0) { throw "certificat : $($a.Out)" }
        $thumb = ''
        if ($a.Out -match 'THUMB:([0-9A-Fa-f]{40})') { $thumb = $Matches[1].ToUpperInvariant() }
        if (-not $thumb) { throw "certificat : empreinte introuvable ($($a.Out))" }
        # 2. Approbation par l'ordinateur : seule étape administrateur, sautée si déjà faite.
        if (@(Get-MachineCerts) -notcontains $thumb) {
            Write-Host "    Approbation du certificat PS-VHDX par l'ordinateur (une invite UAC)."
            Invoke-Admin -What "approbation du certificat PS-VHDX" -Script @"
`$c = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2($(ConvertTo-PsLiteral $cer))
`$s = New-Object System.Security.Cryptography.X509Certificates.X509Store('TrustedPeople', 'LocalMachine')
`$s.Open([System.Security.Cryptography.X509Certificates.OpenFlags]::ReadWrite)
foreach (`$o in @(`$s.Certificates | Where-Object { `$_.Subject -eq $pub -and `$_.Thumbprint -ne `$c.Thumbprint })) { `$s.Remove(`$o) }
`$s.Add(`$c)
`$s.Close()
"@
        }
        # 3. Paquet, signature, enregistrement, puis destruction de la clé privée.
        $ps = @"
`$ErrorActionPreference = 'Continue'
`$o = & $(ConvertTo-PsLiteral (Find-WinSdkTool 'makeappx.exe')) pack /o /nv /d $(ConvertTo-PsLiteral $ShellPkgDir) /p $(ConvertTo-PsLiteral $msix) 2>&1
if (`$LASTEXITCODE) { throw ('makeappx : ' + (`$o | Out-String)) }
`$o = & $(ConvertTo-PsLiteral (Find-WinSdkTool 'signtool.exe')) sign /fd SHA256 /sha1 $thumb /s My $(ConvertTo-PsLiteral $msix) 2>&1
if (`$LASTEXITCODE) { throw ('signtool : ' + (`$o | Out-String)) }
`$ErrorActionPreference = 'Stop'
Get-AppxPackage -Name $pkgName | Remove-AppxPackage -ErrorAction SilentlyContinue
Add-AppxPackage -Path $(ConvertTo-PsLiteral $msix) -ExternalLocation $ext
foreach (`$o in @(Get-ChildItem Cert:\CurrentUser\My | Where-Object { `$_.Subject -eq $pub })) { Remove-Item -LiteralPath `$o.PSPath -DeleteKey -ErrorAction SilentlyContinue }
"@
    } else {
        $ps = @"
Get-AppxPackage -Name $pkgName | Remove-AppxPackage -ErrorAction SilentlyContinue
Add-AppxPackage -Path $(ConvertTo-PsLiteral (Join-Path $ShellPkgDir 'AppxManifest.xml')) -Register -ExternalLocation $ext
"@
    }
    $res = Invoke-WinPS $ps
    if ($res.Code -ne 0) { throw "enregistrement du paquet ($($st.Route)) : $($res.Out)" }
    Get-ModernState
}
function Uninstall-ModernMenu {
    $pub = ConvertTo-PsLiteral $SHELL_PUBLISHER
    [void](Invoke-WinPS @"
`$ErrorActionPreference = 'Continue'
Get-AppxPackage -Name $(ConvertTo-PsLiteral $SHELL_PKG_NAME) | Remove-AppxPackage
foreach (`$o in @(Get-ChildItem Cert:\CurrentUser\TrustedPeople | Where-Object { `$_.Subject -eq $pub })) { Remove-Item -LiteralPath `$o.PSPath -ErrorAction SilentlyContinue }
foreach (`$o in @(Get-ChildItem Cert:\CurrentUser\My | Where-Object { `$_.Subject -eq $pub })) {
    if (`$o.HasPrivateKey) { Remove-Item -LiteralPath `$o.PSPath -DeleteKey -ErrorAction SilentlyContinue } else { Remove-Item -LiteralPath `$o.PSPath -ErrorAction SilentlyContinue }
}
"@)
    if (Test-Path -LiteralPath $SHELL_REGKEY) { Remove-Item -LiteralPath $SHELL_REGKEY -Recurse -Force -ErrorAction SilentlyContinue }
    # Certificat approuvé par l'ordinateur : retrait en administrateur, seulement s'il existe.
    if (@(Get-MachineCerts).Count -gt 0) {
        try {
            Invoke-Admin -What "retrait du certificat PS-VHDX" -Script @"
`$s = New-Object System.Security.Cryptography.X509Certificates.X509Store('TrustedPeople', 'LocalMachine')
`$s.Open([System.Security.Cryptography.X509Certificates.OpenFlags]::ReadWrite)
foreach (`$o in @(`$s.Certificates | Where-Object { `$_.Subject -eq $pub })) { `$s.Remove(`$o) }
`$s.Close()
"@
        } catch { Write-Warning "$_ ; certificat « PSVHDX-Shell » à retirer à la main (certlm.msc, Personnes autorisées)." }
    }
    # Le serveur peut encore tourner (30 s après le dernier clic droit) : il est arrêté.
    Stop-ShellServer
    foreach ($d in @($ShellPkgDir, $ShellDir)) {
        if (Test-Path -LiteralPath $d) { Remove-Item -LiteralPath $d -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

# ================================================================ Conversion
function Invoke-Conversion {
    if (-not $Path) { throw "Indiquer -Path <répertoire>, ou -Install." }
    # Trim('"') : un fond de lecteur passe « C:\" », le \ final échappant le guillemet
    $script:Path = $Path.Trim().Trim('"').TrimEnd('\')
    $Path = $script:Path
    if ($Path -match '^[A-Za-z]:$') { throw "Un lecteur entier n'est pas pris en charge, choisir un dossier." }

    # Auto-élévation
    if (-not (Test-IsAdmin)) {
        $args2 = "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`" -Path `"$Path`" -Marge $Marge"
        if ($NoPause) { $args2 += ' -NoPause' }
        Start-Process -FilePath 'powershell.exe' -Verb RunAs -ArgumentList $args2
        return
    }

    $Host.UI.RawUI.WindowTitle = "$AppName : $Path"
    $vhdx = $null; $monte = $false; $ok = $false
    try {
        $src = Get-Item -LiteralPath $Path
        if (-not $src.PSIsContainer) { throw "« $Path » n'est pas un dossier." }

        # Fichier cible : <dossier>.vhdx à côté de la source, horodaté si déjà présent
        $parent = Split-Path -Parent $src.FullName
        $vhdx = Join-Path $parent ($src.Name + '.vhdx')
        if (Test-Path -LiteralPath $vhdx) { $vhdx = Join-Path $parent ("{0}_{1}.vhdx" -f $src.Name, (Get-Date -Format 'yyyyMMdd_HHmmss')) }

        Write-Etape "Mesure du dossier $($src.FullName)"
        $fichiers = Get-ChildItem -LiteralPath $src.FullName -Recurse -Force -File -ErrorAction SilentlyContinue
        $octets = ($fichiers | Measure-Object -Property Length -Sum).Sum
        if (-not $octets) { $octets = 0 }
        $nb = @($fichiers).Count
        # Taille maximale : contenu x marge + 1 Go (métadonnées NTFS, MFT, petits fichiers). Disque dynamique : seul l'utilisé occupe la place.
        $maxMo = [math]::Max(512, [math]::Ceiling(($octets * $Marge) / 1MB) + 1024)
        Write-Host ("    {0} fichiers, {1} ; taille maximale du VHDX : {2}" -f $nb, (Format-Taille $octets), (Format-Taille ($maxMo * 1MB)))

        $drive = (Split-Path -Qualifier $vhdx).TrimEnd(':')
        $libre = (Get-PSDrive -Name $drive).Free
        if ($libre -lt ($octets * 1.05)) { throw "Espace libre insuffisant sur ${drive}: ($(Format-Taille $libre) pour $(Format-Taille $octets))." }

        Write-Etape "Création de $vhdx"
        $dp = Join-Path $env:TEMP "ps-vhdx_$PID.txt"
        "create vdisk file=`"$vhdx`" maximum=$maxMo type=expandable" | Set-Content -Path $dp -Encoding ASCII
        $sortie = & diskpart.exe /s $dp 2>&1
        Remove-Item $dp -Force -ErrorAction SilentlyContinue
        if (-not (Test-Path -LiteralPath $vhdx)) { throw "diskpart n'a pas créé le fichier :`n$($sortie -join "`n")" }

        Write-Etape "Montage, initialisation GPT, formatage NTFS"
        $img = Mount-DiskImage -ImagePath $vhdx -PassThru
        $monte = $true
        $disque = $img | Get-Disk
        Initialize-Disk -Number $disque.Number -PartitionStyle GPT
        $part = New-Partition -DiskNumber $disque.Number -UseMaximumSize -AssignDriveLetter
        $label = ($src.Name -replace '[^\w\- ]', '_')
        if ($label.Length -gt 32) { $label = $label.Substring(0, 32) }
        Format-Volume -Partition $part -FileSystem NTFS -NewFileSystemLabel $label -Confirm:$false | Out-Null
        $lettre = (Get-Partition -DiskNumber $disque.Number -PartitionNumber $part.PartitionNumber).DriveLetter
        if (-not $lettre) { throw "Aucune lettre attribuée au volume du VHDX." }
        $cible = "${lettre}:\"

        Write-Etape "Copie vers $cible (robocopy, ACL et horodatages conservés)"
        $log = [IO.Path]::ChangeExtension($vhdx, '.robocopy.log')
        & robocopy.exe $src.FullName $cible /E /COPYALL /DCOPY:DAT /B /XJ /R:1 /W:1 /MT:16 /NP /NFL /NDL /TEE "/UNILOG:$log" | Out-Host
        $rc = $LASTEXITCODE
        if ($rc -ge 8) { throw "robocopy a échoué (code $rc), voir $log" }

        Write-Etape "Vérification"
        $copies = Get-ChildItem -LiteralPath $cible -Recurse -Force -File -ErrorAction SilentlyContinue |
                  Where-Object { $_.FullName -notmatch '\\System Volume Information\\' }
        $nbC = @($copies).Count; $octC = ($copies | Measure-Object Length -Sum).Sum
        Write-Host ("    Source : {0} fichiers, {1} | VHDX : {2} fichiers, {3}" -f $nb, (Format-Taille $octets), $nbC, (Format-Taille $octC))
        if ($nbC -ne $nb -or $octC -ne $octets) { Write-Warning "Écart entre source et copie : consulter $log (fichiers verrouillés ou inaccessibles ?)." }
        else { $ok = $true }
    }
    catch {
        Write-Host "ERREUR : $($_.Exception.Message)" -ForegroundColor Red
    }
    finally {
        if ($monte) {
            Write-Etape "Démontage"
            try { Dismount-DiskImage -ImagePath $vhdx | Out-Null } catch { Write-Warning "Démontage impossible : $($_.Exception.Message)" }
        }
    }

    if ($ok) {
        $final = (Get-Item -LiteralPath $vhdx).Length
        Write-Host ("`nTerminé : {0} ({1} sur disque). Le dossier source n'a pas été modifié." -f $vhdx, (Format-Taille $final)) -ForegroundColor Green
        Write-Host "Double-clic sur le .vhdx pour le monter."
    }
    if (-not $NoPause) { Read-Host "`nEntrée pour fermer" | Out-Null }
}

# ================================================================ Code C# de l'extension du menu
# Lisible et vérifiable : c'est ce code, et lui seul, qui est compilé à -Install.
$SHELL_CS = @'
// psvhdx-shell.cs : extension du nouveau menu contextuel de Windows 11 pour PS-VHDX.
// Compilé sur le poste par Windows PowerShell 5.1 (Add-Type, compilateur C# de
// .NET Framework 4.x) au moment de -Install : aucun binaire n'est livré.
//
// Un seul exécutable, deux rôles :
//   psvhdx-shell.exe -Embedding : serveur COM hors processus (com:ExeServer du
//     paquet MSIX). Expose IExplorerCommand : « Convertir en VHDX (PS-VHDX) ».
//     Se termine seul après 30 s sans appel.
//   psvhdx-shell.exe <dossier>  : lance la commande de conversion pour ce dossier.
// Configuration lue dans HKCU\Software\PS-VHDX\Shell : Command (%1 = chemin),
// Label, Icon. Sans Command, l'entrée est masquée. Un seul dossier, jamais la
// racine d'un lecteur.
// C# 5 seulement (compilateur de .NET Framework) : pas d'interpolation ni de ?.
// Projet PS-VHDX (CL SASU). Généré par le modèle claude-opus-5-5
using System;
using System.Diagnostics;
using System.IO;
using System.Runtime.InteropServices;
using System.Windows.Forms;
using Microsoft.Win32;

namespace PsVhdx
{
    [ComImport, Guid("43826d1e-e718-42ee-bc55-a1e261c37bfe"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    public interface IShellItem
    {
        void BindToHandler(IntPtr pbc, ref Guid bhid, ref Guid riid, out IntPtr ppv);
        void GetParent(out IShellItem ppsi);
        void GetDisplayName(uint sigdnName, out IntPtr ppszName);
        void GetAttributes(uint sfgaoMask, out uint psfgaoAttribs);
        void Compare(IShellItem psi, uint hint, out int piOrder);
    }

    [ComImport, Guid("b63ea76d-1f85-456f-a19c-48159efa858b"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    public interface IShellItemArray
    {
        void BindToHandler(IntPtr pbc, ref Guid bhid, ref Guid riid, out IntPtr ppvOut);
        void GetPropertyStore(int flags, ref Guid riid, out IntPtr ppv);
        void GetPropertyDescriptionList(IntPtr keyType, ref Guid riid, out IntPtr ppv);
        void GetAttributes(int attribFlags, uint sfgaoMask, out uint psfgaoAttribs);
        void GetCount(out uint pdwNumItems);
        void GetItemAt(uint dwIndex, out IShellItem ppsi);
        void EnumItems(out IntPtr ppenumShellItems);
    }

    [ComImport, Guid("a08ce4d0-fa25-44ab-b57c-c7b1c323e0b9"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    public interface IExplorerCommand
    {
        [PreserveSig] int GetTitle(IShellItemArray items, out IntPtr name);
        [PreserveSig] int GetIcon(IShellItemArray items, out IntPtr icon);
        [PreserveSig] int GetToolTip(IShellItemArray items, out IntPtr tip);
        [PreserveSig] int GetCanonicalName(out Guid guid);
        [PreserveSig] int GetState(IShellItemArray items, [MarshalAs(UnmanagedType.Bool)] bool okToBeSlow, out uint state);
        [PreserveSig] int Invoke(IShellItemArray items, IntPtr bindCtx);
        [PreserveSig] int GetFlags(out uint flags);
        [PreserveSig] int EnumSubCommands(out IntPtr enumerator);
    }

    [ComImport, Guid("00000001-0000-0000-C000-000000000046"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    public interface IClassFactory
    {
        [PreserveSig] int CreateInstance(IntPtr outer, ref Guid riid, out IntPtr ppv);
        [PreserveSig] int LockServer([MarshalAs(UnmanagedType.Bool)] bool lockIt);
    }

    internal static class Config
    {
        public const string Clsid = "5C09FA0F-EE54-477A-BA60-6F6BAFD6657A";
        const string Key = @"Software\PS-VHDX\Shell";
        public const string DefaultLabel = "Convertir en VHDX (PS-VHDX)";

        public static string Read(string name)
        {
            try
            {
                using (RegistryKey k = Registry.CurrentUser.OpenSubKey(Key))
                {
                    if (k == null) return null;
                    string v = k.GetValue(name) as string;
                    if (string.IsNullOrEmpty(v)) return null;
                    return Environment.ExpandEnvironmentVariables(v);
                }
            }
            catch { return null; }
        }

        // Chemin du seul dossier sélectionné, ou null (plusieurs éléments, racine d'un lecteur).
        public static string SelectedPath(IShellItemArray items)
        {
            if (items == null) return null;
            try
            {
                uint n;
                items.GetCount(out n);
                if (n != 1) return null;
                IShellItem it;
                items.GetItemAt(0, out it);
                IntPtr p;
                it.GetDisplayName(0x80058000u, out p);   // SIGDN_FILESYSPATH
                string path = Marshal.PtrToStringUni(p);
                Marshal.FreeCoTaskMem(p);
                Marshal.ReleaseComObject(it);
                if (string.IsNullOrEmpty(path)) return null;
                string root = Path.GetPathRoot(path);
                if (root != null && string.Equals(root.TrimEnd('\\'), path.TrimEnd('\\'), StringComparison.OrdinalIgnoreCase)) return null;
                return path;
            }
            catch { return null; }
        }

        // Remplace %1 par le chemin, puis lance la commande dans une nouvelle console.
        public static bool Run(string path)
        {
            string tpl = Read("Command");
            if (tpl == null || string.IsNullOrEmpty(path)) return false;
            string line = tpl.Replace("%1", path).Trim();
            string exe, args;
            if (line.StartsWith("\""))
            {
                int q = line.IndexOf('"', 1);
                if (q < 0) return false;
                exe = line.Substring(1, q - 1);
                args = line.Substring(q + 1).TrimStart();
            }
            else
            {
                int s = line.IndexOf(' ');
                exe = s < 0 ? line : line.Substring(0, s);
                args = s < 0 ? "" : line.Substring(s + 1);
            }
            ProcessStartInfo psi = new ProcessStartInfo(exe, args);
            psi.UseShellExecute = false;
            Process.Start(psi);
            return true;
        }
    }

    [ComVisible(true), ClassInterface(ClassInterfaceType.None)]
    public class ConvertCommand : IExplorerCommand
    {
        const int S_OK = 0, E_NOTIMPL = unchecked((int)0x80004001), E_FAIL = unchecked((int)0x80004005);

        public int GetTitle(IShellItemArray items, out IntPtr name)
        {
            Program.Touch();
            name = Marshal.StringToCoTaskMemUni(Config.Read("Label") ?? Config.DefaultLabel);
            return S_OK;
        }
        public int GetIcon(IShellItemArray items, out IntPtr icon)
        {
            Program.Touch();
            string v = Config.Read("Icon");
            icon = v == null ? IntPtr.Zero : Marshal.StringToCoTaskMemUni(v);
            return v == null ? E_NOTIMPL : S_OK;
        }
        public int GetToolTip(IShellItemArray items, out IntPtr tip) { tip = IntPtr.Zero; return E_NOTIMPL; }
        public int GetCanonicalName(out Guid guid) { guid = new Guid(Config.Clsid); return S_OK; }
        public int GetState(IShellItemArray items, bool okToBeSlow, out uint state)
        {
            Program.Touch();
            bool show = Config.Read("Command") != null && Config.SelectedPath(items) != null;
            state = show ? 0u : 8u;   // ECS_ENABLED, ECS_HIDDEN
            return S_OK;
        }
        public int Invoke(IShellItemArray items, IntPtr bindCtx)
        {
            Program.Touch();
            try { return Config.Run(Config.SelectedPath(items)) ? S_OK : E_FAIL; }
            catch { return E_FAIL; }
        }
        public int GetFlags(out uint flags) { flags = 0; return S_OK; }   // ECF_DEFAULT
        public int EnumSubCommands(out IntPtr enumerator) { enumerator = IntPtr.Zero; return E_NOTIMPL; }
    }

    [ComVisible(true), ClassInterface(ClassInterfaceType.None)]
    public class Factory : IClassFactory
    {
        public int CreateInstance(IntPtr outer, ref Guid riid, out IntPtr ppv)
        {
            ppv = IntPtr.Zero;
            if (outer != IntPtr.Zero) return unchecked((int)0x80040110);   // CLASS_E_NOAGGREGATION
            Program.Touch();
            IntPtr unk = Marshal.GetIUnknownForObject(new ConvertCommand());
            try { return Marshal.QueryInterface(unk, ref riid, out ppv); }
            finally { Marshal.Release(unk); }
        }
        public int LockServer(bool lockIt) { return 0; }
    }

    public static class Program
    {
        [DllImport("ole32.dll")]
        static extern int CoRegisterClassObject(ref Guid rclsid, [MarshalAs(UnmanagedType.IUnknown)] object unk, uint context, uint flags, out uint cookie);
        [DllImport("ole32.dll")]
        static extern int CoRevokeClassObject(uint cookie);

        static DateTime last = DateTime.UtcNow;
        public static void Touch() { last = DateTime.UtcNow; }

        [STAThread]
        public static int Main(string[] args)
        {
            bool embedding = false;
            foreach (string a in args)
                if (string.Equals(a.TrimStart('-', '/'), "Embedding", StringComparison.OrdinalIgnoreCase)) embedding = true;

            if (!embedding)
            {
                // Rôle lanceur : psvhdx-shell.exe <dossier>
                if (args.Length < 1) return 0;
                try { return Config.Run(args[0]) ? 0 : 1; } catch { return 2; }
            }

            Guid clsid = new Guid(Config.Clsid);
            uint cookie;
            int hr = CoRegisterClassObject(ref clsid, new Factory(), 4u, 1u, out cookie);   // CLSCTX_LOCAL_SERVER, REGCLS_MULTIPLEUSE
            if (hr != 0) return hr;
            Timer t = new Timer();
            t.Interval = 5000;
            t.Tick += delegate
            {
                if ((DateTime.UtcNow - last).TotalSeconds > 30) { t.Stop(); Application.ExitThread(); }
            };
            t.Start();
            Application.Run();
            CoRevokeClassObject(cookie);
            return 0;
        }
    }
}
'@

# ================================================================ Point d'entrée
if ($Install) {
    New-Item -ItemType Directory -Path $InstDir -Force | Out-Null
    if ($PSCommandPath -ne $InstFile) { Copy-Item -LiteralPath $PSCommandPath -Destination $InstFile -Force }
    Install-ClassicMenu
    Write-Host "Menu classique installé : clic droit sur un dossier (ou dans un dossier) > « $Label »." -ForegroundColor Green
    if ($EnableDeveloperMode) {
        if (-not (Test-IsAdmin)) { throw "-EnableDeveloperMode demande une console PowerShell lancée en administrateur." }
        $k = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\AppModelUnlock'
        if (-not (Test-Path -LiteralPath $k)) { New-Item -Path $k -Force | Out-Null }
        New-ItemProperty -LiteralPath $k -Name 'AllowDevelopmentWithoutDevLicense' -PropertyType DWord -Value 1 -Force | Out-Null
        Write-Host "Mode développeur de Windows activé."
    }
    try {
        $m = Install-ModernMenu
        switch ($m.State) {
            'ok'          { Write-Host "Nouveau menu de Windows 11 installé ($($m.Route)) : l'entrée apparaît dès le premier clic droit." -ForegroundColor Green }
            'unsupported' { Write-Host "Nouveau menu : réservé à Windows 11 x64 ; l'entrée reste dans le menu classique." }
            default       { Write-Warning "Nouveau menu : état « $($m.State) » après installation." }
        }
    } catch {
        Write-Warning "Nouveau menu de Windows 11 non installé : $_"
        Write-Host "Windows 11 : l'entrée reste accessible par « Afficher plus d'options » (ou Maj + clic droit)."
    }
    return
}
if ($Uninstall) {
    Uninstall-ClassicMenu
    Uninstall-ModernMenu
    Write-Host "Entrées de menu retirées. Le script reste dans $InstDir." -ForegroundColor Green
    return
}
# v1.1.1 : lancé sans paramètre (double-clic, « Exécuter avec PowerShell »),
# le script affiche son mode d'emploi et propose d'agir, au lieu d'une erreur.
if (-not $Path) {
    Write-Host "PS-VHDX $Version : convertit un dossier en disque virtuel VHDX." -ForegroundColor Cyan
    Write-Host ""
    Write-Host "  .\PS-VHDX.ps1 -Install           ajoute « $Label » au clic droit des dossiers"
    Write-Host "  .\PS-VHDX.ps1 -Path <dossier>    convertit un dossier en <dossier>.vhdx"
    Write-Host "  .\PS-VHDX.ps1 -Uninstall         retire les entrées de menu"
    Write-Host "  Get-Help .\PS-VHDX.ps1 -Full     aide complète"
    if (-not $NoPause -and [Environment]::UserInteractive) {
        Write-Host ""I
        $r = (Read-Host "I pour installer les menus, le chemin d'un dossier pour le convertir, ou Entrée pour quitter").Trim().Trim('"')
        if ($r -match '^[iI]$') {
            & $PSCommandPath -Install
            Read-Host "`nEntrée pour fermer" | Out-Null
        }
        elseif ($r) { & $PSCommandPath -Path $r }
    }
    return
}
Invoke-Conversion

# Généré par le modèle claude-opus-5-5
