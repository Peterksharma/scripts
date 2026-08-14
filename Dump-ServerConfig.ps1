<#
.SYNOPSIS
    Dump-ServerConfig.ps1 -- dump the entire server configuration into
    ONE human-readable text file.

.DESCRIPTION
    Single-file sibling of Export-ServerConfig.ps1. Run it ELEVATED on the
    server; it appends every section below into one report:

        C:\ServerDump\<hostname>-<yyyyMMdd-HHmmss>.txt

    Sections (each wrapped in its own try/catch -- a broken role never
    stops the rest, the error text is written into the report instead):

        IDENTITY, NETWORK, ROLES & FEATURES, DHCP, DNS, ACTIVE DIRECTORY,
        SHARES & NTFS ACLS, LOCAL USERS & GROUPS, INSTALLED SOFTWARE,
        ODBC DSNS, SERVICES, SCHEDULED TASKS, PRINTERS, CERTIFICATES

    Where the folder-based exporter saved reimportable binaries, this one
    embeds the closest text equivalent:
      - DHCP:      `netsh dhcp server dump` -- a replayable netsh script
      - Firewall:  full enabled-rule listing (readable, not reimportable)
      - DNS:       every record of every primary zone, listed in full
      - NTFS ACLs: icacls output inline

    Invariant: read-only against system state; the only write is the
    report file itself.

.NOTES
    Target: Windows PowerShell 5.1+ (works as-is on Server 2016-2025).

.PARAMETER SkipNetwork
    Omit the NETWORK section. Use when the machine being dumped is a
    restored/virtual copy whose adapters and IPs do NOT reflect the real
    server -- capture networking from the physical box separately.

.EXAMPLE
    PS C:\> Set-ExecutionPolicy -Scope Process Bypass -Force
    PS C:\> .\Dump-ServerConfig.ps1

.EXAMPLE
    # On the backup VM: everything except its (wrong) network config.
    PS C:\> .\Dump-ServerConfig.ps1 -SkipNetwork
#>

#Requires -RunAsAdministrator

