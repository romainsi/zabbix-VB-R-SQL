# VEEAM-B&R-SQL

This template use SQL Query to discover VEEAM Backup jobs, Veeam BackupCopy, Veeam BackupSync, Veeam Tape Job, All Repositories.
Powershell get all informations via SQL and send it to zabbix server/proxy with json, use zabbix sender.

- Work with Veeam backup & replication V9 to V10 and V11 (actually ok on 11.0.1.1261)
- Work with Zabbix 6.x

## Items

- Total number of VEEAM jobs
- Master Item for Veeam jobs and repository Informations

## Triggers

- [WARNING] => No data in RepoInfo
- [WARNING] => No data on Jobs

## Discovery Jobs

### Items discovery Veeam jobs Backup, Replication, FileTape, Tape, BackupSync, Copy, RMAN, Agent

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

## Setup

1. Install the Zabbix agent 2 on your host (and verify you have add zabbix zabbix_sender in zabbix root path).
2. Connect to the veeam sql server, adjust protocols for VEEAMSQL in "Sql Server Configuration Manager" for permit to connect with TCP/IP
3. With SQL Server Management Studio : Create User/Pass with reader rights , permit to connect with local user in sql settings and specify the default database. With sqlcmd.exe (Change password "CHANGEME" with something more secure):

    ```sql
    USE [VeeamBackup]
    CREATE LOGIN [zabbixveeam] WITH PASSWORD = N'CHANGEME', CHECK_POLICY = OFF, CHECK_EXPIRATION = OFF;
    CREATE USER [zabbixveeam] FOR LOGIN [zabbixveeam];
    EXEC sp_addrolemember 'db_datareader', 'zabbixveeam';
    GO
    ```

4. In script, ajust variables line 56 to 63 to match your configuration
5. Copy `zabbix_vbr_job.ps1` in the directory : `C:\Program Files\Zabbix Agent 2\scripts\` (create folder if not exist)
6. Add `UserParameter=veeam.info[*],powershell -NoProfile -ExecutionPolicy Bypass -File "C:\Program Files\Zabbix Agent 2\scripts\zabbix_vbr_job.ps1" "$1"` in zabbix_agent2.conf  
7. Import Template_Veeam_Backup_And_Replication.yaml file into Zabbix.
8. Associate Template "VEEAM Backup and Replication" to the host.  
NOTE: When importing the new template version on an existing installation please check all "Delete missing", except "Template linkage", to make sure the old items are deleted

Ajust Zabbix Agent & Server/Proxy timeout for userparameter, you can use this powershell command to determine the execution time :

```powershell
(Measure-Command -Expression{ powershell -NoProfile -ExecutionPolicy Bypass -File "C:\Program Files\Zabbix Agent 2\scripts\zabbix_vbr_job.ps1" "StartJobs"}).TotalSeconds
```
