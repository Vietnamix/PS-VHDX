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

    NOUVEAU MENU DE WINDOWS 11 (v1.1)
    Ce menu n'accepte que les applications empaquetées. PS-VHDX embarque donc une DLL native
    IExplorerCommand et un lanceur (sources C dans Shell\ du dépôt, construits par Shell\build.sh,
    compilation reproductible), et enregistre un paquet d'identité MSIX avec emplacement externe
    (%LOCALAPPDATA%\PS-VHDX\shell). Deux voies, choisies automatiquement :
      - mode développeur de Windows actif : enregistrement direct du manifeste, sans certificat
        ni droits administrateur ;
      - sinon SDK Windows présent (makeappx, signtool) : paquet signé par un certificat auto-signé,
        approuvé dans « Personnes autorisées » de l'ordinateur (une invite UAC ; le magasin de
        l'utilisateur ne suffit pas, erreur 0x800B0109), clé privée détruite après signature.
    Windows 11 x64 uniquement. Sans l'une des deux voies, seul le menu classique est installé.
    La DLL lit sa commande, son libellé et son icône dans HKCU\Software\PS-VHDX\Shell.

.EXAMPLE
    .\PS-VHDX.ps1 -Install
    .\PS-VHDX.ps1 -Install -EnableDeveloperMode     # en administrateur
    .\PS-VHDX.ps1 -Path "D:\Projets\Archive2025"

.NOTES
    Projet : PS-VHDX (gamme PS-* de CL SASU)
    Version : 1.1
    Compatible Windows PowerShell 5.1 et PowerShell 7.
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
$Version  = '1.1'
$Label    = 'Convertir en VHDX (PS-VHDX)'
$MenuKeys = @("HKCU:\Software\Classes\Directory\shell\$AppName", "HKCU:\Software\Classes\Directory\Background\shell\$AppName")
$InstDir  = Join-Path $env:LOCALAPPDATA $AppName
$InstFile = Join-Path $InstDir 'PS-VHDX.ps1'

# Nouveau menu de Windows 11
$SHELL_PKG_NAME  = 'CLSASU.PSVHDX.Shell'
$SHELL_PUBLISHER = 'CN=PSVHDX-Shell'
$SHELL_PKG_VER   = '1.1.0.0'
$SHELL_CLSID     = '5C09FA0F-EE54-477A-BA60-6F6BAFD6657A'
$SHELL_DLL       = 'psvhdx-shell11.dll'
$SHELL_EXE       = 'psvhdx-launch11.exe'
$SHELL_ICO       = 'psvhdx.ico'
$SHELL_REGKEY    = 'HKCU:\Software\PS-VHDX\Shell'
$ShellDir        = Join-Path $InstDir 'shell'
$ShellPkgDir     = Join-Path $InstDir 'shell-pkg'

# Empreintes SHA-256 des fichiers intégrés en fin de script, identiques à
# Shell\dist\SHA256SUMS produit par Shell\build.sh (compilation reproductible).
$SHELL_SHA256 = [ordered]@{
    'psvhdx-shell11.dll' = 'ca02f6527f2496353d084417350c755d179e21278fea3dd508b37c6ea11b9d9b'
    'psvhdx-launch11.exe' = 'ee0613d96cb3736cc805d426dadd878a8e649f1fa87665919b5d58d527dad45b'
    'psvhdx.ico' = 'f2ec224ea70775735b076665bc8872989d299d7ab0c415eda44bc154a6db1012'
    'Square150x150Logo.png' = 'b07b9c81ee82f150d7f8afd8171196312ad66be9fe37cafb1ee238e07bbda755'
    'Square44x44Logo.png' = '7dc759d4828e36ee7cb9bc0c42fcfa098383417cb88c8df7dfc8d6e3785259c0'
    'StoreLogo.png' = 'f20e09e4fc3c44bcb9a62d628e1ae5fd35022aa536692cb197f89259c242c118'
}

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

