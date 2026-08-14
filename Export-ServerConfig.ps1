<#
.SYNOPSIS
    Export-ServerConfig.ps1 -- full configuration dump of a Windows Server
    (2016-2025) into one timestamped, zipped folder.

.DESCRIPTION
    Run this ELEVATED on the (virtual backup of the) server. It collects,
    in independent sections that each survive their own failures:

      identity   hostname, domain role, OS build, time zone
      network    adapters, IP config, routes, DNS client, hosts file,
                 SMB server/client config, firewall (reimportable .wfw
                 + readable CSV)
      roles      installed Windows features
      dhcp       full reimportable DHCP export (scopes + leases)
      dns        zone files, server settings, forwarders
      ad         domain/forest info, users/groups/OUs/computers as CSV,
                 GPO backups (reference data -- see AD-README in dump)
      shares     SMB shares + share ACLs + NTFS ACLs (icacls /save format)
      users      local users, groups, group memberships
      apps       installed software (both registry views), ODBC DSNs
      services   every service: startup type, logon account, binary path
      tasks      scheduled task inventory + per-task XML (non-Microsoft)
      printers   queues/ports/drivers CSV + reimportable printbrm backup
      certs      LocalMachine\My inventory (no private keys -- listed only)

    Output: C:\ServerDump\<hostname>-<yyyyMMdd-HHmmss>\  and a .zip of it.
    A transcript (transcript.txt) and a per-section status table
    (_sections.csv) record exactly what succeeded.

    Invariant: the script only READS system state; the sole writes are into
    the dump folder (and printbrm/DHCP export files, which are exports).

.NOTES
    Target: Windows PowerShell 5.1 (Server default shell). No modules are
    assumed beyond the ones the installed roles themselves provide; every
    role-specific section first checks that the role is present.

.EXAMPLE
    PS C:\> Set-ExecutionPolicy -Scope Process Bypass -Force
    PS C:\> .\Export-ServerConfig.ps1
#>

#Requires -RunAsAdministrator

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
# 0. Dump folder skeleton
# ---------------------------------------------------------------------------
$hostName  = $env:COMPUTERNAME
$stamp     = Get-Date -Format 'yyyyMMdd-HHmmss'
$DumpRoot  = Join-Path 'C:\ServerDump' "$hostName-$stamp"

# One subfolder per section keeps the dump navigable by hand later.
$Dirs = @{}
foreach ($d in 'identity','network','roles','dhcp','dns','ad','shares',
               'users','apps','services','tasks','printers','certs') {
    $Dirs[$d] = Join-Path $DumpRoot $d
    New-Item -ItemType Directory -Path $Dirs[$d] -Force | Out-Null
}

Start-Transcript -Path (Join-Path $DumpRoot 'transcript.txt') | Out-Null

# ---------------------------------------------------------------------------
# Section runner: each section is a named scriptblock executed in try/catch,
# so a missing role or a flaky cmdlet never aborts the rest of the dump.
# The status of every section is tabulated into _sections.csv at the end.
# ---------------------------------------------------------------------------
$SectionResults = New-Object System.Collections.ArrayList

function Invoke-Section {
    param(
        [Parameter(Mandatory)][string]      $Name,
        [Parameter(Mandatory)][scriptblock] $Body
    )
    Write-Host "==> $Name" -ForegroundColor Cyan
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    try {
        & $Body
        $status = 'OK'; $err = ''
    } catch {
        $status = 'FAILED'; $err = $_.Exception.Message
        Write-Warning "Section '$Name' failed: $err"
    }
    $sw.Stop()
    [void]$SectionResults.Add([pscustomobject]@{
        Section = $Name; Status = $status
        Seconds = [math]::Round($sw.Elapsed.TotalSeconds, 1); Error = $err
    })
}

# Small helpers ------------------------------------------------------------

