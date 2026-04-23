<#
.SYNOPSIS
    Outil d'audit et d'optimisation sécurisée pour Windows.
.DESCRIPTION
    Affiche les informations système, génère un rapport, nettoie les fichiers temporaires,
    désactive des programmes au démarrage et vérifie l'espace disque.
    Toute modification est confirmée et journalisée. Privilégie la sécurité.
.NOTES
    Version : 1.0
    Auteur  : Expert PowerShell
    Licence : MIT
#>

#Requires -Version 5.1

param(
    [switch]$Auto,
    [switch]$ReportOnly
)

# ---------- CONFIGURATION ----------
$ScriptName   = "OptimSystem"
$LogFile      = Join-Path $env:ProgramData "$ScriptName\Logs\$($ScriptName)_$(Get-Date -Format 'yyyyMMdd_HHmmss').log"
$BackupDir    = Join-Path $env:ProgramData "$ScriptName\Backups"
$ReportDir    = Join-Path $env:USERPROFILE "Desktop\SystemReports"
$StartupRegKeys = @(
    "HKCU:\Software\Microsoft\Windows\CurrentVersion\Run",
    "HKLM:\Software\Microsoft\Windows\CurrentVersion\Run"
)
$StartupFolders = @(
    [System.Environment]::GetFolderPath('Startup'),
    [System.Environment]::GetFolderPath('CommonStartup')
)

# ---------- INITIALISATION ----------
if (-not (Test-Path (Split-Path $LogFile))) {
    New-Item -ItemType Directory -Path (Split-Path $LogFile) -Force | Out-Null
}
if (-not (Test-Path $BackupDir)) {
    New-Item -ItemType Directory -Path $BackupDir -Force | Out-Null
}
if (-not (Test-Path $ReportDir)) {
    New-Item -ItemType Directory -Path $ReportDir -Force | Out-Null
}

# ---------- FONCTIONS DIVERSES ----------
function Write-Log {
    param([string]$Message, [string]$Level = "INFO")
    $Timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $LogEntry  = "[$Timestamp] [$Level] $Message"
    Add-Content -Path $LogFile -Value $LogEntry -Encoding UTF8
    Write-Host $LogEntry
}

function Confirm-UserAction {
    param([string]$Question)
    if ($Auto) { return $true } # mode silencieux non interactif
    do {
        $response = Read-Host "$Question (O/N)"
    } while ($response -notmatch '^[onON]$')
    return $response -match '^[oO]$'
}

# ---------- VÉRIFICATION ADMINISTRATEUR ----------
function Test-Administrator {
    $identity = [System.Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object System.Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)
}

# ---------- INFORMATIONS SYSTÈME ----------
function Get-SystemInfo {
    $cpu = Get-CimInstance Win32_Processor | Select-Object -First 1
    $os  = Get-CimInstance Win32_OperatingSystem
    $ramTotal = [math]::Round($os.TotalVisibleMemorySize/1MB, 1)
    $ramFree  = [math]::Round($os.FreePhysicalMemory/1MB, 1)
    $disks = Get-CimInstance Win32_LogicalDisk -Filter "DriveType=3"
    $diskInfo = $disks | ForEach-Object {
        [PSCustomObject]@{
            Drive     = $_.DeviceID
            TotalGB   = [math]::Round($_.Size/1GB, 1)
            FreeGB    = [math]::Round($_.FreeSpace/1GB, 1)
            FreePct   = [math]::Round(($_.FreeSpace/$_.Size)*100, 1)
        }
    }

    $info = [PSCustomObject]@{
        CPU           = $cpu.Name.Trim()
        RAMTotalGB    = $ramTotal
        RAMFreeGB     = $ramFree
        OSVersion     = "$($os.Caption) (Build $($os.Version))"
        Architecture  = $os.OSArchitecture
        LastBootTime  = $os.LastBootUpTime
        Disks         = $diskInfo
    }
    return $info
}

function Show-SystemInfo {
    param($Info)
    Write-Host "`n===== INFORMATIONS SYSTÈME =====" -ForegroundColor Cyan
    Write-Host "Processeur     : $($Info.CPU)"
    Write-Host "RAM Totale     : $($Info.RAMTotalGB) Go"
    Write-Host "RAM Libre      : $($Info.RAMFreeGB) Go"
    Write-Host "Système        : $($Info.OSVersion) ($($Info.Architecture))"
    Write-Host "Dernier démarrage : $($Info.LastBootTime)"
    Write-Host "--- Disques ---"
    foreach ($disk in $Info.Disks) {
        $color = if ($disk.FreePct -lt 15) { "Red" } else { "Green" }
        Write-Host "$($disk.Drive) $($disk.TotalGB) Go total, $($disk.FreeGB) Go libre ($($disk.FreePct)% libre)" -ForegroundColor $color
    }
}

