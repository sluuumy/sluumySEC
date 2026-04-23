<#
.SYNOPSIS
    OptimSystem Pro - Interface graphique d'audit et d'optimisation PC.
.DESCRIPTION
    Script tout-en-un : GUI WPF moderne + logique d'optimisation sécurisée.
    Exécution recommandée en STA (PowerShell ISE ou via la commande ci-dessous).
.NOTES
    Exécution directe :
        irm https://TON-URL/raw/OptimSystem-Pro.ps1 | iex
#>

# ============================================================
# Initialisation STA forcée (WPF nécessite STA)
# ============================================================
if ([System.Threading.Thread]::CurrentThread.ApartmentState -ne 'STA') {
    Write-Host "Redémarrage en mode STA..." -ForegroundColor Cyan
    $psArgs = "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`""
    if ($PSCommandPath -eq $null) {
        $psArgs = "-NoProfile -ExecutionPolicy Bypass -Command `"$($MyInvocation.MyCommand.Definition)`""
    }
    Start-Process PowerShell.exe -ArgumentList $psArgs -Wait
    exit
}

# Charger les assemblys WPF nécessaires
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Windows.Forms

# ============================================================
# Log et chemins
# ============================================================
$ScriptName = "OptimSystem"
$LogFile    = Join-Path $env:ProgramData "$ScriptName\Logs\$($ScriptName)_$(Get-Date -Format 'yyyyMMdd_HHmmss').log"
$BackupDir  = Join-Path $env:ProgramData "$ScriptName\Backups"
$ReportDir  = Join-Path $env:USERPROFILE "Desktop\SystemReports"
$null = New-Item -ItemType Directory -Force -Path (Split-Path $LogFile), $BackupDir, $ReportDir

function Write-Log($msg) {
    $entry = "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] $msg"
    Add-Content $LogFile $entry -Encoding UTF8
}

# ============================================================
# Fonctions métier (sécurisées)
# ============================================================
function Get-SystemInfo {
    $cpu = Get-CimInstance Win32_Processor | Select-Object -First 1
    $os = Get-CimInstance Win32_OperatingSystem
    $ramTotal = [math]::Round($os.TotalVisibleMemorySize/1MB, 1)
    $ramFree = [math]::Round($os.FreePhysicalMemory/1MB, 1)
    $disks = Get-CimInstance Win32_LogicalDisk -Filter "DriveType=3" | ForEach-Object {
        [PSCustomObject]@{ Drive=$_.DeviceID; TotalGB=[math]::Round($_.Size/1GB,1); FreeGB=[math]::Round($_.FreeSpace/1GB,1); FreePct=[math]::Round(($_.FreeSpace/$_.Size)*100,1) }
    }
    [PSCustomObject]@{
        CPU = $cpu.Name.Trim()
        RAMTotalGB = $ramTotal
        RAMFreeGB = $ramFree
        OSVersion = "$($os.Caption) (Build $($os.Version))"
        Arch = $os.OSArchitecture
        LastBoot = $os.LastBootUpTime
        Disks = $disks
    }
}

function Get-CPUUsage { (Get-CimInstance Win32_Processor).LoadPercentage }
function Get-RAMUsage {
    $os = Get-CimInstance Win32_OperatingSystem
    [math]::Round(($os.TotalVisibleMemorySize - $os.FreePhysicalMemory)/$os.TotalVisibleMemorySize*100,1)
}

function Clear-TempFiles {
    $paths = @($env:TEMP, "$env:SystemRoot\Temp")
    $totalSize=0; $count=0
    foreach ($p in $paths) {
        if (-not (Test-Path $p)) {continue}
        Get-ChildItem $p -Recurse -File -ErrorAction SilentlyContinue | ForEach-Object {
            try { $totalSize+=$_.Length; Remove-Item $_.FullName -Force; $count++ } catch {}
        }
    }
    [PSCustomObject]@{FilesDeleted=$count; SizeMB=[math]::Round($totalSize/1MB,2)}
}

function Get-StartupEntries {
    $entries = @()
    # Registre
    'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run','HKLM:\Software\Microsoft\Windows\CurrentVersion\Run' | ForEach-Object {
        if (Test-Path $_) {
            Get-ItemProperty $_ | Get-Member -MemberType NoteProperty | ForEach-Object {
                $entries += [PSCustomObject]@{ Source='Registry'; Name=$_.Name; Command=(Get-ItemProperty $_).($_.Name)}
            }
        }
    }
    # Dossiers
    [System.Environment+SpecialFolder]::Startup,[System.Environment+SpecialFolder]::CommonStartup | ForEach-Object {
        $p = [System.Environment]::GetFolderPath($_)
        if (Test-Path $p) {
            Get-ChildItem $p -Filter *.lnk | ForEach-Object {
                $sh = (New-Object -ComObject WScript.Shell).CreateShortcut($_.FullName)
                $entries += [PSCustomObject]@{ Source='Folder'; Name=$_.BaseName; Command=$sh.TargetPath }
            }
        }
    }
    $entries
}

# ============================================================
# Interface graphique WPF
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
            <RowDefinition Height="32"/>
            <RowDefinition Height="*"/>
        </Grid.RowDefinitions>
        <!-- Barre de titre personnalisée -->
        <Grid Background="#1A1A1A" MouseLeftButtonDown="DragWindow">
            <TextBlock Text="⚡ OptimSystem Pro" Foreground="#4DA3FF" FontWeight="Bold"
                       VerticalAlignment="Center" Margin="10,0,0,0"/>
            <Button Content="X" Style="{StaticResource BaseButton}" Width="40" Height="24"
                    HorizontalAlignment="Right" Margin="0,0,4,0" Click="CloseWindow"/>
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

# Charger la fenêtre WPF
$reader = (New-Object System.Xml.XmlNodeReader $xaml)
$Window = [Windows.Markup.XamlReader]::Load($reader)
$xaml.SelectNodes("//*[@Name]") | ForEach-Object { Set-Variable -Name $_.Name -Value $Window.FindName($_.Name) }

# ============================================================
# Fonctions utilitaires GUI
# ============================================================
function Set-ContentPage($pageFunc) {
    $MainContent.Content = & $pageFunc
}
function DragWindow { $Window.DragMove() }
function CloseWindow { $Window.Close() }

# ============================================================
# Définition des pages (chaque fonction retourne un élément WPF)
# ============================================================
function DashboardPage {
    $grid = New-Object Windows.Controls.Grid
    $grid.RowDefinitions = @(
        (New-Object Windows.Controls.RowDefinition('*')),
        (New-Object Windows.Controls.RowDefinition('Auto'))
    )

    # Cartes en haut
    $panel = New-Object Windows.Controls.WrapPanel -Property @{Margin='0,0,0,15'}
    $cards = @(
        @{Title="CPU"; Value="..." ; Icon="🧠"},
        @{Title="RAM"; Value="..." ; Icon="🧮"},
        @{Title="Stockage"; Value="..." ; Icon="💾"}
    )
    foreach ($c in $cards) {
        $border = New-Object Windows.Controls.Border -Property @{ Style=$Window.Resources['Card']; Width=220; Height=100}
        $stack = New-Object Windows.Controls.StackPanel
        $stack.Children.Add((New-Object Windows.Controls.TextBlock -Property @{Text="$($c.Icon) $($c.Title)"; FontSize=14; Foreground='#AAAAAA'}))
        $valueBlock = New-Object Windows.Controls.TextBlock -Property @{Text=$c.Value; FontSize=24; FontWeight='Bold'}
        $stack.Children.Add($valueBlock)
        $border.Child = $stack
        $panel.Children.Add($border)
    }
    $grid.Children.Add($panel)
    [Windows.Controls.Grid]::SetRow($panel,0)

    # Bouton d'optimisation rapide
    $btnOpt = New-Object Windows.Controls.Button -Property @{
        Content='🚀 Optimisation rapide';
        Style=$Window.Resources['AccentButton'];
        Width=200; Height=36; Margin='10'
    }
    $btnOpt.Add_Click({
        $result = [Windows.MessageBox]::Show("Lancer l'optimisation rapide ?", "Confirmation", "YesNo", "Question")
        if ($result -eq 'Yes') {
            # Actions rapides
        }
    })
    [Windows.Controls.Grid]::SetRow($btnOpt,1)
    $grid.Children.Add($btnOpt)

    # Timer mise à jour des cartes
    $timer = New-Object Windows.Threading.DispatcherTimer
    $timer.Interval = [TimeSpan]::FromSeconds(2)
    $timer.Add_Tick({
        $panel.Children[0].Child.Children[1].Text = "$(Get-CPUUsage) %"
        $panel.Children[1].Child.Children[1].Text = "$(Get-RAMUsage) %"
        $panel.Children[2].Child.Children[1].Text = "$((Get-PSDrive C).Free/1GB) Go libres"
    })
    $timer.Start()
    $Window.Tag = $timer  # pour le stopper si on change de page
    return $grid
}

function SystemInfoPage {
    $grid = New-Object Windows.Controls.Grid
    $info = Get-SystemInfo
    $rows = @(
        "🧠 Processeur : $($info.CPU)",
        "🧮 RAM totale : $($info.RAMTotalGB) Go",
        "💾 Stockage : $($info.Disks[0].Drive) $($info.Disks[0].TotalGB) Go",
        "🖥️ OS : $($info.OSVersion)"
    )
    $list = New-Object Windows.Controls.ItemsControl
    $list.ItemsSource = $rows
    $list.ItemTemplate = [Windows.DataTemplate]@{
        VisualTree = [Windows.FrameworkElementFactory]::CreateType( [Windows.Controls.TextBlock] )
    }
    $grid.Children.Add($list)
    return $grid
}

function CleanPage {
    $grid = New-Object Windows.Controls.Grid
    $btn = New-Object Windows.Controls.Button -Property @{
        Content='🧹 Lancer le nettoyage';
        Style=$Window.Resources['AccentButton'];
        Width=200; Height=36
    }
    $btn.Add_Click({
        $res = Clear-TempFiles
        [Windows.MessageBox]::Show("Supprimé : $($res.FilesDeleted) fichiers, $($res.SizeMB) Mo", "Nettoyage terminé")
    })
    $grid.Children.Add($btn)
    return $grid
}

# ... Ajouter les autres pages (Optimizations, Performance, Tools, Security, Reports, Settings, About)

# Navigation
$pages = @{
    btnDashboard  = { DashboardPage }
    btnSystemInfo = { SystemInfoPage }
    btnClean      = { CleanPage }
    # associer les autres boutons...
}

function MenuChecked {
    param($sender, $e)
    if ($sender.IsChecked) {
        # Arrêter le timer de la page précédente si présent
        if ($Window.Tag -is [Windows.Threading.DispatcherTimer]) { $Window.Tag.Stop() }
        $func = $pages[$sender.Name]
        if ($func) { Set-ContentPage $func }
    }
}

# Page par défaut
Set-ContentPage $pages['btnDashboard']

# Lancer l'application
$Window.ShowDialog() | Out-Null
Write-Log "Application fermée"
