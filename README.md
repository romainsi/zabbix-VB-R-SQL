# VEEAM-B&R-SQL
## Contents
[Description](#Description)
[Setup](#setup)
[Items](#items)
[Triggers](#triggers)
[Discovery](#discovery-items)
    [Backup items](#backup-items)
    [Backup triggers](#triggers-discovery-veeam-jobs-backup-copy-tape-backupsync)
    [Repository items](#repository-items)
    [Repository triggers](#triggers-discovery-veeam-repository)

## Description
This template use SQL Query to discover VEEAM Backup jobs, Veeam BackupCopy, Veeam BackupSync, Veeam Tape Job, Veeam FileTape, Veeam Agent, Veeam Replication, All Repositories.
Powershell get all informations via SQL and send it to zabbix server/proxy with json.

- Work with Veeam backup & replication V9 to V10 and V11 (actually ok on 11.0.1.1261)
- Work with Zabbix 6.x

## Setup
1. Install the Zabbix agent 2 on your host.
2. Using "Sql Server Configuration Manager", go to "SQL Server Network Configuration", "Protocols for VEEAMSQL2016", "TCP/IP", change "Enabled" to "Yes"
3. Using "Microsoft SQL Server Management Studio", Right-click on "<SERVER>\VEEAMSQL2016", "Properties", "Security", change "Server Authentication" to "SQL Server and Windows Authentication mode"
4. Using "Microsoft SQL Server Management Studio", or with "sqlcmd.exe" (command-line tool), use the following commands to create user `zabbixveeam` and enable access. Change password "CHANGEME" with something more secure).
    ```sql
    USE [VeeamBackup]
    CREATE LOGIN [zabbixveeam] WITH PASSWORD = N'CHANGEME', CHECK_POLICY = OFF, CHECK_EXPIRATION = OFF;
    CREATE USER [zabbixveeam] FOR LOGIN [zabbixveeam];
    EXEC sp_addrolemember 'db_datareader', 'zabbixveeam';
    GO
    ```
5. Modify `zabbix_vbr_job.ps1` and ajust variables line 73 to 78 to match your configuration
6. Copy `zabbix_vbr_job.ps1` in the directory : `C:\Program Files\Zabbix Agent 2\scripts\` (create folder if not doesn't exist)
7. Add `UserParameter=veeam.info[*],powershell -NoProfile -ExecutionPolicy Bypass -File "C:\Program Files\Zabbix Agent 2\scripts\zabbix_vbr_job.ps1" "$1"` in zabbix_agent2.conf  
8. Import Template_Veeam_Backup_And_Replication.yaml file into Zabbix.
9. Associate Template "VEEAM Backup and Replication" to the host.
NOTE: When importing the new template version on an existing installation please check all "Delete missing", except "Template linkage", to make sure the old items are deleted

Ajust Zabbix Agent & Server/Proxy timeout for userparameter, you can use this powershell command to determine the execution time :
```powershell
(Measure-Command -Expression{ & "C:\Program Files\Zabbix Agent 2\scripts\zabbix_vbr_job.ps1" "StartJobs"}).TotalSeconds
```

## Items

- Total number of VEEAM jobs
- Master Item for Veeam jobs and repository Informations

## Triggers

- [WARNING] => No data in RepoInfo
- [WARNING] => No data on Jobs

## Discovery Jobs

### Items discovery Veeam Job, Replication, FileTape, Tape, Sync, Copy, Agent

- Result
- Progress
- Last end time
- Last run time
- Last job duration
- If failed Job : Last Reason
- If failed : Is retry ?

### Items discovery Veeam Repository

- Remaining space in repository
- Total space in repository
- Percent free space
- Out of date

### Triggers discovery Veeam jobs Backup, Copy, Tape, BackupSync

- [HIGH] => Job has FAILED
- [HIGH] => Job has FAILED (With Retry)
- [AVERAGE] => Job has completed with warning
- [AVERAGE] => Job has completed with warning (With Retry)
- [HIGH] => Job is still running (8 hours)

### Triggers discovery Veeam Repository

- [HIGH] => Less than 20% remaining on the repository
- [HIGH] => Information is out of date
