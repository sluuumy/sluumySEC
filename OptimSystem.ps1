<#
.SYNOPSIS
    OptimSystem Pro - Interface graphique d'audit et d'optimisation sécurisée.
.DESCRIPTION
    Script tout-en-un avec GUI WPF + logique métier. Exécution sécurisée.
.NOTES
    Commande de lancement :
        irm https://raw.githubusercontent.com/sluuumy/sluumySEC/main/OptimSystem.ps1 | iex
#>

# ============================================================
# Initialisation STA forcée
# ============================================================
if ([System.Threading.Thread]::CurrentThread.ApartmentState -ne 'STA') {
    Write-Host "Redémarrage en mode STA..." -ForegroundColor Cyan
    $cmd = $MyInvocation.MyCommand.Definition
    if (-not $cmd) { $cmd = $PSCommandPath }
    if (-not $cmd) {
        # Exécution depuis pipeline, pas de chemin fichier -> on recrée un script temporaire
        $temp = [System.IO.Path]::GetTempFileName() + '.ps1'
        $script = $MyInvocation.MyCommand.ScriptBlock.ToString()
        Set-Content -Path $temp -Value $script -Encoding UTF8
        $cmd = $temp
    }
    Start-Process PowerShell.exe -ArgumentList "-STA -NoProfile -ExecutionPolicy Bypass -File `"$cmd`"" -Wait
    exit
}

Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase
[System.Windows.Forms.Application]::EnableVisualStyles()

# ============================================================
# Configuration générale
# ============================================================
$LogFile   = "$env:ProgramData\OptimSystem\Logs\log_$(Get-Date -Format 'yyyyMMdd_HHmmss').log"
$BackupDir = "$env:ProgramData\OptimSystem\Backups"
$ReportDir = "$env:USERPROFILE\Desktop\SystemReports"
$null = New-Item -ItemType Directory -Force -Path (Split-Path $LogFile), $BackupDir, $ReportDir

function Write-Log($msg) {
    $entry = "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] $msg"
    Add-Content -Path $LogFile -Value $entry -Encoding UTF8
}
Write-Log "Démarrage de l'application"

# ============================================================
# Fonctions métier (identiques à la version console)
# ============================================================
function Get-SystemInfo {
    $cpu = Get-CimInstance Win32_Processor | Select-Object -First 1
    $os = Get-CimInstance Win32_OperatingSystem
    $ramTotal = [math]::Round($os.TotalVisibleMemorySize/1MB, 1)
    $ramFree  = [math]::Round($os.FreePhysicalMemory/1MB, 1)
    $disks = Get-CimInstance Win32_LogicalDisk -Filter "DriveType=3" | ForEach-Object {
        [PSCustomObject]@{
            Drive   = $_.DeviceID
            TotalGB = [math]::Round($_.Size/1GB,1)
            FreeGB  = [math]::Round($_.FreeSpace/1GB,1)
            FreePct = [math]::Round(($_.FreeSpace/$_.Size)*100,1)
        }
    }
    [PSCustomObject]@{
        CPU           = $cpu.Name.Trim()
        RAMTotalGB    = $ramTotal
        RAMFreeGB     = $ramFree
        OSVersion     = "$($os.Caption) (Build $($os.Version))"
        Architecture  = $os.OSArchitecture
        LastBootTime  = $os.LastBootUpTime
        Disks         = $disks
    }
}

function Get-CPUUsagePercent { (Get-CimInstance Win32_Processor).LoadPercentage }

function Get-RAMUsagePercent {
    $os = Get-CimInstance Win32_OperatingSystem
    [math]::Round(($os.TotalVisibleMemorySize - $os.FreePhysicalMemory) / $os.TotalVisibleMemorySize * 100, 1)
}

function Clear-TempFiles {
    $paths = @($env:TEMP, "$env:SystemRoot\Temp")
    $totalSize = 0; $count = 0
    foreach ($p in $paths) {
        if (-not (Test-Path $p)) { continue }
        Get-ChildItem -Path $p -Recurse -File -ErrorAction SilentlyContinue | ForEach-Object {
            try {
                $size = $_.Length
                Remove-Item $_.FullName -Force -ErrorAction Stop
                $totalSize += $size; $count++
            } catch {}
        }
    }
    [PSCustomObject]@{
        FilesDeleted = $count
        SizeMB       = [math]::Round($totalSize / 1MB, 2)
    }
}

function Get-StartupEntries {
    $entries = @()
    # Registre
    $regPaths = @(
        'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run',
        'HKLM:\Software\Microsoft\Windows\CurrentVersion\Run'
    )
    foreach ($regPath in $regPaths) {
        if (Test-Path $regPath) {
            Get-ItemProperty -Path $regPath | Get-Member -MemberType NoteProperty | ForEach-Object {
                $name = $_.Name
                $value = (Get-ItemProperty -Path $regPath).$name
                $entries += [PSCustomObject]@{ Source = 'Registre'; Name = $name; Command = $value; Path = $regPath }
            }
        }
    }
    # Dossiers de démarrage
    $folders = @(
        [System.Environment]::GetFolderPath('Startup'),
        [System.Environment]::GetFolderPath('CommonStartup')
    )
    foreach ($folder in $folders) {
        if (Test-Path $folder) {
            Get-ChildItem $folder -Filter '*.lnk' | ForEach-Object {
                $shortcut = (New-Object -ComObject WScript.Shell).CreateShortcut($_.FullName)
                $entries += [PSCustomObject]@{ Source = 'Dossier'; Name = $_.BaseName; Command = $shortcut.TargetPath; Path = $_.FullName }
            }
        }
    }
    return $entries
}

function Disable-StartupEntry($entry) {
    $timestamp = Get-Date -Format 'yyyyMMdd_HHmmss'
    if ($entry.Source -eq 'Registre') {
        $backupFile = Join-Path $BackupDir "$($entry.Name)_$timestamp.reg"
        reg export "$($entry.Path)" $backupFile /y *>$null
        Remove-ItemProperty -Path $entry.Path -Name $entry.Name -ErrorAction Stop
        Write-Log "Désactivé (reg): $($entry.Name), backup: $backupFile"
        return $backupFile
    }
    else {
        $shortcutPath = $entry.Path
        if (Test-Path $shortcutPath) {
            $backupFile = Join-Path $BackupDir "$($entry.Name)_$timestamp.lnk"
            Move-Item -Path $shortcutPath -Destination $backupFile -Force
            Write-Log "Désactivé (dossier): $($entry.Name), backup: $backupFile"
            return $backupFile
        }
    }
    return $null
}

# ============================================================
# Construction de l'interface WPF
# ============================================================

[xml]$xaml = @"
<Window
    xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
    xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
    Title="⚡ OptimSystem Pro" Height="700" Width="1200"
    WindowStartupLocation="CenterScreen"
    Background="#121212" Foreground="White" WindowStyle="None" AllowsTransparency="True"
    ResizeMode="CanResizeWithGrip">
    <Window.Resources>
        <Style x:Key="BaseButton" TargetType="Button">
            <Setter Property="Background" Value="#2A2A2A"/>
            <Setter Property="Foreground" Value="White"/>
            <Setter Property="BorderBrush" Value="#3A3A3A"/>
            <Setter Property="BorderThickness" Value="1"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="Button">
                        <Border x:Name="border" Background="{TemplateBinding Background}"
                                BorderBrush="{TemplateBinding BorderBrush}"
                                BorderThickness="{TemplateBinding BorderThickness}"
                                CornerRadius="6">
                            <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
                        </Border>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsMouseOver" Value="True">
                                <Setter TargetName="border" Property="Background" Value="#3A3A3A"/>
                            </Trigger>
                            <Trigger Property="IsPressed" Value="True">
                                <Setter TargetName="border" Property="Background" Value="#4A4A4A"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>
        <Style x:Key="AccentButton" BasedOn="{StaticResource BaseButton}" TargetType="Button">
            <Setter Property="Background" Value="#4DA3FF"/>
            <Setter Property="BorderBrush" Value="#4DA3FF"/>
            <Setter Property="Foreground" Value="White"/>
        </Style>
        <Style x:Key="SidebarButton" TargetType="RadioButton">
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="RadioButton">
                        <Border x:Name="border" CornerRadius="8" Background="Transparent"
                                Padding="12,10" Margin="4,2">
                            <ContentPresenter/>
                        </Border>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsChecked" Value="True">
                                <Setter TargetName="border" Property="Background" Value="#2A2A2A"/>
                                <Setter Property="Foreground" Value="#4DA3FF"/>
                            </Trigger>
                            <Trigger Property="IsMouseOver" Value="True">
                                <Setter TargetName="border" Property="Background" Value="#2E2E2E"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>
        <Style x:Key="Card" TargetType="Border">
            <Setter Property="Background" Value="#1E1E1E"/>
            <Setter Property="CornerRadius" Value="10"/>
            <Setter Property="Margin" Value="5"/>
            <Setter Property="Padding" Value="15"/>
        </Style>
    </Window.Resources>
    <Grid>
        <Grid.RowDefinitions>
            <RowDefinition Height="30"/>
            <RowDefinition Height="*"/>
        </Grid.RowDefinitions>
        <!-- Barre de titre personnalisée -->
        <Grid Background="#1A1A1A" Grid.Row="0" MouseLeftButtonDown="TitleBar_MouseDown">
            <TextBlock Text="⚡ OptimSystem Pro" Foreground="#4DA3FF" FontWeight="Bold"
                       VerticalAlignment="Center" Margin="10,0,0,0"/>
            <StackPanel Orientation="Horizontal" HorizontalAlignment="Right">
                <Button x:Name="BtnMinimize" Content="_" Width="30" Height="20" Background="Transparent" Foreground="White" Click="MinimizeWindow"/>
                <Button x:Name="BtnClose" Content="X" Width="30" Height="20" Background="Transparent" Foreground="White" Click="CloseWindow"/>
            </StackPanel>
        </Grid>
        <!-- Contenu principal -->
        <Grid Grid.Row="1">
            <Grid.ColumnDefinitions>
                <ColumnDefinition Width="230"/>
                <ColumnDefinition Width="*"/>
            </Grid.ColumnDefinitions>
            <!-- Barre latérale -->
            <Border Background="#1A1A1A" Grid.Column="0">
                <StackPanel>
                    <TextBlock Text=" Navigation" Foreground="#888888" Margin="16,20,0,5"/>
                    <RadioButton x:Name="btnDashboard" Content="🏠 Tableau de bord" Style="{StaticResource SidebarButton}" IsChecked="True" Checked="MenuChecked"/>
                    <RadioButton x:Name="btnSystemInfo" Content="💻 Infos système" Style="{StaticResource SidebarButton}" Checked="MenuChecked"/>
                    <RadioButton x:Name="btnOptim" Content="⚙️ Optimisations" Style="{StaticResource SidebarButton}" Checked="MenuChecked"/>
                    <RadioButton x:Name="btnClean" Content="🧹 Nettoyage" Style="{StaticResource SidebarButton}" Checked="MenuChecked"/>
                    <RadioButton x:Name="btnPerf" Content="🚀 Performances" Style="{StaticResource SidebarButton}" Checked="MenuChecked"/>
                    <RadioButton x:Name="btnTools" Content="🛠️ Outils" Style="{StaticResource SidebarButton}" Checked="MenuChecked"/>
                    <RadioButton x:Name="btnSecurity" Content="🔒 Sécurité" Style="{StaticResource SidebarButton}" Checked="MenuChecked"/>
                    <RadioButton x:Name="btnReports" Content="📊 Rapports" Style="{StaticResource SidebarButton}" Checked="MenuChecked"/>
                    <RadioButton x:Name="btnSettings" Content="⚙️ Paramètres" Style="{StaticResource SidebarButton}" Checked="MenuChecked"/>
                    <RadioButton x:Name="btnAbout" Content="❓ À propos" Style="{StaticResource SidebarButton}" Checked="MenuChecked"/>
                </StackPanel>
            </Border>
            <!-- Zone de contenu -->
            <ContentControl x:Name="MainContent" Grid.Column="1" Margin="20"/>
        </Grid>
    </Grid>
</Window>
"@

# Parser le XAML
$reader = New-Object System.Xml.XmlNodeReader $xaml
$Window = [Windows.Markup.XamlReader]::Load($reader)

# Récupérer les contrôles nommés
$xaml.SelectNodes("//*[@Name]") | ForEach-Object {
    Set-Variable -Name $_.Name -Value $Window.FindName($_.Name)
}

# ============================================================
# Handlers WPF
# ============================================================
$Window.Add_Loaded({
    Write-Log "Fenêtre chargée"
})

# Handler pour déplacer la fenêtre (barre de titre)
$null = $Window.FindName('TitleBar_MouseDown')
$Window.FindName('BtnMinimize').Add_Click({ $Window.WindowState = 'Minimized' })
$Window.FindName('BtnClose').Add_Click({ $Window.Close() })

# Fonction DragWindow (déplacement)
$dragHandler = {
    if ([System.Windows.Input.Mouse]::LeftButton -eq [System.Windows.Input.MouseButtonState]::Pressed) {
        $Window.DragMove()
    }
}
# Attacher l'évènement sur le Grid de la barre de titre (nous n'avons pas d'ID sur le Grid, on le fait en code)
# On va chercher le premier Grid enfant du Grid principal
$titleGrid = $Window.Content.FindName('') # un peu tricky
# Plus simple : ajouter le handler directement après le chargement XAML
# On sait que le Grid de titre n'a pas de Name, on va le récupérer via VisualTreeHelper
function Get-TitleBarGrid {
    $root = $Window.Content
    if ($root -is [Windows.Controls.Grid]) {
        return $root.Children[0]  # Premier enfant = Grid barre titre
    }
    return $null
}
$titleGrid = Get-TitleBarGrid
if ($titleGrid) {
    $titleGrid.Add_MouseLeftButtonDown($dragHandler)
}

# ============================================================
# Navigation entre pages
# ============================================================
$currentTimer = $null

function Stop-TimerIfRunning {
    if ($currentTimer -and $currentTimer.IsEnabled) {
        $currentTimer.Stop()
        $currentTimer = $null
    }
}

function Set-ContentPage {
    param($pageFunction)
    Stop-TimerIfRunning
    $page = & $pageFunction
    $MainContent.Content = $page
}

$pages = @{
    btnDashboard  = { DashboardPage }
    btnSystemInfo = { SystemInfoPage }
    btnOptim      = { OptimizationsPage }
    btnClean      = { CleanPage }
    btnPerf       = { PerformancePage }
    btnTools      = { ToolsPage }
    btnSecurity   = { SecurityPage }
    btnReports    = { ReportsPage }
    btnSettings   = { SettingsPage }
    btnAbout      = { AboutPage }
}

function MenuChecked {
    param($sender, $e)
    if ($sender.IsChecked) {
        $func = $pages[$sender.Name]
        if ($func) { Set-ContentPage $func }
    }
}

# ============================================================
# Pages (création dynamique d'éléments WPF)
# ============================================================
function New-SimpleCard($title, $value, $emoji) {
    $border = New-Object Windows.Controls.Border
    $border.Style = $Window.Resources['Card']
    $border.Width = 220
    $border.Height = 100
    $stack = New-Object Windows.Controls.StackPanel
    $tbTitle = New-Object Windows.Controls.TextBlock
    $tbTitle.Text = "$emoji $title"
    $tbTitle.FontSize = 14
    $tbTitle.Foreground = "#AAAAAA"
    $tbValue = New-Object Windows.Controls.TextBlock
    $tbValue.Text = $value
    $tbValue.FontSize = 24
    $tbValue.FontWeight = "Bold"
    $tbValue.Foreground = "White"
    $stack.Children.Add($tbTitle)
    $stack.Children.Add($tbValue)
    $border.Child = $stack
    return $border, $tbValue  # retourne le Border et le TextBlock pour MAJ
}

function DashboardPage {
    $grid = New-Object Windows.Controls.Grid
    $grid.RowDefinitions.Add((New-Object Windows.Controls.RowDefinition))
    $grid.RowDefinitions.Add((New-Object Windows.Controls.RowDefinition))
    $grid.RowDefinitions[0].Height = "Auto"
    $grid.RowDefinitions[1].Height = "*"

    # Panneau de cartes
    $panel = New-Object Windows.Controls.WrapPanel
    $panel.Margin = "0,0,0,15"
    
    $cardCPU, $txtCPU = New-SimpleCard "CPU" "..." "🧠"
    $cardRAM, $txtRAM = New-SimpleCard "RAM" "..." "🧮"
    $cardDisk, $txtDisk = New-SimpleCard "Stockage" "..." "💾"
    
    $panel.Children.Add($cardCPU)
    $panel.Children.Add($cardRAM)
    $panel.Children.Add($cardDisk)
    $grid.Children.Add($panel)
    [Windows.Controls.Grid]::SetRow($panel, 0)

    # Bouton optimisation rapide
    $btnOpt = New-Object Windows.Controls.Button
    $btnOpt.Style = $Window.Resources['AccentButton']
    $btnOpt.Content = "🚀 Optimisation rapide"
    $btnOpt.Width = 200
    $btnOpt.Height = 36
    $btnOpt.Margin = "10"
    $btnOpt.Add_Click({
        $res = [System.Windows.MessageBox]::Show("Lancer l'optimisation rapide ? (Nettoyage + arrêt de tâches légères)", "Confirmation", "YesNo", "Question")
        if ($res -eq 'Yes') {
            $cleanRes = Clear-TempFiles
            [System.Windows.MessageBox]::Show("Nettoyage terminé : $($cleanRes.FilesDeleted) fichiers supprimés ($($cleanRes.SizeMB) Mo)", "Terminé")
            Write-Log "Optimisation rapide effectuée"
        }
    })
    [Windows.Controls.Grid]::SetRow($btnOpt, 1)
    $grid.Children.Add($btnOpt)

    # Timer mise à jour
    $timer = New-Object System.Windows.Threading.DispatcherTimer
    $timer.Interval = [TimeSpan]::FromSeconds(2)
    $timer.Add_Tick({
        $txtCPU.Text = "$(Get-CPUUsagePercent) %"
        $txtRAM.Text = "$(Get-RAMUsagePercent) %"
        $diskInfo = Get-SystemInfo | Select-Object -ExpandProperty Disks | Where-Object Drive -eq "C:"
        if ($diskInfo) { $txtDisk.Text = "$($diskInfo.FreeGB) Go libres" }
    })
    $timer.Start()
    $currentTimer = $timer
    $Window.Tag = $timer
    return $grid
}

function SystemInfoPage {
    $grid = New-Object Windows.Controls.Grid
    $info = Get-SystemInfo
    $text = "🧠 Processeur : $($info.CPU)`n`n🧮 RAM totale : $($info.RAMTotalGB) Go (libre : $($info.RAMFreeGB) Go)`n💾 Stockage :`n"
    foreach ($d in $info.Disks) {
        $text += "   $($d.Drive) $($d.TotalGB) Go total, $($d.FreeGB) Go libre ($($d.FreePct)% libre)`n"
    }
    $text += "`n🖥️ Système : $($info.OSVersion)`n⏱️ Dernier démarrage : $($info.LastBootTime)"
    $tb = New-Object Windows.Controls.TextBlock
    $tb.Text = $text
    $tb.FontSize = 14
    $tb.Foreground = "White"
    $tb.Margin = "10"
    $grid.Children.Add($tb)
    return $grid
}

