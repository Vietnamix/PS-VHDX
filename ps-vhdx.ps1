<#
.SYNOPSIS
    PS-VHDX : convertit un répertoire en disque virtuel VHDX par clic droit dans l'Explorateur.

.DESCRIPTION
    -Install    : copie le script dans %LOCALAPPDATA%\PS-VHDX et ajoute « Convertir en VHDX (PS-VHDX) »
                  au menu contextuel des dossiers (HKCU, sans droits administrateur).
    -Uninstall  : retire l'entrée du menu contextuel.
    -Path <dir> : crée <dossier>.vhdx à côté du dossier source (dynamique, GPT, NTFS),
                  y copie le contenu par robocopy (ACL, attributs, horodatages), puis démonte.

    Ne nécessite pas Hyper-V : création par diskpart, montage par Mount-DiskImage.
    La conversion s'élève automatiquement en administrateur (UAC).

.EXAMPLE
    .\PS-VHDX.ps1 -Install
    .\PS-VHDX.ps1 -Path "D:\Projets\Archive2025"

.NOTES
    Projet : PS-VHDX (gamme PS-* de CL SASU)
    Compatible Windows PowerShell 5.1 et PowerShell 7.
#>
[CmdletBinding(DefaultParameterSetName = 'Convert')]
param(
    [Parameter(ParameterSetName = 'Convert', Position = 0)] [string] $Path,
    [Parameter(ParameterSetName = 'Install')]   [switch] $Install,
    [Parameter(ParameterSetName = 'Uninstall')] [switch] $Uninstall,
    [Parameter(ParameterSetName = 'Convert')]   [double] $Marge = 1.25,
    [Parameter(ParameterSetName = 'Convert')]   [switch] $NoPause
)

$ErrorActionPreference = 'Stop'
$AppName  = 'PS-VHDX'
$MenuKey  = "HKCU:\Software\Classes\Directory\shell\$AppName"
$InstDir  = Join-Path $env:LOCALAPPDATA $AppName
$InstFile = Join-Path $InstDir 'PS-VHDX.ps1'

function Write-Etape([string]$Texte) { Write-Host ("[{0}] {1}" -f (Get-Date -Format 'HH:mm:ss'), $Texte) -ForegroundColor Cyan }
function Format-Taille([double]$o) {
    if ($o -ge 1TB) { '{0:N2} To' -f ($o / 1TB) } elseif ($o -ge 1GB) { '{0:N2} Go' -f ($o / 1GB) }
    elseif ($o -ge 1MB) { '{0:N1} Mo' -f ($o / 1MB) } else { '{0:N0} o' -f $o }
}

# ---------------------------------------------------------------- Installation
if ($Install) {
    New-Item -ItemType Directory -Path $InstDir -Force | Out-Null
    Copy-Item -LiteralPath $PSCommandPath -Destination $InstFile -Force
    New-Item -Path $MenuKey -Force | Out-Null
    Set-ItemProperty -Path $MenuKey -Name '(default)' -Value 'Convertir en VHDX (PS-VHDX)'
    Set-ItemProperty -Path $MenuKey -Name 'Icon'      -Value 'imageres.dll,-30'
    New-Item -Path "$MenuKey\command" -Force | Out-Null
    $cmd = "powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"$InstFile`" -Path `"%V`""
    Set-ItemProperty -Path "$MenuKey\command" -Name '(default)' -Value $cmd
    Write-Host "Installé. Clic droit sur un dossier > « Convertir en VHDX (PS-VHDX) »." -ForegroundColor Green
    Write-Host "Windows 11 : l'entrée est dans « Afficher plus d'options » (ou Maj + clic droit)."
    return
}
if ($Uninstall) {
    if (Test-Path $MenuKey) { Remove-Item -Path $MenuKey -Recurse -Force }
    Write-Host "Entrée de menu retirée. Le script reste dans $InstDir." -ForegroundColor Green
    return
}

# ---------------------------------------------------------------- Conversion
if (-not $Path) { throw "Indiquer -Path <répertoire>, ou -Install." }
$Path = $Path.TrimEnd('\')
if ($Path -match '^[A-Za-z]:$') { throw "Un lecteur entier n'est pas pris en charge, choisir un dossier." }

# Auto-élévation
$admin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
         [Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $admin) {
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