function Out-Dump {
    # Save piped objects both as JSON (machine-readable, for the install
    # scripts) and as a formatted-list TXT (human-readable). Pipeline input
    # is accumulated in the process block -- without it, only the final
    # piped object would survive.
    param(
        [Parameter(Mandatory)][string] $Dir,
        [Parameter(Mandatory)][string] $BaseName,
        [Parameter(ValueFromPipeline)] $Data,
        [int] $Depth = 6
    )
    begin   { $items = New-Object System.Collections.ArrayList }
    process { if ($null -ne $Data) { [void]$items.Add($Data) } }
    end {
        $items | ConvertTo-Json -Depth $Depth |
            Set-Content -Path (Join-Path $Dir "$BaseName.json") -Encoding UTF8
        $items | Format-List * | Out-String -Width 300 |
            Set-Content -Path (Join-Path $Dir "$BaseName.txt") -Encoding UTF8
    }
}

function Test-FeatureInstalled {
    param([Parameter(Mandatory)][string] $FeatureName)
    $f = Get-WindowsFeature -Name $FeatureName -ErrorAction SilentlyContinue
    return ($null -ne $f -and $f.Installed)
}

# ---------------------------------------------------------------------------
# 1. Identity
# ---------------------------------------------------------------------------
Invoke-Section 'identity' {
    $cs = Get-CimInstance Win32_ComputerSystem
    $os = Get-CimInstance Win32_OperatingSystem
    # DomainRole: 0/1 workgroup, 2/3 member, 4 BDC, 5 PDC-emulator (DC).
    [pscustomobject]@{
        ComputerName = $cs.Name
        Domain       = $cs.Domain
        PartOfDomain = $cs.PartOfDomain
        DomainRole   = $cs.DomainRole
        OSCaption    = $os.Caption
        OSVersion    = $os.Version
        OSBuild      = $os.BuildNumber
        InstallDate  = $os.InstallDate
        LastBoot     = $os.LastBootUpTime
        TimeZone     = (tzutil /g)
    } | Out-Dump -Dir $Dirs.identity -BaseName 'computer'

    systeminfo.exe | Set-Content (Join-Path $Dirs.identity 'systeminfo.txt')
}

