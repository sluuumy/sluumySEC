<#
.SYNOPSIS
    OptimSystem Pro - GUI d'optimisation Windows (WPF)
    Dépose ce script dans ton dépôt GitHub, puis exécute :
    irm https://raw.githubusercontent.com/sluuumy/sluumySEC/main/OptimSystem.ps1 | iex
#>

if ([System.Threading.Thread]::CurrentThread.ApartmentState -ne 'STA') {
    $cmd = $MyInvocation.MyCommand.Definition
    if (-not $cmd) {
        $temp = [System.IO.Path]::GetTempFileName() + '.ps1'
        $MyInvocation.MyCommand.ScriptBlock.ToString() | Set-Content -Path $temp -Encoding UTF8
        $cmd = $temp
    }
    Start-Process PowerShell.exe -ArgumentList "-STA -NoProfile -ExecutionPolicy Bypass -File `"$cmd`"" -Wait
    exit
}

Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase

# --------------------------------------------------
# Logging & dossiers
# --------------------------------------------------
$ScriptName = "OptimSystem"
$LogFile    = "$env:ProgramData\$ScriptName\Logs\log_$(Get-Date -Format 'yyyyMMdd_HHmmss').log"
$BackupDir  = "$env:ProgramData\$ScriptName\Backups"
$ReportDir  = "$env:USERPROFILE\Desktop\SystemReports"
$null = New-Item -ItemType Directory -Force -Path (Split-Path $LogFile), $BackupDir, $ReportDir

function Write-Log($msg) {
    Add-Content -Path $LogFile -Value "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] $msg" -Encoding UTF8
}
Write-Log "Démarrage"

# --------------------------------------------------
# Fonctions métier
# --------------------------------------------------
function Get-CPUUsage { (Get-CimInstance Win32_Processor).LoadPercentage }
function Get-RAMUsage {
    $os = Get-CimInstance Win32_OperatingSystem
    [math]::Round(($os.TotalVisibleMemorySize - $os.FreePhysicalMemory) / $os.TotalVisibleMemorySize * 100, 1)
}
function Clear-TempFiles {
    $paths = @($env:TEMP, "$env:SystemRoot\Temp")
    $total = 0; $cnt = 0
    foreach ($p in $paths) {
        if (-not (Test-Path $p)) { continue }
        Get-ChildItem $p -Recurse -File -ErrorAction SilentlyContinue | ForEach-Object {
            try { $total += $_.Length; Remove-Item $_.FullName -Force; $cnt++ } catch {}
        }
    }
    [PSCustomObject]@{ FilesDeleted = $cnt; SizeMB = [math]::Round($total/1MB,2) }
}

# --------------------------------------------------
# XAML (aucune liaison événement !)
# --------------------------------------------------
[xml]$xaml = @"
<Window
    xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
    xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
    Title="OptimSystem Pro" Height="700" Width="1200"
    WindowStartupLocation="CenterScreen"
    Background="#121212" Foreground="White"
    WindowStyle="None" AllowsTransparency="True" ResizeMode="CanResizeWithGrip">
    <Window.Resources>
        <Style x:Key="BaseButton" TargetType="Button">
            <Setter Property="Background" Value="#2A2A2A"/>
            <Setter Property="Foreground" Value="White"/>
            <Setter Property="BorderBrush" Value="#3A3A3A"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="Button">
                        <Border Background="{TemplateBinding Background}"
                                BorderBrush="{TemplateBinding BorderBrush}"
                                CornerRadius="6" Padding="10,5">
                            <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
                        </Border>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>
        <Style x:Key="AccentButton" BasedOn="{StaticResource BaseButton}" TargetType="Button">
            <Setter Property="Background" Value="#4DA3FF"/>
            <Setter Property="BorderBrush" Value="#4DA3FF"/>
        </Style>
        <Style x:Key="SidebarButton" TargetType="RadioButton">
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="RadioButton">
                        <Border x:Name="border" CornerRadius="8" Background="Transparent" Padding="12,8" Margin="4,2">
                            <ContentPresenter/>
                        </Border>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsChecked" Value="True">
                                <Setter TargetName="border" Property="Background" Value="#2A2A2A"/>
                                <Setter Property="Foreground" Value="#4DA3FF"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>
    </Window.Resources>
    <Grid>
        <Grid.RowDefinitions>
            <RowDefinition Height="30"/>
            <RowDefinition/>
        </Grid.RowDefinitions>
        <!-- Barre de titre -->
        <Grid Background="#1A1A1A" Grid.Row="0" x:Name="TitleBar">
            <TextBlock Text="⚡ OptimSystem Pro" Foreground="#4DA3FF" FontWeight="Bold"
                       VerticalAlignment="Center" Margin="10,0,0,0"/>
            <StackPanel Orientation="Horizontal" HorizontalAlignment="Right">
                <Button Content="_" Width="30" Height="20" Background="Transparent" Foreground="White" x:Name="BtnMin"/>
                <Button Content="X" Width="30" Height="20" Background="Transparent" Foreground="White" x:Name="BtnClose"/>
            </StackPanel>
        </Grid>
        <!-- Contenu principal -->
        <Grid Grid.Row="1">
            <Grid.ColumnDefinitions>
                <ColumnDefinition Width="230"/>
                <ColumnDefinition/>
            </Grid.ColumnDefinitions>
            <!-- Barre latérale -->
            <Border Background="#1A1A1A" Grid.Column="0">
                <StackPanel x:Name="MenuPanel" Margin="10,10,0,0">
                    <TextBlock Text=" Navigation" Foreground="#888888" Margin="0,10,0,5"/>
                </StackPanel>
            </Border>
            <!-- Zone de contenu -->
            <ContentControl x:Name="MainContent" Grid.Column="1" Margin="20"/>
        </Grid>
    </Grid>
</Window>
"@

$reader = New-Object System.Xml.XmlNodeReader $xaml
try {
    $Window = [Windows.Markup.XamlReader]::Load($reader)
} catch {
    Write-Host "Erreur chargement XAML : $_" -ForegroundColor Red
    exit
}

# Récupération des objets nommés
$MainContent = $Window.FindName("MainContent")
$TitleBar    = $Window.FindName("TitleBar")
$BtnMin      = $Window.FindName("BtnMin")
$BtnClose    = $Window.FindName("BtnClose")
$MenuPanel   = $Window.FindName("MenuPanel")

# Déplacement fenêtre
$TitleBar.Add_MouseLeftButtonDown({
    if ([System.Windows.Input.Mouse]::LeftButton -eq [System.Windows.Input.MouseButtonState]::Pressed) {
        $Window.DragMove()
    }
})

# Boutons titre
$BtnMin.Add_Click({ $Window.WindowState = 'Minimized' })
$BtnClose.Add_Click({ $Window.Close() })

# --------------------------------------------------
# Menu dynamique (ajouté en code)
# --------------------------------------------------
$menuItems = @(
    @{Name="🏠 Tableau de bord"; Tag="dashboard"},
    @{Name="💻 Infos système"; Tag="info"},
    @{Name="🧹 Nettoyage"; Tag="clean"},
    @{Name="🛠️ Outils"; Tag="tools"},
    @{Name="🔒 Sécurité"; Tag="security"},
    @{Name="❓ À propos"; Tag="about"}
)
$radioGroup = New-Object System.Collections.Generic.List[System.Windows.Controls.RadioButton]

foreach ($item in $menuItems) {
    $rb = New-Object System.Windows.Controls.RadioButton
    $rb.Content = $item.Name
    $rb.Style = $Window.Resources['SidebarButton']
    $rb.Tag = $item.Tag
    $rb.Add_Checked({
        param($sender,$e)
        if ($sender.IsChecked) {
            switch ($sender.Tag) {
                'dashboard'  { Show-Dashboard }
                'info'       { Show-Info }
                'clean'      { Show-Clean }
                'tools'      { Show-Tools }
                'security'   { Show-Security }
                'about'      { Show-About }
            }
        }
    })
    $MenuPanel.Children.Add($rb)
    $radioGroup.Add($rb)
}
# Sélectionner le premier
$radioGroup[0].IsChecked = $true

# --------------------------------------------------
# Pages (fonctions d'affichage)
# --------------------------------------------------
function Show-Dashboard {
    $grid = New-Object System.Windows.Controls.Grid
    $sp = New-Object System.Windows.Controls.StackPanel -Property @{Margin="10"}
    $cardsData = @(
        @{T="🧠 CPU"; V=$([string](Get-CPUUsage)+' %')},
        @{T="🧮 RAM"; V=$([string](Get-RAMUsage)+' %')},
        @{T="💾 Stockage"; V=$([string]([math]::Round((Get-PSDrive C).Free/1GB,1))+' Go libres')}
    )
    foreach ($c in $cardsData) {
        $border = New-Object System.Windows.Controls.Border
        $border.Background = "#1E1E1E"
        $border.CornerRadius = "10"
        $border.Margin = "5"
        $border.Padding = "15"
        $border.Width = 200; $border.Height = 90
        $stack = New-Object System.Windows.Controls.StackPanel
        $tb1 = New-Object System.Windows.Controls.TextBlock -Property @{Text=$c.T; Foreground="#AAAAAA"; FontSize=14}
        $tb2 = New-Object System.Windows.Controls.TextBlock -Property @{Text=$c.V; Foreground="White"; FontSize=22; FontWeight="Bold"}
        $stack.Children.Add($tb1); $stack.Children.Add($tb2)
        $border.Child = $stack
        $sp.Children.Add($border)
    }
    # Bouton rapide
    $btn = New-Object System.Windows.Controls.Button
    $btn.Content = "🚀 Optimisation rapide"; $btn.Style = $Window.Resources['AccentButton']
    $btn.Width=200; $btn.Height=36; $btn.Margin="10,20,0,0"
    $btn.Add_Click({
        $res = [System.Windows.MessageBox]::Show("Lancer le nettoyage ?", "Confirmation", "YesNo", "Question")
        if ($res -eq 'Yes') {
            $out = Clear-TempFiles
            [System.Windows.MessageBox]::Show("Terminé : $($out.FilesDeleted) fichiers, $($out.SizeMB) Mo", "OK")
        }
    })
    $sp.Children.Add($btn)
    $grid.Children.Add($sp)
    $MainContent.Content = $grid
}

function Show-Info {
    $info = Get-CimInstance Win32_Processor | Select -First 1
    $os = Get-CimInstance Win32_OperatingSystem
    $ram = [math]::Round($os.TotalVisibleMemorySize/1MB,1)
    $grid = New-Object System.Windows.Controls.Grid
    $tb = New-Object System.Windows.Controls.TextBlock -Property @{
        Text="🧠 CPU : $($info.Name)`n🧮 RAM : ${ram} Go`n🖥️ OS : $($os.Caption) (Build $($os.Version))"
        Foreground="White"; FontSize=14; Margin="10"
    }
    $grid.Children.Add($tb)
    $MainContent.Content = $grid
}

function Show-Clean {
    $grid = New-Object System.Windows.Controls.Grid
    $sp = New-Object System.Windows.Controls.StackPanel -Property @{Margin="20"}
    $btn = New-Object System.Windows.Controls.Button -Property @{
        Content="🧹 Nettoyer fichiers temporaires"
        Style=$Window.Resources['AccentButton']; Width=220; Height=40
    }
    $lbl = New-Object System.Windows.Controls.TextBlock -Property @{Foreground="White"; Margin="0,15,0,0"}
    $btn.Add_Click({
        $out = Clear-TempFiles
        $lbl.Text = "Nettoyage terminé : $($out.FilesDeleted) fichiers, $($out.SizeMB) Mo supprimés."
        Write-Log "Nettoyage manuel: $($out.FilesDeleted) fichiers, $($out.SizeMB) Mo"
    })
    $sp.Children.Add($btn)
    $sp.Children.Add($lbl)
    $grid.Children.Add($sp)
    $MainContent.Content = $grid
}

function Show-Tools {
    $grid = New-Object System.Windows.Controls.Grid
    $sp = New-Object System.Windows.Controls.StackPanel -Property @{Margin="10"}
    $tools = @('taskmgr','cleanmgr','services.msc','control')
    foreach ($t in $tools) {
        $b = New-Object System.Windows.Controls.Button -Property @{
            Content="🛠️ $t"
            Style=$Window.Resources['BaseButton']; Width=200; Height=35; Margin="5"
        }
        $b.Add_Click({ Start-Process $t })
        $sp.Children.Add($b)
    }
    $grid.Children.Add($sp)
    $MainContent.Content = $grid
}

function Show-Security {
    $grid = New-Object System.Windows.Controls.Grid
    $tb = New-Object System.Windows.Controls.TextBlock -Property @{
        Text="🔒 Sécurité Windows`n`nPare-feu : $(if(Get-NetFirewallProfile | Where Enabled){'✅ Activé'}else{'❌ Désactivé'})"
        Foreground="White"; Margin="10"
    }
    $grid.Children.Add($tb)
    $MainContent.Content = $grid
}

function Show-About {
    $grid = New-Object System.Windows.Controls.Grid
    $tb = New-Object System.Windows.Controls.TextBlock -Property @{
        Text="❓ À propos`nOptimSystem Pro v1.0`npar sluumy`nLicence MIT"
        Foreground="White"; Margin="10"
    }
    $grid.Children.Add($tb)
    $MainContent.Content = $grid
}

# Lancement
$Window.ShowDialog() | Out-Null
Write-Log "Fermeture"