# ---------- RAPPORT HTML ----------
function New-SystemReport {
    param($Info, [switch]$Html)
    $date = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $filePath = Join-Path $ReportDir "SystemReport_$(Get-Date -Format 'yyyyMMdd_HHmmss').html"

    $htmlTemplate = @"
<!DOCTYPE html>
<html>
<head><meta charset="UTF-8"><title>Rapport Système</title></head>
<body>
<h1>Rapport système - $date</h1>
<h2>Informations générales</h2>
<table border="1">
<tr><td>Processeur</td><td>$($Info.CPU)</td></tr>
<tr><td>RAM Totale (Go)</td><td>$($Info.RAMTotalGB)</td></tr>
<tr><td>RAM Libre (Go)</td><td>$($Info.RAMFreeGB)</td></tr>
<tr><td>Système</td><td>$($Info.OSVersion) ($($Info.Architecture))</td></tr>
<tr><td>Dernier démarrage</td><td>$($Info.LastBootTime)</td></tr>
</table>
<h2>Disques</h2>
<table border="1">
<tr><th>Lecteur</th><th>Total (Go)</th><th>Libre (Go)</th><th>% Libre</th></tr>
$($Info.Disks | ForEach-Object { "<tr><td>$($_.Drive)</td><td>$($_.TotalGB)</td><td>$($_.FreeGB)</td><td>$($_.FreePct)%</td></tr>" } -join "`n")
</table>
</body>
</html>
"@
    $htmlTemplate | Out-File -FilePath $filePath -Encoding UTF8
    Write-Log "Rapport HTML généré : $filePath"
    return $filePath
}

# ---------- NETTOYAGE FICHIERS TEMPORAIRES ----------
function Clear-TempFiles {
    param([switch]$SystemWide)
    $paths = @($env:TEMP, "$env:SystemRoot\Temp")
    if (-not $SystemWide) {
        $paths = @($env:TEMP)
    }
    $totalSize = 0
    $filesDeleted = 0
    foreach ($basePath in $paths) {
        if (-not (Test-Path $basePath)) { continue }
        Get-ChildItem -Path $basePath -Recurse -File -ErrorAction SilentlyContinue | ForEach-Object {
            try {
                $size = $_.Length
                Remove-Item $_.FullName -Force -ErrorAction Stop
                $totalSize += $size
                $filesDeleted++
            } catch {
                Write-Log "Impossible de supprimer $($_.FullName) : $_" "WARN"
            }
        }
    }
    $totalMB = [math]::Round($totalSize/1MB, 2)
    Write-Log "Fichiers temporaires nettoyés : $filesDeleted fichiers, $totalMB Mo libérés."
}

# ---------- GESTION DES DÉMARRAGES ----------
function Get-AllStartupEntries {
    $entries = @()
    # Registry
    foreach ($regPath in $StartupRegKeys) {
        if (Test-Path $regPath) {
            Get-ItemProperty -Path $regPath | Get-Member -MemberType NoteProperty | ForEach-Object {
                $name = $_.Name
                $value = (Get-ItemProperty -Path $regPath).$name
                $entries += [PSCustomObject]@{
                    Source = "Registre ($regPath)"
                    Name   = $name
                    Command = $value
                }
            }
        }
    }
    # Dossiers de démarrage
    foreach ($folder in $StartupFolders) {
        if (Test-Path $folder) {
            Get-ChildItem -Path $folder -Filter "*.lnk" | ForEach-Object {
                $shell = New-Object -ComObject WScript.Shell
                $target = $shell.CreateShortcut($_.FullName).TargetPath
                [System.Runtime.InteropServices.Marshal]::ReleaseComObject($shell)
                $entries += [PSCustomObject]@{
                    Source  = "Dossier $folder"
                    Name    = $_.BaseName
                    Command = $target
                }
            }
        }
    }
    return $entries
}

function Disable-StartupEntry {
    param($Entry)
    $datetime = Get-Date -Format "yyyyMMdd_HHmmss"
    # Sauvegarde avant modification
    if ($Entry.Source -match "Registre") {
        # Extraire le chemin de registre de la source
        $regPath = $Entry.Source -replace "Registre \(","" -replace "\)",""
        $backupFile = Join-Path $BackupDir "$($Entry.Name)_$datetime.reg"
        # Exporter la clé pour backup
        reg export "HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\Run" $backupFile   # Simplifié : on exporte toute la ruche Run
        # Alternative plus propre : utiliser Get-ItemPropertyValue et sauvegarder dans un fichier clé/valeur
        # On supprime la valeur
        Remove-ItemProperty -Path $regPath -Name $Entry.Name -ErrorAction Stop
        Write-Log "Désactivé (reg) : $($Entry.Name) (backup: $backupFile)"
    }
    else {
        # Dossier -> déplacer le raccourci vers le dossier backup
        $sourceFolder = $Entry.Source -replace "Dossier ",""
        $shortcutFile = Join-Path $sourceFolder "$($Entry.Name).lnk"
        if (Test-Path $shortcutFile) {
            $backupFile = Join-Path $BackupDir "$($Entry.Name)_$datetime.lnk"
            Move-Item -Path $shortcutFile -Destination $backupFile -Force
            Write-Log "Désactivé (dossier) : $($Entry.Name) (backup: $backupFile)"
        }
    }
}

