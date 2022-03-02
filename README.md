# VEEAM-B&R-SQL

This template use SQL Query to discover VEEAM Backup jobs, Veeam BackupSync, Veeam Tape Job, All Repositories.
Powershell get all informations via SQL and send it to zabbix server/proxy in json in one shot.

- Work with Veeam backup & replication V9 to V10 and V11 (actually ok on 11.0.1.1261)
- Work with Zabbix 5.X (not test with v6)

## Items

  - Number of tasks jobs
  - Master Item for BackupJob,BackupSyncJob,Repository Info,TapeJob

## Discovery Jobs

### 1. Veeam backup Jobs:
  - Result of each jobs
  - Progress of each jobs
  - Last end time of each jobs
  - Last run time of each jobs
  - If failed Job : Last Reason
  - If failed : Is retry ?

### 2. Veeam Tape Jobs:
  - Result of each jobs
  - Last end time of each jobs
  - Last run time of each jobs
  - If failed Job : Last Reason

### 3. Veeam BackupSync Jobs:
  - Result of each jobs
  - Progress of each jobs
  - Last end time of each jobs
  - Last run time of each jobs
  - If failed Job : Last Reason
  - If failed : Is retry ?

### 6. Veeam Repository:
  - Remaining space in repository for each repo
  - Total space in repository for each repo

## Triggers

- [WARNING] => No data in RepoInfo
- [WARNING] => No data in ResultBackup
- [WARNING] => No data in ResultBackupSync
- [WARNING] => No data in ResultTapeJob

### Discovery Veeam Jobs

- [HIGH] => Job has FAILED
- [HIGH] => Job has FAILED (With Retry)	
- [AVERAGE] => Job has completed with warning
- [AVERAGE] => Job has completed with warning (With Retry)	
- [HIGH] => Job is still running (8 hours)

### Discovery Veeam Tape Jobs
- [HIGH] => Job has FAILED
- [AVERAGE] => Job has completed with warning
- [HIGH] => Job is still running (8 hours)
- [INFORMATION] => No data recovery for 24 hours

### Discovery Veeam BackupSync Jobs
- [HIGH] => Job has FAILED
- [HIGH] => Job has FAILED (With Retry)	
- [AVERAGE] => Job has completed with warning
- [AVERAGE] => Job has completed with warning (With Retry)	

### Discovery Veeam Repository
- [HIGH] => Less than 2Gb remaining on the repository


## Setup

1. Install the Zabbix agent 2 on your host
2.  In script, ajust variable $veeamserver = 'veeam.contoso.local' (line 7) and sqlquery function with user/pass (line 64-65) that you will create in the next step on the sql server 
3.  Connect to the veeam sql server (with SQL Server Management Studio or other, adjust protocols for VEEAMSQL in "Sql Server Configuration Manager" for permit to connect with TCP/IP) and create user/pass with reader rights , permit to connect with local user in sql settings and specify the default database.
4. Copy `zabbix_vbr_job.ps1` in the directory : `C:\Program Files\Zabbix Agent 2\scripts\` (create folder if not exist)
5. Add `AllowKey=system.run[*]` in zabbix_agent2.conf.
6. Import Template_Veeam_Backup_And_Replication.yaml file into Zabbix.
7. Associate "Template VEEAM Backup and Replication" to the host.
