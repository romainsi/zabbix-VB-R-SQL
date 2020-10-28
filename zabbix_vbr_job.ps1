# Script: zabbix_vbr_job
# Author: Romainsi
# Description: Query Veeam job information
# This script is intended for use with Zabbix > 5.X

#Configure sqlquery function with user/pass (line 72-73), create user/pass in sql server and reader rights , permit to connect with local user in sql settings.
$veeamserver = 'veeam.contoso.local'

$ITEM = [string]$args[0]

# Function Sort-Object VMs by jobs on last backup (with unique name if retry)
function veeam-backuptask-unique
{
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
		if (($xml1 | Where-Object { $_.Job_Name -like "$unique" }).job_type -like 51)
		{
			$query = $xml1 | Where-Object { $_.Job_Name -like "$unique" } | Sort-Object creation_time -Descending | Select-Object -First 1
			if ($query.end_time -like '01/01/1900 00:00:00')
			{
				$query = $xml1 | Where-Object { $_.Job_Name -like "$unique" } | Sort-Object end_time -Descending | Select-Object -First 1
			}
			## If Idle retrieve last result for BS
			if ($query.Result -like '-1')
			{
				$query = $xml1 | Where-Object { $_.Job_Name -like "$unique" } | Sort-Object end_time -Descending | Select-Object -First 2 | Select-Object -Last 1
			}
		}
		else
		{
			$query = $xml1 | Where-Object { $_.Job_Name -like "$unique" } | Sort-Object creation_time -Descending | Select-Object -First 1
		}
		
		[Xml]$xml = $query.log_xml
		$Log = ($xml.Root.Log | Where-Object { $_.Status -like 'EFailed' }).Title
		
		if ($Log.count -ge '2')
		{
			$Log1 = $Log[1]
			$query | Select-Object @{ N = "JobName"; E = { $query.Job_Name } }, @{ N = "JobResult"; E = { $query.Result } }, @{ N = "JobStart"; E = { $query.creation_time } }, @{ N = "JobEnd"; E = { $query.End_Time } }, @{ N = "Status"; E = { $query.Progress } }, @{ N = "Retry"; E = { $query.is_retry } }, @{ N = "Progress"; E = { $query.progress } }, @{ N = "Reason"; E = { $Log1 } }
		}
		if ($Log.count -lt '2' -and $Log.count -gt '0')
		{
			$query | Select-Object @{ N = "JobName"; E = { $query.Job_Name } }, @{ N = "JobResult"; E = { $query.Result } }, @{ N = "JobStart"; E = { $query.creation_time } }, @{ N = "JobEnd"; E = { $query.End_Time } }, @{ N = "Status"; E = { $query.Progress } }, @{ N = "Retry"; E = { $query.is_retry } }, @{ N = "Progress"; E = { $query.progress } }, @{ N = "Reason"; E = { $Log } }
		}
		if (!$Log)
		{
			$query | Select-Object @{ N = "JobName"; E = { $query.Job_Name } }, @{ N = "JobResult"; E = { $query.Result } }, @{ N = "JobStart"; E = { $query.creation_time } }, @{ N = "JobEnd"; E = { $query.End_Time } }, @{ N = "Status"; E = { $query.Progress } }, @{ N = "Retry"; E = { $query.is_retry } }, @{ N = "Progress"; E = { $query.progress } }, @{ N = "Reason"; E = { $query.reason } }
		}
	}
	$output
}

