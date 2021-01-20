# zabbix-VB-R-SQL
Monitore VB&amp;R with SQL query

1.  Copy script to "C:\Program Files\Zabbix Agent\scripts\zabbix_vbr_job.ps1"

2.  Add UserParameter in zabbix_agentd.conf : UserParameter=vbr[*],powershell -NoProfile -ExecutionPolicy Bypass -File "C:\Program Files\Zabbix Agent\scripts\zabbix_vbr_job.ps1" "$1"

3.  In script, ajust variable $veeamserver = 'veeam.contoso.local' (line 10) and sqlquery function with user/pass (line 75-76) that you will create in the next step on the sql server 

3.  Connect to the veeam sql server (with sql server express or other, adjust protocols for VEEAMSQL in "Sql Server Configuration Manager" for permit to connect with TCP/IP) and create user/pass with reader rights , permit to connect with local user in sql settings and specify the default database.

4.  Import template and wait for firsts results.
