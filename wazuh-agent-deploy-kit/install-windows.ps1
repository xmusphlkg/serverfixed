<#
Wazuh Agent Windows installer for lab deployment.
Usage as Administrator PowerShell:
  powershell -ExecutionPolicy Bypass -File .\install-windows.ps1 -Server 192.168.10.102
Optional:
  -AgentName $env:COMPUTERNAME -Group default -TimeZone "China Standard Time" -Version "4.14.5" -TestFim $true
#>

[CmdletBinding()]
param(
  [Parameter(Mandatory=$false)] [string] $Server = $env:SERVER,
  [Parameter(Mandatory=$false)] [string] $AgentName = $(hostname),
  [Parameter(Mandatory=$false)] [string] $Group = $(if ($env:GROUP) { $env:GROUP } else { "default" }),
  [Parameter(Mandatory=$false)] [string] $TimeZone = $(if ($env:TIMEZONE) { $env:TIMEZONE } else { "China Standard Time" }),
  [Parameter(Mandatory=$false)] [string] $Version = $(if ($env:WAZUH_VERSION) { $env:WAZUH_VERSION } else { "4.14.5" }),
  [Parameter(Mandatory=$false)] [bool] $TestFim = $true
)

$ErrorActionPreference = "Stop"

function Write-Section($Text) {
  Write-Host ""
  Write-Host "========== $Text =========="
}