param(
    [switch] $SkipNetwork
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
# Report file
# ---------------------------------------------------------------------------
$null = New-Item -ItemType Directory -Path 'C:\ServerDump' -Force
$Report = Join-Path 'C:\ServerDump' `
    ("{0}-{1}.txt" -f $env:COMPUTERNAME, (Get-Date -Format 'yyyyMMdd-HHmmss'))

# Fixed-width text renders best around 200 cols; wide enough that
# Format-Table doesn't truncate paths, narrow enough to read anywhere.
$W = 200

function Add-Line {
    param([string] $Text = '')
    Add-Content -Path $Report -Value $Text -Encoding UTF8
}

function Add-Section {
    <#
        Runs $Body, captures everything it emits as text, and appends it
        under a banner. Objects are rendered with Out-String; strings pass
        through untouched. Errors become part of the report, not a crash.
    #>
    param(
        [Parameter(Mandatory)][string]      $Title,
        [Parameter(Mandatory)][scriptblock] $Body
    )
    Write-Host "==> $Title" -ForegroundColor Cyan
    Add-Line ('=' * 79)
    Add-Line "==  $Title"
    Add-Line ('=' * 79)
    try {
        $out = & $Body | Out-String -Width $W
        if ($out.Trim().Length -eq 0) { $out = '(nothing to report)' }
        Add-Line $out.TrimEnd()
    } catch {
        Add-Line "!! SECTION FAILED: $($_.Exception.Message)"
        Write-Warning "Section '$Title' failed: $($_.Exception.Message)"
    }
    Add-Line ''
}

function Add-Heading {
    # Sub-heading inside a section, e.g. one share, one DNS zone.
    param([Parameter(Mandatory)][string] $Text)
    "`r`n---- $Text " + ('-' * [math]::Max(3, 60 - $Text.Length))
}

function Test-FeatureInstalled {
    param([Parameter(Mandatory)][string] $FeatureName)
    $f = Get-WindowsFeature -Name $FeatureName -ErrorAction SilentlyContinue
    return ($null -ne $f -and $f.Installed)
}

# ---------------------------------------------------------------------------
# Header
# ---------------------------------------------------------------------------
Add-Line ('#' * 79)
Add-Line "#  SERVER CONFIGURATION DUMP"
Add-Line "#  Host:      $env:COMPUTERNAME"
Add-Line "#  Generated: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
Add-Line "#  By:        $env:USERDOMAIN\$env:USERNAME"
Add-Line ('#' * 79)
Add-Line ''

# ---------------------------------------------------------------------------
Add-Section 'IDENTITY' {
    $cs = Get-CimInstance Win32_ComputerSystem
    $os = Get-CimInstance Win32_OperatingSystem
    # DomainRole: 0/1 workgroup, 2/3 domain member, 4/5 domain controller.
    [pscustomobject]@{
        ComputerName = $cs.Name
        Domain       = $cs.Domain
        PartOfDomain = $cs.PartOfDomain
        DomainRole   = $cs.DomainRole
        OSCaption    = $os.Caption
        OSVersion    = "$($os.Version) (build $($os.BuildNumber))"
        InstallDate  = $os.InstallDate
        LastBoot     = $os.LastBootUpTime
        TimeZone     = (tzutil /g)
    } | Format-List
}

# ---------------------------------------------------------------------------
if ($SkipNetwork) {
    Add-Section 'NETWORK' {
        'SKIPPED (-SkipNetwork): this machine''s network config is not'
        'authoritative -- capture networking from the physical server.'
    }
} else {
Add-Section 'NETWORK' {
    Add-Heading 'Adapters'
    Get-NetAdapter | Format-Table Name, InterfaceDescription, ifIndex,
        MacAddress, Status, LinkSpeed -AutoSize

    Add-Heading 'IP configuration (ipconfig /all)'
    ipconfig /all

    Add-Heading 'IP addresses'
    Get-NetIPAddress | Sort-Object InterfaceIndex |
        Format-Table InterfaceAlias, AddressFamily, IPAddress,
            PrefixLength, PrefixOrigin -AutoSize

    Add-Heading 'Routes (gateways + statics; link-local omitted)'
    Get-NetRoute -AddressFamily IPv4 |
        Where-Object { $_.NextHop -ne '0.0.0.0' } |
        Format-Table DestinationPrefix, NextHop, InterfaceAlias,
            RouteMetric, ifMetric -AutoSize

    Add-Heading 'DNS client servers per interface'
    Get-DnsClientServerAddress |
        Where-Object { $_.ServerAddresses.Count -gt 0 } |
        Format-Table InterfaceAlias, AddressFamily, ServerAddresses -AutoSize

    Add-Heading 'DNS suffix search list'
    Get-DnsClientGlobalSetting | Format-List

    Add-Heading 'hosts file (non-comment lines)'
    Get-Content "$env:SystemRoot\System32\drivers\etc\hosts" |
        Where-Object { $_ -match '\S' -and $_ -notmatch '^\s*#' }

    Add-Heading 'Firewall profiles'
    Get-NetFirewallProfile |
        Format-Table Name, Enabled, DefaultInboundAction,
            DefaultOutboundAction -AutoSize

    Add-Heading 'Firewall rules (enabled only)'
    Get-NetFirewallRule | Where-Object Enabled -eq 'True' |
        Sort-Object Direction, DisplayName |
        Format-Table DisplayName, Direction, Action, Profile -AutoSize

    Add-Heading 'SMB server configuration'
    Get-SmbServerConfiguration | Format-List
}
}

# ---------------------------------------------------------------------------
Add-Section 'ROLES & FEATURES (installed)' {
    Get-WindowsFeature | Where-Object Installed |
        Format-Table Name, DisplayName, FeatureType -AutoSize
}

# ---------------------------------------------------------------------------
Add-Section 'DHCP' {
    if (-not (Test-FeatureInstalled 'DHCP')) { return 'DHCP role not installed.' }

    Add-Heading 'Scopes'
    Get-DhcpServerv4Scope | Format-Table ScopeId, Name, StartRange,
        EndRange, SubnetMask, LeaseDuration, State -AutoSize

    Add-Heading 'Server-level options'
    Get-DhcpServerv4OptionValue -ErrorAction SilentlyContinue |
        Format-Table OptionId, Name, Value -AutoSize

    foreach ($scope in Get-DhcpServerv4Scope) {
        Add-Heading "Scope $($scope.ScopeId) options"
        Get-DhcpServerv4OptionValue -ScopeId $scope.ScopeId `
            -ErrorAction SilentlyContinue |
            Format-Table OptionId, Name, Value -AutoSize

        Add-Heading "Scope $($scope.ScopeId) reservations"
        Get-DhcpServerv4Reservation -ScopeId $scope.ScopeId `
            -ErrorAction SilentlyContinue |
            Format-Table IPAddress, ClientId, Name, Description -AutoSize
    }

    # The netsh dump is a REPLAYABLE script: `netsh exec <file>` on the
    # new server recreates scopes/options/reservations from this text.
    Add-Heading 'netsh dhcp server dump (replayable)'
    netsh dhcp server dump
}

# ---------------------------------------------------------------------------
Add-Section 'DNS' {
    if (-not (Test-FeatureInstalled 'DNS')) { return 'DNS role not installed.' }

    Add-Heading 'Forwarders'
    Get-DnsServerForwarder | Format-List IPAddress, UseRootHint, Timeout

    Add-Heading 'Zones'
    Get-DnsServerZone | Format-Table ZoneName, ZoneType, IsDsIntegrated,
        IsAutoCreated, IsReverseLookupZone -AutoSize

    foreach ($zone in (Get-DnsServerZone |
             Where-Object { -not $_.IsAutoCreated -and $_.ZoneType -eq 'Primary' })) {
        Add-Heading "Zone: $($zone.ZoneName) -- all records"
        Get-DnsServerResourceRecord -ZoneName $zone.ZoneName |
            Format-Table HostName, RecordType, TimeToLive,
                @{n='Data';e={$_.RecordData.PSObject.Properties |
                    Where-Object { $_.Name -notmatch '^(Cim|PS)' } |
                    ForEach-Object { $_.Value } }} -AutoSize
    }
}

# ---------------------------------------------------------------------------
Add-Section 'ACTIVE DIRECTORY' {
    if ((Get-CimInstance Win32_ComputerSystem).DomainRole -lt 4) {
        return 'This machine is not a domain controller.'
    }
    Import-Module ActiveDirectory

    Add-Heading 'Domain / Forest'
    Get-ADDomain | Format-List Name, DNSRoot, NetBIOSName, DomainMode,
        PDCEmulator, InfrastructureMaster, RIDMaster
    Get-ADForest | Format-List Name, ForestMode, SchemaMaster,
        DomainNamingMaster, GlobalCatalogs

    Add-Heading 'Users'
    Get-ADUser -Filter * -Properties DisplayName, Enabled,
        PasswordNeverExpires, LastLogonDate, Description |
        Sort-Object SamAccountName |
        Format-Table SamAccountName, DisplayName, Enabled,
            PasswordNeverExpires, LastLogonDate, Description -AutoSize

    Add-Heading 'Groups and members'
    foreach ($g in (Get-ADGroup -Filter * | Sort-Object SamAccountName)) {
        $members = (Get-ADGroupMember -Identity $g -ErrorAction SilentlyContinue |
            ForEach-Object { $_.SamAccountName }) -join ', '
        if ($members) { "{0}: {1}" -f $g.SamAccountName, $members }
    }

    Add-Heading 'Computers'
    Get-ADComputer -Filter * -Properties OperatingSystem, IPv4Address,
        LastLogonDate |
        Sort-Object Name |
        Format-Table Name, DNSHostName, OperatingSystem, IPv4Address,
            Enabled, LastLogonDate -AutoSize

    Add-Heading 'Organizational units'
    Get-ADOrganizationalUnit -Filter * |
        Format-Table Name, DistinguishedName -AutoSize

    Add-Heading 'GPOs (names only -- use Backup-GPO for restorable copies)'
    if (Get-Module -ListAvailable GroupPolicy) {
        Get-GPO -All | Format-Table DisplayName, Id, GpoStatus,
            ModificationTime -AutoSize
    }

    'NOTE: this listing documents AD; it is not a restorable backup.'
    'For a restorable DC: wbadmin start systemstatebackup -backupTarget:<drive>'
}

# ---------------------------------------------------------------------------
Add-Section 'SHARES & NTFS ACLS' {
    $shares = @(Get-SmbShare | Where-Object { -not $_.Special })
    if ($shares.Count -eq 0) { return 'No non-administrative shares.' }

    Add-Heading 'Shares'
    $shares | Format-Table Name, Path, Description -AutoSize

    foreach ($s in $shares) {
        Add-Heading "Share '$($s.Name)' -- share-level access"
        Get-SmbShareAccess -Name $s.Name |
            Format-Table AccountName, AccessControlType, AccessRight -AutoSize

        if ($s.Path -and (Test-Path $s.Path)) {
            Add-Heading "Share '$($s.Name)' -- NTFS ACL on $($s.Path)"
            icacls $s.Path
        }
    }
}

# ---------------------------------------------------------------------------
Add-Section 'LOCAL USERS & GROUPS' {
    Add-Heading 'Users'
    Get-LocalUser | Format-Table Name, Enabled, PasswordExpires,
        LastLogon, Description -AutoSize

    Add-Heading 'Groups and members'
    foreach ($g in Get-LocalGroup) {
        $members = (Get-LocalGroupMember -Group $g.Name `
            -ErrorAction SilentlyContinue |
            ForEach-Object { $_.Name }) -join ', '
        if ($members) { "{0}: {1}" -f $g.Name, $members }
    }
}

