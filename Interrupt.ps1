#region Administrative Validation
if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    try {
        $adminProcess = Start-Process powershell.exe "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`"" -Verb RunAs -PassThru -ErrorAction Stop
        exit $adminProcess.ExitCode
    }
    catch {
        Write-Error "❌ Failed to elevate privileges: $_" -ErrorAction Stop
    }
}
#endregion

#region System Configuration Analysis
$systemConfig = Get-CimInstance Win32_Processor -ErrorAction Stop | Select-Object NumberOfCores, NumberOfLogicalProcessors
$coresAmount = [int]$systemConfig.NumberOfCores
$threadsAmount = [int]$systemConfig.NumberOfLogicalProcessors
$hyperThreadingStatus = if ($threadsAmount -gt $coresAmount) { 'Enabled' } else { 'Disabled' }

function Test-CoreRequirements {
    [CmdletBinding()]
    param()
    
    if ($coresAmount -lt 4) {
        Write-Error "❌ Interrupt Affinity tweaks require at least 4 physical cores (Detected: $coresAmount)" -ErrorAction Stop
        throw "Insufficient processor cores"
    }
}

Test-CoreRequirements

$systemReport = @"
🚀 Starting Interrupt Affinity Optimization
• Physical Cores: $coresAmount
• Logical Cores: $threadsAmount
• Hyper-Threading: $hyperThreadingStatus

"@

Write-Host $systemReport -ForegroundColor Cyan
#endregion

#region Device Configuration Engine
function Optimize-DeviceRegistry {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$DeviceClass,
        [scriptblock]$ConfigurationScript = {}
    )

    Get-CimInstance $DeviceClass -ErrorAction Stop | Where-Object { 
        $_.PNPDeviceID -match "PCI\\VEN" 
    } | ForEach-Object {
        $devicePath = "HKLM:\SYSTEM\CurrentControlSet\Enum\$($_.PNPDeviceID)\Device Parameters"
        $affinityPolicyPath = "$devicePath\Interrupt Management\Affinity Policy"
        $msiPropertiesPath = "$devicePath\Interrupt Management\MessageSignaledInterruptProperties"

        # Reset affinity policies
        Remove-ItemProperty -Path $affinityPolicyPath -Name 'AssignmentSetOverride', 'DevicePolicy', 'DevicePriority' -Force -ErrorAction SilentlyContinue
        
        # Configure MSI support
        if (Test-Path $msiPropertiesPath) {
            Set-ItemProperty -Path $msiPropertiesPath -Name "MSISupported" -Value 1 -Force -ErrorAction Stop
        }

        # Apply custom configuration
        if ($ConfigurationScript) {
            . $ConfigurationScript
        }
    }
}

@('Win32_VideoController', 'Win32_USBController', 'Win32_IDEController', 'Win32_SoundDevice') | ForEach-Object {
    Optimize-DeviceRegistry -DeviceClass $_ -ErrorAction Stop
}

# Special configuration for network adapters
Optimize-DeviceRegistry -DeviceClass Win32_NetworkAdapter -ConfigurationScript {
    if (Test-Path $msiPropertiesPath) {
        Set-ItemProperty -Path $msiPropertiesPath -Name "MessageNumberLimit" -Value 256 -Force -ErrorAction Stop
    }
}
#endregion

#region Device Topology Mapping
function Get-DeviceHierarchy {
    [CmdletBinding()]
    param()

    $deviceClasses = 'Mouse', 'Display', 'Net'
    $pnpParams = @{
        PresentOnly = $true
        Class       = $deviceClasses
        Status      = 'OK'
        ErrorAction = 'Stop'
    }

    Get-PnpDevice @pnpParams | Sort-Object Class | ForEach-Object {
        $properties = Get-PnpDeviceProperty -InstanceId $_.InstanceId -ErrorAction Stop
        $parentInfo = $properties | Where-Object { $_.KeyName -eq 'DEVPKEY_Device_Parent' }

        [PSCustomObject]@{
            Class         = $_.Class
            Name          = $_.FriendlyName
            InstanceId    = $_.InstanceId
            Location      = ($properties | Where-Object KeyName -eq 'DEVPKEY_Device_LocationInfo').Data
            PDOName       = ($properties | Where-Object KeyName -eq 'DEVPKEY_Device_PDOName').Data
            Parent        = Resolve-ParentController -ParentId $parentInfo.Data -DeviceClass $_.Class
        }
    }
}

