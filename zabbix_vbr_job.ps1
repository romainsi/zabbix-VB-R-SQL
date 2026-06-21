#Requires -Version 5.1
<#
.SYNOPSIS
    Query Veeam job and repository information for Zabbix active agent monitoring.

.DESCRIPTION
    Queries Veeam's SQL Server or PostgreSQL database to retrieve job and repository
    information. Intended to be called by the Zabbix active agent via UserParameter.

    Credentials and connection parameters are read from a configuration file on disk.
    The config file must be secured using NTFS permissions so that only the Zabbix
    agent service account can read it.

    Place the config file in the same directory as this script and name it "zabbix_vbr.conf".
    Override with -ConfigFile parameter.

.CONFIGURATION FILE FORMAT
    The config file uses a simple Key=Value format. Lines starting with # are comments.
    Blank lines are ignored. Example (SQL Server):

        # Veeam SQL Server connection settings
        SQLServer=SQL-SERVER\INSTANCE
        SQLDatabase=VeeamBackup
        SQLIntegratedSecurity=false
        SQLUsername=veeam_db
        SQLPassword=S3cur3P@ssw0rd
        DBProvider=SqlServer

    Example (PostgreSQL via ODBC):

        # Veeam PostgreSQL connection settings
        SQLServer=localhost
        SQLPort=5432
        SQLDatabase=VeeamBackup
        SQLIntegratedSecurity=false
        SQLUsername=postgres
        SQLPassword=S3cur3P@ssw0rd
        DBProvider=Postgres

    DBProvider must be either SqlServer or Postgres.
    When SQLIntegratedSecurity=true, SQLUsername and SQLPassword are ignored
    (SQL Server only; PostgreSQL always requires credentials).
    SQLPort is optional for PostgreSQL and defaults to 5432.

.POSTGRESQL ODBC REQUIREMENTS
    PostgreSQL connectivity uses the system ODBC driver via System.Data.Odbc (built into
    .NET / PowerShell — no extra DLLs required).
    The "PostgreSQL Unicode" ODBC driver must be installed on the Zabbix agent host.
    Download from: https://www.postgresql.org/ftp/odbc/versions/msi/

.SECURING THE CONFIG FILE
    Run the following from an elevated PowerShell prompt to lock down the config file.
    Replace $path if you are not using the default location.

        $path = "zabbix_vbr.conf"
        $acl = Get-Acl $path
        $acl.SetAccessRuleProtection($true, $false)
        $acl.SetAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule("SYSTEM", "FullControl", "Allow")))
        $acl.SetAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule("BUILTIN\Administrators", "FullControl", "Allow")))
        Set-Acl $path $acl

