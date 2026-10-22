# Incident Diagnostics & Log Collector

A set of lightweight, **read-only** diagnostic collection scripts designed to capture system state and logs immediately following a crash, freeze, or unexpected reboot on **Linux** and **Windows**.

## 📌 Overview

When a system freezes or reboots unexpectedly, finding the root cause often requires manually cross-referencing system logs, hardware states, and sensor data.

These scripts automate the post-mortem data collection process safely without altering system configurations or installing permanent services. All gathered information is saved into a dedicated directory for easy analysis or sharing.

---

## 🛠️ Included Tools

### 🐧 `collecte_incident_linux.sh` (Linux)
* **Target Environment:** Linux systems (optimized for laptop/desktop hardware like ROG Strix G713QM).
* **Key Features:**
  * Analyzes past `journald` boots to pinpoint the exact time of freeze and calculate uptime.
  * Captures suspect kernel traces (`amdgpu`, `nvidia`, PCIe errors, C-states, hung tasks, MCE).
  * Checks crash dump repositories (`pstore`, `coredumps`, `/var/crash`).
  * Gathers GPU power management and thermal state parameters.
  * Archives all findings into a single `.tar.gz` package.

### 🪟 `collecte_incident_windows.ps1` (Windows)
* **Target Environment:** Windows 10 / 11 (PowerShell 5.1+).
* **Key Features:**
  * Automatically cross-references HWiNFO log files (`hwinfo*.csv`) to estimate the precise crash timestamp.
  * Parses critical system events (Kernel-Power Event ID 41, Event 6008, BugCheck 1001).
  * Filters WHEA-Logger hardware errors and Display driver events preceding the incident.
  * Checks for `Minidump`, `MEMORY.DMP`, and `LiveKernelReports` files.
  * Generates a structured Markdown (`.md`) summary report.

---

## 🚀 Quick Usage

### Linux
Run the script specifying the boot offset (`-1` for the previous boot before the freeze):
```bash
bash collecte_incident_linux.sh -1
```

### Windows
Run PowerShell as Administrator and bypass execution policy for the session:

```PowerShell
powershell -ExecutionPolicy Bypass -File .\collecte_incident_windows.ps1
```
## 🛡️ License
This project is licensed under the MIT License — see the [LICENSE](./LICENSE) file for details.
