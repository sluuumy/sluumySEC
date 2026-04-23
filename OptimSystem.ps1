# ================================================
# OptimSystem Pro v2.0 — by Sluumy
# Interface moderne WPF — Design Windows 11
# Script stable, sécurisé, fonctionnel
# ================================================

# Force STA pour WPF
if ([System.Threading.Thread]::CurrentThread.ApartmentState -ne 'STA') {
    $cmd = $MyInvocation.MyCommand.Definition
    if (-not $cmd -or $cmd -eq '') {
        $tmp = [System.IO.Path]::GetTempFileName() -replace '\.tmp$', '.ps1'
        $MyInvocation.MyCommand.ScriptBlock.ToString() | Set-Content $tmp -Encoding UTF8
        $cmd = $tmp
    }
    Start-Process PowerShell.exe -ArgumentList "-STA -NoProfile -ExecutionPolicy Bypass -File `"$cmd`"" -Wait
    exit
}

Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Windows.Forms

# --- Admin check ---
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]"Administrator")

# --- Logs ---
$LogDir  = "$env:ProgramData\OptimSystem\Logs"
$null    = New-Item -ItemType Directory -Force -Path $LogDir -ErrorAction SilentlyContinue
$LogFile = "$LogDir\log_$(Get-Date -Format 'yyyyMMdd_HHmmss').log"
function Write-Log($msg) {
    $line = "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] $msg"
    Add-Content -Path $LogFile -Value $line -Encoding UTF8 -ErrorAction SilentlyContinue
}
Write-Log "Démarrage OptimSystem Pro v2.0 — Admin: $isAdmin"

# ================================================
# FONCTIONS SYSTÈME
# ================================================
function Get-CPUUsage {
    try { (Get-CimInstance Win32_Processor -ErrorAction Stop | Measure-Object -Property LoadPercentage -Average).Average }
    catch { 0 }
}
function Get-RAMInfo {
    try {
        $os  = Get-CimInstance Win32_OperatingSystem -ErrorAction Stop
        $pct = [math]::Round(($os.TotalVisibleMemorySize - $os.FreePhysicalMemory) / $os.TotalVisibleMemorySize * 100, 1)
        $total = [math]::Round($os.TotalVisibleMemorySize / 1MB, 1)
        $free  = [math]::Round($os.FreePhysicalMemory / 1MB, 1)
        [PSCustomObject]@{ Pct=$pct; Total=$total; Free=$free; Used=[math]::Round($total-$free,1) }
    } catch { [PSCustomObject]@{ Pct=0; Total=0; Free=0; Used=0 } }
}
function Get-DiskInfo {
    try {
        $d = Get-PSDrive C -ErrorAction Stop
        $total = [math]::Round(($d.Used + $d.Free) / 1GB, 1)
        $free  = [math]::Round($d.Free / 1GB, 1)
        $pct   = [math]::Round($d.Used / ($d.Used + $d.Free) * 100, 1)
        [PSCustomObject]@{ Total=$total; Free=$free; Pct=$pct }
    } catch { [PSCustomObject]@{ Total=0; Free=0; Pct=0 } }
}
function Get-OSInfo {
    try {
        $os  = Get-CimInstance Win32_OperatingSystem -ErrorAction Stop
        $cpu = Get-CimInstance Win32_Processor -ErrorAction Stop | Select-Object -First 1
        $ram = Get-RAMInfo
        [PSCustomObject]@{
            OS      = $os.Caption
            Version = $os.Version
            Build   = $os.BuildNumber
            CPU     = $cpu.Name
            CPUCores= $cpu.NumberOfCores
            RAMTotal= $ram.Total
            Uptime  = (Get-Date) - $os.LastBootUpTime
        }
    } catch { $null }
}
function Get-SecurityStatus {
    $fw = $false; $av = "Inconnu"; $wu = "Inconnu"
    try { $fw = (Get-NetFirewallProfile -ErrorAction Stop | Where-Object Enabled -eq $true).Count -gt 0 } catch {}
    try { $avProd = Get-CimInstance -Namespace root/SecurityCenter2 -ClassName AntivirusProduct -ErrorAction Stop | Select-Object -First 1; if ($avProd) { $av = $avProd.displayName } } catch {}
    try { $wuSvc = Get-Service wuauserv -ErrorAction Stop; $wu = if ($wuSvc.Status -eq 'Running') { "Actif" } else { "Arrêté" } } catch {}
    [PSCustomObject]@{ Firewall=$fw; Antivirus=$av; WindowsUpdate=$wu }
}
function Get-StartupApps {
    $list = @()
    try { $list += Get-CimInstance Win32_StartupCommand -ErrorAction Stop | Select-Object Name, Command, User, Location } catch {}
    try { $list += Get-ItemProperty "HKCU:\Software\Microsoft\Windows\CurrentVersion\Run" -ErrorAction Stop | 
        Select-Object -Property * -ExcludeProperty PS* | 
        ForEach-Object { $_.PSObject.Properties | ForEach-Object { [PSCustomObject]@{Name=$_.Name; Command=$_.Value; User="HKCU"; Location="Registre"} } }
    } catch {}
    $list
}
function Clear-TempFiles {
    $paths = @("$env:TEMP", "$env:SystemRoot\Temp", "$env:LOCALAPPDATA\Temp")
    $total = 0; $cnt = 0
    foreach ($p in $paths) {
        if (-not (Test-Path $p)) { continue }
        Get-ChildItem $p -Recurse -File -ErrorAction SilentlyContinue | ForEach-Object {
            try { $total += $_.Length; Remove-Item $_.FullName -Force -ErrorAction Stop; $cnt++ } catch {}
        }
    }
    [PSCustomObject]@{ Files=$cnt; MB=[math]::Round($total/1MB,2) }
}
function Clear-RecycleBinSafe {
    try { Clear-RecycleBin -Force -Confirm:$false -ErrorAction Stop; "OK" }
    catch { "Erreur: $_" }
}
function Flush-DNS {
    try { ipconfig /flushdns | Out-Null; "DNS vidé avec succès." }
    catch { "Erreur: $_" }
}
function Get-PerformanceScore {
    $cpu = Get-CPUUsage
    $ram = (Get-RAMInfo).Pct
    $disk= (Get-DiskInfo).Pct
    $score = [math]::Round(100 - ($cpu * 0.4) - ($ram * 0.35) - ($disk * 0.25), 0)
    [math]::Max(0, [math]::Min(100, $score))
}

# ================================================
# XAML — Interface complète
# ================================================
[xml]$XAML = @"
<Window
    xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
    xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
    Title="OptimSystem Pro — by Sluumy"
    Width="1200" Height="750"
    MinWidth="1000" MinHeight="650"
    Background="#111827"
    WindowStartupLocation="CenterScreen"
    WindowStyle="None"
    AllowsTransparency="True"
    ResizeMode="CanResizeWithGrip"
    FontFamily="Segoe UI">

  <Window.Resources>

    <!-- Toggle animé -->
    <Style x:Key="Toggle" TargetType="CheckBox">
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="CheckBox">
            <Grid Width="46" Height="24" Cursor="Hand">
              <Border x:Name="Tr" CornerRadius="12" Background="#374151" BorderBrush="#4B5563" BorderThickness="1"/>
              <Ellipse x:Name="Dot" Width="18" Height="18" Fill="#6B7280" HorizontalAlignment="Left" VerticalAlignment="Center" Margin="3,0,0,0"/>
            </Grid>
            <ControlTemplate.Triggers>
              <Trigger Property="IsChecked" Value="True">
                <Setter TargetName="Tr" Property="Background" Value="#4DA3FF"/>
                <Setter TargetName="Tr" Property="BorderBrush" Value="#4DA3FF"/>
                <Setter TargetName="Dot" Property="Fill" Value="White"/>
                <Setter TargetName="Dot" Property="HorizontalAlignment" Value="Right"/>
                <Setter TargetName="Dot" Property="Margin" Value="0,0,3,0"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <!-- Bouton principal bleu -->
    <Style x:Key="BtnBlue" TargetType="Button">
      <Setter Property="Background" Value="#4DA3FF"/>
      <Setter Property="Foreground" Value="White"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="FontSize" Value="13"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="BorderThickness" Value="0"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="Bd" Background="{TemplateBinding Background}" CornerRadius="8" Padding="14,8">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="Bd" Property="Background" Value="#3B8FE8"/>
              </Trigger>
              <Trigger Property="IsPressed" Value="True">
                <Setter TargetName="Bd" Property="Background" Value="#2D7BD4"/>
              </Trigger>
              <Trigger Property="IsEnabled" Value="False">
                <Setter TargetName="Bd" Property="Background" Value="#374151"/>
                <Setter Property="Foreground" Value="#6B7280"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <!-- Bouton vert -->
    <Style x:Key="BtnGreen" TargetType="Button">
      <Setter Property="Background" Value="#22C55E"/>
      <Setter Property="Foreground" Value="White"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="FontSize" Value="13"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="BorderThickness" Value="0"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="Bd" Background="{TemplateBinding Background}" CornerRadius="8" Padding="14,8">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="Bd" Property="Background" Value="#16A34A"/></Trigger>
              <Trigger Property="IsPressed" Value="True"><Setter TargetName="Bd" Property="Background" Value="#15803D"/></Trigger>
              <Trigger Property="IsEnabled" Value="False"><Setter TargetName="Bd" Property="Background" Value="#374151"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <!-- Bouton orange -->
    <Style x:Key="BtnOrange" TargetType="Button">
      <Setter Property="Background" Value="#F59E0B"/>
      <Setter Property="Foreground" Value="White"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="FontSize" Value="13"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="BorderThickness" Value="0"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="Bd" Background="{TemplateBinding Background}" CornerRadius="8" Padding="14,8">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="Bd" Property="Background" Value="#D97706"/></Trigger>
              <Trigger Property="IsPressed" Value="True"><Setter TargetName="Bd" Property="Background" Value="#B45309"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <!-- Sidebar RadioButton -->
    <Style x:Key="SideBtn" TargetType="RadioButton">
      <Setter Property="Foreground" Value="#9CA3AF"/>
      <Setter Property="FontSize" Value="13"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="RadioButton">
            <Border x:Name="Bd" CornerRadius="10" Padding="14,11" Margin="0,2" Background="Transparent">
              <ContentPresenter/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsChecked" Value="True">
                <Setter TargetName="Bd" Property="Background" Value="#1E3A5F"/>
                <Setter Property="Foreground" Value="#4DA3FF"/>
                <Setter Property="FontWeight" Value="Bold"/>
              </Trigger>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="Bd" Property="Background" Value="#1F2937"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <!-- Card style -->
    <Style x:Key="Card" TargetType="Border">
      <Setter Property="Background" Value="#1F2937"/>
      <Setter Property="CornerRadius" Value="12"/>
      <Setter Property="Padding" Value="18"/>
      <Setter Property="Margin" Value="0,0,12,12"/>
    </Style>

    <!-- ProgressBar -->
    <Style x:Key="PBar" TargetType="ProgressBar">
      <Setter Property="Height" Value="8"/>
      <Setter Property="Background" Value="#374151"/>
      <Setter Property="Foreground" Value="#4DA3FF"/>
      <Setter Property="BorderThickness" Value="0"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="ProgressBar">
            <Border CornerRadius="4" Background="{TemplateBinding Background}" Height="8">
              <Border x:Name="PART_Track">
                <Border x:Name="PART_Indicator" CornerRadius="4" Background="{TemplateBinding Foreground}" HorizontalAlignment="Left"/>
              </Border>
            </Border>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

  </Window.Resources>

  <Border CornerRadius="12" BorderBrush="#374151" BorderThickness="1">
    <Grid>
      <Grid.RowDefinitions>
        <RowDefinition Height="46"/>
        <RowDefinition Height="*"/>
      </Grid.RowDefinitions>

      <!-- TITLEBAR -->
      <Border Grid.Row="0" Background="#0F172A" CornerRadius="12,12,0,0" x:Name="TitleBar">
        <Grid Margin="16,0">
          <Grid.ColumnDefinitions>
            <ColumnDefinition Width="Auto"/>
            <ColumnDefinition Width="*"/>
            <ColumnDefinition Width="Auto"/>
          </Grid.ColumnDefinitions>
          <StackPanel Grid.Column="0" Orientation="Horizontal" VerticalAlignment="Center">
            <TextBlock Text="⚡" FontSize="18" Margin="0,0,8,0"/>
            <TextBlock Text="OptimSystem Pro" Foreground="White" FontSize="15" FontWeight="Bold" VerticalAlignment="Center"/>
            <Border Background="#1E3A5F" CornerRadius="6" Padding="8,2" Margin="10,0,0,0" VerticalAlignment="Center">
              <TextBlock Text="v2.0" Foreground="#4DA3FF" FontSize="10" FontFamily="Consolas" FontWeight="Bold"/>
            </Border>
          </StackPanel>
          <TextBlock Grid.Column="1" x:Name="AdminBadge" Text="" Foreground="#F59E0B" FontSize="11" HorizontalAlignment="Center" VerticalAlignment="Center"/>
          <StackPanel Grid.Column="2" Orientation="Horizontal" VerticalAlignment="Center">
            <Button x:Name="BtnMin" Content="─" Width="32" Height="24" Background="Transparent" Foreground="#9CA3AF" BorderThickness="0" Cursor="Hand" FontSize="14"/>
            <Button x:Name="BtnClose" Content="✕" Width="32" Height="24" Background="Transparent" Foreground="#9CA3AF" BorderThickness="0" Cursor="Hand" FontSize="13"/>
          </StackPanel>
        </Grid>
      </Border>

      <!-- BODY -->
      <Grid Grid.Row="1">
        <Grid.ColumnDefinitions>
          <ColumnDefinition Width="220"/>
          <ColumnDefinition Width="*"/>
        </Grid.ColumnDefinitions>

        <!-- SIDEBAR -->
        <Border Grid.Column="0" Background="#0F172A" CornerRadius="0,0,0,12">
          <StackPanel Margin="12,16,12,16">
            <TextBlock Text="N A V I G A T I O N" Foreground="#4B5563" FontSize="10" FontWeight="Bold" Margin="14,0,0,10"/>
            <RadioButton x:Name="NavDash"   Style="{StaticResource SideBtn}" Content="🏠  Tableau de bord"       IsChecked="True"/>
            <RadioButton x:Name="NavInfo"   Style="{StaticResource SideBtn}" Content="💻  Informations système"/>
            <RadioButton x:Name="NavClean"  Style="{StaticResource SideBtn}" Content="🧹  Nettoyage"/>
            <RadioButton x:Name="NavSec"    Style="{StaticResource SideBtn}" Content="🛡️  Sécurité"/>
            <RadioButton x:Name="NavTools"  Style="{StaticResource SideBtn}" Content="🛠️  Outils Windows"/>
            <RadioButton x:Name="NavAbout"  Style="{StaticResource SideBtn}" Content="❓  À propos"/>

            <Border Background="#1F2937" CornerRadius="10" Padding="14" Margin="0,20,0,0">
              <StackPanel>
                <TextBlock Text="ÉTAT SYSTÈME" Foreground="#4B5563" FontSize="9" FontWeight="Bold" Margin="0,0,0,8"/>
                <StackPanel Orientation="Horizontal" Margin="0,0,0,6">
                  <Ellipse x:Name="DotFW" Width="8" Height="8" Fill="#6B7280" Margin="0,0,6,0" VerticalAlignment="Center"/>
                  <TextBlock Text="Pare-feu" Foreground="#9CA3AF" FontSize="11"/>
                </StackPanel>
                <StackPanel Orientation="Horizontal" Margin="0,0,0,6">
                  <Ellipse x:Name="DotAV" Width="8" Height="8" Fill="#6B7280" Margin="0,0,6,0" VerticalAlignment="Center"/>
                  <TextBlock Text="Antivirus" Foreground="#9CA3AF" FontSize="11"/>
                </StackPanel>
                <StackPanel Orientation="Horizontal">
                  <Ellipse x:Name="DotAdmin" Width="8" Height="8" Fill="#6B7280" Margin="0,0,6,0" VerticalAlignment="Center"/>
                  <TextBlock Text="Mode Admin" Foreground="#9CA3AF" FontSize="11"/>
                </StackPanel>
              </StackPanel>
            </Border>
          </StackPanel>
        </Border>

        <!-- MAIN CONTENT -->
        <Grid Grid.Column="1" Background="#111827">

          <!-- PAGE DASHBOARD -->
          <ScrollViewer x:Name="PageDash" VerticalScrollBarVisibility="Auto" Padding="24,20">
            <StackPanel>
              <TextBlock Text="🏠  Tableau de bord" Foreground="White" FontSize="22" FontWeight="Bold" Margin="0,0,0,4"/>
              <TextBlock Text="Vue d'ensemble de votre système" Foreground="#6B7280" FontSize="13" Margin="0,0,0,20"/>

              <!-- Cartes stats -->
              <UniformGrid Rows="1" Columns="4" Margin="0,0,0,20">
                <Border Style="{StaticResource Card}">
                  <StackPanel>
                    <TextBlock Text="🖥️  Processeur" Foreground="#9CA3AF" FontSize="12" Margin="0,0,0,8"/>
                    <TextBlock x:Name="CardCPU" Text="—" Foreground="White" FontSize="28" FontWeight="Black"/>
                    <ProgressBar x:Name="PBarCPU" Style="{StaticResource PBar}" Margin="0,8,0,4" Foreground="#4DA3FF"/>
                    <TextBlock x:Name="CardCPUName" Text="CPU" Foreground="#6B7280" FontSize="10" TextWrapping="Wrap"/>
                  </StackPanel>
                </Border>
                <Border Style="{StaticResource Card}">
                  <StackPanel>
                    <TextBlock Text="🧮  Mémoire RAM" Foreground="#9CA3AF" FontSize="12" Margin="0,0,0,8"/>
                    <TextBlock x:Name="CardRAM" Text="—" Foreground="White" FontSize="28" FontWeight="Black"/>
                    <ProgressBar x:Name="PBarRAM" Style="{StaticResource PBar}" Margin="0,8,0,4" Foreground="#A855F7"/>
                    <TextBlock x:Name="CardRAMSub" Text="RAM" Foreground="#6B7280" FontSize="10"/>
                  </StackPanel>
                </Border>
                <Border Style="{StaticResource Card}">
                  <StackPanel>
                    <TextBlock Text="💾  Stockage C:" Foreground="#9CA3AF" FontSize="12" Margin="0,0,0,8"/>
                    <TextBlock x:Name="CardDisk" Text="—" Foreground="White" FontSize="28" FontWeight="Black"/>
                    <ProgressBar x:Name="PBarDisk" Style="{StaticResource PBar}" Margin="0,8,0,4" Foreground="#22C55E"/>
                    <TextBlock x:Name="CardDiskSub" Text="Disque" Foreground="#6B7280" FontSize="10"/>
                  </StackPanel>
                </Border>
                <Border Style="{StaticResource Card}" Margin="0,0,0,12">
                  <StackPanel>
                    <TextBlock Text="📊  Score système" Foreground="#9CA3AF" FontSize="12" Margin="0,0,0,8"/>
                    <TextBlock x:Name="CardScore" Text="—" Foreground="White" FontSize="28" FontWeight="Black"/>
                    <ProgressBar x:Name="PBarScore" Style="{StaticResource PBar}" Margin="0,8,0,4" Foreground="#F59E0B"/>
                    <TextBlock x:Name="CardScoreSub" Text="/ 100" Foreground="#6B7280" FontSize="10"/>
                  </StackPanel>
                </Border>
              </UniformGrid>

              <!-- Actions rapides + Conseils -->
              <Grid>
                <Grid.ColumnDefinitions>
                  <ColumnDefinition Width="*"/>
                  <ColumnDefinition Width="260"/>
                </Grid.ColumnDefinitions>

                <Border Grid.Column="0" Style="{StaticResource Card}" Margin="0,0,12,0">
                  <StackPanel>
                    <TextBlock Text="⚡  Actions rapides" Foreground="White" FontSize="15" FontWeight="Bold" Margin="0,0,0,14"/>
                    <Button x:Name="BtnQuickClean" Style="{StaticResource BtnBlue}" Content="🧹  Nettoyer les fichiers temporaires" HorizontalAlignment="Left" Margin="0,0,0,10" Height="38"/>
                    <Button x:Name="BtnQuickRecycle" Style="{StaticResource BtnGreen}" Content="♻️  Vider la corbeille" HorizontalAlignment="Left" Margin="0,0,0,10" Height="38"/>
                    <Button x:Name="BtnQuickDNS" Style="{StaticResource BtnOrange}" Content="🌐  Vider le cache DNS" HorizontalAlignment="Left" Margin="0,0,0,10" Height="38"/>
                    <Button x:Name="BtnRefresh" Style="{StaticResource BtnBlue}" Content="🔄  Actualiser les données" HorizontalAlignment="Left" Height="38"/>
                  </StackPanel>
                </Border>

                <Border Grid.Column="1" Style="{StaticResource Card}" Margin="0,0,0,0">
                  <StackPanel>
                    <TextBlock Text="💡  Conseils" Foreground="White" FontSize="15" FontWeight="Bold" Margin="0,0,0,14"/>
                    <TextBlock x:Name="TxtConseils" Text="Chargement..." Foreground="#9CA3AF" FontSize="12" TextWrapping="Wrap" LineHeight="20"/>
                  </StackPanel>
                </Border>
              </Grid>

              <!-- Log live -->
              <Border Background="#0F172A" CornerRadius="10" Padding="16" Margin="0,0,0,0">
                <StackPanel>
                  <TextBlock Text="📋  Activité récente" Foreground="White" FontSize="13" FontWeight="Bold" Margin="0,0,0,10"/>
                  <TextBlock x:Name="TxtLog" Text="Aucune action effectuée." Foreground="#4DA3FF" FontFamily="Consolas" FontSize="11" TextWrapping="Wrap" LineHeight="18"/>
                </StackPanel>
              </Border>
            </StackPanel>
          </ScrollViewer>

          <!-- PAGE INFOS -->
          <ScrollViewer x:Name="PageInfo" Visibility="Collapsed" VerticalScrollBarVisibility="Auto" Padding="24,20">
            <StackPanel>
              <TextBlock Text="💻  Informations système" Foreground="White" FontSize="22" FontWeight="Bold" Margin="0,0,0,4"/>
              <TextBlock Text="Détails complets de votre PC" Foreground="#6B7280" FontSize="13" Margin="0,0,0,20"/>

              <UniformGrid Rows="1" Columns="2">
                <Border Style="{StaticResource Card}">
                  <StackPanel>
                    <TextBlock Text="🖥️  Système" Foreground="White" FontSize="15" FontWeight="Bold" Margin="0,0,0,14"/>
                    <TextBlock x:Name="InfoOS"    Text="OS : —"       Foreground="#D1D5DB" FontSize="13" Margin="0,0,0,8"/>
                    <TextBlock x:Name="InfoBuild" Text="Build : —"    Foreground="#D1D5DB" FontSize="13" Margin="0,0,0,8"/>
                    <TextBlock x:Name="InfoUptime" Text="Uptime : —"  Foreground="#D1D5DB" FontSize="13" Margin="0,0,0,8"/>
                    <TextBlock x:Name="InfoVersion" Text="Version : —" Foreground="#D1D5DB" FontSize="13"/>
                  </StackPanel>
                </Border>
                <Border Style="{StaticResource Card}" Margin="0,0,0,12">
                  <StackPanel>
                    <TextBlock Text="⚙️  Matériel" Foreground="White" FontSize="15" FontWeight="Bold" Margin="0,0,0,14"/>
                    <TextBlock x:Name="InfoCPU"   Text="CPU : —"     Foreground="#D1D5DB" FontSize="13" Margin="0,0,0,8" TextWrapping="Wrap"/>
                    <TextBlock x:Name="InfoCores" Text="Cœurs : —"   Foreground="#D1D5DB" FontSize="13" Margin="0,0,0,8"/>
                    <TextBlock x:Name="InfoRAM"   Text="RAM : —"     Foreground="#D1D5DB" FontSize="13" Margin="0,0,0,8"/>
                    <TextBlock x:Name="InfoDisk"  Text="Disque : —"  Foreground="#D1D5DB" FontSize="13"/>
                  </StackPanel>
                </Border>
              </UniformGrid>

              <!-- Démarrage -->
              <Border Style="{StaticResource Card}" Margin="0,0,0,0">
                <StackPanel>
                  <StackPanel Orientation="Horizontal" Margin="0,0,0,12">
                    <TextBlock Text="🚀  Programmes au démarrage" Foreground="White" FontSize="15" FontWeight="Bold"/>
                    <TextBlock x:Name="StartupCount" Text="" Foreground="#4DA3FF" FontSize="13" Margin="10,0,0,0" VerticalAlignment="Center"/>
                  </StackPanel>
                  <ListBox x:Name="StartupList" Background="Transparent" BorderThickness="0" MaxHeight="200" Foreground="#D1D5DB" FontSize="12" FontFamily="Consolas"/>
                  <Button x:Name="BtnLoadStartup" Style="{StaticResource BtnBlue}" Content="📋  Charger la liste" HorizontalAlignment="Left" Height="36" Margin="0,12,0,0"/>
                </StackPanel>
              </Border>
            </StackPanel>
          </ScrollViewer>

          <!-- PAGE NETTOYAGE -->
          <ScrollViewer x:Name="PageClean" Visibility="Collapsed" VerticalScrollBarVisibility="Auto" Padding="24,20">
            <StackPanel>
              <TextBlock Text="🧹  Nettoyage" Foreground="White" FontSize="22" FontWeight="Bold" Margin="0,0,0,4"/>
              <TextBlock Text="Libérez de l'espace et améliorez les performances" Foreground="#6B7280" FontSize="13" Margin="0,0,0,20"/>

              <!-- Résultat -->
              <Border x:Name="CleanResult" Background="#052E16" BorderBrush="#14532D" BorderThickness="1" CornerRadius="10" Padding="16,12" Margin="0,0,0,16" Visibility="Collapsed">
                <TextBlock x:Name="CleanResultTxt" Text="" Foreground="#22C55E" FontSize="13" TextWrapping="Wrap"/>
              </Border>

              <UniformGrid Rows="1" Columns="2">
                <Border Style="{StaticResource Card}">
                  <StackPanel>
                    <TextBlock Text="🗑️  Fichiers temporaires" Foreground="White" FontSize="14" FontWeight="Bold" Margin="0,0,0,6"/>
                    <TextBlock Text="Supprime les fichiers inutiles dans %TEMP% et Windows\Temp. Gain typique : 200–500 Mo." Foreground="#9CA3AF" FontSize="11" TextWrapping="Wrap" Margin="0,0,0,14" LineHeight="18"/>
                    <ProgressBar x:Name="PCleanTemp" Style="{StaticResource PBar}" Visibility="Collapsed" Margin="0,0,0,10" IsIndeterminate="True"/>
                    <Button x:Name="BtnCleanTemp" Style="{StaticResource BtnBlue}" Content="🧹  Nettoyer maintenant" HorizontalAlignment="Left" Height="36"/>
                  </StackPanel>
                </Border>
                <Border Style="{StaticResource Card}" Margin="0,0,0,12">
                  <StackPanel>
                    <TextBlock Text="♻️  Corbeille" Foreground="White" FontSize="14" FontWeight="Bold" Margin="0,0,0,6"/>
                    <TextBlock Text="Vide définitivement tous les fichiers dans la corbeille de Windows." Foreground="#9CA3AF" FontSize="11" TextWrapping="Wrap" Margin="0,0,0,14" LineHeight="18"/>
                    <ProgressBar x:Name="PCleanRecy" Style="{StaticResource PBar}" Visibility="Collapsed" Margin="0,0,0,10" IsIndeterminate="True"/>
                    <Button x:Name="BtnCleanRecy" Style="{StaticResource BtnGreen}" Content="♻️  Vider la corbeille" HorizontalAlignment="Left" Height="36"/>
                  </StackPanel>
                </Border>
              </UniformGrid>

              <UniformGrid Rows="1" Columns="2">
                <Border Style="{StaticResource Card}">
                  <StackPanel>
                    <TextBlock Text="🌐  Cache DNS" Foreground="White" FontSize="14" FontWeight="Bold" Margin="0,0,0,6"/>
                    <TextBlock Text="Vide le cache DNS de Windows. Utile si des sites ne se chargent pas correctement." Foreground="#9CA3AF" FontSize="11" TextWrapping="Wrap" Margin="0,0,0,14" LineHeight="18"/>
                    <Button x:Name="BtnCleanDNS" Style="{StaticResource BtnOrange}" Content="🌐  Vider le cache DNS" HorizontalAlignment="Left" Height="36"/>
                  </StackPanel>
                </Border>
                <Border Style="{StaticResource Card}" Margin="0,0,0,0">
                  <StackPanel>
                    <TextBlock Text="⚙️  Cache Prefetch" Foreground="White" FontSize="14" FontWeight="Bold" Margin="0,0,0,6"/>
                    <TextBlock Text="Supprime les fichiers de pré-chargement Windows. Se régénère automatiquement. Gain : 50–150 Mo." Foreground="#9CA3AF" FontSize="11" TextWrapping="Wrap" Margin="0,0,0,14" LineHeight="18"/>
                    <Button x:Name="BtnCleanPrefetch" Style="{StaticResource BtnBlue}" Content="⚙️  Nettoyer Prefetch" HorizontalAlignment="Left" Height="36"/>
                  </StackPanel>
                </Border>
              </UniformGrid>
            </StackPanel>
          </ScrollViewer>

          <!-- PAGE SÉCURITÉ -->
          <ScrollViewer x:Name="PageSec" Visibility="Collapsed" VerticalScrollBarVisibility="Auto" Padding="24,20">
            <StackPanel>
              <TextBlock Text="🛡️  Sécurité" Foreground="White" FontSize="22" FontWeight="Bold" Margin="0,0,0,4"/>
              <TextBlock Text="État de la protection de votre système" Foreground="#6B7280" FontSize="13" Margin="0,0,0,20"/>

              <UniformGrid Rows="1" Columns="3" Margin="0,0,0,16">
                <Border Style="{StaticResource Card}">
                  <StackPanel>
                    <TextBlock Text="🔥  Pare-feu" Foreground="#9CA3AF" FontSize="12" Margin="0,0,0,8"/>
                    <TextBlock x:Name="SecFW" Text="—" Foreground="White" FontSize="20" FontWeight="Bold"/>
                  </StackPanel>
                </Border>
                <Border Style="{StaticResource Card}">
                  <StackPanel>
                    <TextBlock Text="🛡️  Antivirus" Foreground="#9CA3AF" FontSize="12" Margin="0,0,0,8"/>
                    <TextBlock x:Name="SecAV" Text="—" Foreground="White" FontSize="14" FontWeight="Bold" TextWrapping="Wrap"/>
                  </StackPanel>
                </Border>
                <Border Style="{StaticResource Card}" Margin="0,0,0,12">
                  <StackPanel>
                    <TextBlock Text="🔄  Windows Update" Foreground="#9CA3AF" FontSize="12" Margin="0,0,0,8"/>
                    <TextBlock x:Name="SecWU" Text="—" Foreground="White" FontSize="20" FontWeight="Bold"/>
                  </StackPanel>
                </Border>
              </UniformGrid>

              <!-- Scan Defender -->
              <Border Style="{StaticResource Card}" Margin="0,0,0,0">
                <StackPanel>
                  <TextBlock Text="🔍  Scan Windows Defender" Foreground="White" FontSize="15" FontWeight="Bold" Margin="0,0,0,10"/>
                  <TextBlock Text="Lance un scan rapide via Windows Defender pour détecter les menaces." Foreground="#9CA3AF" FontSize="12" Margin="0,0,0,14" TextWrapping="Wrap"/>
                  <StackPanel Orientation="Horizontal">
                    <Button x:Name="BtnScanDef" Style="{StaticResource BtnBlue}" Content="🔍  Lancer scan rapide" Height="38" Margin="0,0,10,0"/>
                    <Button x:Name="BtnScanFull" Style="{StaticResource BtnOrange}" Content="🔬  Scan complet" Height="38"/>
                  </StackPanel>
                  <TextBlock x:Name="ScanResult" Text="" Foreground="#22C55E" FontSize="12" Margin="0,12,0,0" TextWrapping="Wrap"/>
                </StackPanel>
              </Border>
            </StackPanel>
          </ScrollViewer>

          <!-- PAGE OUTILS -->
          <ScrollViewer x:Name="PageTools" Visibility="Collapsed" VerticalScrollBarVisibility="Auto" Padding="24,20">
            <StackPanel>
              <TextBlock Text="🛠️  Outils Windows" Foreground="White" FontSize="22" FontWeight="Bold" Margin="0,0,0,4"/>
              <TextBlock Text="Accès rapide aux outils système de Windows" Foreground="#6B7280" FontSize="13" Margin="0,0,0,20"/>

              <UniformGrid Columns="3">
                <Border Style="{StaticResource Card}">
                  <StackPanel>
                    <TextBlock Text="📊" FontSize="28" Margin="0,0,0,8"/>
                    <TextBlock Text="Gestionnaire de tâches" Foreground="White" FontSize="13" FontWeight="Bold" Margin="0,0,0,6"/>
                    <TextBlock Text="Voir les processus actifs et l'usage des ressources." Foreground="#9CA3AF" FontSize="11" TextWrapping="Wrap" Margin="0,0,0,12"/>
                    <Button Style="{StaticResource BtnBlue}" Content="Ouvrir" Height="34" HorizontalAlignment="Left" Tag="taskmgr" x:Name="BtnTaskMgr"/>
                  </StackPanel>
                </Border>
                <Border Style="{StaticResource Card}">
                  <StackPanel>
                    <TextBlock Text="💿" FontSize="28" Margin="0,0,0,8"/>
                    <TextBlock Text="Nettoyage de disque" Foreground="White" FontSize="13" FontWeight="Bold" Margin="0,0,0,6"/>
                    <TextBlock Text="Outil Windows intégré pour libérer de l'espace." Foreground="#9CA3AF" FontSize="11" TextWrapping="Wrap" Margin="0,0,0,12"/>
                    <Button Style="{StaticResource BtnBlue}" Content="Ouvrir" Height="34" HorizontalAlignment="Left" x:Name="BtnCleanMgr"/>
                  </StackPanel>
                </Border>
                <Border Style="{StaticResource Card}" Margin="0,0,0,12">
                  <StackPanel>
                    <TextBlock Text="⚙️" FontSize="28" Margin="0,0,0,8"/>
                    <TextBlock Text="Services Windows" Foreground="White" FontSize="13" FontWeight="Bold" Margin="0,0,0,6"/>
                    <TextBlock Text="Gérer les services et processus en arrière-plan." Foreground="#9CA3AF" FontSize="11" TextWrapping="Wrap" Margin="0,0,0,12"/>
                    <Button Style="{StaticResource BtnBlue}" Content="Ouvrir" Height="34" HorizontalAlignment="Left" x:Name="BtnServices"/>
                  </StackPanel>
                </Border>
                <Border Style="{StaticResource Card}">
                  <StackPanel>
                    <TextBlock Text="🔧" FontSize="28" Margin="0,0,0,8"/>
                    <TextBlock Text="Panneau de configuration" Foreground="White" FontSize="13" FontWeight="Bold" Margin="0,0,0,6"/>
                    <TextBlock Text="Accès aux paramètres système classiques." Foreground="#9CA3AF" FontSize="11" TextWrapping="Wrap" Margin="0,0,0,12"/>
                    <Button Style="{StaticResource BtnBlue}" Content="Ouvrir" Height="34" HorizontalAlignment="Left" x:Name="BtnControl"/>
                  </StackPanel>
                </Border>
                <Border Style="{StaticResource Card}">
                  <StackPanel>
                    <TextBlock Text="🛡️" FontSize="28" Margin="0,0,0,8"/>
                    <TextBlock Text="Sécurité Windows" Foreground="White" FontSize="13" FontWeight="Bold" Margin="0,0,0,6"/>
                    <TextBlock Text="Centre de sécurité Windows Defender." Foreground="#9CA3AF" FontSize="11" TextWrapping="Wrap" Margin="0,0,0,12"/>
                    <Button Style="{StaticResource BtnBlue}" Content="Ouvrir" Height="34" HorizontalAlignment="Left" x:Name="BtnDefenderUI"/>
                  </StackPanel>
                </Border>
                <Border Style="{StaticResource Card}" Margin="0,0,0,12">
                  <StackPanel>
                    <TextBlock Text="📋" FontSize="28" Margin="0,0,0,8"/>
                    <TextBlock Text="Observateur d'événements" Foreground="White" FontSize="13" FontWeight="Bold" Margin="0,0,0,6"/>
                    <TextBlock Text="Journaux d'événements et erreurs Windows." Foreground="#9CA3AF" FontSize="11" TextWrapping="Wrap" Margin="0,0,0,12"/>
                    <Button Style="{StaticResource BtnBlue}" Content="Ouvrir" Height="34" HorizontalAlignment="Left" x:Name="BtnEventLog"/>
                  </StackPanel>
                </Border>
              </UniformGrid>
            </StackPanel>
          </ScrollViewer>

          <!-- PAGE À PROPOS -->
          <ScrollViewer x:Name="PageAbout" Visibility="Collapsed" VerticalScrollBarVisibility="Auto" Padding="24,20">
            <StackPanel>
              <TextBlock Text="❓  À propos" Foreground="White" FontSize="22" FontWeight="Bold" Margin="0,0,0,4"/>
              <TextBlock Text="OptimSystem Pro — Outil d'analyse et d'optimisation Windows" Foreground="#6B7280" FontSize="13" Margin="0,0,0,20"/>
              <Border Style="{StaticResource Card}" Margin="0,0,0,0">
                <StackPanel>
                  <TextBlock Text="⚡  OptimSystem Pro" Foreground="White" FontSize="18" FontWeight="Black" Margin="0,0,0,6"/>
                  <TextBlock Text="Version 2.0 — Réécrit et amélioré" Foreground="#4DA3FF" FontSize="13" Margin="0,0,0,16"/>
                  <TextBlock Text="Développé par Sluumy" Foreground="#D1D5DB" FontSize="13" Margin="0,0,0,8"/>
                  <TextBlock Text="Licence MIT — Utilisation libre et gratuite" Foreground="#D1D5DB" FontSize="13" Margin="0,0,0,16"/>
                  <TextBlock Text="Fonctionnalités :" Foreground="White" FontSize="14" FontWeight="Bold" Margin="0,0,0,8"/>
                  <TextBlock Foreground="#9CA3AF" FontSize="12" LineHeight="20" TextWrapping="Wrap">
• Surveillance CPU, RAM, stockage en temps réel
• Nettoyage fichiers temporaires, corbeille, cache DNS, Prefetch
• Analyse de sécurité (pare-feu, antivirus, Windows Update)
• Accès rapide aux outils Windows intégrés
• Logs automatiques dans ProgramData\OptimSystem\Logs
• Interface moderne WPF — thème sombre Windows 11
                  </TextBlock>
                  <TextBlock Text="⚠️  Ce logiciel ne modifie aucun fichier système critique." Foreground="#F59E0B" FontSize="12" Margin="0,16,0,0" TextWrapping="Wrap"/>
                </StackPanel>
              </Border>
            </StackPanel>
          </ScrollViewer>

        </Grid>
      </Grid>
    </Grid>
  </Border>
</Window>
"@

# ================================================
# CHARGEMENT FENÊTRE
# ================================================
$reader = [System.Xml.XmlNodeReader]::new($XAML)
try {
    $window = [System.Windows.Markup.XamlReader]::Load($reader)
} catch {
    [System.Windows.MessageBox]::Show("Erreur chargement XAML:`n$_", "Erreur critique")
    exit
}

