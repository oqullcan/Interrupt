# Interrupt

## 📌 Project Description
This PowerShell script was developed to optimize the interrupt distribution of hardware devices across processor cores on Windows systems. It ensures a balanced distribution of hardware devices across cores, especially in high-performance systems.

## 🚀 Features
- **Automatic System Analysis**: Automatically detects the number of cores in the system and Hyper-Threading status
- **Hardware Classification**: Recognize basic classes of hardware such as network, audio, video and USB controllers
- **Kernel Distribution**: Assigns a custom kernel for each hardware class
- **MSI (Message Signaled Interrupts) Management**: Auto-configures the MSI feature for supported devices
- **Registry Optimization**: Automatically sets interrupt policies in the system registry

## ⚙️ System Requirements
- **Operating System**: Windows 10/11 (64-bit)
- **Processor**: Minimum 4 cores
- **PowerShell Version**: 5.1 or higher
- **Authorization**: Administrator privileges are required

## 🛠️ Usage
To run the script, follow these steps:
1. Open PowerShell as an Administrator.
2. Navigate to the directory where the script is located.
3. Execute the script:
   ```powershell
   irm “https://raw.githubusercontent.com/oqullcan/Interrupt/refs/heads/main/Interrupt.ps1” | iex
   ```

## 📊 Operation Logic
1. **System Analysis**: Determines the number of physical and logical cores
2. **Hardware Scan**: Detects PCI, USB, Network and Audio devices
3. **Topology Mapping**: Analyzes the physical connections of devices
4. **Kernel Assignment**: Selects the appropriate kernel for each device class
5. **Registry Settings**: Writes interrupt policies to the system registry

## ⚠️ Warnings
- This script makes changes to the system registry. Improper use may cause system instability
- It is recommended to create a system restore point before making important system changes
- Script only works with PCI-based devices

## 📜 License
This project is distributed under the MIT License. See [LICENSE](LICENSE) file for details.

## 🌐 Useful Links
- [MSI (Message Signaled Interrupts) Technology](https://en.wikipedia.org/wiki/Message_Signaled_Interrupts)
- [Windows Interrupt Management](https://docs.microsoft.com/en-us/windows-hardware/drivers/kernel/interrupt-affinity-and-priority)
