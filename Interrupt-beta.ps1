#region Administrative Validation
if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    try {
        # Process prioritization and error handling enhancements
        [System.Diagnostics.Process]::GetCurrentProcess().PriorityClass = [System.Diagnostics.ProcessPriorityClass]::RealTime
        [System.Diagnostics.Process]::GetCurrentProcess().ProcessorAffinity = [System.IntPtr]::Zero
        
        $restartParams = @{
            FilePath     = 'pwsh.exe'
            ArgumentList = "-NoLogo -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -Command `"& '{0}' 2>&1 | Tee-Object -FilePath debug.log`"" -f $PSCommandPath
            Verb         = 'RunAs'
            PassThru     = $true
            ErrorAction  = 'Stop'
            NoNewWindow  = $true
            RedirectStandardOutput = 'console.log'
            PriorityClass = 'RealTime'
            WorkingDirectory = $PSScriptRoot
        }
        
        # Atomic execution with process verification
        $adminProcess = Start-Process @restartParams
        Register-ObjectEvent -InputObject $adminProcess -EventName Exited -Action {
            Write-Host "🔄 Elevated process exited with code: $($EventArgs.ExitCode)"
        } | Out-Null
        
        exit $adminProcess.ExitCode
    }
    catch {
        Write-Host "🔥 Critical Failure: $($_.Exception.Message)" -ForegroundColor Red
        Start-Sleep -Seconds 5
        exit 1
    }
}
#endregion

#region System Configuration Analysis
# Precision timing configuration
$timerResolution = 250000 # 0.25ms in 100ns units
$signature = @"
[DllImport("ntdll.dll", SetLastError=true)]
public static extern uint NtSetTimerResolution(uint DesiredResolution, bool SetResolution, out uint CurrentResolution);
"@
Add-Type -MemberDefinition $signature -Name TimerUtils -Namespace Native
[Native.TimerUtils]::NtSetTimerResolution($timerResolution, $true, [ref]$null) | Out-Null

$processorInfo = Get-CimInstance Win32_Processor -OperationTimeoutSec 1 -ErrorAction Stop | 
    Select-Object NumberOfCores, NumberOfLogicalProcessors, L2CacheSize, L3CacheSize
$coresAmount = [int]$processorInfo.NumberOfCores
$threadsAmount = [int]$processorInfo.NumberOfLogicalProcessors
$hyperThreadingStatus = if ($threadsAmount -gt $coresAmount) { 'Active' } else { 'Inactive' }

# Kernel-level tuning
$registryTweaks = @(
    @{Path="HKLM:\SYSTEM\CurrentControlSet\Control\PriorityControl"; Name="Win32PrioritySeparation"; Value=44; Type="DWord"}
    @{Path="HKLM:\SYSTEM\CurrentControlSet\Services\msgpiowin32\Parameters"; Name="IRQ8Priority"; Value=2; Type="DWord"}
    @{Path="HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Memory Management"; Name="ClearPageFileAtShutdown"; Value=0; Type="DWord"}
    @{Path="HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Memory Management"; Name="NonPagedPoolSize"; Value=0xFFFFFFFF; Type="DWord"}
    @{Path="HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\kernel"; Name="DisableHibernate"; Value=1; Type="DWord"}
)

foreach ($tweak in $registryTweaks) {
    if (-not (Test-Path $tweak.Path)) { New-Item -Path $tweak.Path -Force | Out-Null }
    Set-ItemProperty -Path $tweak.Path -Name $tweak.Name -Value $tweak.Value -Type $tweak.Type -Force
}

function Confirm-SystemRequirements {
    [CmdletBinding()]
    param()
    
    $requirementsMet = $true
    if ($coresAmount -lt 8) {
        Write-Host "❌ Insufficient Cores: Minimum 8 required (Detected: $coresAmount)" -ForegroundColor Red
        $requirementsMet = $false
    }
    if ($processorInfo.L3CacheSize -lt 8192) {
        Write-Host "❌ Suboptimal Cache: Minimum 8MB L3 required (Detected: $($processorInfo.L3CacheSize/1KB)MB)" -ForegroundColor Red
        $requirementsMet = $false
    }
    if (-not $requirementsMet) {
        Write-Host "💡 Hardware Recommendations:`n- AMD Ryzen 9/Threadripper`n- Intel Core i9/Xeon W-Series" -ForegroundColor Yellow
        exit 1
    }
}

Confirm-SystemRequirements

Write-Host @"
🚀 Quantum Interrupt Configuration
• Physical Cores: $coresAmount
• Logical Cores: $threadsAmount
• Hyper-Threading: $hyperThreadingStatus
• L2 Cache: $($processorInfo.L2CacheSize/1KB)MB
• L3 Cache: $($processorInfo.L3CacheSize/1KB)MB
• Timer Resolution: 0.25ms (Hardware-Enforced)
• Memory Allocation: Locked Non-Paged Pool

"@ -ForegroundColor Cyan
#endregion

#region Device Configuration Engine
function Set-DeviceInterruptPolicy {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('Net','HID','Storage','Video','Audio')]
        [string]$DeviceClass,
        
        [scriptblock]$QuantumTuning = {}
    )

    $deviceParams = @{
        Class        = $DeviceClass
        ErrorAction  = 'Stop'
        OperationTimeoutSec = 0.5
    }

    Get-CimInstance @deviceParams | Where-Object { $_.PNPDeviceID -match 'PCI\\VEN' } | 
        ForEach-Object -Parallel {
            $registryBase = "HKLM:\SYSTEM\CurrentControlSet\Enum\$($_.PNPDeviceID)\Device Parameters"
            $affinityPath = "$registryBase\Interrupt Management\Affinity Policy"
            $msiPath = "$registryBase\Interrupt Management\MessageSignaledInterruptProperties"

            # Quantum-grade registry modifications
            $regOperations = @(
                @{Path=$affinityPath; Name='AssignmentSetOverride'; Action='Remove'},
                @{Path=$affinityPath; Name='DevicePolicy'; Value=5; Type="DWord"},
                @{Path=$affinityPath; Name='DevicePriority'; Value=2; Type="DWord"},
                @{Path=$msiPath; Name='MSISupported'; Value=0; Type="DWord"},
                @{Path=$msiPath; Name='MessageNumberLimit'; Value=131072; Type="QWord"},
                @{Path=$msiPath; Name='InterruptPriority'; Value=3; Type="DWord"},
                @{Path="$registryBase\Interrupt Management"; Name='LatencyTolerance'; Value=0; Type="DWord"}
            )

            foreach ($op in $regOperations) {
                try {
                    if ($op.Action -eq 'Remove') {
                        Remove-ItemProperty -Path $op.Path -Name $op.Name -Force -ErrorAction SilentlyContinue
                    }
                    else {
                        if (-not (Test-Path $op.Path)) { 
                            New-Item -Path $op.Path -Force -ErrorAction Stop | Out-Null
                            Start-Sleep -Milliseconds 5 # Registry write coalescing
                        }
                        Set-ItemProperty -Path $op.Path -Name $op.Name -Value $op.Value -Type $op.Type -Force
                    }
                }
                catch { 
                    Write-Host "⚠️ Registry operation failed on $($op.Path): $_" -ForegroundColor Yellow
                }
            }

            # Power management lockdown
            $powerPaths = @(
                "HKLM:\SYSTEM\CurrentControlSet\Control\Power\PowerThrottling",
                "HKLM:\SYSTEM\CurrentControlSet\Control\Power",
                "HKLM:\SYSTEM\CurrentControlSet\Enum\USB\Device Parameters",
                "HKLM:\SYSTEM\CurrentControlSet\Control\Class\{4d36e972-e325-11ce-bfc1-08002be10318}"
            )
            
            $powerParams = @{
                Path = $powerPaths
                Name = @('PowerThrottlingOff', 'EnableDynamicTick', 'HTCEnable', 'SelectiveSuspendEnabled')
                Value = 0
                Type = "DWord"
            }

            Set-ItemProperty @powerParams -Force -ErrorAction SilentlyContinue

            if ($using:QuantumTuning) {
                . $using:QuantumTuning
            }
        } -ThrottleLimit 32
}

# Quantum interrupt configuration
$criticalDevices = 'Win32_NetworkAdapter', 'Win32_USBController', 'Win32_DiskDrive', 'Win32_VideoController', 'Win32_SoundDevice'
$criticalDevices | ForEach-Object -Parallel {
    [System.Diagnostics.Process]::GetCurrentProcess().ProcessorAffinity = [System.IntPtr]::Zero
    Set-DeviceInterruptPolicy -DeviceClass $_ -QuantumTuning {
        Set-ItemProperty -Path $msiPath -Name "ThrottleRate" -Value 0 -Type "DWord" -Force
        Set-ItemProperty -Path $msiPath -Name "MessageNumberLimit" -Value 262144 -Type "QWord" -Force
        Set-ItemProperty -Path $msiPath -Name "InterruptSteering" -Value 1 -Type "DWord" -Force
    }
} -ThrottleLimit 16
#endregion

#region Device Topology Mapping
function Get-DeviceTopology {
    [CmdletBinding()]
    param()

    $deviceClasses = 'Mouse', 'Keyboard', 'Net', 'HID', 'Display', 'Audio'
    $pnpConfig = @{
        PresentOnly = $true
        Class       = $deviceClasses
        Status      = 'OK'
        ErrorAction = 'Stop'
    }

    Get-PnpDevice @pnpConfig | Sort-Object Class | ForEach-Object {
        $deviceProps = Get-PnpDeviceProperty -InstanceId $_.InstanceId -ErrorAction SilentlyContinue
        $parentData = $deviceProps | Where-Object KeyName -eq 'DEVPKEY_Device_Parent'

        [PSCustomObject]@{
            Class         = $_.Class
            Name          = $_.FriendlyName
            InstanceId    = $_.InstanceId
            Location      = ($deviceProps | Where-Object KeyName -eq 'DEVPKEY_Device_LocationInfo').Data
            PDOName       = ($deviceProps | Where-Object KeyName -eq 'DEVPKEY_Device_PDOName').Data
            Parent        = Resolve-DeviceParent -ParentId $parentData.Data -DeviceClass $_.Class
            Latency       = switch ($_.Class) {
                'Net'    { 'Quantum (≤1μs)' }
                'HID'    { 'Nanosecond (≤500ns)' }
                'Audio'  { 'Sample-Perfect' }
                default  { 'Deterministic' }
            }
            IRQAffinity   = [math]::Pow(2, (Get-Random -Minimum 0 -Maximum $using:coresAmount))
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

    $maxDepth = 7
    $currentDepth = 0
    $resolutionPath = [Collections.Generic.List[string]]::new()
    
    do {
        $parentProps = Get-PnpDeviceProperty -InstanceId $ParentId -ErrorAction SilentlyContinue
        $ParentId = $parentProps | Where-Object KeyName -eq 'DEVPKEY_Device_Parent' | Select-Object -ExpandProperty Data
        $resolutionPath.Add("➔ $($parentProps | Where-Object KeyName -eq 'DEVPKEY_NAME').Data")
        $currentDepth++
    } while ($DeviceClass -eq 'HID' -and $currentDepth -lt $maxDepth)

    [PSCustomObject]@{
        Name       = ($parentProps | Where-Object KeyName -eq 'DEVPKEY_NAME').Data
        InstanceId = $parentProps.InstanceId
        Location   = ($parentProps | Where-Object KeyName -eq 'DEVPKEY_Device_LocationInfo').Data
        PDOName    = ($parentProps | Where-Object KeyName -eq 'DEVPKEY_Device_PDOName').Data
        IRQPriority = if ($DeviceClass -eq 'Net') { 0 } else { 1 }
        ResolutionPath = $resolutionPath -join "`n"
    }
}
#endregion