# --- Récupération des contrôles ---
function Ctrl($n) { $window.FindName($n) }

$TitleBar   = Ctrl "TitleBar"
$BtnMin     = Ctrl "BtnMin"
$BtnClose   = Ctrl "BtnClose"
$AdminBadge = Ctrl "AdminBadge"

$NavDash    = Ctrl "NavDash"
$NavInfo    = Ctrl "NavInfo"
$NavClean   = Ctrl "NavClean"
$NavSec     = Ctrl "NavSec"
$NavTools   = Ctrl "NavTools"
$NavAbout   = Ctrl "NavAbout"

$PageDash   = Ctrl "PageDash"
$PageInfo   = Ctrl "PageInfo"
$PageClean  = Ctrl "PageClean"
$PageSec    = Ctrl "PageSec"
$PageTools  = Ctrl "PageTools"
$PageAbout  = Ctrl "PageAbout"

$DotFW      = Ctrl "DotFW"
$DotAV      = Ctrl "DotAV"
$DotAdmin   = Ctrl "DotAdmin"

# Dashboard
$CardCPU    = Ctrl "CardCPU";    $PBarCPU   = Ctrl "PBarCPU";   $CardCPUName = Ctrl "CardCPUName"
$CardRAM    = Ctrl "CardRAM";    $PBarRAM   = Ctrl "PBarRAM";   $CardRAMSub  = Ctrl "CardRAMSub"
$CardDisk   = Ctrl "CardDisk";   $PBarDisk  = Ctrl "PBarDisk";  $CardDiskSub = Ctrl "CardDiskSub"
$CardScore  = Ctrl "CardScore";  $PBarScore = Ctrl "PBarScore"; $CardScoreSub= Ctrl "CardScoreSub"
$TxtConseils= Ctrl "TxtConseils"
$TxtLog     = Ctrl "TxtLog"
$BtnRefresh = Ctrl "BtnRefresh"
$BtnQuickClean  = Ctrl "BtnQuickClean"
$BtnQuickRecycle= Ctrl "BtnQuickRecycle"
$BtnQuickDNS    = Ctrl "BtnQuickDNS"

