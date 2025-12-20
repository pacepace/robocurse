#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Enables or disables PowerShell Remoting (WinRM) with optional IP restrictions.

.DESCRIPTION
    Configures PowerShell Remoting (WinRM) for remote management via Enter-PSSession
    and Invoke-Command. Can restrict access to specific IP addresses for security.

    PowerShell Remoting uses:
    - Port 5985 (HTTP) - default, used by this script
    - Port 5986 (HTTPS) - for certificate-based auth (not managed by this script)

    When enabled:
    - WinRM service is started and set to Automatic
    - HTTP listener is configured on port 5985
    - Firewall rules allow inbound connections (optionally restricted by IP)

    When disabled:
    - PSRemoting session configurations are unregistered
    - WinRM firewall rules are disabled
    - WinRM service is stopped and set to Disabled

    Disabling WinRM does NOT affect:
    - RDP (Remote Desktop) - uses port 3389
    - SMB file sharing - uses ports 139/445
    - Remote MMC snap-ins - use RPC/SMB
    - Scheduled tasks, Group Policy, or other domain management

    WinRM is only required for PowerShell Remoting and Windows Admin Center.

.PARAMETER Enable
    Enables PowerShell Remoting:
    - Runs Enable-PSRemoting to configure the service and listener
    - Configures firewall rules (default WinRM rules or custom IP-restricted rule)
    - Starts the WinRM service

.PARAMETER Disable
    Disables PowerShell Remoting:
    - Unregisters PS session configurations
    - Disables all WinRM firewall rules (both default and custom)
    - Stops and disables the WinRM service

.PARAMETER AllowedIPs
    One or more IP addresses or CIDR subnets allowed to connect.
    Only used with -Enable.

    When specified:
    - Default WinRM firewall rules are disabled
    - A custom rule (Robocurse-WinRM-HTTP) is created allowing only these IPs

    When omitted:
    - Default WinRM firewall rules are used (allows any IP)

    Examples: "192.168.1.100", "10.0.0.0/24", "192.168.1.0/24"

.PARAMETER Status
    Displays the current state of WinRM without making changes:
    - Service status and startup type
    - HTTP listener configuration
    - Firewall rules and allowed IPs

.EXAMPLE
    .\Set-PsRemoting.ps1 -Enable

    Enables PowerShell Remoting with default firewall rules (any IP can connect).

.EXAMPLE
    .\Set-PsRemoting.ps1 -Enable -AllowedIPs "192.168.1.100"

    Enables remoting, but only allows connections from 192.168.1.100.

.EXAMPLE
    .\Set-PsRemoting.ps1 -Enable -AllowedIPs "10.0.0.0/8","192.168.0.0/16"

    Enables remoting for multiple subnets (internal networks only).

.EXAMPLE
    .\Set-PsRemoting.ps1 -Disable

    Completely disables PowerShell Remoting.

.EXAMPLE
    .\Set-PsRemoting.ps1 -Status

    Shows current WinRM configuration without making changes.

.NOTES
    Requires: Administrator privileges

    Firewall rules managed by this script:
    - Robocurse-WinRM-HTTP (custom IP-restricted rule, when -AllowedIPs is used)
    - "Windows Remote Management" group (default rules, enabled/disabled as needed)

    To test connectivity from another machine:
        Test-WSMan -ComputerName <servername>
        Enter-PSSession -ComputerName <servername>

    For HTTPS (port 5986), you need to configure a certificate separately.
    This script only manages HTTP on port 5985.

    Unlike SMB, disabling WinRM has minimal impact on traditional Windows
    administration tools. Most MMC snap-ins use RPC (port 135), not WinRM.

.LINK
    Set-SmbFirewall.ps1
    Set-FileSharing.ps1
    https://docs.microsoft.com/en-us/powershell/module/microsoft.powershell.core/enable-psremoting
#>
[CmdletBinding()]
param(
    [switch]$Enable,
    [switch]$Disable,
    [string[]]$AllowedIPs,
    [switch]$Status
)

$ErrorActionPreference = 'Stop'

$customRuleName = 'Robocurse-WinRM-HTTP'

function Get-RemotingStatus {
    Write-Host "`nPowerShell Remoting Status:" -ForegroundColor Cyan

    # WinRM service
    $svc = Get-Service -Name WinRM -ErrorAction SilentlyContinue
    if ($svc) {
        $startType = (Get-WmiObject Win32_Service -Filter "Name='WinRM'").StartMode
        Write-Host "  WinRM Service: $($svc.Status) ($startType)"
    } else {
        Write-Host "  WinRM Service: NOT FOUND" -ForegroundColor Red
        return
    }

    # Listener
    $listener = Get-ChildItem WSMan:\localhost\Listener -ErrorAction SilentlyContinue |
        Where-Object { $_.Keys -contains 'Transport=HTTP' }
    if ($listener) {
        Write-Host "  HTTP Listener: Configured" -ForegroundColor Green
    } else {
        Write-Host "  HTTP Listener: Not configured" -ForegroundColor Yellow
    }

    # Firewall rules
    $customRule = Get-NetFirewallRule -Name $customRuleName -ErrorAction SilentlyContinue
    $defaultRules = Get-NetFirewallRule -DisplayGroup "Windows Remote Management" -ErrorAction SilentlyContinue |
        Where-Object { $_.Enabled -eq $true }

    if ($customRule) {
        $filter = $customRule | Get-NetFirewallAddressFilter
        Write-Host "  Firewall: Custom rule active" -ForegroundColor Green
        if ($filter.RemoteAddress -and $filter.RemoteAddress -ne 'Any') {
            Write-Host "  Allowed IPs: $($filter.RemoteAddress -join ', ')" -ForegroundColor Cyan
        } else {
            Write-Host "  Allowed IPs: Any" -ForegroundColor Yellow
        }
    } elseif ($defaultRules) {
        Write-Host "  Firewall: Default WinRM rules enabled" -ForegroundColor Green
        Write-Host "  Allowed IPs: Any (default rules)" -ForegroundColor Yellow
    } else {
        Write-Host "  Firewall: No WinRM rules enabled" -ForegroundColor Yellow
    }

    # Overall status
    if ($svc.Status -eq 'Running' -and ($listener -or $customRule -or $defaultRules)) {
        Write-Host "`n  PS Remoting: ENABLED" -ForegroundColor Green
    } else {
        Write-Host "`n  PS Remoting: DISABLED" -ForegroundColor Yellow
    }
}

