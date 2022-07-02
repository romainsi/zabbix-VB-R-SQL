[CmdletBinding()]
param(
    [Parameter(Position = 0, Mandatory = $false)]
    [ValidateSet("RepoInfo", "JobsInfo", "TotalJob")]
    [System.String]$Operation
)
<#
.SYNOPSIS
Query Veeam job information
This script is intended for use with Zabbix > 6.X

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
RepoInfo - Get repository information
JobsInfo - Get job information
TotalJob - The number of Veeam active jobs 

.OUTPUTS
System.String. Information requested depending on the parameter given
The output is JSON formated for RepoInfo and JobsInfo parameters.
TotalJob outputs a single string with the number of active jobs.

.EXAMPLE
zabbix_vbr_jobs.ps1 RepoInfo

Description
---------------------------------------
Gets information about Veeam repository

.EXAMPLE
zabbix_vbr_jobs.ps1 JobsInfo

Description
---------------------------------------
Gets information about Veeam jobs

.EXAMPLE
zabbix_vbr_jobs.ps1 TotalJob

Description
---------------------------------------
Sends total number of active Veeam jobs to Zabbix

.NOTES
Created by   : Romainsi   https://github.com/romainsi
Contributions: aholiveira https://github.com/aholiveira
               xtonousou  https://github.com/xtonousou
Version      : 2.8

.LINK
https://github.com/romainsi/zabbix-VB-R-SQL

#>

########### Adjust the following variables to match your configuration ###########
$veeamserver = 'veeam.contoso.local'   # Machine name where Veeam is installed
$SQLServer = 'sqlserver.contoso.local' # Database server where Veeam database is located. Change to sqlserver.contoso.local\InstanceName if you are running an SQL named instance
$SQLIntegratedSecurity = $false        # Use Windows integrated security?
$SQLuid = 'zabbixveeam'                # SQL Username when using SQL Authentication - ignored if using Integrated security
$SQLpwd = 'CHANGEME'                   # SQL user password
$SQLveeamdb = 'VeeamBackup'            # Name of Veeam database. VeeamBackup is the default

<#
Supported job types.
You can add additional types by extending the variable below
Look into Veeam's database table [BJobs] to find more job types
If using version 2.0 or higher of the companion Zabbix template new types added here are automatically used in Zabbix
If you extend this, please inform the author so that the script can be extended
$typeNames is used in Get-SessionInfo function to send the type name to Zabbix
#>
$typeNames = @{
    0     = "Job";
    1     = "Replication";
    2     = "File";
    28    = "Tape";
    51    = "Sync";
    63    = "Copy";
    4030  = "RMAN";
    12002 = "Agent backup policy";
    12003 = "Agent backup job";
}

# $jobtypes is used in SQL queries. Built automatically from the enumeration above.
$jobTypes = "($(($typeNames.Keys | Sort-Object) -join ", "))"

########### DO NOT MODIFY BELOW ###########

<#
.SYNOPSIS
Build and return a SQL connection string
It uses the variables defined at the top of the script

.INPUTS
None. The function uses the variables defined at the top of the script

.OUTPUTS
System.String. A SQL connection string
#>
function Get-ConnectionString() {
    $builder = New-Object System.Data.SqlClient.SqlConnectionStringBuilder
    $builder.Add("Data Source", $SQLServer)
    $builder.Add("Integrated Security", $SQLIntegratedSecurity)
    $builder.Add("Initial Catalog", $SQLveeamdb)
    $builder.Add("User Id", $SQLuid)
    $builder.Add("Password", $SQLpwd)
    Write-Debug "Connection String: $($builder.ConnectionString)"
    return $builder.ConnectionString
}

<#
.SYNOPSIS
Opens a connection to the database
Retries if unsucessfull on the first try

.INPUTS
None

.OUTPUTS
System.String. A SQL connection string
#>
function Start-Connection() {
    $connectionString = Get-ConnectionString

    # Create a connection to MSSQL
    Write-Debug "Opening SQL connection"
    $connection = New-Object System.Data.SqlClient.SqlConnection
    $connection.ConnectionString = $connectionString
    $connection.Open()
    if ($connection.State -notmatch "Open") {
        # Connection open failed. Wait and retry connection
        Start-Sleep -Seconds 5
        $connection = New-Object System.Data.SqlClient.SqlConnection
        $connection.ConnectionString = $connectionString
        $connection.Open()
    }
    Write-Debug "SQL connection state: $($connection.State)"
    return $connection
}