function OptimizationsPage {
    $grid = New-Object Windows.Controls.Grid
    $sp = New-Object Windows.Controls.StackPanel -Property @{Margin="10"}
    $tb = New-Object Windows.Controls.TextBlock -Property @{Text="Optimisations disponibles (sécurisées)"; FontSize=18; Foreground="White"}
    $sp.Children.Add($tb)

    # Liste des optimisations avec toggles
    $opts = @(
        @{ Name="Désactiver les effets de transparence"; Desc="Améliore les performances sur les anciens PC" },
        @{ Name="Désactiver les animations Windows"; Desc="Réduit la latence visuelle" },
        @{ Name="Désactiver les notifications inutiles"; Desc="Moins de distractions" },
        @{ Name="Supprimer les programmes inutiles au démarrage"; Desc="Démarrage plus rapide" }
    )
    foreach ($opt in $opts) {
        $stack = New-Object Windows.Controls.StackPanel -Property @{Orientation="Horizontal"; Margin="0,5"}
        $toggle = New-Object Windows.Controls.Primitives.ToggleButton -Property @{Width=50; Height=24}
        $desc = New-Object Windows.Controls.TextBlock -Property @{Text="$($opt.Desc)"; Foreground="#CCCCCC"; Margin="10,0,0,0"}
        $stack.Children.Add($toggle)
        $stack.Children.Add($desc)
        $sp.Children.Add($stack)
    }
    $grid.Children.Add($sp)
    return $grid
}