# Infos
$InfoOS     = Ctrl "InfoOS";    $InfoBuild  = Ctrl "InfoBuild"
$InfoUptime = Ctrl "InfoUptime"; $InfoVersion= Ctrl "InfoVersion"
$InfoCPU    = Ctrl "InfoCPU";   $InfoCores  = Ctrl "InfoCores"
$InfoRAM    = Ctrl "InfoRAM";   $InfoDisk   = Ctrl "InfoDisk"
$StartupList= Ctrl "StartupList"; $StartupCount= Ctrl "StartupCount"
$BtnLoadStartup= Ctrl "BtnLoadStartup"

# Clean
$CleanResult    = Ctrl "CleanResult";  $CleanResultTxt = Ctrl "CleanResultTxt"
$BtnCleanTemp   = Ctrl "BtnCleanTemp"; $PCleanTemp     = Ctrl "PCleanTemp"
$BtnCleanRecy   = Ctrl "BtnCleanRecy"; $PCleanRecy     = Ctrl "PCleanRecy"
$BtnCleanDNS    = Ctrl "BtnCleanDNS"
$BtnCleanPrefetch= Ctrl "BtnCleanPrefetch"

# Sécurité
$SecFW      = Ctrl "SecFW";   $SecAV     = Ctrl "SecAV";   $SecWU = Ctrl "SecWU"
$BtnScanDef = Ctrl "BtnScanDef"; $BtnScanFull= Ctrl "BtnScanFull"
$ScanResult = Ctrl "ScanResult"