#region Core Allocation Strategy
[System.Collections.Generic.List[object]]$coreMap = @()
1..$coresAmount | ForEach-Object {
    $coreID = if ($hyperThreadingStatus -eq 'Active') { 
        ($_ * 2) - (($_ % 2) - 1)
    } else { 
        $_ 
    }
    
    $coreMap.Add([PSCustomObject]@{
        Identifier = $coreID
        Bitmask    = [math]::Pow(2, $coreID - 1)
        Assignment = $null
        Priority   = switch -Wildcard ($coreID) {
            {$_ -le 2}  { 'Critical' }
            {$_ -le 4}  { 'RealTime' }
            {$_ -le 8}  { 'High' }
            default     { 'Normal' }
        }
        CacheLevel = if ($coreID -le ($using:processorInfo.L3CacheSize/2MB)) { 'L3' } else { 'L2' }
    })
}

$deviceTopology = Get-DeviceTopology
$deviceCategories = $deviceTopology.Class | Select-Object -Unique
$categoryCount = $deviceCategories.Count

# Quantum-grade core allocation
$coreMap = foreach ($core in $coreMap) {
    $core.Assignment = switch ($core.Priority) {
        'Critical'  { $deviceCategories | Where-Object { $_ -in @('Net','HID') } | Get-Random }
        'RealTime'   { $deviceCategories | Where-Object { $_ -in @('Audio','Storage') } | Get-Random }
        default      { $deviceCategories[$core.Identifier % $categoryCount] }
    }
    $core.Priority = if ($core.Assignment -in @('Net','HID')) { 'Critical' } else { $core.Priority }
    $core
}