function QuerySql
{
	[CmdletBinding()]
	param (
		[Parameter(Mandatory = $true)]
		[System.String]$Command
	)
	
	$SQLServer = $veeamserver
	$uid = 'zabbixveeamuser'
	$pwd = 'CHANGE ME'
	$date = get-date -format 'dd/MM/yyyy'
	$date1 = (get-date).AddDays(-1).ToString("dd/MM/yyyy")
	
	# Create a connection to MSSQL
	
	# If windows authentication
	$connectionString = "Server = $SQLServer; User ID = $uid; Password = $pwd;"
	
	# If integrated authentication
	#$connectionString = "Server = $SQLServer; Integrated Security = True;"
	
	$connection = New-Object System.Data.SqlClient.SqlConnection
	$connection.ConnectionString = $connectionString
	$connection.Open()
	if ($connection.State -notmatch "Open")
	{
		Start-Sleep -s 5
		$connectionString = "Server = $SQLServer; User ID = $uid; Password = $pwd;"
		
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
	Try
	{
		$SqlAdapter.Fill($DataSet)
	}
	
	Catch
	{
		$returnsql = $_
	}
	
	$Connection.Close()
	# Verify Error
	if ($returnsql)
	{
		write-host $returnsql
		return
	}
	
	# We get a list of databases. Write to the variable.
	$basename = $DataSet.Tables[0]
	$basename
	
}

switch ($ITEM)
{
	"StartJobs" {
		
		$BackupSessions = QuerySql -Command "SELECT * FROM [VeeamBackup].[dbo].[Backup.Model.JobSessions] INNER JOIN [VeeamBackup].[dbo].[Backup.Model.BackupJobSessions] ON [VeeamBackup].[dbo].[Backup.Model.JobSessions].[id] = [VeeamBackup].[dbo].[Backup.Model.BackupJobSessions].[id]"
		$BackupJobs = QuerySql -Command "SELECT jobs.* FROM [VeeamBackup].[dbo].[JobsView] jobs"
		
		##Result Backup
		$query = $BackupJobs | Where-Object { $_.Schedule_Enabled -like "true" -and $_.Type -like "0" }
		
		$return = $null
		$return = @()
		
		#UTC time
		[System.DateTime]$date = (get-date -date "01/01/1970").AddHours(2)
		
		foreach ($item in $query)
		{
			[xml]$runmanually = $item.options
			if ($runmanually.JobOptionsRoot.RunManually -like "False")
			{
				
				$job = veeam-backuptask-unique -Name $item.name -backupsessions $BackupSessions
				
				if (!$job) { } ## If no history
				
				else
				{
					
					$Object = $null
					$Object = New-Object System.Object
					$Object | Add-Member -type NoteProperty -Name JOBID -Value $item.id
					$Object | Add-Member -type NoteProperty -Name JOBNAME -Value $job.JobName
					$Object | Add-Member -type NoteProperty -Name JOBRESULT -Value $job.JobResult
					$Object | Add-Member -type NoteProperty -Name JOBRETRY -Value $job.Retry
					$Object | Add-Member -type NoteProperty -Name JOBREASON -Value $job.Reason
					$Object | Add-Member -type NoteProperty -Name JOBPROGRESS -Value $job.Progress
					
					[string]$query0 = (($job | Where-Object { $_.JobName -like $job.JOBNAME }).JobStart).ToString('dd/MM/yyyy HH:mm:ss')
					$result = $nextdate, $nexttime = $query0.Split(" ")
					$newdate = ("$($nextdate -replace "(\d{2})-(\d{2})", "`$2-`$1") $nexttime")
					[String]$result0 = (New-TimeSpan -Start $date -end $newdate).TotalSeconds
					
					[string]$query1 = (($job | Where-Object { $_.JobName -like $job.JOBNAME }).JobEnd).ToString('dd/MM/yyyy HH:mm:ss')
					$result1 = $nextdate0, $nexttime0 = $query1.Split(" ")
					$newdate0 = ("$($nextdate0 -replace "(\d{2})-(\d{2})", "`$2-`$1") $nexttime0")
					[String]$result1 = (New-TimeSpan -Start $date -end $newdate0).TotalSeconds
					
					$Object | Add-Member -type NoteProperty -Name JOBSTART -Value $result0
					$Object | Add-Member -type NoteProperty -Name JOBEND -Value $result1
					$Return += $Object
				}
			}
		}
		
		$ResultsBackup = $Return
		cd 'C:\Program Files\Zabbix Agent'
		$Return = ConvertTo-Json -Compress -InputObject @($return)
		$Return = $Return -replace 'é', '&eacute;'
		$Return = $Return -replace 'è', '&eagrave;'
		$Return = $Return -replace 'à', '&aacute;'
		$Return = $Return -replace '"', '""'
		
		.\zabbix_sender.exe -c .\zabbix_agentd.conf -k ResultsBackup -o $Return
		
		## Result BackupSync
		$query = $BackupJobs | Where-Object { $_.Schedule_Enabled -like "true" -and $_.Type -like "51" }
		
		$return = $null
		$return = @()
		
		foreach ($item in $query)
		{
			[xml]$runmanually = $item.options
			if ($runmanually.JobOptionsRoot.RunManually -like "False")
			{
				
				$job = veeam-backuptask-unique -Name $item.name -backupsessions $BackupSessions
				
				$Object = $null
				$Object = New-Object System.Object
				$Object | Add-Member -type NoteProperty -Name JOBBSID -Value $item.id
				$Object | Add-Member -type NoteProperty -Name JOBBSNAME -Value $job.JobName
				$Object | Add-Member -type NoteProperty -Name JOBBSRESULT -Value $job.JobResult
				$Object | Add-Member -type NoteProperty -Name JOBBSRETRY -Value $job.Retry
				$Object | Add-Member -type NoteProperty -Name JOBBSREASON -Value $job.Reason
				
				[string]$query0 = (($job | Where-Object { $_.JobName -like $job.JOBNAME }).JobStart).ToString('dd/MM/yyyy HH:mm:ss')
				$result = $nextdate, $nexttime = $query0.Split(" ")
				$newdate = ("$($nextdate -replace "(\d{2})-(\d{2})", "`$2-`$1") $nexttime")
				[String]$result0 = (New-TimeSpan -Start $date -end $newdate).TotalSeconds
				
				[string]$query1 = (($job | Where-Object { $_.JobName -like $job.JOBNAME }).JobEnd).ToString('dd/MM/yyyy HH:mm:ss')
				$result1 = $nextdate0, $nexttime0 = $query1.Split(" ")
				$newdate0 = ("$($nextdate0 -replace "(\d{2})-(\d{2})", "`$2-`$1") $nexttime0")
				[String]$result1 = (New-TimeSpan -Start $date -end $newdate0).TotalSeconds
				
				$Object | Add-Member -type NoteProperty -Name JOBBSSTART -Value $result0
				$Object | Add-Member -type NoteProperty -Name JOBBSEND -Value $result1
				$Return += $Object
			}
		}
		
		$ResultsBackupSync = $Return
		cd 'C:\Program Files\Zabbix Agent'
		$Return = ConvertTo-Json -Compress -InputObject @($return)
		$Return = $Return -replace 'é', '&eacute;'
		$Return = $Return -replace 'è', '&eagrave;'
		$Return = $Return -replace 'à', '&aacute;'
		$Return = $Return -replace '"', '"""'
		
		.\zabbix_sender.exe -c .\zabbix_agentd.conf -k ResultsBackupSync -o $Return
		
		## Result TapeBackup
		$query = $BackupJobs | Where-Object { $_.Schedule_Enabled -like "true" -and $_.Type -like "28" }
		
		$return = $null
		$return = @()
		
		foreach ($item in $query)
		{
			[xml]$runmanually = $item.options
			if ($runmanually.JobOptionsRoot.RunManually -like "False")
			{
				
				$job = veeam-backuptask-unique -Name $item.name -backupsessions $BackupSessions
				
				$Object = $null
				$Object = New-Object System.Object
				$Object | Add-Member -type NoteProperty -Name JOBTAPEID -Value $item.id
				$Object | Add-Member -type NoteProperty -Name JOBTAPENAME -Value $job.JobName
				$Object | Add-Member -type NoteProperty -Name JOBTAPERESULT -Value $job.JobResult
				$Object | Add-Member -type NoteProperty -Name JOBTAPERETRY -Value $job.Retry
				$Object | Add-Member -type NoteProperty -Name JOBTAPEREASON -Value $job.Reason
				
				[string]$query0 = (($job | Where-Object { $_.JobName -like $job.JOBNAME }).JobStart).ToString('dd/MM/yyyy HH:mm:ss')
				$result = $nextdate, $nexttime = $query0.Split(" ")
				$newdate = ("$($nextdate -replace "(\d{2})-(\d{2})", "`$2-`$1") $nexttime")
				[String]$result0 = (New-TimeSpan -Start $date -end $newdate).TotalSeconds
				
				[string]$query1 = (($job | Where-Object { $_.JobName -like $job.JOBNAME }).JobEnd).ToString('dd/MM/yyyy HH:mm:ss')
				$result1 = $nextdate0, $nexttime0 = $query1.Split(" ")
				$newdate0 = ("$($nextdate0 -replace "(\d{2})-(\d{2})", "`$2-`$1") $nexttime0")
				[String]$result1 = (New-TimeSpan -Start $date -end $newdate0).TotalSeconds
				
				$Object | Add-Member -type NoteProperty -Name JOBTAPESTART -Value $result0
				$Object | Add-Member -type NoteProperty -Name JOBTAPEEND -Value $result1
				$Return += $Object
			}
		}
		
		$ResultsBackupTape = $Return
		cd 'C:\Program Files\Zabbix Agent'
		$Return = ConvertTo-Json -Compress -InputObject @($return)
		$Return = $Return -replace 'é', '&eacute;'
		$Return = $Return -replace 'è', '&eagrave;'
		$Return = $Return -replace 'à', '&aacute;'
		$Return = $Return -replace '"', '""'
		
		if ($Return)
		{
			.\zabbix_sender.exe -c .\zabbix_agentd.conf -k ResultsBackupTape -o $Return
		}
		
		##ResultsRepository
		$query = Get-CimInstance -Class Repository -ComputerName $veeamserver -Namespace ROOT\VeeamBS | Select-Object @{ N = "REPONAME"; E = { $_.NAME } }
		
		$return = $null
		$return = @()
		
		foreach ($item in $query)
		{
			$Result = Get-CimInstance -Class Repository -ComputerName $veeamserver -Namespace ROOT\VeeamBS | Where-Object { $_.Name -eq $item.REPONAME }
			$Object = $null
			$Object = New-Object System.Object
			$Object | Add-Member -type NoteProperty -Name REPONAME -Value $item.REPONAME
			$Object | Add-Member -type NoteProperty -Name REPOCAPACITY -Value ($Result | Select-Object -ExpandProperty Capacity)
			$Object | Add-Member -type NoteProperty -Name REPOFREE -Value ($Result | Select-Object -ExpandProperty FreeSpace)
			$Return += $Object
		}
		cd 'C:\Program Files\Zabbix Agent'
		$Return = ConvertTo-Json -Compress -InputObject @($return)
		$Return = $Return -replace '"', '""'
		
		.\zabbix_sender.exe -c .\zabbix_agentd.conf -k RepoInfo -o $return
	}
	
	"TotalJob" {
		$BackupJobs = QuerySql -Command "SELECT jobs.* FROM [VeeamBackup].[dbo].[JobsView] jobs"
		$query = ($BackupJobs | sort name -unique | Where-Object { $_.Schedule_Enabled -like "true" -and ($_.Type -like "0" -or $_.Type -like "28" -or $_.Type -like "51") }).count
		write-host $query
	}
	
	default
	{
		write-output "-- ERROR -- : Need an option !"
	}
}
