<#
.SYNOPSIS
# zabbix_vbr_job
# Author: Romainsi
# Contributions: Antonio Oliveira (aholiveira)

.DESCRIPTION
Query Veeam job information
This script is intended for use with Zabbix > 6.X
It uses SQL queries to the Veeam database to obtain the information
Please change the values of the variables below to match your configuration

You can create the user with SQL Server Management Studio (SSMS) or with sqlcmd.exe.
Using SSMS GUI, create a new SQL user, add it to veeam's database and assign it to db_datareader role.
Alternatively, you can run the following query in either of them to create the user and grant it appropriate rights.
Change password "CHANGEME" with something more secure.

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
$typeNames = @{
    0  = "Job";
    28 = "Tape";
    51 = "Sync";
    63 = "Copy";
}

# Get last job session for the given job name
# @param name Job name to filter by
# @param BackupSessions The sessions table from the SQL query
function Get-LastJob {
    [CmdletBinding()]
    Param (
        [Parameter(Mandatory = $true)]
        $name,
        [Parameter(Mandatory = $true)]
        $backupsessions
    )
    $lastsession = $backupsessions | Where-Object { $_.job_name -like "$name" } | Sort-Object creation_time -Descending | Select-Object -First 1
    $obj = New-Object System.Object
    $obj | Add-Member -type NoteProperty -Name JobType -Value $lastsession.job_type
    $obj | Add-Member -type NoteProperty -Name JobName -Value $lastsession.job_name
    $obj | Add-Member -type NoteProperty -Name JobResult -Value $lastsession.result
    $obj | Add-Member -type NoteProperty -Name JobStart -Value $lastsession.creation_time
    $obj | Add-Member -type NoteProperty -Name JobEnd -Value $lastsession.end_time
    $obj | Add-Member -type NoteProperty -Name Progress -Value $lastsession.progress
    $obj | Add-Member -type NoteProperty -Name Retry -Value $lastsession.is_retry

    # Get reason from the XML log or for the "reason" table column (XML log has more detail). 
    # Use table column as a fallback
    $Log = (([Xml]$lastsession.log_xml).Root.Log | Where-Object { $_.Status -like 'EFailed' }).Title
    if ($Log.count -ge 2) {
        $obj | Add-Member -type NoteProperty -Name Reason -Value $Log[1]
    }
    if ($Log.count -lt 2 -and $Log.count -gt 0) {
        $obj | Add-Member -type NoteProperty -Name Reason -Value $Log
    }
    if (!$Log) {
        $obj | Add-Member -type NoteProperty -Name Reason -Value $lastsession.reason
    }
    return $obj
}

# Build and return a SQL connection string
# It uses the variables defined at the top of the script
function Get-ConnectionString() {
    $builder = New-Object System.Data.SqlClient.SqlConnectionStringBuilder
    $builder.Add("Data Source", $SQLServer)
    $builder.Add("Integrated Security", $SQLIntegratedSecurity)
    $builder.Add("Initial Catalog", $SQLveeamdb)
    $builder.Add("User Id", $SQLuid)
    $builder.Add("Password", $SQLpwd)

    return $builder.ConnectionString
}

# Opens a connection to the database
# Retries if unsucessfull on the first try
function Start-Connection() {
    $connectionString = Get-ConnectionString

    # Create a connection to MSSQL
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
    return $connection
}

# Runs a query against the database given the supplied query string
# @param Command query string to run
function QuerySql {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [System.String]$Command
    )

    $Connection = Start-Connection
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

    # Returns the first table from the dataset
    return $DataSet.Tables[0]
}