function CleanPage {
    $grid = New-Object Windows.Controls.Grid
    $sp = New-Object Windows.Controls.StackPanel -Property @{Margin="20"; VerticalAlignment="Center"}
    $btnAnalyze = New-Object Windows.Controls.Button -Property @{
        Content="🔍 Analyser les fichiers inutiles"
        Style=$Window.Resources['AccentButton']
        Width=220; Height=40
    }
    $btnClean = New-Object Windows.Controls.Button -Property @{
        Content="🧹 Nettoyer tout"
        Style=$Window.Resources['AccentButton']
        Width=220; Height=40; Margin="0,10,0,0"
    }
    $txtResult = New-Object Windows.Controls.TextBlock -Property @{Text="Prêt."; Foreground="White"; Margin="0,15,0,0"; FontSize=14}
    $btnAnalyze.Add_Click({
        $txtResult.Text = "Analyse en cours..."
        $res = Clear-TempFiles
        $txtResult.Text = "Fichiers temporaires récupérables : ~$($res.SizeMB) Mo"
    })
    $btnClean.Add_Click({
        if ([System.Windows.MessageBox]::Show("Supprimer tous les fichiers temporaires ?", "Confirmation", "YesNo", "Question") -eq 'Yes') {
            $res = Clear-TempFiles
            $txtResult.Text = "Nettoyage terminé : $($res.FilesDeleted) fichiers supprimés ($($res.SizeMB) Mo)"
            Write-Log "Nettoyage manuel: $($res.FilesDeleted) fichiers, $($res.SizeMB) Mo"
        }
    })
    $sp.Children.Add($btnAnalyze)
    $sp.Children.Add($btnClean)
    $sp.Children.Add($txtResult)
    $grid.Children.Add($sp)
    return $grid
}