# ---------------------------------------------------------------------------
# 2. Network -- the part you most need to recreate exactly.
# ---------------------------------------------------------------------------
Invoke-Section 'network' {
    $d = $Dirs.network

    Get-NetAdapter | Select-Object Name, InterfaceDescription, ifIndex,
        MacAddress, Status, LinkSpeed |
        Out-Dump -Dir $d -BaseName 'adapters'

    # IP addresses with prefix lengths -- JSON is authoritative; the
    # -Detailed text form is the readable cross-check.
    Get-NetIPAddress | Select-Object InterfaceAlias, InterfaceIndex,
        AddressFamily, IPAddress, PrefixLength, PrefixOrigin |
        Out-Dump -Dir $d -BaseName 'ip-addresses'
    Get-NetIPConfiguration -Detailed | Out-String -Width 300 |
        Set-Content (Join-Path $d 'ipconfig-detailed.txt')
    ipconfig /all | Set-Content (Join-Path $d 'ipconfig-all.txt')

    # Non-link-local routes: default gateway(s) and any statics live here.
    Get-NetRoute -AddressFamily IPv4 |
        Where-Object { $_.NextHop -ne '0.0.0.0' } |
        Select-Object DestinationPrefix, NextHop, InterfaceAlias,
            RouteMetric, ifMetric |
        Out-Dump -Dir $d -BaseName 'routes'

    Get-DnsClientServerAddress |
        Select-Object InterfaceAlias, AddressFamily, ServerAddresses |
        Out-Dump -Dir $d -BaseName 'dns-client-servers'
    Get-DnsClientGlobalSetting | Out-Dump -Dir $d -BaseName 'dns-client-global'

    Copy-Item "$env:SystemRoot\System32\drivers\etc\hosts" `
        (Join-Path $d 'hosts') -ErrorAction SilentlyContinue

    Get-SmbServerConfiguration | Out-Dump -Dir $d -BaseName 'smb-server-config'
    Get-SmbClientConfiguration | Out-Dump -Dir $d -BaseName 'smb-client-config'

    # Firewall: the .wfw is binary and reimportable with
    #   netsh advfirewall import; the CSV is for reading. Only enabled
    #   rules go in the CSV -- the .wfw carries everything regardless.
    netsh advfirewall export (Join-Path $d 'firewall-policy.wfw') | Out-Null
    Get-NetFirewallProfile | Out-Dump -Dir $d -BaseName 'firewall-profiles'
    Get-NetFirewallRule | Where-Object Enabled -eq 'True' |
        Select-Object Name, DisplayName, Direction, Action, Profile |
        Export-Csv (Join-Path $d 'firewall-rules-enabled.csv') -NoTypeInformation
}

# ---------------------------------------------------------------------------
# 3. Installed roles & features -- the checklist for the rebuild.
# ---------------------------------------------------------------------------
Invoke-Section 'roles' {
    $installed = Get-WindowsFeature | Where-Object Installed |
        Select-Object Name, DisplayName, FeatureType, Path
    $installed | Out-Dump -Dir $Dirs.roles -BaseName 'installed-features'
    # Bare name list -- feed straight into Install-WindowsFeature later.
    $installed | Select-Object -ExpandProperty Name |
        Set-Content (Join-Path $Dirs.roles 'feature-names.txt')
}

# ---------------------------------------------------------------------------
# 4. DHCP -- Export-DhcpServer produces a file Import-DhcpServer can
#    replay verbatim on the new box (scopes, options, reservations, leases).
# ---------------------------------------------------------------------------
Invoke-Section 'dhcp' {
    if (-not (Test-FeatureInstalled 'DHCP')) {
        Set-Content (Join-Path $Dirs.dhcp 'NOT-INSTALLED.txt') `
            'DHCP Server role is not installed on this machine.'
        return
    }
    Export-DhcpServer -ComputerName $env:COMPUTERNAME `
        -File (Join-Path $Dirs.dhcp 'dhcp-full-export.xml') -Leases -Force

    # Readable summaries alongside the authoritative XML:
    Get-DhcpServerv4Scope | Out-Dump -Dir $Dirs.dhcp -BaseName 'scopes'
    Get-DhcpServerv4Scope | ForEach-Object {
        Get-DhcpServerv4Reservation -ScopeId $_.ScopeId -ErrorAction SilentlyContinue
    } | Out-Dump -Dir $Dirs.dhcp -BaseName 'reservations'
    Get-DhcpServerv4OptionValue -ErrorAction SilentlyContinue |
        Out-Dump -Dir $Dirs.dhcp -BaseName 'server-options'
}

# ---------------------------------------------------------------------------
# 5. DNS -- zone files are the canonical restore artifact; settings and
#    forwarders come along as JSON.
# ---------------------------------------------------------------------------
Invoke-Section 'dns' {
    if (-not (Test-FeatureInstalled 'DNS')) {
        Set-Content (Join-Path $Dirs.dns 'NOT-INSTALLED.txt') `
            'DNS Server role is not installed on this machine.'
        return
    }
    Get-DnsServerSetting | Out-Dump -Dir $Dirs.dns -BaseName 'server-settings'
    Get-DnsServerForwarder | Out-Dump -Dir $Dirs.dns -BaseName 'forwarders'
    Get-DnsServerZone | Out-Dump -Dir $Dirs.dns -BaseName 'zones'

    # Export-DnsServerZone writes only into %SystemRoot%\System32\dns,
    # so export there first, then copy into the dump. AD-integrated zones
    # export fine this way (as a standard zone-file snapshot).
    $sysDns = Join-Path $env:SystemRoot 'System32\dns'
    Get-DnsServerZone |
        Where-Object { -not $_.IsAutoCreated -and $_.ZoneType -eq 'Primary' } |
        ForEach-Object {
            $file = "export-$($_.ZoneName).dns"
            Remove-Item (Join-Path $sysDns $file) -ErrorAction SilentlyContinue
            Export-DnsServerZone -Name $_.ZoneName -FileName $file
            Copy-Item (Join-Path $sysDns $file) $Dirs.dns
        }
}