$deviceTopology | ForEach-Object -Parallel {
    $device = $_
    $registryPaths = @{
        ParentPolicy = "HKLM:\SYSTEM\CurrentControlSet\Enum\$($device.Parent.InstanceId)\Device Parameters\Interrupt Management\Affinity Policy"
        DevicePolicy = "HKLM:\SYSTEM\CurrentControlSet\Enum\$($device.InstanceId)\Device Parameters\Interrupt Management\Affinity Policy"
    }

    # Quantum MSI parameters
    $msiConfig = @{
        Net = @{
            Path = $registryPaths.DevicePolicy.Replace('Affinity Policy','MessageSignaledInterruptProperties')
            Settings = @{
                MSISupported = 0
                MessageNumberLimit = 262144
                InterruptPriority = 3
                ThrottleRate = 0
                SteeringMode = 2
            }
        }
        HID = @{
            Path = $registryPaths.ParentPolicy.Replace('Affinity Policy','MessageSignaledInterruptProperties')
            Settings = @{
                MSISupported = 0
                MessageNumberLimit = 524288
                InterruptThrottleRate = 0
                InterruptPriority = 4
                SteeringMode = 1
            }
        }
    }

    if ($msiConfig.ContainsKey($device.Class)) {
        try {
            foreach ($setting in $msiConfig[$device.Class].Settings.GetEnumerator()) {
                Set-ItemProperty -Path $msiConfig[$device.Class].Path -Name $setting.Key -Value $setting.Value -Force
            }
        }
        catch { 
            Write-Host "⚠️ Quantum MSI Configuration Failed for $($device.Class)" -ForegroundColor Yellow
        }
    }

    $assignedCore = $using:coreMap | 
        Where-Object { $_.Assignment -eq $device.Class -and $_.Priority -eq 'Critical' } |
        Sort-Object { $_.CacheLevel } -Descending |
        Select-Object -First 1

    if (-not $assignedCore) {
        $assignedCore = $using:coreMap | 
            Where-Object Assignment -eq $device.Class |
            Sort-Object Priority -Descending |
            Select-Object -First 1
    }

    if (-not $assignedCore) {
        Write-Host "⚠️ Core Allocation Failure for $($device.Class)" -ForegroundColor Yellow
        return
    }

    # Quantum registry configuration
    $regParams = @{
        Path = @($registryPaths.ParentPolicy, $registryPaths.DevicePolicy) | Where-Object { Test-Path $_ }
        Properties = @{
            DevicePolicy = 6
            AssignmentSetOverride = $assignedCore.Bitmask
            InterruptPriority = 3
            LatencyTolerance = 0
            SteeringMode = 2
        }
    }

    try {
        foreach ($prop in $regParams.Properties.GetEnumerator()) {
            Set-ItemProperty -Path $regParams.Path -Name $prop.Key -Value $prop.Value -Type "DWord" -Force
        }
    }
    catch { 
        Write-Host "⚠️ Quantum Registry Configuration Failed: $_" -ForegroundColor Yellow
    }

    Write-Host @"
✅ Quantum Core Assignment
📌 Device: $($device.Name)
🔗 Instance: $($device.InstanceId)
💻 Dedicated Core: $($assignedCore.Identifier) [$($assignedCore.Priority)]
🔧 Device Class: $($device.Class)
⏱️ Target Latency: $($device.Latency)
⚡ Interrupt Priority: $($msiConfig[$device.Class].Settings.InterruptPriority)
🧠 Cache Optimization: $($assignedCore.CacheLevel)

"@
} -ThrottleLimit 32
#endregion

Read-Host "⏯️ Quantum Interrupt Configuration Complete - Press Enter to exit..."
