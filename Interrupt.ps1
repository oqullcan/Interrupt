#region Administrative Validation
if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    try {
        $restartParams = @{
            FilePath     = 'powershell.exe'
            ArgumentList = "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`""
            Verb         = 'RunAs'
            PassThru     = $true
            ErrorAction  = 'Stop'
        }
        $adminProcess = Start-Process @restartParams
        exit $adminProcess.ExitCode
    }
    catch {
        Write-Error "❌ Elevation Failed: $($_.Exception.Message)" -ErrorAction Stop
    }
}
#endregion

#region System Configuration Analysis
$processorInfo = Get-CimInstance Win32_Processor -ErrorAction Stop | Select-Object NumberOfCores, NumberOfLogicalProcessors
$coresAmount = [int]$processorInfo.NumberOfCores
$threadsAmount = [int]$processorInfo.NumberOfLogicalProcessors
$hyperThreadingStatus = if ($threadsAmount -gt $coresAmount) { 'Enabled' } else { 'Disabled' }

function Confirm-SystemRequirements {
    [CmdletBinding()]
    param()
    
    if ($coresAmount -lt 4) {
        $errorMessage = @"
❌ System Requirements Not Met
Minimum Required Cores: 4
Detected Cores: $coresAmount
Please upgrade your hardware
"@
        Write-Error $errorMessage -ErrorAction Stop
    }
}

Confirm-SystemRequirements

$systemDiagnostics = @"
🚀 System Configuration Analysis
• Physical Cores: $coresAmount
• Logical Cores: $threadsAmount
• Hyper-Threading: $hyperThreadingStatus

"@
Write-Host $systemDiagnostics -ForegroundColor Cyan
#endregion

#region Device Configuration Engine
function Set-DeviceInterruptPolicy {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$DeviceClass,
        
        [scriptblock]$CustomConfiguration = {}
    )

    $deviceParams = @{
        Class        = $DeviceClass
        ErrorAction  = 'Stop'
    }

    Get-CimInstance @deviceParams | Where-Object { 
        $_.PNPDeviceID -match 'PCI\\VEN' 
    } | ForEach-Object {
        $registryBase = "HKLM:\SYSTEM\CurrentControlSet\Enum\$($_.PNPDeviceID)\Device Parameters"
        $affinityPath = "$registryBase\Interrupt Management\Affinity Policy"
        $msiPath = "$registryBase\Interrupt Management\MessageSignaledInterruptProperties"

        # Reset existing affinity configurations
        Remove-ItemProperty -Path $affinityPath -Name 'AssignmentSetOverride', 'DevicePolicy', 'DevicePriority' -Force -ErrorAction SilentlyContinue
        
        # Enable MSI by default if supported
        if (Test-Path $msiPath) {
            Set-ItemProperty -Path $msiPath -Name "MSISupported" -Value 1 -Force -ErrorAction Stop
        }

        # Apply device-specific customization
        if ($CustomConfiguration) {
            . $CustomConfiguration
        }
    }
}

# Configure core device classes
$coreDevices = 'Win32_VideoController', 'Win32_USBController', 'Win32_IDEController', 'Win32_SoundDevice'
$coreDevices | ForEach-Object { Set-DeviceInterruptPolicy -DeviceClass $_ }

# Enhanced network adapter configuration
Set-DeviceInterruptPolicy -DeviceClass Win32_NetworkAdapter -CustomConfiguration {
    if (Test-Path $msiPath) {
        Set-ItemProperty -Path $msiPath -Name "MessageNumberLimit" -Value 256 -Force -ErrorAction Stop
    }
}
#endregion

#region Device Topology Mapping
function Get-DeviceTopology {
    [CmdletBinding()]
    param()

    $deviceClasses = 'Mouse', 'Display', 'Net'
    $pnpConfig = @{
        PresentOnly = $true
        Class       = $deviceClasses
        Status      = 'OK'
        ErrorAction = 'Stop'
    }

    Get-PnpDevice @pnpConfig | Sort-Object Class | ForEach-Object {
        $deviceProps = Get-PnpDeviceProperty -InstanceId $_.InstanceId -ErrorAction Stop
        $parentData = $deviceProps | Where-Object KeyName -eq 'DEVPKEY_Device_Parent'

        [PSCustomObject]@{
            Class         = $_.Class
            Name          = $_.FriendlyName
            InstanceId    = $_.InstanceId
            Location      = ($deviceProps | Where-Object KeyName -eq 'DEVPKEY_Device_LocationInfo').Data
            PDOName       = ($deviceProps | Where-Object KeyName -eq 'DEVPKEY_Device_PDOName').Data
            Parent        = Resolve-DeviceParent -ParentId $parentData.Data -DeviceClass $_.Class
        }
    }
}

