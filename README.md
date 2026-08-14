# Server rebuild kit

Recovering the crashed store server from its virtual backup.

## Phase 1 — dump

Two equivalent collectors; pick by output format:

- **`Dump-ServerConfig.ps1`** — everything in **one readable TXT**
  (`C:\ServerDump\<hostname>-<timestamp>.txt`). DHCP is embedded as a
  replayable `netsh dhcp server dump`, scheduled-task XML and ACLs inline.
- **`Export-ServerConfig.ps1`** — folder-per-section dump + zip, including
  binary reimportables (DHCP XML, firewall `.wfw`, printbrm archive).

Run either **elevated** on the server (or its booted backup VM):

```powershell
Set-ExecutionPolicy -Scope Process Bypass -Force
.\Dump-ServerConfig.ps1                  # full dump (on the real server)
.\Dump-ServerConfig.ps1 -SkipNetwork     # on the backup VM: skip its
                                         # non-authoritative network config
# or .\Export-ServerConfig.ps1 for the folder/zip variant
```

Plan for this recovery: run `-SkipNetwork` on the VM now; capture the
NETWORK section from the physical server later.

Single-file output: `C:\ServerDump\<hostname>-<timestamp>.txt` — copy it off.
Folder-export output: `C:\ServerDump\<hostname>-<timestamp>\` + a `.zip`;
check `_sections.csv` for any FAILED sections and `transcript.txt` for detail.

What the folder export contains (the TXT covers the same ground inline):

| Folder | Contents | Restorable? |
|---|---|---|
| `identity/` | hostname, domain role, OS build, time zone | reference |
| `network/` | IPs, routes, DNS client, hosts, SMB config, firewall `.wfw` | firewall `.wfw` reimports via `netsh advfirewall import` |
| `roles/` | installed features + bare name list | feeds `Install-WindowsFeature` |
| `dhcp/` | `dhcp-full-export.xml` (scopes/options/reservations/leases) | **yes** — `Import-DhcpServer` |
| `dns/` | zone files, settings, forwarders | zone files drop into `System32\dns` |
| `ad/` | users/groups/OUs/computers CSVs, GPO backups | CSVs are reference only; GPOs restore via `Import-GPO`. See `AD-README.txt` |
| `shares/` | share defs, share ACLs, NTFS root ACLs (`icacls /save`) | **yes** — `New-SmbShare` + `icacls /restore` |
| `users/` | local users/groups/membership | scriptable (passwords not exportable) |
| `apps/` | installed software list, ODBC DSNs | reference / reinstall checklist |
| `services/` | all services + shortlist running under custom accounts | reference |
| `tasks/` | task inventory + per-task XML (non-Microsoft) | **yes** — `Register-ScheduledTask -Xml` |
| `printers/` | queues/ports/drivers + `printers.printerExport` | **yes** — `printbrm -r` |
| `certs/` | LocalMachine\My inventory (no private keys) | flags certs needing manual PFX export |

**If the VM is a domain controller:** the CSVs document AD but do not restore
it. Before the VM goes away, also run
`wbadmin start systemstatebackup -backupTarget:<drive>` for a real AD backup.

## Phase 2 — install scripts (next)

Once the dump exists, the install scripts get written against its actual
contents (static IP + DNS, features, DHCP import, shares + ACLs, tasks,
printers, firewall).