# ---------------------------------------------------------------------------
Add-Section 'INSTALLED SOFTWARE' {
    # Uninstall registry keys (both bitness views) -- Win32_Product is
    # deliberately avoided: enumerating it reconfigures MSI packages.
    $keys = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
    )
    Get-ItemProperty $keys -ErrorAction SilentlyContinue |
        Where-Object DisplayName |
        Sort-Object DisplayName -Unique |
        Format-Table DisplayName, DisplayVersion, Publisher,
            InstallLocation -AutoSize
}

# ---------------------------------------------------------------------------
Add-Section 'ODBC DSNS' {
    Get-OdbcDsn -ErrorAction SilentlyContinue |
        Format-List Name, DsnType, Platform, DriverName, Attribute
}

# ---------------------------------------------------------------------------
Add-Section 'SERVICES' {
    $svcs = Get-CimInstance Win32_Service

    Add-Heading 'Services running under custom accounts (re-establish these!)'
    $builtin = '^(LocalSystem|NT AUTHORITY\\(LocalService|NetworkService|System))$'
    $svcs | Where-Object { $_.StartName -and $_.StartName -notmatch $builtin } |
        Format-Table Name, StartName, StartMode, State, PathName -AutoSize

    Add-Heading 'All services'
    $svcs | Sort-Object Name |
        Format-Table Name, DisplayName, StartMode, State, StartName -AutoSize
}