if (-not $Enable -and -not $Disable -and -not $Status) {
    Write-Host "Specify -Enable, -Disable, or -Status" -ForegroundColor Red
    Get-RemotingStatus
    exit 1
}

if ($Enable -and $Disable) {
    throw "Cannot specify both -Enable and -Disable"
}

if ($AllowedIPs -and -not $Enable) {
    throw "-AllowedIPs can only be used with -Enable"
}

if ($Status) {
    Get-RemotingStatus
    exit 0
}

if ($Enable) {
    Write-Host "Enabling PowerShell Remoting..." -ForegroundColor Cyan

    # Enable PS Remoting (creates listener, starts service, sets startup type)
    Enable-PSRemoting -Force -SkipNetworkProfileCheck | Out-Null
    Write-Host "  PSRemoting enabled" -ForegroundColor Green

    # Handle firewall rules
    if ($AllowedIPs) {
        Write-Host "  Configuring IP restrictions..." -ForegroundColor Cyan

        # Disable default WinRM rules
        $defaultRules = Get-NetFirewallRule -DisplayGroup "Windows Remote Management" -ErrorAction SilentlyContinue
        foreach ($rule in $defaultRules) {
            Set-NetFirewallRule -Name $rule.Name -Enabled False
        }
        Write-Host "  Disabled default WinRM firewall rules" -ForegroundColor Cyan

        # Remove existing custom rule if present
        $existing = Get-NetFirewallRule -Name $customRuleName -ErrorAction SilentlyContinue
        if ($existing) {
            Remove-NetFirewallRule -Name $customRuleName
        }

        # Create custom rule with IP restrictions
        New-NetFirewallRule -Name $customRuleName `
            -DisplayName "WinRM HTTP (Robocurse - Restricted)" `
            -Direction Inbound `
            -Protocol TCP `
            -LocalPort 5985 `
            -Action Allow `
            -Profile Any `
            -RemoteAddress $AllowedIPs `
            -Description "Created by Robocurse Set-PsRemoting.ps1" | Out-Null

        Write-Host "  Created firewall rule for: $($AllowedIPs -join ', ')" -ForegroundColor Green
    } else {
        # Remove custom rule if it exists, re-enable defaults
        $existing = Get-NetFirewallRule -Name $customRuleName -ErrorAction SilentlyContinue
        if ($existing) {
            Remove-NetFirewallRule -Name $customRuleName
            Write-Host "  Removed custom IP-restricted rule" -ForegroundColor Cyan
        }

        # Re-enable default rules
        $defaultRules = Get-NetFirewallRule -DisplayGroup "Windows Remote Management" -ErrorAction SilentlyContinue
        foreach ($rule in $defaultRules) {
            Set-NetFirewallRule -Name $rule.Name -Enabled True
        }
        Write-Host "  Using default WinRM firewall rules (any IP)" -ForegroundColor Yellow
    }

    Write-Host "`nPowerShell Remoting enabled" -ForegroundColor Green
    Get-RemotingStatus
}

if ($Disable) {
    Write-Host "Disabling PowerShell Remoting..." -ForegroundColor Cyan

    # Disable PSRemoting config first (while service is still running)
    # This unregisters the PS session configurations
    try {
        Disable-PSRemoting -Force -WarningAction SilentlyContinue -ErrorAction SilentlyContinue | Out-Null
        Write-Host "  Disabled PSRemoting configuration" -ForegroundColor Green
    } catch {
        Write-Host "  PSRemoting configuration already disabled" -ForegroundColor Cyan
    }

    # Remove custom firewall rule
    $existing = Get-NetFirewallRule -Name $customRuleName -ErrorAction SilentlyContinue
    if ($existing) {
        Remove-NetFirewallRule -Name $customRuleName
        Write-Host "  Removed custom firewall rule" -ForegroundColor Cyan
    }

    # Disable default WinRM firewall rules
    $defaultRules = Get-NetFirewallRule -DisplayGroup "Windows Remote Management" -ErrorAction SilentlyContinue
    foreach ($rule in $defaultRules) {
        Set-NetFirewallRule -Name $rule.Name -Enabled False
    }
    Write-Host "  Disabled WinRM firewall rules" -ForegroundColor Cyan

    # Stop and disable WinRM service
    $svc = Get-Service -Name WinRM
    if ($svc.Status -eq 'Running') {
        Stop-Service -Name WinRM -Force
    }
    Set-Service -Name WinRM -StartupType Disabled
    Write-Host "  Stopped and disabled WinRM service" -ForegroundColor Green

    Write-Host "`nPowerShell Remoting disabled" -ForegroundColor Green
    Get-RemotingStatus
}