function Resolve-ParentController {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$ParentId,
        
        [Parameter(Mandatory)]
        [string]$DeviceClass
    )

    $maxIterations = 5
    $iteration = 0

    do {
        $parentDevice = Get-PnpDeviceProperty -InstanceId $ParentId -ErrorAction Stop
        $ParentId = $parentDevice | Where-Object KeyName -eq 'DEVPKEY_Device_Parent' | Select-Object -ExpandProperty Data
        $iteration++
    } while ($DeviceClass -eq 'Mouse' -and $parentDevice.Data -notmatch 'Controller' -and $iteration -lt $maxIterations)

    [PSCustomObject]@{
        Name       = ($parentDevice | Where-Object KeyName -eq 'DEVPKEY_NAME').Data
        InstanceId = $parentDevice.InstanceId
        Location   = ($parentDevice | Where-Object KeyName -eq 'DEVPKEY_Device_LocationInfo').Data
        PDOName    = ($parentDevice | Where-Object KeyName -eq 'DEVPKEY_Device_PDOName').Data
    }
}
#endregion

#region Core Allocation Strategy
$coreAllocationPlan = 1..$coresAmount | ForEach-Object {
    $coreIdentifier = if ($threadsAmount -gt $coresAmount) { 
        if ($_ % 2 -eq 0) { $_ } else { $_ + 1 }
    } else { 
        $_ 
    }
    
    [PSCustomObject]@{
        Core = $coreIdentifier
        Mask = [math]::Pow(2, $coreIdentifier - 1)
        Type = $null
    }
}

$deviceMap = Get-DeviceHierarchy -ErrorAction Stop
$uniqueDeviceTypes = $deviceMap.Class | Select-Object -Unique

# Assign core types based on device hierarchy
$typeIndex = 0
$coreAllocationPlan = foreach ($core in $coreAllocationPlan) {
    $core.Type = if ($typeIndex -lt $uniqueDeviceTypes.Count) { 
        $uniqueDeviceTypes[$typeIndex++] 
    }
    $core
}

foreach ($device in $deviceMap) {
    $registryPaths = @{
        ParentAffinity = "HKLM:\SYSTEM\CurrentControlSet\Enum\$($device.Parent.InstanceId)\Device Parameters\Interrupt Management\Affinity Policy"
        ChildAffinity  = "HKLM:\SYSTEM\CurrentControlSet\Enum\$($device.InstanceId)\Device Parameters\Interrupt Management\Affinity Policy"
        ParentMSI      = "HKLM:\SYSTEM\CurrentControlSet\Enum\$($device.Parent.InstanceId)\Device Parameters\Interrupt Management\MessageSignaledInterruptProperties"
        ChildMSI       = "HKLM:\SYSTEM\CurrentControlSet\Enum\$($device.InstanceId)\Device Parameters\Interrupt Management\MessageSignaledInterruptProperties"
    }

    # Configure device-specific MSI settings
    switch -Wildcard ($device.Class) {
        'Net'   { if (Test-Path $registryPaths.ChildMSI) { Set-ItemProperty -Path $registryPaths.ChildMSI -Name MSISupported -Value 0 } }
        'Mouse' { if (Test-Path $registryPaths.ParentMSI) { Set-ItemProperty -Path $registryPaths.ParentMSI -Name MSISupported -Value 0 } }
    }

    $coreAssignment = $coreAllocationPlan | Where-Object { $_.Type -eq $device.Class } | Select-Object -First 1
    if (-not $coreAssignment) {
        Write-Warning "No core assignment found for $($device.Class) device type"
        continue
    }

    # Apply affinity settings
    @('ParentAffinity', 'ChildAffinity') | ForEach-Object {
        if (Test-Path $registryPaths.$_) {
            Set-ItemProperty -Path $registryPaths.$_ -Name DevicePolicy -Value 4 -ErrorAction Stop
            Set-ItemProperty -Path $registryPaths.$_ -Name AssignmentSetOverride -Value $coreAssignment.Mask -ErrorAction Stop
        }
    }

    $assignmentDetails = @"
✅ Assigned to Core $($coreAssignment.Core)
📌 Device: $($device.Name)
🔗 Instance: $($device.InstanceId)
📌 Parent: $($device.Parent.Name)
🔗 Parent Instance: $($device.Parent.InstanceId)

"@
    Write-Host $assignmentDetails
}
#endregion

Read-Host "⏯️ Press Enter to exit..."
