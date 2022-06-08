<#
.SYNOPSIS
# zabbix_vbr_job
# Author: Romainsi
# Modified: Antonio Oliveira, 07/05/2022

.DESCRIPTION
Query Veeam job information
This script is intended for use with Zabbix > 5.X
It uses SQL queries to the Veeam database to obtain the information
Please change the values of the variables below to match your configuration

Use the following SQL commands (run with sqlcmd.exe) to create the username if you are using SQL Express:

USE [VeeamBackup]
CREATE LOGIN [zabbixveeam] WITH PASSWORD = N'CHANGEME', CHECK_POLICY = OFF, CHECK_EXPIRATION = OFF;
CREATE USER [zabbixveeam] FOR LOGIN [zabbixveeam];
EXEC sp_addrolemember 'db_datareader', 'zabbixveeam';
GO

.INPUTS
The script takes an unnamed single argument which specifies the information to supply
StartJobs - Sends all Veeam jobs to Zabbix
TotalJob - The number of Veeam active jobs 

.OUTPUTS
None
#>

$veeamserver = 'veeam.contoso.local'   # Machine name where Veeam is installed
$SQLServer = 'sqlserver.contoso.local' # Database server where Veeam database is located. Change to sqlserver.contoso.local\InstanceName if you are running an SQL named instance
$SQLIntegratedSecurity = $false        # Use Windows integrated security?
$SQLuid = 'zabbixveeam'                # SQL Username when using SQL Authentication - ignored if using Integrated security
$SQLpwd = 'CHANGEME'                   # SQL user password
$SQLveeamdb = 'VeeamBackup'            # Name of Veeam database. VeeamBackup is the default
$pathzabbixsender = 'C:\Program Files\Zabbix Agent 2' # Location of the Zabbix agent
$config = '.\zabbix_agent2.conf'                    # Zabbix configuration file (relative to the above path)


########### DO NOT MODIFY BELOW
$ITEM = [string]$args[0]
$jobTypes = "(0, 28, 51, 63)"

# Function Sort-Object VMs by jobs on last backup (with unique name if retry)
function get-veeam-backup-task-unique {
    [CmdletBinding()]
    Param (
        [Parameter(Mandatory = $true)]
        $name,
        [Parameter(Mandatory = $true)]
        $backupsessions
    )
    $xml1 = $backupsessions | Where-Object { $_.Job_Name -like "$name" }
    $unique = $xml1.Job_Name | Sort-Object -Unique

    $output = & {
        if (($xml1 | Where-Object { $_.Job_Name -like "$unique" }).job_type -like 51) {
            $query = $xml1 | Where-Object { $_.Job_Name -like "$unique" } | Sort-Object creation_time -Descending | Select-Object -First 1
            if ($query.end_time -like '01/01/1900 00:00:00Z') {
                $query = $xml1 | Where-Object { $_.Job_Name -like "$unique" } | Sort-Object end_time -Descending | Select-Object -First 1
            }
            ## If Idle retrieve last result for BS
            if ($query.Result -like '-1') {
                $query = $xml1 | Where-Object { $_.Job_Name -like "$unique" } | Sort-Object end_time -Descending | Select-Object -First 2 | Select-Object -Last 1
            }
        }
        else {
            $query = $xml1 | Where-Object { $_.Job_Name -like "$unique" } | Sort-Object creation_time -Descending | Select-Object -First 1
        }

        [Xml]$xml = $query.log_xml
        $Log = ($xml.Root.Log | Where-Object { $_.Status -like 'EFailed' }).Title

        if ($Log.count -ge '2') {
            $Log1 = $Log[1]
            $query | Select-Object @{ N = "JobName"; E = { $query.Job_Name } }, @{ N = "JobResult"; E = { $query.Result } }, @{ N = "JobStart"; E = { $query.creation_time } }, @{ N = "JobEnd"; E = { $query.End_Time } }, @{ N = "Status"; E = { $query.Progress } }, @{ N = "Retry"; E = { $query.is_retry } }, @{ N = "Progress"; E = { $query.progress } }, @{ N = "Reason"; E = { $Log1 } }
        }
        if ($Log.count -lt '2' -and $Log.count -gt '0') {
            $query | Select-Object @{ N = "JobName"; E = { $query.Job_Name } }, @{ N = "JobResult"; E = { $query.Result } }, @{ N = "JobStart"; E = { $query.creation_time } }, @{ N = "JobEnd"; E = { $query.End_Time } }, @{ N = "Status"; E = { $query.Progress } }, @{ N = "Retry"; E = { $query.is_retry } }, @{ N = "Progress"; E = { $query.progress } }, @{ N = "Reason"; E = { $Log } }
        }
        if (!$Log) {
            $query | Select-Object @{ N = "JobName"; E = { $query.Job_Name } }, @{ N = "JobResult"; E = { $query.Result } }, @{ N = "JobStart"; E = { $query.creation_time } }, @{ N = "JobEnd"; E = { $query.End_Time } }, @{ N = "Status"; E = { $query.Progress } }, @{ N = "Retry"; E = { $query.is_retry } }, @{ N = "Progress"; E = { $query.progress } }, @{ N = "Reason"; E = { $query.reason } }
        }
    }
    $output
}