# Outils
$BtnTaskMgr  = Ctrl "BtnTaskMgr"
$BtnCleanMgr = Ctrl "BtnCleanMgr"
$BtnServices = Ctrl "BtnServices"
$BtnControl  = Ctrl "BtnControl"
$BtnDefenderUI= Ctrl "BtnDefenderUI"
$BtnEventLog = Ctrl "BtnEventLog"

# ================================================
# HELPERS
# ================================================
$logLines = [System.Collections.Generic.List[string]]::new()

function AddLog($msg) {
    $window.Dispatcher.Invoke([action]{
        $line = "[$(Get-Date -Format 'HH:mm:ss')]  $msg"
        $script:logLines.Insert(0, $line)
        if ($script:logLines.Count -gt 12) { $script:logLines.RemoveAt($script:logLines.Count-1) }
        $TxtLog.Text = $script:logLines -join "`n"
    })
    Write-Log $msg
}

function UI([scriptblock]$a) { $window.Dispatcher.Invoke($a) }

function ShowOnly($page) {
    foreach ($p in @($PageDash,$PageInfo,$PageClean,$PageSec,$PageTools,$PageAbout)) {
        $p.Visibility = "Collapsed"
    }
    $page.Visibility = "Visible"
}

function ShowCleanResult($msg, $ok=$true) {
    UI {
        $CleanResultTxt.Text  = $msg
        $CleanResultTxt.Foreground = if($ok){"#22C55E"} else {"#EF4444"}
        $CleanResult.Visibility = "Visible"
    }
}