.ZABBIX AGENT CONFIGURATION
    Add the following to your Zabbix agent configuration file (zabbix_agentd.conf) or
    in a zabbix_agentd.d/*.conf file. Adjust the path to the script as needed:

        UserParameter=veeam.info[*],powershell -NoProfile -ExecutionPolicy Bypass -File "C:\Program Files\Zabbix Agent\scripts\zabbix_vbr_job.ps1" -Config "C:\Program Files\Zabbix Agent\scripts\zabbix_vbr.conf" -Operation "$1"

    Zabbix item keys:
        veeam.info[RepoInfo]   - Repository information (JSON)
        veeam.info[JobsInfo]   - Job information (JSON)
        veeam.info[TotalJob]   - Total number of active jobs (integer)

.CREATING THE SQL SERVER USER
    Run the following in SQL Server Management Studio or sqlcmd.exe.
    Replace CHANGEME with a secure password.

        USE [VeeamBackup]
        CREATE LOGIN [zabbixveeam] WITH PASSWORD = N'CHANGEME', CHECK_POLICY = OFF, CHECK_EXPIRATION = OFF;
        CREATE USER [zabbixveeam] FOR LOGIN [zabbixveeam];
        EXEC sp_addrolemember 'db_datareader', 'zabbixveeam';
        GO

.CREATING THE POSTGRESQL USER
    Run the following in psql or pgAdmin:

        CREATE USER zabbixveeam WITH PASSWORD 'CHANGEME';
        GRANT CONNECT ON DATABASE "VeeamBackup" TO zabbixveeam;
        GRANT USAGE ON SCHEMA public TO zabbixveeam;
        GRANT SELECT ON ALL TABLES IN SCHEMA public TO zabbixveeam;

.PARAMETER Operation
    The operation to perform. Valid values: RepoInfo, JobsInfo, TotalJob.

.PARAMETER ConfigFile
    Path to the configuration file. Defaults to zabbix_vbr.conf in the script directory.

.INPUTS
    None

.OUTPUTS
    JSON string for RepoInfo and JobsInfo.
    Integer string for TotalJob.
    Error message string on failure.

.NOTES
    Original author : Romainsi   https://github.com/romainsi
    Contributions   : aholiveira https://github.com/aholiveira
                      xtonousou  https://github.com/xtonousou
    Version         : 3.3

.LINK
    https://github.com/romainsi/zabbix-VB-R-SQL
#>

[CmdletBinding()]
param(
    [Parameter(Position = 0, Mandatory = $true)]
    [ValidateSet("RepoInfo", "JobsInfo", "TotalJob")]
    [System.String]$Operation,
    [Parameter(Mandatory = $false)]
    [System.String]$ConfigFile = [System.IO.Path]::Combine($PSScriptRoot, "zabbix_vbr.conf")
)


if ($PSBoundParameters['Debug']) {
    $DebugPreference = 'Continue'
}

#region --- Supported job types ---
<#
Supported job types.
You can add additional types by extending the hashtable below.
Look into Veeam's database table [BJobs] to find more job types.
If using version 2.0 or higher of the companion Zabbix template, new types
added here are automatically picked up by Zabbix.
#>
$typeNames = @{
    0     = "Job"
    1     = "Replication"
    2     = "File"
    28    = "Tape"
    51    = "Sync"
    63    = "Copy"
    4030  = "RMAN"
    12002 = "Agent backup policy"
    12003 = "Agent backup job"
}

# Built automatically from the hashtable above. Used in SQL WHERE clauses.
$jobTypes = "($(($typeNames.Keys | Sort-Object) -join ', '))"
#endregion

#region --- Configuration ---
<#
.SYNOPSIS
    Reads the configuration file and returns a hashtable of key/value pairs.
    Lines starting with # and blank lines are ignored.
    Exits the script with an error message if the file cannot be read or a
    required key is missing.
#>
function Read-Config {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [System.String]$Path
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        Write-Output "-- ERROR -- : Config file not found: $Path"
        exit 1
    }

    $config = @{}
    try {
        $lines = [System.IO.File]::ReadAllLines($Path)
        foreach ($line in $lines) {
            $trimmed = $line.Trim()
            if ($trimmed -eq '' -or $trimmed.StartsWith('#')) {
                continue 
            }
            $idx = $trimmed.IndexOf('=')
            if ($idx -le 0) { continue }
            $key = $trimmed.Substring(0, $idx).Trim()
            $value = $trimmed.Substring($idx + 1).Trim()
            $config[$key] = $value
        }
    }
    catch {
        Write-Output "-- ERROR -- : Failed to read config file: $($_.Exception.Message)"
        exit 1
    }

    # Validate required keys
    $required = @('SQLServer', 'SQLDatabase', 'SQLIntegratedSecurity', 'DBProvider')
    foreach ($key in $required) {
        if (-not $config.ContainsKey($key)) {
            Write-Output "-- ERROR -- : Missing required config key: $key"
            exit 1
        }
    }

    # Validate DBProvider value
    $validProviders = @('SqlServer', 'Postgres')
    if ($config['DBProvider'] -notin $validProviders) {
        Write-Output "-- ERROR -- : DBProvider must be one of: $($validProviders -join ', ')"
        exit 1
    }

    # Normalise the boolean flag
    $config['SQLIntegratedSecurity'] = ($config['SQLIntegratedSecurity'] -eq 'true')

    # SQL auth credentials are only required when not using integrated security
    if (-not $config['SQLIntegratedSecurity']) {
        foreach ($key in @('SQLUsername', 'SQLPassword')) {
            if (-not $config.ContainsKey($key)) {
                Write-Output "-- ERROR -- : Missing required config key for SQL authentication: $key"
                exit 1
            }
        }
    }

    # Default PostgreSQL port if not specified
    if ($config['DBProvider'] -eq 'Postgres' -and -not $config.ContainsKey('SQLPort')) {
        $config['SQLPort'] = '5432'
    }

    Write-Debug "Config loaded from    : $Path"
    Write-Debug "DBProvider            : $($config['DBProvider'])"
    Write-Debug "SQLServer             : $($config['SQLServer'])"
    Write-Debug "SQLDatabase           : $($config['SQLDatabase'])"
    Write-Debug "SQLIntegratedSecurity : $($config['SQLIntegratedSecurity'])"

    return $config
}
#endregion

#region --- Database provider abstraction ---
function Get-ConnectionString {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$Config
    )

    switch ($Config['DBProvider']) {
        'SqlServer' {
            $builder = New-Object System.Data.SqlClient.SqlConnectionStringBuilder
            $builder['Data Source'] = $Config['SQLServer']
            $builder['Initial Catalog'] = $Config['SQLDatabase']
            $builder['Integrated Security'] = $Config['SQLIntegratedSecurity']
            if (-not $Config['SQLIntegratedSecurity']) {
                $builder['User ID'] = $Config['SQLUsername']
                $builder['Password'] = $Config['SQLPassword']
            }
            # Recommended hardening: do not trust arbitrary server certificates
            $builder['TrustServerCertificate'] = $false
            $connStr = $builder.ConnectionString
        }
        'Postgres' {
            # Uses the "PostgreSQL Unicode" ODBC driver (System.Data.Odbc is built into .NET).
            # Install the driver from: https://www.postgresql.org/ftp/odbc/versions/msi/
            $connStr = "Driver={PostgreSQL Unicode};" +
            "Server=$($Config['SQLServer']);" +
            "Port=$($Config['SQLPort']);" +
            "Database=$($Config['SQLDatabase']);" +
            "Uid=$($Config['SQLUsername']);" +
            "Pwd=$($Config['SQLPassword']);"
        }
        default {
            Write-Output "-- ERROR -- : Unknown DBProvider: $($Config['DBProvider'])"
            exit 1
        }
    }

    Write-Debug "Connection string built (password redacted)"
    return $connStr
}

function Start-Connection {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$Config
    )

    $connStr = Get-ConnectionString -Config $Config

    switch ($Config['DBProvider']) {
        'SqlServer' {
            $connection = New-Object System.Data.SqlClient.SqlConnection
            $connection.ConnectionString = $connStr
            Write-Debug "Opening SQL Server connection to $($Config['SQLServer'])"
            $connection.Open()
            if ($connection.State -ne 'Open') {
                Start-Sleep -Seconds 5
                $connection.Open()
            }
        }
        'Postgres' {
            Write-Debug "Opening PostgreSQL ODBC connection to $($Config['SQLServer'])"
            $connection = New-Object System.Data.Odbc.OdbcConnection
            $connection.ConnectionString = $connStr
            $connection.Open()
            if ($connection.State -ne 'Open') {
                Start-Sleep -Seconds 5
                $connection = New-Object System.Data.Odbc.OdbcConnection
                $connection.ConnectionString = $connStr
                $connection.Open()
            }
        }
    }

    Write-Debug "Connection state: $($connection.State)"
    return $connection
}
#endregion

#region --- Query execution ---
<#
.SYNOPSIS
    Executes a SQL query and returns the result as a DataTable.
    Returns $null on failure and writes the error message to stdout
    (which Zabbix will capture as the item value).
    Handles both SqlClient (SQL Server) and OdbcConnection (PostgreSQL) transparently.
#>
function Invoke-SqlQuery {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [System.String]$Query,
        [Parameter(Mandatory = $true)]
        [hashtable]$Config
    )

    $connection = $null
    try {
        $connection = Start-Connection -Config $Config
        # Instantiate the correct command/adapter types based on the connection type
        if ($connection -is [System.Data.SqlClient.SqlConnection]) {
            $cmd = New-Object System.Data.SqlClient.SqlCommand
            $adapter = New-Object System.Data.SqlClient.SqlDataAdapter
        }
        else {
            $cmd = New-Object System.Data.Odbc.OdbcCommand
            $adapter = New-Object System.Data.Odbc.OdbcDataAdapter
        }
        $cmd.CommandText = $Query
        $cmd.Connection = $connection
        $cmd.CommandTimeout = 0

        Write-Debug "Executing SQL query: ##$Query##"

        $adapter.SelectCommand = $cmd
        $dataSet = New-Object System.Data.DataSet
        $adapter.Fill($dataSet) | Out-Null
        $table = $dataSet.Tables[0]

        # Convert DataTable rows to PSCustomObjects so that Sort-Object, Select-Object
        # and property dot-notation all work correctly downstream.
        # DataRow objects only expose columns via indexer; PS property access is unreliable
        # across providers, particularly after Sort-Object re-wraps the rows.
        $retval = @()
        if ($null -ne $table) {
            $columns = $table.Columns | ForEach-Object { $_.ColumnName }
            foreach ($row in $table.Rows) {
                $obj = [ordered]@{}
                foreach ($col in $columns) {
                    $val = $row[$col]
                    # Replace DBNull with $null so callers can use simple -eq $null checks
                    if ($val -is [System.DBNull]) { $val = $null }
                    $obj[$col] = $val
                }
                $retval += [PSCustomObject]$obj
            }
        }
    }
    catch {
        $retval = $null
        Write-Output $_.Exception.Message
    }
    finally {
        if ($null -ne $connection) {
            $connection.Close()
        }
    }
    return $retval
}
#endregion

#region --- SQL dialect helpers ---
<#
.SYNOPSIS
    Returns a provider-aware SQL snippet that limits rows to $n, for use
    at the end of a SELECT statement.
    SQL Server uses TOP n in the SELECT clause; PostgreSQL uses LIMIT n at the end.
    Because TOP must appear in the SELECT clause (not at the end), callers that
    need TOP must handle SQL Server separately. For LIMIT-style providers this
    function appends "LIMIT n".
    Where possible the queries below use ORDER BY + this helper so that a single
    query string can be shared.
#>
function Get-LimitClause {
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$Config,
        [Parameter(Mandatory = $true)]
        [int]$Rows
    )
    if ($Config['DBProvider'] -eq 'Postgres') {
        return "LIMIT $Rows"
    }
    # SQL Server: caller must embed TOP n inside the SELECT clause
    return ""
}

<#
.SYNOPSIS
    Wraps an identifier in the correct quoting style for the active provider.
    SQL Server uses [brackets]; PostgreSQL uses "double quotes".
#>
function Get-QuotedIdentifier {
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$Config,
        [Parameter(Mandatory = $true)]
        [System.String]$Name
    )
    if ($Config['DBProvider'] -eq 'Postgres') {
        return "`"$Name`""
    }
    return "[$Name]"
}
#endregion

#region --- Helper functions ---
<#
.SYNOPSIS
    Converts a DateTime to a Unix timestamp (seconds since epoch).
    Returns -1 for null or pre-epoch dates, which makes the Zabbix item
    "unsupported" while a job is running or before its first run.
#>
function ConvertTo-UnixTimestamp {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [System.Object]$Date
    )

    [System.DateTime]$epoch = Get-Date -Date "01/01/1970 00:00:00Z"

    # Accept $null or non-DateTime values (e.g. DBNull already converted to $null)
    if ($null -eq $Date -or $Date -isnot [System.DateTime] -or ([System.DateTime]$Date) -lt $epoch) {
        return -1
    }

    return [int]((New-TimeSpan -Start $epoch -End ([System.DateTime]$Date)).TotalSeconds)
}

<#
.SYNOPSIS
    Builds a PSCustomObject with standardised job session fields
    ready for JSON serialisation.
#>
function Get-SessionInfo {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [System.Object]$BackupSession
    )

    if (-not $BackupSession) { return $null }

    # Collect failure reasons from both the reason column and the embedded XML log
    $reason = $BackupSession.reason
    if (-not [string]::IsNullOrWhiteSpace($BackupSession.log_xml)) {
        $logEntries = (([xml]$BackupSession.log_xml).Root.Log | Where-Object { $_.Status -eq 'EFailed' }).Title
        foreach ($entry in $logEntries) {
            $reason += "`r`n$entry"
        }
    }

    Write-Debug "Building session info object for job: $($BackupSession.job_name)"

    return [PSCustomObject]@{
        JOBID                = $BackupSession.job_id
        JOBTYPEID            = $BackupSession.job_type
        JOBTYPENAME          = $typeNames[$BackupSession.job_type]
        JOBNAME              = [System.Net.WebUtility]::HtmlEncode($BackupSession.job_name)
        JOBRESULT            = $BackupSession.result
        JOBRETRY             = $BackupSession.is_retry
        JOBREASON            = [System.Net.WebUtility]::HtmlEncode($reason)
        JOBPROGRESS          = $BackupSession.progress
        JOBSTART             = ConvertTo-UnixTimestamp ($BackupSession.creation_time -as [datetime] | ForEach-Object { $_.ToUniversalTime() })
        JOBEND               = ConvertTo-UnixTimestamp ($BackupSession.end_time -as [datetime] | ForEach-Object { $_.ToUniversalTime() })
        JOBBACKUPTOTALSIZE   = $BackupSession.backup_total_size
        JOBTOTALSIZE         = $BackupSession.total_size
        JOBTOTALUSEDSIZE     = $BackupSession.total_used_size
        JOBPROCESSEDSIZE     = $BackupSession.processed_size
        JOBPROCESSEDUSEDSIZE = $BackupSession.processed_used_size
        JOBSTOREDSIZE        = $BackupSession.stored_size
        JOBBACKEDUPSIZE      = $BackupSession.backed_up_size
        JOBAVGSPEED          = $BackupSession.avg_speed
    }
}
#endregion

#region --- Operations ---
<#
.SYNOPSIS
    Returns JSON with information about all active, scheduled Veeam jobs.
#>
function Get-JobInfo {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$Config
    )

    Write-Debug "Entering Get-JobInfo()"

    # ---------------------------------------------------------------
    # Fetch active jobs — dialect-specific quoting & table references
    # ---------------------------------------------------------------
    if ($Config['DBProvider'] -eq 'Postgres') {
        $jobsQuery = @"
SELECT id, name, options
FROM BJobs
WHERE schedule_enabled = 'true'
  AND type IN $jobTypes
ORDER BY type, name
"@
    }
    else {
        $jobsQuery = @"
SELECT id, name, options
FROM [BJobs]
WHERE [schedule_enabled] = 'true'
  AND [type] IN $jobTypes
ORDER BY [type], [name]
"@
    }

    $jobs = Invoke-SqlQuery -Config $Config -Query $jobsQuery

    if ($null -eq $jobs) { return }

    Write-Debug "Active job count: $(@($jobs).Count)"

    $result = @()
    foreach ($job in $jobs) {
        # Skip jobs configured to run manually only
        if (([xml]$job.options).JobOptionsRoot.RunManually -eq 'False') {
            Write-Debug "Fetching last session for job: $($job.name)"

            # -----------------------------------------------------------
            # Fetch the two most-recent sessions for this job.
            # SQL Server uses TOP 2; PostgreSQL uses LIMIT 2.
            # Table names differ by provider:
            #   SQL Server : [Backup.Model.JobSessions] / [Backup.Model.BackupJobSessions]
            #   PostgreSQL : "backup.model.jobsessions" / "backup.model.backupjobsessions"
            # -----------------------------------------------------------
            if ($Config['DBProvider'] -eq 'Postgres') {
                $sessionsQuery = @"
SELECT job_id, job_type, job_name, result, is_retry, progress,
       creation_time, end_time, log_xml, reason,
       backup_total_size, total_size, total_used_size,
       processed_size, processed_used_size, avg_speed,
       read_size, stored_size, backed_up_size
FROM "backup.model.jobsessions"
INNER JOIN "backup.model.backupjobsessions" ON "backup.model.jobsessions".id = "backup.model.backupjobsessions".id
WHERE job_id = '$($job.id)'
ORDER BY creation_time DESC
LIMIT 2
"@
            }
            else {
                $sessionsQuery = @"
SELECT TOP 2
    job_id, job_type, job_name, result, is_retry, progress,
    creation_time, end_time, log_xml, reason,
    backup_total_size, total_size, total_used_size,
    processed_size, processed_used_size, avg_speed,
    read_size, stored_size, backed_up_size
FROM [Backup.Model.JobSessions]
INNER JOIN [Backup.Model.BackupJobSessions] ON [Backup.Model.JobSessions].[id] = [Backup.Model.BackupJobSessions].[id]
WHERE job_id = '$($job.id)'
ORDER BY creation_time DESC
"@
            }

            $lastJobSessions = Invoke-SqlQuery -Config $Config -Query $sessionsQuery
            $lastJobSession = $lastJobSessions | Sort-Object end_time -Descending | Select-Object -First 1

            # Exception: BackupSync continuous state — use the older session instead
            if ($lastJobSession.job_type -like '51' -and $lastJobSession.state -like '9') {
                $lastJobSession = $lastJobSessions | Sort-Object end_time -Descending | Select-Object -Last 1
            }

            if ($null -eq $lastJobSession) {
                Write-Debug "No sessions found for job: $($job.name)"
                continue
            }
            $sessionInfo = Get-SessionInfo -BackupSession $lastJobSession
            if ($null -ne $sessionInfo) {
                $result += $sessionInfo
            }
        }
    }

    Write-Verbose "Returning info for $($result.Count) job(s)"
    Write-Output (ConvertTo-Json -Compress -InputObject @($result))
}

<#
.SYNOPSIS
    Returns JSON with repository capacity and availability information.
#>
function Get-RepoInfo {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$Config
    )

    Write-Debug "Entering Get-RepoInfo()"

    # The BackupRepositoriesView columns are the same in both providers.
    # Quoting style differs: brackets vs. double-quotes.
    if ($Config['DBProvider'] -eq 'Postgres') {
        $repoQuery = @"
SELECT name, total_space, free_space, is_unavailable, is_full, type
FROM BackupRepositoriesView
ORDER BY name
"@
    }
    else {
        $repoQuery = @"
SELECT [name], [total_space], [free_space], [is_unavailable], [is_full], [type]
FROM [dbo].[BackupRepositoriesView]
ORDER BY [name]
"@
    }

    $repos = Invoke-SqlQuery -Config $Config -Query $repoQuery

    if ($null -eq $repos) { return }

    $result = @()
    foreach ($repo in $repos) {
        if ([string]::IsNullOrWhiteSpace($repo.name)) { continue }
        Write-Debug "Processing repository: $($repo.name)"
        $result += [PSCustomObject]@{
            REPONAME      = [System.Net.WebUtility]::HtmlEncode($repo.name)
            REPOCAPACITY  = [int64]$repo.total_space
            REPOFREE      = [int64]$repo.free_space
            REPOOUTOFDATE = ($repo.is_unavailable -or $repo.is_full)
            REPOTYPE      = [string]$repo.type
        }
    }

    Write-Debug "Repository count: $($result.Count)"
    Write-Output (ConvertTo-Json -Compress -InputObject @($result))
}

<#
.SYNOPSIS
    Returns the total number of active Veeam jobs as a plain integer string.
#>
function Get-TotalJob {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$Config
    )

    Write-Debug "Entering Get-TotalJob()"

    if ($Config['DBProvider'] -eq 'Postgres') {
        $totalQuery = @"
SELECT COUNT(name) AS JobCount
FROM JobsView
WHERE schedule_enabled = 'true'
  AND type IN $jobTypes
"@
    }
    else {
        $totalQuery = @"
SELECT COUNT(name) AS JobCount
FROM [dbo].[JobsView]
WHERE [Schedule_Enabled] = 'true'
  AND [type] IN $jobTypes
"@
    }

    $data = Invoke-SqlQuery -Config $Config -Query $totalQuery

    if ($null -ne $data) {
        Write-Output $data.JobCount
    }
    else {
        Write-Output "-- ERROR -- : No data available. Check configuration."
    }
}
#endregion

#region --- Entry point ---
Write-Debug "Operation  : $Operation"
Write-Debug "ConfigFile : $ConfigFile"
Write-Debug "Job types  : $jobTypes"

$cfg = Read-Config -Path $ConfigFile

switch ($Operation) {
    "RepoInfo" { Get-RepoInfo -Config $cfg }
    "JobsInfo" { Get-JobInfo  -Config $cfg }
    "TotalJob" { Get-TotalJob -Config $cfg }
}
#endregion