<#
.SYNOPSIS
Runs a query against the database given the supplied query string

.PARAMETER Command
Query string to run

.INPUTS
None

.OUTPUTS
System.Data.DataTable. A datatable object on success or $null on failure
#>
function Get-SqlCommand {
    [CmdletBinding()]
    param (
        [Parameter(Position = 0, Mandatory = $true)]
        [System.String]$Command
    )

    $Connection = $null
    # Use try-catch to avoid exceptions if connection to SQL cannot be opened or data cannot be read
    # It either returns the data read or $null on failure
    try {
        $Connection = Start-Connection
        $SqlCmd = New-Object System.Data.SqlClient.SqlCommand
        $SqlCmd.CommandText = $Command
        $SqlCmd.Connection = $Connection
        $SqlCmd.CommandTimeout = 0
        $SqlAdapter = New-Object System.Data.SqlClient.SqlDataAdapter
        Write-Debug "Executing SQL query: ##$Command##"
        $SqlAdapter.SelectCommand = $SqlCmd
        $DataSet = New-Object System.Data.DataSet
        $SqlAdapter.Fill($DataSet)
        $retval = $DataSet.Tables[0]
    }
    catch {
        $retval = $null
        # We output the error message. This gets sent to Zabbix.
        Write-Output $_.Exception.Message
    }
    finally {
        # Make sure the connection is closed
        if ($null -ne $Connection) {
            $Connection.Close()
        }
    }
    return $retval
}

<#
.SYNOPSIS
Convert to unix timestamp - Seconds elapsed since unix epoch

.PARAMETER date
System.DateTime. The reference date to convert to unix timestamp

.INPUTS
None

.OUTPUTS
System.Int. The converted date to unix timestamp or -1 if date was before the epoch
#>
function ConvertTo-Unixtimestamp {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [System.DateTime]$date
    )
    # Unix epoch
    [System.DateTime]$unixepoch = (get-date -date "01/01/1970 00:00:00Z")

    # Handle empty dates
    # We make this one second less than $unixepoch.
    # This makes the time calculation below return -1 to Zabbix, making the item "unsupported" while the job is running (or before it ran for the first time)
    if ($null -eq $date -or $date -lt $unixepoch) {
        $date = $unixepoch.AddSeconds(-1);
    }

    # Return the seconds elapsed between the reference date and the epoch
    return [int]((New-TimeSpan -Start $unixepoch -end $date).TotalSeconds)
}

<#
.SYNOPSIS
Builds an object with the information for each job

.PARAMETER BackupSession
System.Object. An object containing job session information

.INPUTS
None

.OUTPUTS
System.Object. An object with the job information with the tags used by the Zabbix template
#>
function Get-SessionInfo {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [System.Object]$BackupSession
    )

    # Return $null if there is no session data
    if (!$BackupSession) {
        return $null
    }

    # Get reason for the job failure/warning
    # We get all jobs reasons from both table column and log_xml
    $Log = (([Xml]$BackupSession.log_xml).Root.Log | Where-Object { $_.Status -eq 'EFailed' }).Title
    $reason = $BackupSession.reason
    foreach ($logreason in $Log) {
        $reason += "`r`n$logreason"
    }

    # Build the output object
    Write-Debug "Building object for job: $($BackupSession.job_name)"
    $Object = [PSCustomObject]@{
        JOBID       = $BackupSession.job_id
        JOBTYPEID   = $BackupSession.job_type
        JOBTYPENAME = $typeNames[$BackupSession.job_type]
        JOBNAME     = ([System.Net.WebUtility]::HtmlEncode($BackupSession.job_name))
        JOBRESULT   = $BackupSession.result
        JOBRETRY    = $BackupSession.is_retry
        JOBREASON   = ([System.Net.WebUtility]::HtmlEncode($reason))
        JOBPROGRESS = $BackupSession.progress
        JOBSTART    = (ConvertTo-Unixtimestamp $BackupSession.creation_time.ToUniversalTime())
        JOBEND      = (ConvertTo-Unixtimestamp $BackupSession.end_time.ToUniversalTime())
    }
    return $Object
}