# ================================================
# INITIALISATION DES DONNÉES
# ================================================
function Load-Dashboard {
    $cpu  = Get-CPUUsage
    $ram  = Get-RAMInfo
    $disk = Get-DiskInfo
    $score= Get-PerformanceScore
    $os   = Get-OSInfo

    UI {
        $CardCPU.Text    = "$cpu %"
        $PBarCPU.Value   = $cpu
        $CardCPUName.Text= if($os){ ($os.CPU -replace '\s+',' ').Substring(0,[math]::Min(40,$os.CPU.Length)) } else { "CPU" }

        $CardRAM.Text    = "$($ram.Pct) %"
        $PBarRAM.Value   = $ram.Pct
        $CardRAMSub.Text = "$($ram.Used) Go / $($ram.Total) Go utilisés"

        $CardDisk.Text   = "$($disk.Free) Go"
        $PBarDisk.Value  = $disk.Pct
        $CardDiskSub.Text= "Libres sur $($disk.Total) Go (C:)"

        $CardScore.Text  = "$score"
        $PBarScore.Value = $score
        $CardScoreSub.Text = if($score -ge 80){"Excellent !"} elseif($score -ge 60){"Correct"} else {"À optimiser"}

        # Conseils
        $tips = @()
        if($cpu -gt 80) { $tips += "⚠️ CPU très chargé ($cpu%). Fermez des applications." }
        if($ram.Pct -gt 85) { $tips += "⚠️ RAM presque pleine ($($ram.Pct)%). Pensez à redémarrer." }
        if($disk.Free -lt 10) { $tips += "⚠️ Peu d'espace disque ($($disk.Free) Go). Nettoyez les fichiers temporaires." }
        if($tips.Count -eq 0) { $tips += "✅ Votre système est en bonne santé." }
        $tips += "💡 Exécutez un nettoyage régulier pour maintenir les performances."
        $TxtConseils.Text = $tips -join "`n`n"
    }
}