function PerformancePage {
    $grid = New-Object Windows.Controls.Grid
    $tb = New-Object Windows.Controls.TextBlock -Property @{Text="Graphiques en temps réel (bientôt disponibles)"; FontSize=16; Foreground="White"; Margin="10"}
    $grid.Children.Add($tb)
    return $grid
}

function ToolsPage {
    $grid = New-Object Windows.Controls.Grid
    $sp = New-Object Windows.Controls.StackPanel -Property @{Margin="10"}
    $tb = New-Object Windows.Controls.TextBlock -Property @{Text="🛠️ Outils système rapides"; FontSize=16; Foreground="White"}
    $sp.Children.Add($tb)
    $tools = @(
        @{Name="Gestionnaire de démarrage"; Exe="taskmgr"},
        @{Name="Nettoyage de disque natif"; Exe="cleanmgr"},
        @{Name="Services Windows"; Exe="services.msc"},
        @{Name="Panneau de configuration"; Exe="control"}
    )
    foreach ($tool in $tools) {
        $btn = New-Object Windows.Controls.Button -Property @{
            Content=$tool.Name
            Style=$Window.Resources['BaseButton']
            Width=200; Height=35; Margin="0,5"
        }
        $exe = $tool.Exe
        $btn.Add_Click({ Start-Process $exe })
        $sp.Children.Add($btn)
    }
    $grid.Children.Add($sp)
    return $grid
}