# Builds an object with the information for each job
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
    $job = Get-LastJob -Name $item.name -backupsessions $BackupSessions
    if ($job) {
        $Object = New-Object System.Object
        $Object | Add-Member -type NoteProperty -Name JOBID -Value $item.id
        $Object | Add-Member -type NoteProperty -Name JOBTYPEID -Value $job.JobType
        $Object | Add-Member -type NoteProperty -Name JOBTYPENAME -Value $typeNames[$job.JobType]
        $Object | Add-Member -type NoteProperty -Name JOBNAME -Value ([System.Net.WebUtility]::HtmlEncode($job.JobName))
        $Object | Add-Member -type NoteProperty -Name JOBRESULT -Value $job.JobResult
        $Object | Add-Member -type NoteProperty -Name JOBRETRY -Value $job.Retry
        $Object | Add-Member -type NoteProperty -Name JOBREASON -Value ([System.Net.WebUtility]::HtmlEncode($job.Reason))
        $Object | Add-Member -type NoteProperty -Name JOBPROGRESS -Value $job.Progress

        # Convert datetimes to UTC to handle timezones correctly
        $jobstart = $job.JobStart.ToUniversalTime()
        $jobend = $job.JobEnd.ToUniversalTime()

        # Handle empty dates
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

# Queries Veeam's database to obtain information about all supported job types.
function Get-AllJobsInfo() {
    ## Get backup jobs session information
    $BackupSessions = QuerySql -Command "SELECT * FROM [VeeamBackup].[dbo].[Backup.Model.JobSessions] 
        INNER JOIN [VeeamBackup].[dbo].[Backup.Model.BackupJobSessions] 
        ON [VeeamBackup].[dbo].[Backup.Model.JobSessions].[id] = [VeeamBackup].[dbo].[Backup.Model.BackupJobSessions].[id]
        WHERE job_type IN $jobTypes 
        ORDER BY creation_time DESC, job_type, job_name"

    # Get all active jobs
    $BackupJobs = QuerySql -Command "SELECT id,[type],name,options FROM [VeeamBackup].[dbo].[JobsView] WHERE [Schedule_Enabled] = 'true' AND [type] IN $jobTypes"

    $return = @()
    foreach ($job in $BackupJobs) {
        if (([Xml]$job.options).JobOptionsRoot.RunManually -like "False") {
            $obj = Get-JobInfo -item $job -backupsessions $BackupSessions
            $return += ($obj)
        }
    }
    $return = ConvertTo-Json -Compress -InputObject @($return)
    $return = $return -replace '"', '""'
    $return = '"' + $return + '"'
    Set-Location $pathzabbixsender
    .\zabbix_sender.exe -c $config -k veeam.Jobs.Info -o $return
}

# Queries WIM to obtain Veeam's repository information and sends data to zabbix
function Get-RepoInfo() {
    ## Get repository information from WIM
    $repoinfo = Get-CimInstance -Class Repository -ComputerName $veeamserver -Namespace ROOT\VeeamBS
    $return = @()
    foreach ($item in $repoinfo) {
        $Object = New-Object System.Object
        $Object | Add-Member -type NoteProperty -Name REPONAME -Value ([System.Net.WebUtility]::HtmlEncode($item.NAME)) 
        $Object | Add-Member -type NoteProperty -Name REPOCAPACITY -Value $item.Capacity
        $Object | Add-Member -type NoteProperty -Name REPOFREE -Value $item.FreeSpace
        $Object | Add-Member -type NoteProperty -Name REPOOUTOFDATE -Value $item.OutOfDate
        $return += $Object
    }
    $return = ConvertTo-Json -Compress -InputObject @($return)
    $return = $return -replace '"', '""'
    $return = '"' + $return + '"'
    Set-Location $pathzabbixsender
    .\zabbix_sender.exe -c $config -k veeam.Repo.Info -o $return
}

# Main program
# Gets the requested information from Veeam
switch ($ITEM) {
    "StartJobs" {
        Get-AllJobsInfo
        Get-RepoInfo
    }
    "TotalJob" {
        $BackupJobs = QuerySql -Command "SELECT jobs.name FROM [VeeamBackup].[dbo].[JobsView] jobs WHERE [Schedule_Enabled] = 'true' AND [type] IN $jobTypes"
        Write-Host $BackupJobs.Rows.Count
    }
    default {
        Write-Output "-- ERROR -- : Need an option !"
    }
}