function Load-Security {
    $sec = Get-SecurityStatus
    UI {
        $SecFW.Text = if($sec.Firewall){"✅ Activé"} else {"❌ Désactivé"}
        $SecFW.Foreground = if($sec.Firewall){"#22C55E"} else {"#EF4444"}
        $SecAV.Text = if($sec.Antivirus -ne "Inconnu"){$sec.Antivirus} else {"❌ Non détecté"}
        $SecAV.Foreground = if($sec.Antivirus -ne "Inconnu"){"#22C55E"} else {"#F59E0B"}
        $SecWU.Text = $sec.WindowsUpdate
        $SecWU.Foreground = if($sec.WindowsUpdate -eq "Actif"){"#22C55E"} else {"#F59E0B"}

        $DotFW.Fill    = if($sec.Firewall){"#22C55E"} else {"#EF4444"}
        $DotAV.Fill    = if($sec.Antivirus -ne "Inconnu"){"#22C55E"} else {"#F59E0B"}
        $DotAdmin.Fill = if($script:isAdmin){"#22C55E"} else {"#EF4444"}
    }
}

function Load-Infos {
    $os  = Get-OSInfo
    $ram = Get-RAMInfo
    $disk= Get-DiskInfo
    UI {
        if($os) {
            $InfoOS.Text      = "Système : $($os.OS)"
            $InfoBuild.Text   = "Build : $($os.Build)"
            $InfoVersion.Text = "Version : $($os.Version)"
            $upStr = "$([math]::Floor($os.Uptime.TotalDays))j $($os.Uptime.Hours)h $($os.Uptime.Minutes)m"
            $InfoUptime.Text  = "Uptime : $upStr"
            $InfoCPU.Text     = "Processeur : $($os.CPU)"
            $InfoCores.Text   = "Cœurs : $($os.CPUCores)"
        }
        $InfoRAM.Text  = "RAM : $($ram.Used) Go utilisés / $($ram.Total) Go total ($($ram.Pct)%)"
        $InfoDisk.Text = "Disque C: : $($disk.Free) Go libres / $($disk.Total) Go ($($disk.Pct)% utilisé)"
    }
}