function SecurityPage {
    $grid = New-Object Windows.Controls.Grid
    $sp = New-Object Windows.Controls.StackPanel -Property @{Margin="10"}
    $tb = New-Object Windows.Controls.TextBlock -Property @{Text="🔒 État de sécurité du système"; FontSize=16; Foreground="White"}
    $sp.Children.Add($tb)
    # Vérifications simples
    $fw = Get-NetFirewallProfile | Where-Object Enabled -eq 'True'
    $av = Get-CimInstance -Namespace root/SecurityCenter2 -Class AntiVirusProduct -ErrorAction SilentlyContinue
    $status = "Pare-feu : " + $(if ($fw) {"✅ Activé"} else {"❌ Désactivé"})
    $status += "`nAntivirus : " + $(if ($av) {"✅ $($av.displayName)"} else {"❌ Aucun détecté"})
    $tb2 = New-Object Windows.Controls.TextBlock -Property @{Text=$status; Foreground="#CCCCCC"; Margin="0,10"}
    $sp.Children.Add($tb2)
    $btn = New-Object Windows.Controls.Button -Property @{
        Content="Ouvrir la Sécurité Windows"
        Style=$Window.Resources['BaseButton']
        Width=200; Height=35
    }
    $btn.Add_Click({ Start-Process windowsdefender: })
    $sp.Children.Add($btn)
    $grid.Children.Add($sp)
    return $grid
}