function QuerySql {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [System.String]$Command
    )

    # Create a connection to MSSQL
    $builder = New-Object System.Data.SqlClient.SqlConnectionStringBuilder
    $builder.Add("Data Source", $SQLServer)
    $builder.Add("Integrated Security", $SQLIntegratedSecurity)
    $builder.Add("Initial Catalog", $SQLveeamdb)
    $builder.Add("User Id", $SQLuid)
    $builder.Add("Password", $SQLpwd)

    $connectionString = $builder.ConnectionString

    $connection = New-Object System.Data.SqlClient.SqlConnection
    $connection.ConnectionString = $connectionString
    $connection.Open()
    if ($connection.State -notmatch "Open") {
        # Retry connection
        Start-Sleep -s 5
        $connection = New-Object System.Data.SqlClient.SqlConnection
        $connection.ConnectionString = $connectionString
        $connection.Open()
    }

    $SqlCmd = New-Object System.Data.SqlClient.SqlCommand
    $SqlCmd.CommandText = $Command
    $SqlCmd.Connection = $Connection
    $SqlCmd.CommandTimeout = 0
    $SqlAdapter = New-Object System.Data.SqlClient.SqlDataAdapter
    $SqlAdapter.SelectCommand = $SqlCmd
    $DataSet = New-Object System.Data.DataSet
    $returnsql = $null
    Try {
        $SqlAdapter.Fill($DataSet)
    }

    Catch {
        $returnsql = $_
    }

    $Connection.Close()
    # Verify Error
    if ($returnsql) {
        write-host $returnsql
        return
    }

    # We get a list of databases. Write to the variable.
    return $DataSet.Tables[0]
}
function Get-JobInfo {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [System.Object]$item,
        [Parameter(Mandatory = $true)]
        [System.Object]$backupsessions
    )

    #UTC time
    [System.DateTime]$unixepoch = (get-date -date "01/01/1970 00:00:00Z")

    $Object = $null
    $job = get-veeam-backup-task-unique -Name $item.name -backupsessions $BackupSessions
    if ($job) {
        $Object = New-Object System.Object
        $Object | Add-Member -type NoteProperty -Name JOBID -Value $item.id
        $Object | Add-Member -type NoteProperty -Name JOBNAME -Value ([System.Net.WebUtility]::HtmlEncode($job.JobName))
        $Object | Add-Member -type NoteProperty -Name JOBRESULT -Value $job.JobResult
        $Object | Add-Member -type NoteProperty -Name JOBRETRY -Value $job.Retry
        $Object | Add-Member -type NoteProperty -Name JOBREASON -Value ([System.Net.WebUtility]::HtmlEncode($job.Reason))
        $Object | Add-Member -type NoteProperty -Name JOBPROGRESS -Value $job.Progress

        $jobstart = (($job | Where-Object { $_.JobName -like $job.JOBNAME }).JobStart).ToUniversalTime()
        $jobend = (($job | Where-Object { $_.JobName -like $job.JOBNAME }).JobEnd).ToUniversalTime()
        if ($jobstart -lt $unixepoch) {
            $jobstart = $unixepoch.AddSeconds(-1)
        }
        if ($jobend -lt $unixepoch) {
            $jobend = $unixepoch.AddSeconds(-1)
        }
        # Convert to unix timestamp
        $Object | Add-Member -type NoteProperty -Name JOBSTART -Value ([int]((New-TimeSpan -Start $unixepoch -end $jobstart).TotalSeconds))
        $Object | Add-Member -type NoteProperty -Name JOBEND -Value ([int]((New-TimeSpan -Start $unixepoch -end $jobend).TotalSeconds))
    }
    return $Object
}