# ================================================
# NAVIGATION
# ================================================
$NavDash.Add_Checked({ ShowOnly $PageDash; Load-Dashboard })
$NavInfo.Add_Checked({ ShowOnly $PageInfo; Load-Infos })
$NavClean.Add_Checked({ ShowOnly $PageClean; $CleanResult.Visibility="Collapsed" })
$NavSec.Add_Checked({ ShowOnly $PageSec; Load-Security })
$NavTools.Add_Checked({ ShowOnly $PageTools })
$NavAbout.Add_Checked({ ShowOnly $PageAbout })

# ================================================
# TITLEBAR
# ================================================
$TitleBar.Add_MouseLeftButtonDown({
    if ([System.Windows.Input.Mouse]::LeftButton -eq 'Pressed') { $window.DragMove() }
})
$BtnMin.Add_Click({ $window.WindowState = 'Minimized' })
$BtnClose.Add_Click({ $window.Close() })

if ($isAdmin) {
    $AdminBadge.Text = "✅ Mode Administrateur"
} else {
    $AdminBadge.Text = "⚠️ Sans droits admin — certaines fonctions limitées"
}

# ================================================
# ACTIONS DASHBOARD
# ================================================
$BtnRefresh.Add_Click({
    $BtnRefresh.IsEnabled = $false
    [System.Threading.Tasks.Task]::Run([action]{
        Load-Dashboard
        AddLog "Données actualisées."
        UI { $BtnRefresh.IsEnabled = $true }
    }) | Out-Null
})

$BtnQuickClean.Add_Click({
    $BtnQuickClean.IsEnabled = $false
    [System.Threading.Tasks.Task]::Run([action]{
        AddLog "Nettoyage des fichiers temporaires..."
        $r = Clear-TempFiles
        AddLog "✅ Nettoyage terminé : $($r.Files) fichiers, $($r.MB) Mo libérés."
        UI { $BtnQuickClean.IsEnabled = $true }
    }) | Out-Null
})

$BtnQuickRecycle.Add_Click({
    $BtnQuickRecycle.IsEnabled = $false
    [System.Threading.Tasks.Task]::Run([action]{
        AddLog "Vidage de la corbeille..."
        Clear-RecycleBinSafe | Out-Null
        AddLog "✅ Corbeille vidée."
        UI { $BtnQuickRecycle.IsEnabled = $true }
    }) | Out-Null
})

$BtnQuickDNS.Add_Click({
    $BtnQuickDNS.IsEnabled = $false
    [System.Threading.Tasks.Task]::Run([action]{
        AddLog "Vidage du cache DNS..."
        Flush-DNS | Out-Null
        AddLog "✅ Cache DNS vidé."
        UI { $BtnQuickDNS.IsEnabled = $true }
    }) | Out-Null
})