function Test-Admin {
  $id = [Security.Principal.WindowsIdentity]::GetCurrent()
  $principal = New-Object Security.Principal.WindowsPrincipal($id)
  return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

if (-not $Server) { throw "Server is required. Example: powershell -ExecutionPolicy Bypass -File .\install-windows.ps1 -Server 192.168.10.102" }
if (-not (Test-Admin)) { throw "Please run PowerShell as Administrator." }

$ReportDir = "C:\Windows\Temp\wazuh-agent-install-report"
New-Item -ItemType Directory -Force -Path $ReportDir | Out-Null
$LogFile = Join-Path $ReportDir ("install-{0}.log" -f (Get-Date -Format "yyyy-MM-dd_HHmmss"))
Start-Transcript -Path $LogFile -Append | Out-Null

try {
  Write-Section "Basic information"
  Write-Host "Computer      : $env:COMPUTERNAME"
  Write-Host "AgentName     : $AgentName"
  Write-Host "Group         : $Group"
  Write-Host "Server        : $Server"
  Write-Host "TimeZone      : $TimeZone"
  Write-Host "Version       : $Version"
  Write-Host "ReportDir     : $ReportDir"

  Write-Section "Set timezone"
  try { Set-TimeZone -Id $TimeZone } catch { Write-Warning "Set-TimeZone failed: $($_.Exception.Message)" }
  try { w32tm /resync | Out-Host } catch { Write-Warning "w32tm resync failed: $($_.Exception.Message)" }
  Get-TimeZone | Format-List | Out-Host
  Get-Date | Out-Host

  Write-Section "Network test to Wazuh manager"
  foreach ($Port in @(1514,1515)) {
    try {
      $Result = Test-NetConnection -ComputerName $Server -Port $Port -WarningAction SilentlyContinue
      if ($Result.TcpTestSucceeded) { Write-Host "[OK] $Server`:$Port reachable" }
      else { Write-Warning "$Server`:$Port not reachable. Check firewall/routing/VLAN/Headscale/Tailscale." }
    } catch { Write-Warning "Test-NetConnection $Server`:$Port failed: $($_.Exception.Message)" }
  }

  Write-Section "Install or reconfigure Wazuh agent"
  $InstallDirX86 = "C:\Program Files (x86)\ossec-agent"
  $InstallDir64 = "C:\Program Files\ossec-agent"
  $OssecDir = if (Test-Path $InstallDirX86) { $InstallDirX86 } elseif (Test-Path $InstallDir64) { $InstallDir64 } else { $InstallDirX86 }

  if (-not (Get-Service -Name WazuhSvc -ErrorAction SilentlyContinue)) {
    $MsiName = "wazuh-agent-$Version-1.msi"
    $MsiPath = Join-Path $env:TEMP $MsiName
    $MsiUrl = "https://packages.wazuh.com/4.x/windows/$MsiName"
    Write-Host "Downloading: $MsiUrl"
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    Invoke-WebRequest -Uri $MsiUrl -OutFile $MsiPath

    $Args = @(
      "/i", "`"$MsiPath`"",
      "/q",
      "WAZUH_MANAGER=`"$Server`"",
      "WAZUH_PROTOCOL=`"tcp`"",
      "WAZUH_AGENT_NAME=`"$AgentName`"",
      "WAZUH_AGENT_GROUP=`"$Group`""
    )
    Write-Host "Running msiexec $($Args -join ' ')"
    $Proc = Start-Process -FilePath msiexec.exe -ArgumentList $Args -Wait -PassThru
    Write-Host "msiexec exit code: $($Proc.ExitCode)"
    if ($Proc.ExitCode -ne 0 -and $Proc.ExitCode -ne 3010) { throw "msiexec failed with exit code $($Proc.ExitCode)" }
  } else {
    Write-Host "WazuhSvc already exists; skip MSI install and reconfigure ossec.conf."
  }

  if (Test-Path $InstallDirX86) { $OssecDir = $InstallDirX86 } elseif (Test-Path $InstallDir64) { $OssecDir = $InstallDir64 } else { throw "Cannot find ossec-agent install directory." }
  $Conf = Join-Path $OssecDir "ossec.conf"
  if (-not (Test-Path $Conf)) { throw "Cannot find $Conf" }

  Write-Section "Configure ossec.conf"
  $Backup = "$Conf.bak.$(Get-Date -Format 'yyyyMMdd_HHmmss')"
  Copy-Item $Conf $Backup -Force
  $Text = Get-Content -Path $Conf -Raw
  $Text = [Regex]::Replace($Text, '<address>.*?</address>', "<address>$Server</address>", 'Singleline')
  $Text = [Regex]::Replace($Text, '<protocol>.*?</protocol>', "<protocol>tcp</protocol>", 'Singleline')

  $FimBlock = @"
    <!-- Lab critical security monitoring: installed by install-windows.ps1 -->
    <directories check_all="yes" realtime="yes">C:\ProgramData\ssh</directories>
    <directories check_all="yes" realtime="yes">C:\Windows\System32\drivers\etc</directories>
    <directories check_all="yes" realtime="yes">C:\Windows\System32\Tasks</directories>
    <directories check_all="yes" realtime="yes">C:\ProgramData\Microsoft\Windows\Start Menu\Programs\Startup</directories>
"@

  $UserDirs = Get-ChildItem -Path "C:\Users" -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -notin @('All Users','Default','Default User','Public') }
  foreach ($U in $UserDirs) {
    $SshDir = Join-Path $U.FullName ".ssh"
    $StartupDir = Join-Path $U.FullName "AppData\Roaming\Microsoft\Windows\Start Menu\Programs\Startup"
    if (Test-Path $SshDir) { $FimBlock += "    <directories check_all=`"yes`" realtime=`"yes`">$SshDir</directories>`r`n" }
    if (Test-Path $StartupDir) { $FimBlock += "    <directories check_all=`"yes`" realtime=`"yes`">$StartupDir</directories>`r`n" }
  }

  if ($Text -notmatch 'Lab critical security monitoring') {
    if ($Text -match '</syscheck>') {
      $Text = $Text -replace '</syscheck>', ($FimBlock + "  </syscheck>")
    } else {
      $SyscheckBlock = @"
  <syscheck>
    <disabled>no</disabled>
    <frequency>43200</frequency>
    <scan_on_start>yes</scan_on_start>
$FimBlock
  </syscheck>
"@
      $Text = $Text -replace '</ossec_config>', ($SyscheckBlock + "`r`n</ossec_config>")
    }
  }

  foreach ($Channel in @('Application','Security','System')) {
    if ($Text -notmatch "<location>$Channel</location>") {
      $Block = @"
  <localfile>
    <location>$Channel</location>
    <log_format>eventchannel</log_format>
  </localfile>
"@
      $Text = $Text -replace '</ossec_config>', ($Block + "`r`n</ossec_config>")
    }
  }

  Set-Content -Path $Conf -Value $Text -Encoding ASCII

  Write-Section "Start service"
  Start-Service WazuhSvc -ErrorAction SilentlyContinue
  Restart-Service WazuhSvc -Force
  Start-Sleep -Seconds 8

  Write-Section "Service and process status"
  Get-Service WazuhSvc | Format-List * | Out-Host
  Get-Process | Where-Object { $_.ProcessName -like '*wazuh*' -or $_.ProcessName -like '*ossec*' -or ($_.Path -and $_.Path -like '*ossec-agent*') } |
    Select-Object Id, ProcessName, CPU, WorkingSet64, Path | Format-Table -AutoSize | Out-Host

  Write-Section "Recent agent log"
  $AgentLog = Join-Path $OssecDir "ossec.log"
  if (Test-Path $AgentLog) {
    Get-Content $AgentLog -Tail 160 | Select-String -Pattern 'connected|manager|enroll|registration|auth|syscheck|fim|logcollector|error|warning|started|real time monitoring' | Out-Host
  }

  if ($TestFim) {
    Write-Section "FIM local test"
    New-Item -ItemType Directory -Force -Path "C:\ProgramData\ssh" | Out-Null
    $TestFile = "C:\ProgramData\ssh\wazuh_fim_test_$([int][double]::Parse((Get-Date -UFormat %s))).txt"
    "wazuh fim create test $(Get-Date)" | Set-Content $TestFile
    Start-Sleep -Seconds 3
    "wazuh fim modify test $(Get-Date)" | Add-Content $TestFile
    Start-Sleep -Seconds 3
    Remove-Item $TestFile -Force
    Write-Host "[OK] Created, modified, and deleted $TestFile. Check Wazuh server alerts.log or Dashboard for syscheck events."
  }

  Write-Section "Configuration summary"
  Select-String -Path $Conf -Pattern '<client>|<address>|<protocol>|Lab critical security monitoring|C:\\ProgramData\\ssh|eventchannel|Security' -Context 2,8 | Out-Host

  Write-Section "Final result"
  Write-Host "[OK] Windows Wazuh agent install/config completed."
  Write-Host "On Wazuh server, run: sudo /var/ossec/bin/agent_control -l"
}
finally {
  Stop-Transcript | Out-Null
  Write-Host "Report log: $LogFile"
}