# ---------------------------------------------------------------------------
# 6. Active Directory -- reference data only. A domain controller is NOT
#    rebuilt from CSVs; it is restored from a System State backup or
#    re-promoted and repopulated. These exports document what exists.
# ---------------------------------------------------------------------------
Invoke-Section 'ad' {
    $isDC = (Get-CimInstance Win32_ComputerSystem).DomainRole -ge 4
    if (-not $isDC) {
        Set-Content (Join-Path $Dirs.ad 'NOT-A-DC.txt') `
            'This machine is not a domain controller; AD section skipped.'
        return
    }
    Import-Module ActiveDirectory

    Get-ADDomain | Out-Dump -Dir $Dirs.ad -BaseName 'domain'
    Get-ADForest | Out-Dump -Dir $Dirs.ad -BaseName 'forest'

    Get-ADUser -Filter * -Properties DisplayName, EmailAddress, Enabled,
        MemberOf, PasswordNeverExpires, LastLogonDate, Description |
        Select-Object SamAccountName, DisplayName, EmailAddress, Enabled,
            PasswordNeverExpires, LastLogonDate, Description,
            @{n='MemberOf';e={($_.MemberOf | ForEach-Object {
                ($_ -split ',')[0] -replace '^CN=' }) -join ';' }} |
        Export-Csv (Join-Path $Dirs.ad 'users.csv') -NoTypeInformation

    Get-ADGroup -Filter * -Properties Description |
        Select-Object SamAccountName, GroupCategory, GroupScope, Description |
        Export-Csv (Join-Path $Dirs.ad 'groups.csv') -NoTypeInformation

    Get-ADComputer -Filter * -Properties OperatingSystem, LastLogonDate,
        IPv4Address, Description |
        Select-Object Name, DNSHostName, OperatingSystem, IPv4Address,
            Enabled, LastLogonDate, Description |
        Export-Csv (Join-Path $Dirs.ad 'computers.csv') -NoTypeInformation

    Get-ADOrganizationalUnit -Filter * |
        Select-Object Name, DistinguishedName |
        Export-Csv (Join-Path $Dirs.ad 'ous.csv') -NoTypeInformation

    # GPOs ARE properly restorable from Backup-GPO output.
    if (Get-Module -ListAvailable GroupPolicy) {
        $gpoDir = Join-Path $Dirs.ad 'gpo-backups'
        New-Item -ItemType Directory -Path $gpoDir -Force | Out-Null
        Backup-GPO -All -Path $gpoDir | Select-Object DisplayName, Id |
            Export-Csv (Join-Path $Dirs.ad 'gpo-index.csv') -NoTypeInformation
    }

    Set-Content (Join-Path $Dirs.ad 'AD-README.txt') @'
These CSVs document the directory; they are NOT a restorable AD backup.
To preserve a restorable copy of this DC, also run on this VM:
    wbadmin start systemstatebackup -backupTarget:<drive-or-UNC>
GPO backups in gpo-backups\ ARE restorable via Import-GPO / Restore-GPO.
'@
}

# ---------------------------------------------------------------------------
# 7. Shares -- share definitions, share-level ACLs, and NTFS ACLs of each
#    shared tree root in icacls /save format (replayable with /restore).
# ---------------------------------------------------------------------------
Invoke-Section 'shares' {
    $d = $Dirs.shares
    $shares = @(Get-SmbShare | Where-Object { -not $_.Special })
    if ($shares.Count -eq 0) {
        Set-Content (Join-Path $d 'NO-SHARES.txt') 'No non-administrative SMB shares exist.'
        return
    }
    $shares | Select-Object Name, Path, Description, FolderEnumerationMode,
        EncryptData, ConcurrentUserLimit |
        Out-Dump -Dir $d -BaseName 'smb-shares'
    $shares | ForEach-Object {
        Get-SmbShareAccess -Name $_.Name -ErrorAction SilentlyContinue
    } | Select-Object Name, AccountName, AccessControlType, AccessRight |
        Out-Dump -Dir $d -BaseName 'smb-share-access'

    foreach ($s in $shares) {
        if ($s.Path -and (Test-Path $s.Path)) {
            $safe = $s.Name -replace '[^\w\-]', '_'
            # icacls /save on the root (not /t): the top-level ACL is what
            # the install script must re-seed; inheritance does the rest.
            icacls $s.Path /save (Join-Path $d "ntfs-acl-$safe.icacls") |
                Out-Null
        }
    }
}

# ---------------------------------------------------------------------------
# 8. Local users & groups
# ---------------------------------------------------------------------------
Invoke-Section 'users' {
    Get-LocalUser | Select-Object Name, Enabled, Description,
        PasswordExpires, LastLogon, SID |
        Out-Dump -Dir $Dirs.users -BaseName 'local-users'
    Get-LocalGroup | Select-Object Name, Description, SID |
        Out-Dump -Dir $Dirs.users -BaseName 'local-groups'

    # Group -> members map; membership is the part share ACLs depend on.
    $membership = foreach ($g in Get-LocalGroup) {
        foreach ($m in (Get-LocalGroupMember -Group $g.Name -ErrorAction SilentlyContinue)) {
            [pscustomobject]@{
                Group = $g.Name; Member = $m.Name
                Class = $m.ObjectClass; Source = $m.PrincipalSource
            }
        }
    }
    @($membership) | Where-Object { $_ } |
        Export-Csv (Join-Path $Dirs.users 'group-membership.csv') -NoTypeInformation
}

# ---------------------------------------------------------------------------
# 9. Installed applications + ODBC DSNs
# ---------------------------------------------------------------------------
Invoke-Section 'apps' {
    # The Uninstall registry keys (64- and 32-bit views) are the reliable
    # inventory; Win32_Product is avoided (it re-configures MSI packages
    # as a side effect of enumeration).
    $keys = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
    )
    Get-ItemProperty $keys -ErrorAction SilentlyContinue |
        Where-Object DisplayName |
        Select-Object DisplayName, DisplayVersion, Publisher, InstallDate,
            InstallLocation, UninstallString |
        Sort-Object DisplayName |
        Export-Csv (Join-Path $Dirs.apps 'installed-software.csv') -NoTypeInformation

    Get-OdbcDsn -ErrorAction SilentlyContinue |
        Select-Object Name, DsnType, Platform, DriverName,
            @{n='Attributes';e={($_.Attribute.GetEnumerator() |
                ForEach-Object { "$($_.Key)=$($_.Value)" }) -join '; '}} |
        Out-Dump -Dir $Dirs.apps -BaseName 'odbc-dsns'
}

# ---------------------------------------------------------------------------
# 10. Services -- startup type and, critically, non-default logon accounts.
# ---------------------------------------------------------------------------
Invoke-Section 'services' {
    $svcs = Get-CimInstance Win32_Service |
        Select-Object Name, DisplayName, State, StartMode, StartName, PathName
    $svcs | Export-Csv (Join-Path $Dirs.services 'services.csv') -NoTypeInformation
    # Shortlist: services running as a real account -- these need their
    # credentials and rights re-established on the new server.
    $builtin = '^(LocalSystem|NT AUTHORITY\\(LocalService|NetworkService|System))$'
    $svcs | Where-Object { $_.StartName -and $_.StartName -notmatch $builtin } |
        Export-Csv (Join-Path $Dirs.services 'services-custom-accounts.csv') `
            -NoTypeInformation
}

# ---------------------------------------------------------------------------
# 11. Scheduled tasks -- full inventory CSV + per-task XML for every task
#     outside \Microsoft\ (XML re-registers directly on the new server).
# ---------------------------------------------------------------------------
Invoke-Section 'tasks' {
    $all = Get-ScheduledTask
    $all | Select-Object TaskPath, TaskName, State,
        @{n='Author';e={$_.Author}},
        @{n='UserId';e={$_.Principal.UserId}},
        @{n='RunLevel';e={$_.Principal.RunLevel}} |
        Export-Csv (Join-Path $Dirs.tasks 'all-tasks.csv') -NoTypeInformation

    $xmlDir = Join-Path $Dirs.tasks 'xml'
    New-Item -ItemType Directory -Path $xmlDir -Force | Out-Null
    foreach ($t in ($all | Where-Object { $_.TaskPath -notlike '\Microsoft\*' })) {
        $safe = ($t.TaskPath + $t.TaskName) -replace '[\\/:*?"<>|]', '_'
        Export-ScheduledTask -TaskName $t.TaskName -TaskPath $t.TaskPath |
            Set-Content (Join-Path $xmlDir "$safe.xml") -Encoding Unicode
    }
}

# ---------------------------------------------------------------------------
# 12. Printers -- CSV inventory plus a printbrm archive, which restores
#     queues, ports, AND drivers in one shot on the new server.
# ---------------------------------------------------------------------------
Invoke-Section 'printers' {
    $d = $Dirs.printers
    Get-Printer | Select-Object Name, DriverName, PortName, Shared,
        ShareName, Published, Location, Comment |
        Out-Dump -Dir $d -BaseName 'printers'
    Get-PrinterPort | Select-Object Name, PrinterHostAddress, PortNumber,
        Description |
        Out-Dump -Dir $d -BaseName 'printer-ports'
    Get-PrinterDriver | Select-Object Name, Manufacturer,
        DriverVersion, InfPath |
        Out-Dump -Dir $d -BaseName 'printer-drivers'

    $brm = Join-Path $env:SystemRoot 'System32\spool\tools\printbrm.exe'
    if (Test-Path $brm) {
        & $brm -b -f (Join-Path $d 'printers.printerExport') |
            Set-Content (Join-Path $d 'printbrm-log.txt')
    }
}

# ---------------------------------------------------------------------------
# 13. Certificates -- inventory only. Private keys are deliberately NOT
#     exported by an unattended script; the inventory tells you which
#     certs (if any) need a manual PFX export before the VM goes away.
# ---------------------------------------------------------------------------
Invoke-Section 'certs' {
    Get-ChildItem Cert:\LocalMachine\My |
        Select-Object Subject, Issuer, Thumbprint, NotBefore, NotAfter,
            HasPrivateKey, @{n='DnsNames';e={$_.DnsNameList -join '; '}} |
        Out-Dump -Dir $Dirs.certs -BaseName 'machine-personal-store'
}

# ---------------------------------------------------------------------------
# Finish: status table, transcript, zip.
# ---------------------------------------------------------------------------
$SectionResults |
    Export-Csv (Join-Path $DumpRoot '_sections.csv') -NoTypeInformation
$SectionResults | Format-Table -AutoSize | Out-String | Write-Host

Stop-Transcript | Out-Null

$zip = "$DumpRoot.zip"
Compress-Archive -Path $DumpRoot -DestinationPath $zip -Force

Write-Host ''
Write-Host "Dump folder : $DumpRoot"           -ForegroundColor Green
Write-Host "Zip archive : $zip"                -ForegroundColor Green
$failed = @($SectionResults | Where-Object Status -eq 'FAILED')
if ($failed.Count -gt 0) {
    Write-Warning ("Sections with errors: " + ($failed.Section -join ', ') +
        " -- see transcript.txt and _sections.csv")
} else {
    Write-Host 'All sections completed cleanly.' -ForegroundColor Green
}