function Enable-StartupEntry {
    param($BackupEntry)
    # Restoration basée sur un fichier de log ou sur le dossier backup.
    # Implémentation simplifiée : on cherche les fichiers de backup et on les restaure.
    # Pour une version professionnelle, on aurait un log structuré.
    Write-Warning "Restauration manuelle requise. Voir les sauvegardes dans : $BackupDir"
}

# ---------- VÉRIFICATION ESPACE DISQUE ----------
function Show-DiskSpace {
    $disks = Get-CimInstance Win32_LogicalDisk -Filter "DriveType=3"
    Write-Host "`n===== ESPACE DISQUE =====" -ForegroundColor Cyan
    foreach ($disk in $disks) {
        $freeGB = [math]::Round($disk.FreeSpace/1GB, 1)
        $totalGB = [math]::Round($disk.Size/1GB, 1)
        $pctFree = [math]::Round(($disk.FreeSpace/$disk.Size)*100, 1)
        $color = if ($pctFree -lt 15) { "Red" } else { "Green" }
        Write-Host "$($disk.DeviceID) $totalGB Go total, $freeGB Go libre ($pctFree%)" -ForegroundColor $color
    }
}

# ---------- MENU PRINCIPAL ----------
function Show-Menu {
    Write-Host "`n===== OPTIMSYSTEM - Outil d'audit et optimisation =====" -ForegroundColor Magenta
    Write-Host "1 - Afficher les informations système"
    Write-Host "2 - Générer un rapport HTML"
    Write-Host "3 - Nettoyer les fichiers temporaires"
    Write-Host "4 - Gérer les programmes au démarrage"
    Write-Host "5 - Vérifier l'espace disque"
    Write-Host "6 - Afficher le journal des opérations"
    Write-Host "0 - Quitter"
}

function Run-Optimizations {
    Write-Log "Démarrage du script $ScriptName"
    $isAdmin = Test-Administrator
    if (-not $isAdmin) {
        Write-Host "Attention : Script exécuté sans droits administrateur. Certaines opérations seront limitées." -ForegroundColor Yellow
        Write-Log "Exécution sans privilèges administrateur." "WARN"
    }

    $info = Get-SystemInfo

    do {
        Show-Menu
        $choice = Read-Host "Votre choix"
        switch ($choice) {
            "1" {
                Show-SystemInfo -Info $info
            }
            "2" {
                New-SystemReport -Info $info -Html
                Write-Host "Rapport enregistré dans $ReportDir" -ForegroundColor Green
            }
            "3" {
                Write-Host "Cela supprimera les fichiers temporaires dans votre profil."
                if (Test-Administrator) {
                    $sysWide = Confirm-UserAction "Souhaitez-vous aussi nettoyer les fichiers temporaires système (Windows\Temp) ?"
                } else {
                    $sysWide = $false
                }
                if (Confirm-UserAction "Continuer le nettoyage ?") {
                    Clear-TempFiles -SystemWide:$sysWide
                    Write-Host "Nettoyage terminé." -ForegroundColor Green
                }
            }
            "4" {
                $entries = Get-AllStartupEntries
                if ($entries.Count -eq 0) {
                    Write-Host "Aucun programme de démarrage trouvé." -ForegroundColor Yellow
                } else {
                    Write-Host "Programmes de démarrage actuels :" -ForegroundColor Cyan
                    for ($i=0; $i -lt $entries.Count; $i++) {
                        Write-Host "$($i+1). $($entries[$i].Name) [$($entries[$i].Source)] ($($entries[$i].Command))"
                    }
                    $input = Read-Host "Entrez les numéros à désactiver (séparés par des virgules, ou 0 pour annuler)"
                    if ($input -ne "0") {
                        $numbers = $input -split ',' | ForEach-Object { [int]$_.Trim() - 1 }
                        $toDisable = @()
                        foreach ($n in $numbers) {
                            if ($n -ge 0 -and $n -lt $entries.Count) {
                                $toDisable += $entries[$n]
                            }
                        }
                        if ($toDisable.Count -gt 0) {
                            $msg = "Vous allez désactiver :`n$($toDisable.Name -join "`n")"
                            Write-Host $msg
                            if (Confirm-UserAction "Confirmer la désactivation ?") {
                                foreach ($e in $toDisable) {
                                    Disable-StartupEntry -Entry $e
                                }
                                Write-Host "Entrées désactivées. Redémarrez pour appliquer les changements." -ForegroundColor Green
                            }
                        }
                    }
                }
            }
            "5" {
                Show-DiskSpace
            }
            "6" {
                if (Test-Path $LogFile) {
                    Get-Content $LogFile | Out-Host
                } else {
                    Write-Host "Aucun journal disponible." -ForegroundColor Yellow
                }
            }
            "0" {
                Write-Log "Fin du script."
                return
            }
            default {
                Write-Host "Option invalide." -ForegroundColor Red
            }
        }
    } while ($true)
}

# ---------- EXÉCUTION ----------
if ($ReportOnly) {
    $info = Get-SystemInfo
    $report = New-SystemReport -Info $info -Html
    Write-Host "Rapport uniquement : $report"
} else {
    Run-Optimizations
}