<#
.SYNOPSIS
Queries Veeam's database to obtain information about all supported job types.

.INPUTS
None

.OUTPUTS
Job information in JSON format
#>
function Get-JobInfo() {
    Write-Debug "Entering Get-JobInfo()"

    # Get all active jobs
    $BackupJobs = Get-SqlCommand "SELECT id, name, options FROM [BJobs] WHERE [schedule_enabled] = 'true' AND [type] IN $jobTypes ORDER BY [type], [name]"
    Write-Debug "Job count: $($BackupJobs.Count)"
    $return = @()
    # Get information for each active job
    foreach ($job in $BackupJobs) {
        if (([Xml]$job.options).JobOptionsRoot.RunManually -eq "False") {
            Write-Debug "Getting data for job: $($job.name)"
            # Get backup jobs session information
            $LastJobSession = Get-SqlCommand "SELECT TOP 1
            job_id, job_type, job_name, result, is_retry, progress, creation_time, end_time, log_xml, reason
            FROM [Backup.Model.JobSessions]
            INNER JOIN [Backup.Model.BackupJobSessions] 
            ON [Backup.Model.JobSessions].[id] = [Backup.Model.BackupJobSessions].[id]
            WHERE job_id='$($job.id)'
            ORDER BY creation_time DESC"
            $sessionInfo = Get-SessionInfo $LastJobSession
            $return += $sessionInfo
        }
    }
    Write-Verbose "Got job information. Number of jobs: $($return.Count)"
    # Convert data to JSON
    $return = ConvertTo-Json -Compress -InputObject @($return)
    Write-Output $return
}

<#
.SYNOPSIS
Queries WIM to obtain Veeam's repository information

.INPUTS
None

.OUTPUTS
Repository information in JSON format
#>
function Get-RepoInfo() {
    Write-Debug "Entering Get-RepoInfo()" 
    Write-Debug "Veeam server: $veeamserver"
    # Get data from WIM class
    $repoinfo = Get-CimInstance -Class Repository -ComputerName $veeamserver -Namespace ROOT\VeeamBS

    $return = @()
    # Build the output object
    foreach ($item in $repoinfo) {
        Write-Debug "Repository $($item.NAME)"
        $Object = [PSCustomObject]@{
            REPONAME      = ([System.Net.WebUtility]::HtmlEncode($item.NAME))
            REPOCAPACITY  = $item.Capacity
            REPOFREE      = $item.FreeSpace
            REPOOUTOFDATE = $item.OutOfDate
        }
        $return += $Object
    }
    Write-Debug "Repository count: $($return.Count)"

    # Convert data to JSON
    $return = ConvertTo-Json -Compress -InputObject @($return)
    Write-Output $return
}

<#
.SYNOPSIS
Gets the number of active jobs from Veeam

.INPUTS
None

.OUTPUTS
The number of active jobs.
In case of an error a message is printed to standard output
#>
function Get-Totaljob() {
    $BackupJobs = Get-SqlCommand "SELECT COUNT(jobs.name) as JobCount
        FROM [VeeamBackup].[dbo].[JobsView] jobs 
        WHERE [Schedule_Enabled] = 'true' AND [type] IN $jobTypes"
    Write-Debug $BackupJobs.ToString()
    if ($null -ne $BackupJobs) {
        Write-Output $BackupJobs.JobCount
    }
    else {
        Write-Output "-- ERROR -- : No data available. Check configuration"
    }
}

<#
.SYNOPSIS
Main program
Gets the requested information from Veeam

.INPUTS
None

.OUTPUTS
Requested data in JSON format to be ingested by Zabbix
In case of an error a message is printed to standard output
#>
If ($PSBoundParameters['Debug']) {
    $DebugPreference = 'Continue'
}

Write-Debug "Job types: $jobTypes"
Write-Debug "Veeam server: $veeamserver"
Write-Debug "SQL server: $SQLServer"
switch ($Operation) {
    "RepoInfo" {
        Get-RepoInfo
    }
    "JobsInfo" {
        Get-JobInfo
    }
    "TotalJob" {
        Get-Totaljob
    }
    default {
        Write-Output "-- ERROR -- : Need an option  !"
        Write-Output "Valid options are: RepoInfo, JobsInfo or TotalJob"
        Write-Output "This script is not intended to be run directly but called by Zabbix."
    }
}