function ReportsPage {
    $grid = New-Object Windows.Controls.Grid
    $sp = New-Object Windows.Controls.StackPanel -Property @{Margin="10"}
    $tb = New-Object Windows.Controls.TextBlock -Property @{Text="📊 Rapports générés récemment"; FontSize=16; Foreground="White"}
    $sp.Children.Add($tb)
    if (Test-Path $ReportDir) {
        $files = Get-ChildItem $ReportDir -Filter "*.html" | Sort-Object LastWriteTime -Descending | Select-Object -First 5
        foreach ($f in $files) {
            $tblink = New-Object Windows.Controls.TextBlock -Property @{Text=$f.Name; Foreground="#4DA3FF"; TextDecorations="Underline"; Cursor="Hand"}
            $tblink.Add_MouseLeftButtonDown({ Start-Process $f.FullName })
            $sp.Children.Add($tblink)
        }
    } else {
        $sp.Children.Add((New-Object Windows.Controls.TextBlock -Property @{Text="Aucun rapport trouvé."; Foreground="#888888"}))
    }
    $grid.Children.Add($sp)
    return $grid
}

function SettingsPage {
    $grid = New-Object Windows.Controls.Grid
    $tb = New-Object Windows.Controls.TextBlock -Property @{Text="⚙️ Paramètres (thème, langue... à venir)"; FontSize=16; Foreground="White"; Margin="10"}
    $grid.Children.Add($tb)
    return $grid
}

function AboutPage {
    $grid = New-Object Windows.Controls.Grid
    $tb = New-Object Windows.Controls.TextBlock -Property @{Text="❓ À propos`n`nOptimSystem Pro v1.0`nPar sluumy`nLicence MIT`n`nOutil d'audit et d'optimisation Windows sécurisé."; FontSize=14; Foreground="White"; Margin="10"}
    $grid.Children.Add($tb)
    return $grid
}

# ============================================================
# Page par défaut
# ============================================================
Set-ContentPage $pages['btnDashboard']

# Lancer l'application
$Window.ShowDialog() | Out-Null
Write-Log "Application fermée"