# ================================================================ Fichiers intégrés
function Get-Sha256([byte[]]$Bytes) {
    $h = [System.Security.Cryptography.SHA256]::Create()
    try { -join ($h.ComputeHash($Bytes) | ForEach-Object { $_.ToString('x2') }) } finally { $h.Dispose() }
}
function Get-ShellDest([string]$Name) {
    if ($Name -like '*.png') { return (Join-Path (Join-Path $ShellPkgDir 'Assets') $Name) }
    Join-Path $ShellDir $Name
}
function Test-ShellFile([string]$Name) {
    $d = Get-ShellDest $Name
    if (-not $SHELL_SHA256.Contains($Name) -or -not (Test-Path -LiteralPath $d)) { return $false }
    try { (Get-Sha256 ([System.IO.File]::ReadAllBytes($d))) -eq $SHELL_SHA256[$Name] } catch { $false }
}
# Dépose chaque fichier après vérification de son SHA-256. Un fichier déjà en
# place et identique n'est pas réécrit (une DLL chargée par l'Explorateur ne peut pas l'être).
function Install-ShellBinaries {
    foreach ($d in @($ShellDir, $ShellPkgDir, (Join-Path $ShellPkgDir 'Assets'))) {
        if (-not (Test-Path -LiteralPath $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
    }
    foreach ($n in $SHELL_SHA256.Keys) {
        if (Test-ShellFile $n) { continue }
        if (-not $SHELL_BLOBS.Contains($n)) { throw "fichier $n absent du script" }
        $bytes = [Convert]::FromBase64String(($SHELL_BLOBS[$n] -replace '\s', ''))
        $h = Get-Sha256 $bytes
        if ($h -ne $SHELL_SHA256[$n]) { throw "fichier $n intégré au script altéré (SHA-256 $h au lieu de $($SHELL_SHA256[$n])) : script modifié ou incomplet" }
        $dest = Get-ShellDest $n
        try { [System.IO.File]::WriteAllBytes($dest, $bytes) }
        catch { throw "écriture impossible de $dest (fichier utilisé par l'Explorateur ?) : $_" }
    }
}

# ================================================================ Menu classique
function Install-ClassicMenu {
    $ico = Join-Path $ShellDir $SHELL_ICO
    foreach ($k in $MenuKeys) {
        $arg = if ($k -like '*\Background\*') { '%V' } else { '%1' }
        New-Item -Path $k -Force | Out-Null
        Set-ItemProperty -LiteralPath $k -Name '(default)' -Value $Label
        Set-ItemProperty -LiteralPath $k -Name 'Icon' -Value $(if (Test-Path -LiteralPath $ico) { $ico } else { 'imageres.dll,-30' })
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
    Set-ItemProperty -LiteralPath $SHELL_REGKEY -Name 'Icon'    -Value (Join-Path $ShellDir $SHELL_ICO)
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
            <com:SurrogateServer DisplayName="PS-VHDX">
              <com:Class Id="$SHELL_CLSID" Path="$SHELL_DLL" ThreadingModel="STA" />
            </com:SurrogateServer>
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
    elseif ($r.Version -ne $SHELL_PKG_VER -or -not (Test-ShellFile $SHELL_DLL)) { $r.State = 'outdated' }
    else { $r.State = 'ok' }
    $r
}
function Install-ModernMenu {
    $st = Get-ModernState
    if ($st.State -eq 'unsupported') { return $st }
    Write-ShellConfig
    if ($st.State -eq 'ok') { return $st }
    if ($st.Route -eq 'none') { throw "activez le mode développeur de Windows (.\PS-VHDX.ps1 -Install -EnableDeveloperMode, en administrateur) ou installez le SDK Windows (makeappx, signtool)" }
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
    # La DLL peut rester chargée par l'Explorateur : le dossier est retiré si possible.
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

# ================================================================ Fichiers intégrés (base64)
# Construits par Shell\build.sh du dépôt, de façon reproductible : en recompilant
# les sources, chacun retrouve exactement les empreintes SHA-256 ci-dessus.
$SHELL_BLOBS = @{
    'psvhdx-shell11.dll' = @'
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
CEjHRxAAAAAAuQgAAAAPEQfoVgAAAEiF9nQkSIPrCEg583ITSIsDSIXAdO//0EiD6whIOfNz7UiJ8ehFAAAAMcBIg8QoW15fXcOQkP8lKnYAAJCQ/yUqdgAA
kJD/JSp2AACQkP8lKnYAAJCQ/yUqdgAAkJD/JSp2AACQkP8lKnYAAJCQ/yUqdgAAkJD/JSp2AACQkP8lKnYAAJCQ/yUqdgAAkJD/JSp2AACQkP8lKnYAAJCQ
/yUqdgAAkJD/Jap1AACQkP8lmnUAAJCQ/yWKdQAAkJD/JXp1AACQkP8lanUAAJCQ/yVadQAAkJD/JUp1AACQkP8lOnUAAJCQ/yUqdQAAkJD/JRp1AACQkP8l
CnUAAJCQ/yX6dAAAkJD/Jep0AACQkA8fhAAAAAAA6Zvm//+QkJCQkJCQkJCQkP//////////0Cw54wEAAAAAAAAAAAAAAP//////////AAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAEAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAQDA54wEAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAABwFDnjAQAAAOATOeMBAAAA8BM54wEAAACAGjnjAQAAAOAZOeMBAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAABQ54wEAAADQFDnjAQAAAAAaOeMBAAAAQBo54wEAAADAFTnjAQAAAJATOeMBAAAAoBM54wEAAACwFjnjAQAAAEAXOeMBAAAAwBM54wEA
AADQEznjAQAAAAAAAAAAAAAAAC054wEAAAAAAAAAAAAAAP//////////AAAAAAAAAAACAAAAAAAAAAAAAAAAAAAAUCo54wEAAAAAAAAAAAAAAIArOeMBAAAA
oCo54wEAAACAKjnjAQAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAUwBvAGYAdAB3AGEAcgBlAFwAUABTAC0AVgBIAEQAWABcAFMAaABlAGwAbAAAAEkAYwBvAG4A
AABDAG8AbQBtAGEAbgBkAAAATABhAGIAZQBsAAAAAAAAAEMAbwBuAHYAZQByAHQAaQByACAAZQBuACAAVgBIAEQAWAAgACgAUABTAC0AVgBIAEQAWAApAAAA
0OSMoCX6q0S1fMexwyPguQ/6CVxU7npHumBva6/WZXoAAAAAAAAAAAAAAAAAAAAAcB054wEAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAwDnjAQAAAAjA
OeMBAAAAXIA54wEAAAAwsDnjAQAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAATWluZ3ctdzY0IHJ1bnRpbWUgZmFpbHVyZToKAAAAAABBZGRy
ZXNzICVwIGhhcyBubyBpbWFnZS1zZWN0aW9uACAgVmlydHVhbFF1ZXJ5IGZhaWxlZCBmb3IgJWQgYnl0ZXMgYXQgYWRkcmVzcyAlcAAAAAAAAAAAICBWaXJ0
dWFsUHJvdGVjdCBmYWlsZWQgd2l0aCBjb2RlIDB4JXgAACAgVW5rbm93biBwc2V1ZG8gcmVsb2NhdGlvbiBwcm90b2NvbCB2ZXJzaW9uICVkLgoAAAAAAAAA
ICBVbmtub3duIHBzZXVkbyByZWxvY2F0aW9uIGJpdCBzaXplICVkLgoAAAAAAAAAJWQgYml0IHBzZXVkbyByZWxvY2F0aW9uIGF0ICVwIG91dCBvZiByYW5n
ZSwgdGFyZ2V0aW5nICVwLCB5aWVsZGluZyB0aGUgdmFsdWUgJXAuCgAAAAAAALBPOeMBAAAAAAAAAAAAAAAwWTnjAQAAAAAAAAAAAAAAADE54wEAAAAAAAAA
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
AAAAAEdDQzogKEdOVSkgMTMtd2luMzIAAAAAAAAAAAAAAAAAR0NDOiAoR05VKSAxMy13aW4zMgAAAAAAAAAAAAAAAABHQ0M6IChHTlUpIDEzLXdpbjMyAAAA
AAAAAAAAAAAAAEdDQzogKEdOVSkgMTMtd2luMzIAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAEAAADBAAAABwAAAQEAAA3xEAAARwAADgEQAAPBMAABxwAABAEwAAUhMAADBwAABgEwAA
bxMAADRwAABwEwAAfBMAADhwAACAEwAAgRMAADxwAACQEwAAnRMAAEBwAACgEwAAvhMAAERwAADAEwAAyRMAAEhwAADQEwAA3RMAAExwAADgEwAA5hMAAFBw
AADwEwAA9hMAAFRwAAAAFAAAbxQAAFhwAABwFAAAzBQAAGBwAADQFAAA3hQAAGRwAADgFAAAtRUAAGhwAADAFQAA6BUAAHxwAADwFQAAqxYAAIRwAACwFgAA
OBcAAIxwAABAFwAA2xkAAJhwAADgGQAA+xkAALBwAAAAGgAANhoAALRwAABAGgAAfhoAALxwAACAGgAALRsAAMRwAAAwGwAAxhsAANBwAADQGwAA7hsAANRw
AADwGwAAGBwAANhwAABQHAAAkxwAAOBwAACgHAAAGh0AAOxwAAAgHQAAPx0AAPxwAABAHQAAcB0AAABxAABwHQAA8h0AAAxxAAAAHgAAAx4AABxxAAAQHgAA
eR4AACBxAACAHgAA4h8AADBxAADwHwAATSMAAEBxAABQIwAAyyMAAFhxAADQIwAATyQAAGxxAABQJAAA6SQAAHxxAADwJAAA4iUAAIxxAADwJQAAHCYAAJhx
AAAgJgAAcCYAAJxxAABwJgAAFicAAKBxAAAgJwAAoCcAALBxAACgJwAA1ycAALRxAADgJwAAUygAALhxAABgKAAAligAALxxAACgKAAAKSkAAMBxAAAwKQAA
7ikAAMRxAADwKQAA8ykAAMhxAABAKgAARioAAMxxAABQKgAAdioAANBxAACAKgAAnSoAANxxAACgKgAAeCsAAOBxAACAKwAA7isAAPRxAADQLAAA1SwAAARy
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAQAAAAETCSUTAw4yCjAJYAhw
B8AF0APgAVAAAAERCCURAwxCCDAHYAZwBcAD0AFQAQAAAAEAAAABAAAAAQAAAAEAAAABAAAAAQAAAAEAAAABAAAAAQAAAAEEAQAEQgAAAQAAAAEAAAABDAcA
DKIIMAdgBnAFUATAAtAAAAEFAgAFMgEwAQUCAAVyATABBwQABzIDMAJgAXABEQkAEQEcAAowCWAIcAdQBsAE0ALgAAABAAAAAQUCAAUyATABBQIABTIBMAEH
BAAHUgMwAmABcAEAAAABAAAAAQQBAARCAAABCAMFCDIEAwFQAAABDAUlDAMHMgMwAmABUAAAAQAAAAEIAwUIMgQDAVAAAAEMBSUMAwcyAzACYAFQAAABAAAA
AQwFNQwDB1IDMAJgAVAAAAENBlUNAwiiBDADYAJwAVABFQpFFQMQggwwC2AKcAnAB9AF4APwAVABEQglEQMMQggwB2AGcAXAA9ABUAENBiUNAwhCBDADYAJw
AVABDAUlDAMHMgMwAmABUAAAAQsEJQsDBkICMAFQAQAAAAEAAAABDQYlDQMIQgQwA2ACcAFQAQAAAAEAAAABAAAAAQAAAAEAAAABAAAAAQAAAAEAAAABCwQl
CwMGQgIwAVABAAAAAQ8HJQ8DCjIGMAVgBHADwAFQAAABDQYlDQMIQgQwA2ACcAFQAQAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAADyQAAABAAAAAgAAAAIAAAAokAAAMJAAADiQAADQGwAAMBsAAE+QAABfkAAAAAABAHBzdmhkeC1zaGVsbDEx
LmRsbABEbGxDYW5VbmxvYWROb3cARGxsR2V0Q2xhc3NPYmplY3QAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAeKAAAAAAAAAAAAAA
oKQAAKChAACIoAAAAAAAAAAAAADkpAAAsKEAAPigAAAAAAAAAAAAACylAAAgogAAcKEAAAAAAAAAAAAAQKUAAJiiAACIoQAAAAAAAAAAAABUpQAAsKIAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAyKIAAAAAAAAAAAAAAAAAANiiAAAAAAAA5qIAAAAAAAD4ogAAAAAAABCjAAAAAAAALKMAAAAAAABEowAAAAAAAFSjAAAAAAAA
cKMAAAAAAACIowAAAAAAAJCjAAAAAAAAnqMAAAAAAACwowAAAAAAAMCjAAAAAAAAAAAAAAAAAADMowAAAAAAANqjAAAAAAAA6KMAAAAAAAD0owAAAAAAAPyj
AAAAAAAABqQAAAAAAAAOpAAAAAAAABikAAAAAAAAIKQAAAAAAAAqpAAAAAAAADSkAAAAAAAAPqQAAAAAAABIpAAAAAAAAFKkAAAAAAAAAAAAAAAAAABepAAA
AAAAAHCkAAAAAAAAAAAAAAAAAACApAAAAAAAAI6kAAAAAAAAAAAAAAAAAADIogAAAAAAAAAAAAAAAAAA2KIAAAAAAADmogAAAAAAAPiiAAAAAAAAEKMAAAAA
AAAsowAAAAAAAESjAAAAAAAAVKMAAAAAAABwowAAAAAAAIijAAAAAAAAkKMAAAAAAACeowAAAAAAALCjAAAAAAAAwKMAAAAAAAAAAAAAAAAAAMyjAAAAAAAA
2qMAAAAAAADoowAAAAAAAPSjAAAAAAAA/KMAAAAAAAAGpAAAAAAAAA6kAAAAAAAAGKQAAAAAAAAgpAAAAAAAACqkAAAAAAAANKQAAAAAAAA+pAAAAAAAAEik
AAAAAAAAUqQAAAAAAAAAAAAAAAAAAF6kAAAAAAAAcKQAAAAAAAAAAAAAAAAAAICkAAAAAAAAjqQAAAAAAAAAAAAAAAAAAGoGUmVnR2V0VmFsdWVXAACNAENs
b3NlSGFuZGxlAO0AQ3JlYXRlUHJvY2Vzc1cAABkBRGVsZXRlQ3JpdGljYWxTZWN0aW9uACoBRGlzYWJsZVRocmVhZExpYnJhcnlDYWxscwA9AUVudGVyQ3Jp
dGljYWxTZWN0aW9uAAB0AkdldExhc3RFcnJvcgAAegNJbml0aWFsaXplQ3JpdGljYWxTZWN0aW9uANYDTGVhdmVDcml0aWNhbFNlY3Rpb24AAH8FU2xlZXAA
ogVUbHNHZXRWYWx1ZQDRBVZpcnR1YWxQcm90ZWN0AADTBVZpcnR1YWxRdWVyeQAASQZsc3RybGVuVwAAVABfX2lvYl9mdW5jAAB4AF9hbXNnX2V4aXQAAB0B
X2luaXR0ZXJtAIMBX2xvY2sAygJfdW5sb2NrAIcDYWJvcnQAmANjYWxsb2MAAMADZnJlZQAAzQNmd3JpdGUAAAUEbWVtY3B5AAAaBHJlYWxsb2MAPARzdHJs
ZW4AAD8Ec3RybmNtcABgBHZmcHJpbnRmAACAAENvVGFza01lbUFsbG9jAACBAENvVGFza01lbUZyZWUAbABQYXRoSXNSb290VwAJAVNIU3RyRHVwVwAAAACg
AABBRFZBUEkzMi5kbGwAAAAAFKAAABSgAAAUoAAAFKAAABSgAAAUoAAAFKAAABSgAAAUoAAAFKAAABSgAAAUoAAAFKAAAEtFUk5FTDMyLmRsbAAAAAAooAAA
KKAAACigAAAooAAAKKAAACigAAAooAAAKKAAACigAAAooAAAKKAAACigAAAooAAAKKAAAG1zdmNydC5kbGwAADygAAA8oAAAb2xlMzIuZGxsAAAAUKAAAFCg
AABTSExXQVBJLmRsbAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAABA54wEAAAAAAAAAAAAAAAAAAAAAAAAAcB054wEAAABAHTnjAQAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAgAAAMAAAA6KwAAAAwAAA0AAAAIKBAoEigUKBYoGCggKCIoJCgmKCgoKigsKC4oMCgyKDQoOCgEKEgoSih
MKEAQAAANAAAAMCg4KDooPCg+KCAopCioKKwosCi0KLgovCiAKMQoyCjMKNAo1CjYKNwowAAALAAABAAAAAYoDCgOKAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
'@
    'psvhdx-launch11.exe' = @'
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
TMooDx9EAABEi0IMTInBTDnAcggDSghIOchyFEiDwihJOdF140UxwEyJwMMPH0AATAHY6wsPHwBBg+oBSIPAFItIBIXJdQeLUAyF0nTXRYXSf+VEi0AMTQHY
TInAw5CQUVBIPQAQAABIjUwkGHIZSIHpABAAAEiDCQBILQAQAABIPQAQAAB350gpwUiDCQBYWcOQkJCQkJCQkJCQkJCQkEiLBWkbAABIiwDDkJCQkJBIiwVJ
GwAASIsAw5CQkJCQSIsFKRsAAEiLAMOQkJCQkEiLBZmIAADDDx+EAAAAAABIichIhwWGiAAAw5CQkJCQVVNIg+woSI1sJCCJy+gmAAAAidlIjRRJSMHiBEgB
0EiDxChbXcOQkJCQkJCQkJCQ/yU6mQAAkJD/JTqZAACQkP8lOpkAAJCQ/yU6mQAAkJD/JTqZAACQkP8lQpkAAJCQ/yVCmQAAkJD/JVKZAACQkP8lUpkAAJCQ
/yVamQAAkJD/JVqZAACQkP8lWpkAAJCQ/yVamQAAkJD/JVqZAACQkP8lWpkAAJCQ/yVamQAAkJD/JVqZAACQkP8lWpkAAJCQ/yVamQAAkJD/JVqZAACQkP8l
WpkAAJCQ/yVamQAAkJD/JXqYAACQkP8lapgAAJCQ/yVamAAAkJD/JUqYAACQkP8lOpgAAJCQ/yUqmAAAkJD/JRqYAACQkP8lCpgAAJCQ/yX6lwAAkJD/JeqX
AACQkP8l2pcAAJCQ/yXKlwAAkJD/JbqXAACQkP8lqpcAAJCQ/yWalwAAkJD/JYqXAACQkOnr6f//kJCQkJCQkJCQkJD//////////3AqAEABAAAAAAAAAAAA
AAD//////////wAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AACgKgBAAQAAAAAAAAAAAAAA//////////8AAAAAAAAAAAIAAAAAAAAAAAAAAAAAAAD/////AAAAAAAAAAAAAAAAwCgAQAEAAAAAAAAAAAAAANAoAEABAAAA
AAAAAAAAAADgKABAAQAAAAAAAAAAAAAA8CgAQAEAAAAAKQBAAQAAABApAEABAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAEMAbwBtAG0AYQBuAGQAAABTAG8AZgB0AHcA
YQByAGUAXABQAFMALQBWAEgARABYAFwAUwBoAGUAbABsAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAANAYAEABAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAOAAQAEAAAAI4ABAAQAAAIywAEABAAAAONAAQAEAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAEFyZ3VtZW50IGRvbWFp
biBlcnJvciAoRE9NQUlOKQBBcmd1bWVudCBzaW5ndWxhcml0eSAoU0lHTikAAAAAAABPdmVyZmxvdyByYW5nZSBlcnJvciAoT1ZFUkZMT1cpAFBhcnRpYWwg
bG9zcyBvZiBzaWduaWZpY2FuY2UgKFBMT1NTKQAAAABUb3RhbCBsb3NzIG9mIHNpZ25pZmljYW5jZSAoVExPU1MpAAAAAAAAVGhlIHJlc3VsdCBpcyB0b28g
c21hbGwgdG8gYmUgcmVwcmVzZW50ZWQgKFVOREVSRkxPVykAVW5rbm93biBlcnJvcgAAAAAAX21hdGhlcnIoKTogJXMgaW4gJXMoJWcsICVnKSAgKHJldHZh
bD0lZykKAAB42P//LNj//8TX//9M2P//XNj//2zY//882P//TWluZ3ctdzY0IHJ1bnRpbWUgZmFpbHVyZToKAAAAAABBZGRyZXNzICVwIGhhcyBubyBpbWFn
ZS1zZWN0aW9uACAgVmlydHVhbFF1ZXJ5IGZhaWxlZCBmb3IgJWQgYnl0ZXMgYXQgYWRkcmVzcyAlcAAAAAAAAAAAICBWaXJ0dWFsUHJvdGVjdCBmYWlsZWQg
d2l0aCBjb2RlIDB4JXgAACAgVW5rbm93biBwc2V1ZG8gcmVsb2NhdGlvbiBwcm90b2NvbCB2ZXJzaW9uICVkLgoAAAAAAAAAICBVbmtub3duIHBzZXVkbyBy
ZWxvY2F0aW9uIGJpdCBzaXplICVkLgoAAAAAAAAAJWQgYml0IHBzZXVkbyByZWxvY2F0aW9uIGF0ICVwIG91dCBvZiByYW5nZSwgdGFyZ2V0aW5nICVwLCB5
aWVsZGluZyB0aGUgdmFsdWUgJXAuCgAAAAAAABjd//8Y3f//GN3//xjd//8Y3f//kN3//xjd///Q3f//kN3//2vd//8AAAAAAAAAACAwAEABAAAAAAAAAAAA
AAAwMABAAQAAAAAAAAAAAAAAgCoAQAEAAAAAAAAAAAAAABBJAEABAAAAAAAAAAAAAAAQSQBAAQAAAAAAAAAAAAAAYEAAQAEAAAAAAAAAAAAAAAAAAEABAAAA
AAAAAAAAAACowgBAAQAAAAAAAAAAAAAAwMIAQAEAAAAAAAAAAAAAAMjCAEABAAAAAAAAAAAAAADgwgBAAQAAAAAAAAAAAAAAoLAAQAEAAAAAAAAAAAAAAIiw
AEABAAAAAAAAAAAAAACEsABAAQAAAAAAAAAAAAAAgLAAQAEAAAAAAAAAAAAAAOCwAEABAAAAAAAAAAAAAABQsABAAQAAAAAAAAAAAAAAWLAAQAEAAAAAAAAA
AAAAAADQAEABAAAAAAAAAAAAAAAQ0ABAAQAAAAAAAAAAAAAAGNAAQAEAAAAAAAAAAAAAACjQAEABAAAAAAAAAAAAAACQsABAAQAAAAAAAAAAAAAAYLAAQAEA
AAAAAAAAAAAAANCwAEABAAAAAAAAAAAAAAAgIABAAQAAAAAAAAAAAAAAcBkAQAEAAAAAAAAAAAAAAHCwAEABAAAAAAAAAAAAAABHQ0M6IChHTlUpIDEzLXdp
bjMyAAAAAAAAAAAAAAAAAEdDQzogKEdOVSkgMTMtd2luMzIAAAAAAAAAAAAAAAAAR0NDOiAoR05VKSAxMy13aW4zMgAAAAAAAAAAAAAAAABHQ0M6IChHTlUp
IDEzLXdpbjMyAAAAAAAAAAAAAAAAAEdDQzogKEdOVSkgMTMtd2luMzIAAAAAAAAAAAAAAAAAR0NDOiAoR05VKSAxMy13aW4zMgAAAAAAAAAAAAAAAABHQ0M6
IChHTlUpIDEzLXdpbjMyAAAAAAAAAAAAAAAAAEdDQzogKEdOVSkgMTMtd2luMzIAAAAAAAAAAAAAAAAAR0NDOiAoR05VKSAxMy13aW4zMgAAAAAAAAAAAAAA
AABHQ0M6IChHTlUpIDEzLXdpbjMyAAAAAAAAAAAAAAAAAEdDQzogKEdOVSkgMTMtd2luMzIAAAAAAAAAAAAAAAAAR0NDOiAoR05VKSAxMy13aW4zMgAAAAAA
AAAAAAAAAABHQ0M6IChHTlUpIDEzLXdpbjMyAAAAAAAAAAAAAAAAAEdDQzogKEdOVSkgMTMtd2luMzIAAAAAAAAAAAAAAAAAR0NDOiAoR05VKSAxMy13aW4z
MgAAAAAAAAAAAAAAAABHQ0M6IChHTlUpIDEzLXdpbjMyAAAAAAAAAAAAAAAAAEdDQzogKEdOVSkgMTMtd2luMzIAAAAAAAAAAAAAAAAAR0NDOiAoR05VKSAx
My13aW4zMgAAAAAAAAAAAAAAAABHQ0M6IChHTlUpIDEzLXdpbjMyAAAAAAAAAAAAAAAAAEdDQzogKEdOVSkgMTMtd2luMzIAAAAAAAAAAAAAAAAAR0NDOiAo
R05VKSAxMy13aW4zMgAAAAAAAAAAAAAAAABHQ0M6IChHTlUpIDEzLXdpbjMyAAAAAAAAAAAAAAAAAEdDQzogKEdOVSkgMTMtd2luMzIAAAAAAAAAAAAAAAAA
R0NDOiAoR05VKSAxMy13aW4zMgAAAAAAAAAAAAAAAABHQ0M6IChHTlUpIDEzLXdpbjMyAAAAAAAAAAAAAAAAAEdDQzogKEdOVSkgMTMtd2luMzIAAAAAAAAA
AAAAAAAAR0NDOiAoR05VKSAxMy13aW4zMgAAAAAAAAAAAAAAAABHQ0M6IChHTlUpIDEzLXdpbjMyAAAAAAAAAAAAAAAAAEdDQzogKEdOVSkgMTMtd2luMzIA
AAAAAAAAAAAAAAAAR0NDOiAoR05VKSAxMy13aW4zMgAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAEAAAARAAAABgAAAQEAAANhEAAARgAABAEQAAjhEAABBgAACQEQAA4BMAABxgAADgEwAAAhQAADBgAAAQFAAAMhQAAFRgAABAFAAA
WRQAAHhgAABgFAAAbBQAAIRgAABwFAAAcRQAAIhgAACAFAAAshYAAIxgAADgFgAAIxcAAKBgAAAwFwAAqhcAAKxgAACwFwAAzxcAALxgAADQFwAAmRgAAMBg
AACgGAAA0BgAANBgAADQGAAAUhkAANxgAABgGQAAYxkAAOxgAABwGQAAaBoAAPBgAABwGgAAcxoAAAxhAACAGgAAgxoAABBhAACQGgAA+RoAABRhAAAAGwAA
YhwAACRhAABwHAAAzR8AADRhAADQHwAACiAAAExhAAAQIAAAHCAAAFhhAAAgIAAA3SEAAFxhAADgIQAAWyIAAGhhAABgIgAA3yIAAHxhAADgIgAAeSMAAIxh
AACAIwAAciQAAJxhAACAJAAArCQAAKhhAACwJAAAACUAAKxhAAAAJQAApiUAALBhAACwJQAAMCYAAMBhAAAwJgAAZyYAAMRhAABwJgAA4yYAAMhhAADwJgAA
JicAAMxhAAAwJwAAuScAANBhAADAJwAAfigAANRhAADAKAAAyygAANhhAADQKAAA2ygAANxhAADgKAAA6ygAAOBhAADwKAAA+CgAAORhAAAAKQAACykAAOhh
AAAQKQAANikAAOxhAABwKgAAdSoAAPhhAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAQAAAAEIAwUIMgQDAVAAAAEIAwUIUgQDAVAAAAERCCURAwxCCDAHYAZw
BcAD0AFQCQgDBQgyBAMBUAAAQCkAAAEAAADoEwAA+xMAACAgAAD7EwAACQgDBQgyBAMBUAAAQCkAAAEAAAAYFAAAKxQAACAgAAArFAAAAQgDBQgyBAMBUAAA
AQAAAAEAAAABEwcAEwEeBAswCmAJcAhQAsAAAAEIAwUIMgQDAVAAAAEMBSUMAwcyAzACYAFQAAABAAAAARIGlRIDCgESAAMwAnABUAEIAwUIMgQDAVAAAAEM
BSUMAwcyAzACYAFQAAABAAAAARkLRRmIBgAUeAUAEGgEAAwDB9IDMAJgAVAAAAEAAAABAAAAAQwFNQwDB1IDMAJgAVAAAAENBlUNAwiiBDADYAJwAVABFQpF
FQMQggwwC2AKcAnAB9AF4APwAVABCAMFCJIEAwFQAAABAAAAAQsEJQsDBkICMAFQAREIJREDDEIIMAdgBnAFwAPQAVABDQYlDQMIQgQwA2ACcAFQAQwFJQwD
BzIDMAJgAVAAAAELBCULAwZCAjABUAEAAAABAAAAAQ0GJQ0DCEIEMANgAnABUAEAAAABAAAAAQAAAAEAAAABAAAAAQAAAAEAAAABAAAAAQAAAAEAAAABAAAA
AQsEJQsDBkICMAFQAQAAAAAAAABowAAAAAAAAAAAAADwxQAA6MEAAHjAAAAAAAAAAAAAAEDGAAD4wQAAAMEAAAAAAAAAAAAAuMYAAIDCAADYwQAAAAAAAAAA
AADIxgAAWMMAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAGjDAAAAAAAAAAAAAAAAAAB4wwAAAAAAAIbDAAAAAAAAmMMAAAAAAACwwwAAAAAAAMjDAAAAAAAA
2sMAAAAAAADqwwAAAAAAAPzDAAAAAAAAGMQAAAAAAAAwxAAAAAAAADzEAAAAAAAAWsQAAAAAAABixAAAAAAAAHDEAAAAAAAAgsQAAAAAAACSxAAAAAAAAAAA
AAAAAAAAnsQAAAAAAAC2xAAAAAAAAMTEAAAAAAAA1sQAAAAAAADqxAAAAAAAAPzEAAAAAAAACsUAAAAAAAAYxQAAAAAAACLFAAAAAAAALsUAAAAAAAA4xQAA
AAAAAETFAAAAAAAATsUAAAAAAABYxQAAAAAAAGDFAAAAAAAAasUAAAAAAAByxQAAAAAAAHzFAAAAAAAAhMUAAAAAAACOxQAAAAAAAJjFAAAAAAAAosUAAAAA
AACsxQAAAAAAALbFAAAAAAAAwMUAAAAAAADMxQAAAAAAAAAAAAAAAAAA1sUAAAAAAAAAAAAAAAAAAGjDAAAAAAAAAAAAAAAAAAB4wwAAAAAAAIbDAAAAAAAA
mMMAAAAAAACwwwAAAAAAAMjDAAAAAAAA2sMAAAAAAADqwwAAAAAAAPzDAAAAAAAAGMQAAAAAAAAwxAAAAAAAADzEAAAAAAAAWsQAAAAAAABixAAAAAAAAHDE
AAAAAAAAgsQAAAAAAACSxAAAAAAAAAAAAAAAAAAAnsQAAAAAAAC2xAAAAAAAAMTEAAAAAAAA1sQAAAAAAADqxAAAAAAAAPzEAAAAAAAACsUAAAAAAAAYxQAA
AAAAACLFAAAAAAAALsUAAAAAAAA4xQAAAAAAAETFAAAAAAAATsUAAAAAAABYxQAAAAAAAGDFAAAAAAAAasUAAAAAAAByxQAAAAAAAHzFAAAAAAAAhMUAAAAA
AACOxQAAAAAAAJjFAAAAAAAAosUAAAAAAACsxQAAAAAAALbFAAAAAAAAwMUAAAAAAADMxQAAAAAAAAAAAAAAAAAA1sUAAAAAAAAAAAAAAAAAAGoGUmVnR2V0
VmFsdWVXAACNAENsb3NlSGFuZGxlAO0AQ3JlYXRlUHJvY2Vzc1cAABkBRGVsZXRlQ3JpdGljYWxTZWN0aW9uAD0BRW50ZXJDcml0aWNhbFNlY3Rpb24AAOYB
R2V0Q29tbWFuZExpbmVXAHQCR2V0TGFzdEVycm9yAADmAkdldFN0YXJ0dXBJbmZvVwB6A0luaXRpYWxpemVDcml0aWNhbFNlY3Rpb24A1gNMZWF2ZUNyaXRp
Y2FsU2VjdGlvbgAA6ANMb2NhbEZyZWUAbwVTZXRVbmhhbmRsZWRFeGNlcHRpb25GaWx0ZXIAfwVTbGVlcACiBVRsc0dldFZhbHVlANEFVmlydHVhbFByb3Rl
Y3QAANMFVmlydHVhbFF1ZXJ5AABJBmxzdHJsZW5XAAA4AF9fQ19zcGVjaWZpY19oYW5kbGVyAABUAF9faW9iX2Z1bmMAAGEAX19zZXRfYXBwX3R5cGUAAGMA
X19zZXR1c2VybWF0aGVycgAAbgBfX3dnZXRtYWluYXJncwAAbwBfX3dpbml0ZW52AAB4AF9hbXNnX2V4aXQAAIkAX2NleGl0AACVAF9jb21tb2RlAADbAF9m
bW9kZQAAHQFfaW5pdHRlcm0AKQJfb25leGl0AAQDX3djbWRsbgCHA2Fib3J0AJgDY2FsbG9jAAClA2V4aXQAALkDZnByaW50ZgDAA2ZyZWUAAM0DZndyaXRl
AAD9A21hbGxvYwAABQRtZW1jcHkAACUEc2lnbmFsAAA8BHN0cmxlbgAAPwRzdHJuY21wAGAEdmZwcmludGYAAHoEd2NzbGVuAAALAENvbW1hbmRMaW5lVG9B
cmd2VwAAAMAAAEFEVkFQSTMyLmRsbAAAAAAUwAAAFMAAABTAAAAUwAAAFMAAABTAAAAUwAAAFMAAABTAAAAUwAAAFMAAABTAAAAUwAAAFMAAABTAAAAUwAAA
S0VSTkVMMzIuZGxsAAAAACjAAAAowAAAKMAAACjAAAAowAAAKMAAACjAAAAowAAAKMAAACjAAAAowAAAKMAAACjAAAAowAAAKMAAACjAAAAowAAAKMAAACjA
AAAowAAAKMAAACjAAAAowAAAKMAAACjAAAAowAAAbXN2Y3J0LmRsbAAAPMAAAFNIRUxMMzIuZGxsAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAQBEAQAEAAAAAAAAAAAAAAAAAAAAAAAAAEBAAQAEAAAAAAAAAAAAAAAAAAAAAAAAA0BgAQAEAAACgGABAAQAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAIAAADAAAAIiqAAAAMAAAGAAAAACgQKBQoGCgcKB4oICgAAAAQAAATAAAAGCggKCIoJCgmKCQo6Cj
sKPAo9Cj4KPwowCkEKQgpDCkQKRQpGCkcKSApJCkoKSwpMCk0KTgpPCkAKUQpSClMKVApQAAANAAABAAAAAIoCCgOKBAoAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAA==
'@
    'psvhdx.ico' = @'
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
'@
    'Square150x150Logo.png' = @'
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
'@
    'Square44x44Logo.png' = @'
iVBORw0KGgoAAAANSUhEUgAAACwAAAAsCAYAAAAehFoBAAAEq0lEQVR4nO2XTWxUVRiGn3POnZ87Py22BCmtQAttKQSNgoqIEEmMIhIXQogE2bBw4UITNNGF
ho0rY0xMJBLZSI1WF0oCiSFIjUbTYIxaA1goLdIBCintdNqZ6fzde1y0JUx76dxOp5VF32QW5zvnft8zZ+55zzcwr3nNa04lnIJd39SVG1mj0k0Cj2BoyZ6L
t0pOdhflAfd81bjEytktAp6aRo6Y1jxbu6/zTOnxJkveOdCW/f40YQHKheDk5aP1j5cWzVl5O/zv0fp/EKwqMldMInZomTpbLIwnnksvefV6cqo1+cDNDb2g
FxdbsES6BuLg8lcuHnGalE7B/1nVoA93Nzc85DRpTAx4PH58fhMp5v67aAF2LktyJC6lpTcB7RPX5AGbZsAfClfMKeQk+cDnDxIduFXjNJ23jf5AKDhnYFNI
KYNAMNTkNJcHLIVSc0ZVQEqpcqf4vXjoxqQdb+F8YCGn9MC5lBJGj1N8wish4nNGVECG19vtGJ92JulDhmsRRqAUXHeXnVkArZPCee9J4uTWXsD5phMSuWwv
Rt0e+gbTDCWtWWOVEqoqg1mljKuml51CiD/G51zvsFy2m96yXbx1yOJGTAGzbShZz7YH9fI3t3t+1Fo3CiFu4BpYSFTtPt4+bHMjpgFNNjGItmZnl5U/hPL6
+f7vnFhTI/0vPKxeB95xDSwDNSRSFteio+NEbyfZoT5XxYUUlIe8pDIWqVTOJbIgtGwthj/MmS7Lu3W12jw+426HlUkqY982lVwiWrikgI2PVLNjax1CCryG
ojsySMuJC/QNFHJPTS4+iOEPM5LRCEF4esCT8xXU9qfrWNu4kE+++ItI7zCGkmx+rIYD+9fxwWe/0z84UlSRiTedu9+5gBYvDLJpXTWHmtuJ9A4DkLNsWtt6
aG2LsOv5hqJz5/9FQjfPHBdW11fS3tFHLJ4mYHo4sH89z2xaDsDPv0VoWlmJko43b0HlvRLBti0fjjzxU1ojduf5sVA+hKhy23sYhiKdGXWQoOlhaXUZQ/E0
AOmcjQCkklj29F0mD1gcPGgDH499bkvr0+sZ1KchVeYmac/1IXY+V8+xU5foG0jy3ke/khzJArBmZSU3byXJZouzxFnp1i509xONpdi1rQGlJLHhNNmcTdWi
ILu3N3LsVGfRuYtziQLSGj7/7jx7X2zi3dc2cOlKFNP0sGLpAo6f7uJcZ3/RuYsCVl6TXGp4yjXxRIZPv2ynbukCHlgcJpnK0XKig+F4xlUN6XNurooCDlQ1
kI5ew7YK31yRKESiY54ryvCEp14vAGWG8YYWlg5Yev2Y968o5tEZ6x7+i+Ssog9d0C/Y3KTwlfjYXunX/Nl9d8srutyGBsWTq0pvMutWQsdVm5GMcy/htqIW
E27SsxGb2kU23hL38Vf7bVJ3wAox2jOMj90CX64IYkoB9tijN6M2R35wZ1EzUfV9EiHoGB+7OnRCiIGMxbmXHjXsWaWbIL8H9m40EiE/X99mcfuw1roxnaWt
9bwV+OWi5UukXTTFM1BNhRyD1cfDpnp5PD6tHk9rXZGxeWMkzRbbJjQrpKOVMCRdYVO0CCG+nb0685qs/wCQJXZMRMpCswAAAABJRU5ErkJggg==
'@
    'StoreLogo.png' = @'
iVBORw0KGgoAAAANSUhEUgAAADIAAAAyCAYAAAAeP4ixAAAFM0lEQVR4nO2ZXWwUVRTHf2dmdnfa7tIW2tLaAqVfsdBQoGg0EORBgaDEGIwmEiCSEDFRg5j4
ZEx5MGpCfDM+lAdjY4AYAxqMEmkCJZIURKCKUCgtLYQGKJTSlm27O/f6UEq62m13d7YFtb9kk7333Dnn/Od+zL0zMMUUU0zxb0JGq2zeXTzLcswKUcofqyOl
GSzc2Py9CDqpGcbIP4S0fVX2sRb9PmDE7U3rmjkbmt94GGIihFyuLVkMctKVx4ckJuKuixhVrj2KbGmrLd2lqxPoURdYIwsanZMUr8LmtuLSlZdrGUyCt27R
+oKCL+ZubD4SrVGEEBQy+vRPiIJkOdIiiwTWtXxdtrRo/YXjo7WxRqsEEMPAkEkdHaOitUYpB8AylNoAxCbE4/UR8GdiWp7JyDMmtFL09XUTDPaVRGsTIcS0
rEB6ehbyCPTESMQw8AcyUVrlR2sTkXFKqr/0URMxkhQ7NepiFLn8Gua0SckoQcQwfdFsj+7tj5MIIYYYXQ8vlfExRHqi2kYWvF77zKRklCCmZV2KZvvPDK2o
D8SxkNR8zIK1OClFYESdf0nHYHC+1ovfBHaJSGikLW4h5mOrMB9/lxMtij9aDcIqqbmOid+W7JU+/VlGiryttV4tIu3DtriEGIEirPL3+OBbh6NNCphEFff5
sj5k71jnK1ky19ittV4mIpq4e6RwEz81OhxtcobKSjHY1wVOaLwr3SGC4UvDsv0MhOGj7wY9+7f5ngB5BjhMvEJ0WgkNLcMF6L16lnDw7oTkPhqpuaV403Po
6ddcvK5DFQWyICEhYnoYDA/9V+H+uETkZqWxZsVcyktm4POZdN4O0nC6g7pj7YSd2IZoqKcTb/rQLqU/pAWwh20JrVoA6NhPsqWFmWx9rZIz525Qs7eR3r4Q
BXkBVi8vpLx0Bp/XniIUGl+MVtHbRJ4QRQYljgRjwfaabH65gh+PtHLol7YH9ddu9NJ4/ibbX6/ihRVF7Pu52VWcyAei5pQrb6OwcN5MggNh6o4NrZT+VA8l
szMQgf6BMPsONbO0Kh/TcHc0jRCStrLuELDfXeqR5OWk0nLlDvp+T295dQHbNldRVZELQHNbF7ZtMT0jxVWciKElgtbVy9f1PVW/XmA5QnpEa8O7duQEiwXH
UXg95oNyx81eCvIC3LoTBMBrDdlCYSd5QgCkuloBtfd/Edwb8HdAKDeeABfbulm2pADbtujvD7PnQBN7DjQ9sC+aP5NbXUHu3B1IXMVkbBrPX7rF9c57bHpp
Hh5PZLg5+dN48dlifjjc6jpO4stvjGgNu/b+ztb1lXz41tOcPHud3r4Qs/MCVJZnc/DoZY6f6XAdJ2EhYsZ+aXfvADtrTrBkQS7lJdPJy/bTefseO3f9ypWO
qGeluGK6EOLBziygv+tqTO0dpWk43UHD6cTuvmF6sLOiv/NzNbTsnDn4svLR4bAbN+MjguHxRvsKAsmYI2JYiHfCp9q4/L+PuiPJTBPWLLbwepL39vvvtHcq
6hrHHr6uhTxZZlJeYMbQMnGKZxr81uLQ1Rt9Q+t6aJ27ougJTtzHKa2h6ZpDd9/YMeLqEaXpCaQQsUVp71R8ut/d9iIRMlINBXQPl+PqEdsjB5+vtAYmbjbE
RmG2UJQjNlA/XBeXENNgx/x8Cb6zyuN4JnZaRKUwW/jkFV+/o6gRkXPD9XHfXK31woEQ34QUs1pvKkepJH6sG4c0n6iiHLEdRY3HZLuIBIdtCSWhtfYCzwFl
gDep2Y5NN1AvIn9OYswpEuIvvMKgephF7wAAAAAASUVORK5CYII=
'@
}

# ================================================================ Point d'entrée
if ($Install) {
    New-Item -ItemType Directory -Path $InstDir -Force | Out-Null
    if ($PSCommandPath -ne $InstFile) { Copy-Item -LiteralPath $PSCommandPath -Destination $InstFile -Force }
    Install-ShellBinaries
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
Invoke-Conversion