function Resolve-DeviceParent {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$ParentId,
        
        [Parameter(Mandatory)]
        [string]$DeviceClass
    )

    $maxDepth = 5
    $currentDepth = 0
    do {
        $parentProps = Get-PnpDeviceProperty -InstanceId $ParentId -ErrorAction Stop
        $ParentId = $parentProps | Where-Object KeyName -eq 'DEVPKEY_Device_Parent' | Select-Object -ExpandProperty Data
        $currentDepth++
    } while ($DeviceClass -eq 'Mouse' -and $parentProps.Data -notmatch 'Controller' -and $currentDepth -lt $maxDepth)

    [PSCustomObject]@{
        Name       = ($parentProps | Where-Object KeyName -eq 'DEVPKEY_NAME').Data
        InstanceId = $parentProps.InstanceId
        Location   = ($parentProps | Where-Object KeyName -eq 'DEVPKEY_Device_LocationInfo').Data
        PDOName    = ($parentProps | Where-Object KeyName -eq 'DEVPKEY_Device_PDOName').Data
    }
}
#endregion

#region Core Allocation Strategy
$coreMap = 1..$coresAmount | ForEach-Object {
    $coreID = if ($hyperThreadingStatus -eq 'Enabled') { 
        if ($_ % 2 -eq 0) { $_ } else { $_ + 1 }
    } else { 
        $_ 
    }
    
    [PSCustomObject]@{
        Identifier = $coreID
        Bitmask    = [math]::Pow(2, $coreID - 1)
        Assignment = $null
    }
}

$deviceTopology = Get-DeviceTopology -ErrorAction Stop
$deviceCategories = $deviceTopology.Class | Select-Object -Unique

# Distribute device types across available cores
$coreMap = foreach ($core in $coreMap) {
    $core.Assignment = $deviceCategories[$core.Identifier % $deviceCategories.Count]
    $core
}

foreach ($device in $deviceTopology) {
    $registryPaths = @{
        ParentPolicy = "HKLM:\SYSTEM\CurrentControlSet\Enum\$($device.Parent.InstanceId)\Device Parameters\Interrupt Management\Affinity Policy"
        DevicePolicy = "HKLM:\SYSTEM\CurrentControlSet\Enum\$($device.InstanceId)\Device Parameters\Interrupt Management\Affinity Policy"
        ParentMSI    = "HKLM:\SYSTEM\CurrentControlSet\Enum\$($device.Parent.InstanceId)\Device Parameters\Interrupt Management\MessageSignaledInterruptProperties"
        DeviceMSI    = "HKLM:\SYSTEM\CurrentControlSet\Enum\$($device.InstanceId)\Device Parameters\Interrupt Management\MessageSignaledInterruptProperties"
    }

    # Device-specific MSI configurations
    switch -Wildcard ($device.Class) {
        'Net'   { if (Test-Path $registryPaths.DeviceMSI) { Set-ItemProperty -Path $registryPaths.DeviceMSI -Name MSISupported -Value 0 } }
        'Mouse' { if (Test-Path $registryPaths.ParentMSI) { Set-ItemProperty -Path $registryPaths.ParentMSI -Name MSISupported -Value 0 } }
    }

    $assignedCore = $coreMap | Where-Object Assignment -eq $device.Class | Select-Object -First 1
    if (-not $assignedCore) {
        Write-Warning "No available core for $($device.Class) device class"
        continue
    }

    # Apply interrupt affinity policies
    'ParentPolicy', 'DevicePolicy' | Where-Object { Test-Path $registryPaths.$_ } | ForEach-Object {
        Set-ItemProperty -Path $registryPaths.$_ -Name DevicePolicy -Value 4 -ErrorAction Stop
        Set-ItemProperty -Path $registryPaths.$_ -Name AssignmentSetOverride -Value $assignedCore.Bitmask -ErrorAction Stop
    }

    $assignmentReport = @"
✅ Core Assignment Completed
📌 Device: $($device.Name)
🔗 Instance: $($device.InstanceId)
💻 Assigned Core: $($assignedCore.Identifier)
🔧 Device Class: $($device.Class)

"@
    Write-Host $assignmentReport
}
#endregion

Read-Host "⏯️ Operation Complete - Press Enter to exit..."
