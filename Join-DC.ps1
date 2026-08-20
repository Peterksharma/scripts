# ============================================================
#  Domain join - run ELEVATED on the target laptop, on-network
#  Domain: int.arteagas.com  |  DC: 10.27.114.17
#  Keeps existing hostname. Computer object -> default CN=Computers.
# ============================================================

$Domain = "int.arteagas.com"
$DCip   = "10.27.114.17"
$Name   = $env:COMPUTERNAME

Write-Host "Target machine name: $Name" -ForegroundColor Cyan

# 1. DNS at the DC for the join
$adapter = (Get-NetAdapter | Where-Object Status -eq 'Up' | Select-Object -First 1).Name
Write-Host "Setting DNS on '$adapter' to $DCip ..." -ForegroundColor Cyan
Set-DnsClientServerAddress -InterfaceAlias $adapter -ServerAddresses $DCip

# 2. Confirm DC reachable
nltest /dsgetdc:$Domain
if ($LASTEXITCODE -ne 0) {
    Write-Host "DC not reachable - check network/VLAN/DNS." -ForegroundColor Red
    return
}
Write-Host "DC reachable.`n" -ForegroundColor Green

# 3. Credentials
$cred = Get-Credential -Message "Enter domain join account (INT\username)"

# 4. Join (no OU specified -> lands in CN=Computers like the other 62)
Add-Computer -DomainName $Domain -Credential $cred -Force -Restart:$false

# 5. Verify
$cs = Get-CimInstance Win32_ComputerSystem
"PartOfDomain : $($cs.PartOfDomain)"
"Domain       : $($cs.Domain)"
Write-Host "`nAfter reboot, log in with a DOMAIN account (INT\user), not local." -ForegroundColor Yellow
Write-Host "Reboot to complete: Restart-Computer -Force" -ForegroundColor Yellow