# ---------------------------------------------------------------------------
Add-Section 'SCHEDULED TASKS (non-Microsoft)' {
    $tasks = Get-ScheduledTask |
        Where-Object { $_.TaskPath -notlike '\Microsoft\*' }

    Add-Heading 'Inventory'
    $tasks | Format-Table TaskPath, TaskName, State,
        @{n='UserId';e={$_.Principal.UserId}},
        @{n='RunLevel';e={$_.Principal.RunLevel}} -AutoSize

    # Full XML inline: paste into a .xml file and
    # `Register-ScheduledTask -Xml (Get-Content file -Raw)` re-creates it.
    foreach ($t in $tasks) {
        Add-Heading "Task XML: $($t.TaskPath)$($t.TaskName)"
        Export-ScheduledTask -TaskName $t.TaskName -TaskPath $t.TaskPath
    }
}

# ---------------------------------------------------------------------------
Add-Section 'PRINTERS' {
    Add-Heading 'Queues'
    Get-Printer | Format-Table Name, DriverName, PortName, Shared,
        ShareName, Location -AutoSize

    Add-Heading 'Ports'
    Get-PrinterPort | Format-Table Name, PrinterHostAddress, PortNumber,
        Description -AutoSize

    Add-Heading 'Drivers'
    Get-PrinterDriver | Format-Table Name, Manufacturer, DriverVersion,
        InfPath -AutoSize
}

# ---------------------------------------------------------------------------
Add-Section 'CERTIFICATES (LocalMachine\My -- inventory only)' {
    Get-ChildItem Cert:\LocalMachine\My |
        Format-Table Subject, NotAfter, HasPrivateKey, Thumbprint -AutoSize
    'Certs with HasPrivateKey=True need a manual PFX export if still required.'
}

# ---------------------------------------------------------------------------
Write-Host ''
Write-Host "Report written to: $Report" -ForegroundColor Green
