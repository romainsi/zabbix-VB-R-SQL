# VEEAM-B&R-SQL

## Contents
- [Description](#description)
- [Features](#features)
- [Requirements](#requirements)
- [Setup](#setup)
- [Configuration File](#configuration-file)
- [Zabbix Configuration](#zabbix-configuration)
- [Items](#items)
- [Discovery](#discovery)
- [Triggers](#triggers)

---

## Description
This template uses SQL queries to retrieve Veeam Backup & Replication job and repository data and sends it to Zabbix using a PowerShell script.

The script supports both:
- Microsoft SQL Server (native .NET provider)
- PostgreSQL (via ODBC)

The script outputs JSON for discovery and dependent items.

---

## Features
- Supports Veeam Backup & Replication v11 → v13
- Supports Zabbix 7.x
- Multi-database support:
  - SQL Server (integrated or SQL authentication)
  - PostgreSQL (ODBC driver required)
- Automatic Low-Level Discovery (LLD):
  - Jobs
  - Repositories
- Secure credential handling via external config file
- No hardcoded credentials in script
- Template available in US English (en-us) and French (fr-fr)

---

## Requirements
- Zabbix Agent or Zabbix Agent 2
- PowerShell 5.1+
- Network access to Veeam database

### For SQL Server
- TCP/IP enabled
- SQL authentication (optional)

### For PostgreSQL
- PostgreSQL ODBC driver:
  https://www.postgresql.org/ftp/odbc/versions/msi/

---

## Setup

### 1. Database Access

#### SQL Server
```sql
USE [VeeamBackup]
CREATE LOGIN [zabbixveeam] WITH PASSWORD = N'CHANGEME', CHECK_POLICY = OFF, CHECK_EXPIRATION = OFF;
CREATE USER [zabbixveeam] FOR LOGIN [zabbixveeam];
EXEC sp_addrolemember 'db_datareader', 'zabbixveeam';
GO
```

#### PostgreSQL
```sql
CREATE USER zabbixveeam WITH PASSWORD 'CHANGEME';
GRANT CONNECT ON DATABASE "VeeamBackup" TO zabbixveeam;
GRANT USAGE ON SCHEMA public TO zabbixveeam;
GRANT SELECT ON ALL TABLES IN SCHEMA public TO zabbixveeam;
```

---

### 2. Script Deployment
Copy script:
```
zabbix_vbr_job.ps1
```
to:
```
C:\Program Files\Zabbix Agent\scripts\
```

---

### 3. Create Configuration File

Create file:
```
zabbix_vbr.conf
```

Place it in the same directory as the script.

---

## Configuration File

### SQL Server Example
```ini
SQLServer=SQLSERVER\INSTANCE
SQLDatabase=VeeamBackup
SQLIntegratedSecurity=false
SQLUsername=zabbixveeam
SQLPassword=CHANGEME
DBProvider=SqlServer
```

### PostgreSQL Example
```ini
SQLServer=localhost
SQLPort=5432
SQLDatabase=VeeamBackup
SQLIntegratedSecurity=false
SQLUsername=postgres
SQLPassword=CHANGEME
DBProvider=Postgres
```

---

### Secure the file
```powershell
$path = "zabbix_vbr.conf"
$acl = Get-Acl $path
$acl.SetAccessRuleProtection($true,$false)
$acl.SetAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule("SYSTEM","FullControl","Allow")))
$acl.SetAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule("BUILTIN\Administrators","FullControl","Allow")))
Set-Acl $path $acl
```

---

## Zabbix Configuration

Add to agent config:

```
UserParameter=veeam.info[*],powershell -NoProfile -ExecutionPolicy Bypass -File "C:\Program Files\Zabbix Agent\scripts\zabbix_vbr_job.ps1" -Config "C:\Program Files\Zabbix Agent\scripts\zabbix_vbr.conf" -Operation "$1"
```

For Zabbix Agent 2 the paths should be, respectively:
* `C:\Program Files\Zabbix Agent 2\scripts\zabbix_vbr_job.ps1`
* `C:\Program Files\Zabbix Agent 2\scripts\zabbix_vbr.conf`

Ajust where applicable.

### Supported keys
- veeam.info[RepoInfo]
- veeam.info[JobsInfo]
- veeam.info[TotalJob]

---

### Import Template
- Import `template_veeam_backup_and_replication_<language>.yaml`
- Link template to host

---

### Timeout tuning
```powershell
(Measure-Command { & "C:\Program Files\Zabbix Agent\scripts\zabbix_vbr_job.ps1" -Operation "JobsInfo" }).TotalSeconds
```

If discovery rules are timing out in Zabbix, increase the Timeout parameter in the Zabbix agent configuration file to 30 seconds. The default Zabbix agent Timeout value is 3 seconds, which may not be sufficient in larger environments.

---

## Items

### Master Items
- Veeam Job Info (JSON)
- Veeam Repository Info (JSON)
- Total number of jobs

---

## Discovery

### Jobs Discovery
Automatically discovers:
- Backup jobs
- Replication jobs
- Tape jobs
- Backup Copy jobs
- Backup Sync jobs
- Agent jobs
- RMAN jobs

### Job Item Prototypes
- Result
- Progress
- Start / End time
- Duration
- Retry status
- Failure reason
- Size metrics
- Speed

---

### Repository Discovery
- Total space
- Free space
- Used space
- Percent free
- Out-of-date status

---

## Triggers

### Global
- No data in RepoInfo
- No data in JobsInfo

### Jobs
- Job failed
- Job failed (with retry)
- Job warning
- Job warning (with retry)
- Job running too long

### Repository
- Low free space (default < 20%)
- Repository out-of-date

---

## Notes
- PostgreSQL support is implemented but not fully tested due to lack of a Veeam environment using PostgreSQL. Feedback and validation are welcome.
- Script supports both SQL Server and PostgreSQL transparently
- PostgreSQL requires ODBC driver
- Config file is mandatory (no inline credentials)
- JSON output is consumed by dependent items

---

## Credits
- Original author: [romainsi](https://github.com/romainsi)

- Contributors:
  - [aholiveira](https://github.com/aholiveira)
  - [xtonousou](https://github.com/xtonousou)

- Acknowledgements:
  - PostgreSQL support was added by adapting the existing SQL Server logic and using community PostgreSQL-related scripts from [aaeMotoko](https://github.com/aaeMotoko) and [smolkik-code](https://github.com/smolkik-code) as reference material. Final implementation (ODBC) was AI-assisted.
---

## Version
3.3