switch ($ITEM) {
    "StartJobs" {
        $typeKeys = @{
            0  = "veeam.Results.Backup";
            28 = "veeam.Results.BackupTape";
            51 = "veeam.Results.BackupSync";
            63 = "veeam.Results.BackupCopy";
        }

        ## Get backup jobs information
        $BackupSessions = QuerySql -Command "SELECT * FROM [VeeamBackup].[dbo].[Backup.Model.JobSessions] 
        INNER JOIN [VeeamBackup].[dbo].[Backup.Model.BackupJobSessions] 
        ON [VeeamBackup].[dbo].[Backup.Model.JobSessions].[id] = [VeeamBackup].[dbo].[Backup.Model.BackupJobSessions].[id]
        WHERE job_type IN $jobTypes"
        $BackupJobs = QuerySql -Command "SELECT jobs.* FROM [VeeamBackup].[dbo].[JobsView] jobs WHERE [Schedule_Enabled] = 'true' AND [type] IN $jobTypes"

        foreach ($currentType in $typeKeys.Keys) {
            $query = $BackupJobs | Where-Object { $_.Type -like $currentType }
            $return = $null
            $return = @()
            foreach ($item in $query) {
                [xml]$runmanually = $item.options
                if ($runmanually.JobOptionsRoot.RunManually -like "False") {
                    $job = get-veeam-backup-task-unique -Name $item.name -backupsessions $BackupSessions
                    $Return += Get-JobInfo -item $item -backupsessions $BackupSessions
                }
            }
            Set-Location $pathzabbixsender
            $Return = ConvertTo-Json -Compress -InputObject @($Return)
            $Return = $Return -replace '"', '""'
            $Return = '"' + $Return + '"'

            .\zabbix_sender.exe -c $config -k $typeKeys[$currentType] -o $Return
        }

        ## Get repository repository information
        $query = Get-CimInstance -Class Repository -ComputerName $veeamserver -Namespace ROOT\VeeamBS | Select-Object @{ N = "REPONAME"; E = { $_.NAME } }

        $return = $null
        $return = @()

        foreach ($item in $query) {
            $Result = Get-CimInstance -Class Repository -ComputerName $veeamserver -Namespace ROOT\VeeamBS | Where-Object { $_.Name -eq $item.REPONAME }
            $Object = $null
            $Object = New-Object System.Object
            $Object | Add-Member -type NoteProperty -Name REPONAME -Value ([System.Net.WebUtility]::HtmlEncode($item.REPONAME)) 
            $Object | Add-Member -type NoteProperty -Name REPOCAPACITY -Value $Result.Capacity
            $Object | Add-Member -type NoteProperty -Name REPOFREE -Value $Result.FreeSpace
            $Object | Add-Member -type NoteProperty -Name REPOOUTOFDATE -Value $Result.OutOfDate
            $return += $Object
        }
        Set-Location $pathzabbixsender
        $return = ConvertTo-Json -Compress -InputObject @($return)
        $Return = $Return -replace '"', '""'
        $Return = '"' + $Return + '"'

        .\zabbix_sender.exe -c $config -k veeam.Repo.Info -o $return
    }

    "TotalJob" {
        $BackupJobs = QuerySql -Command "SELECT jobs.name FROM [VeeamBackup].[dbo].[JobsView] jobs WHERE [Schedule_Enabled] = 'true' AND [type] IN $jobTypes"
        $query = $BackupJobs.Rows.Count
        write-host $query
    }

    default {
        write-output "-- ERROR -- : Need an option !"
    }
}