# ================================================
# ACTIONS INFOS
# ================================================
$BtnLoadStartup.Add_Click({
    $BtnLoadStartup.IsEnabled = $false
    [System.Threading.Tasks.Task]::Run([action]{
        $apps = Get-StartupApps
        UI {
            $StartupList.Items.Clear()
            foreach($a in $apps) { $StartupList.Items.Add("[$($a.User)]  $($a.Name)  →  $($a.Command)") }
            $StartupCount.Text = "($($apps.Count) entrées)"
            $BtnLoadStartup.IsEnabled = $true
        }
        AddLog "Démarrage : $($apps.Count) programme(s) chargés."
    }) | Out-Null
})

# ================================================
# ACTIONS NETTOYAGE
# ================================================
$BtnCleanTemp.Add_Click({
    $BtnCleanTemp.IsEnabled = $false
    $PCleanTemp.Visibility = "Visible"
    [System.Threading.Tasks.Task]::Run([action]{
        AddLog "Nettoyage fichiers temporaires..."
        $r = Clear-TempFiles
        $msg = "✅ Nettoyage terminé : $($r.Files) fichiers supprimés, $($r.MB) Mo libérés."
        ShowCleanResult $msg
        AddLog $msg
        UI { $PCleanTemp.Visibility="Collapsed"; $BtnCleanTemp.IsEnabled=$true }
    }) | Out-Null
})

$BtnCleanRecy.Add_Click({
    $BtnCleanRecy.IsEnabled = $false
    [System.Threading.Tasks.Task]::Run([action]{
        AddLog "Vidage corbeille..."
        $r = Clear-RecycleBinSafe
        ShowCleanResult "✅ Corbeille vidée avec succès."
        AddLog "✅ Corbeille vidée."
        UI { $BtnCleanRecy.IsEnabled=$true }
    }) | Out-Null
})

$BtnCleanDNS.Add_Click({
    $BtnCleanDNS.IsEnabled = $false
    [System.Threading.Tasks.Task]::Run([action]{
        AddLog "Vidage cache DNS..."
        Flush-DNS | Out-Null
        ShowCleanResult "✅ Cache DNS vidé avec succès."
        AddLog "✅ DNS vidé."
        UI { $BtnCleanDNS.IsEnabled=$true }
    }) | Out-Null
})

$BtnCleanPrefetch.Add_Click({
    $BtnCleanPrefetch.IsEnabled = $false
    [System.Threading.Tasks.Task]::Run([action]{
        AddLog "Nettoyage Prefetch..."
        $before = (Get-ChildItem "C:\Windows\Prefetch" -ErrorAction SilentlyContinue | Measure-Object -Property Length -Sum).Sum
        Get-ChildItem "C:\Windows\Prefetch" -Force -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue
        $freed = [math]::Round($before/1MB,2)
        ShowCleanResult "✅ Prefetch nettoyé : ~$freed Mo libérés."
        AddLog "✅ Prefetch nettoyé ($freed Mo)."
        UI { $BtnCleanPrefetch.IsEnabled=$true }
    }) | Out-Null
})

# ================================================
# ACTIONS SÉCURITÉ
# ================================================
$BtnScanDef.Add_Click({
    if (-not $isAdmin) { $ScanResult.Text = "❌ Droits admin requis pour lancer Defender."; $ScanResult.Foreground="#EF4444"; return }
    $BtnScanDef.IsEnabled=$false; $BtnScanFull.IsEnabled=$false
    [System.Threading.Tasks.Task]::Run([action]{
        UI { $ScanResult.Text="⏳ Scan rapide en cours..."; $ScanResult.Foreground="#F59E0B" }
        AddLog "Lancement scan Defender rapide..."
        try {
            Start-MpScan -ScanType QuickScan -ErrorAction Stop
            $threats = Get-MpThreatDetection -ErrorAction SilentlyContinue
            if($threats) {
                UI { $ScanResult.Text="⚠️ $($threats.Count) menace(s) détectée(s) ! Ouvrez Windows Security pour agir."; $ScanResult.Foreground="#EF4444" }
                AddLog "⚠️ $($threats.Count) menace(s) détectée(s)."
            } else {
                UI { $ScanResult.Text="✅ Scan terminé — Aucune menace détectée."; $ScanResult.Foreground="#22C55E" }
                AddLog "✅ Scan Defender : aucune menace."
            }
        } catch { UI { $ScanResult.Text="❌ Erreur Defender : $($_.Exception.Message)"; $ScanResult.Foreground="#EF4444" } }
        UI { $BtnScanDef.IsEnabled=$true; $BtnScanFull.IsEnabled=$true }
    }) | Out-Null
})

$BtnScanFull.Add_Click({
    if (-not $isAdmin) { $ScanResult.Text = "❌ Droits admin requis."; $ScanResult.Foreground="#EF4444"; return }
    $r = [System.Windows.MessageBox]::Show("Le scan complet peut prendre 15–30 minutes.`nContinuer ?","Scan complet","YesNo","Question")
    if($r -ne "Yes") { return }
    $BtnScanDef.IsEnabled=$false; $BtnScanFull.IsEnabled=$false
    [System.Threading.Tasks.Task]::Run([action]{
        UI { $ScanResult.Text="⏳ Scan complet en cours (peut prendre 15-30 min)..."; $ScanResult.Foreground="#F59E0B" }
        AddLog "Lancement scan Defender complet..."
        try {
            Start-MpScan -ScanType FullScan -ErrorAction Stop
            UI { $ScanResult.Text="✅ Scan complet terminé."; $ScanResult.Foreground="#22C55E" }
            AddLog "✅ Scan complet Defender terminé."
        } catch { UI { $ScanResult.Text="❌ Erreur : $($_.Exception.Message)"; $ScanResult.Foreground="#EF4444" } }
        UI { $BtnScanDef.IsEnabled=$true; $BtnScanFull.IsEnabled=$true }
    }) | Out-Null
})

# ================================================
# ACTIONS OUTILS
# ================================================
$BtnTaskMgr.Add_Click({ Start-Process "taskmgr" -ErrorAction SilentlyContinue; AddLog "Gestionnaire de tâches ouvert." })
$BtnCleanMgr.Add_Click({ Start-Process "cleanmgr" -ErrorAction SilentlyContinue; AddLog "Nettoyage de disque ouvert." })
$BtnServices.Add_Click({ Start-Process "services.msc" -ErrorAction SilentlyContinue; AddLog "Services Windows ouverts." })
$BtnControl.Add_Click({ Start-Process "control" -ErrorAction SilentlyContinue; AddLog "Panneau de configuration ouvert." })
$BtnDefenderUI.Add_Click({ Start-Process "windowsdefender:" -ErrorAction SilentlyContinue; AddLog "Sécurité Windows ouverte." })
$BtnEventLog.Add_Click({ Start-Process "eventvwr.msc" -ErrorAction SilentlyContinue; AddLog "Observateur d'événements ouvert." })

# ================================================
# DÉMARRAGE — Chargement initial async
# ================================================
$window.Add_Loaded({
    [System.Threading.Tasks.Task]::Run([action]{
        Load-Dashboard
        Load-Security
        AddLog "OptimSystem Pro v2.0 démarré."
        AddLog "Admin : $($script:isAdmin)"
    }) | Out-Null
})

Write-Log "Interface chargée."
$window.ShowDialog() | Out-Null
Write-Log "Fermeture."
