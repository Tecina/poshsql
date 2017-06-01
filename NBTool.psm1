Function CreateTraxDB {
 <#
  .SYNOPSIS
  New SQL Database creation for TRAX.

  .DESCRIPTION
  This powershell function helps configure an SQL environement for new client.
  It sets up user's Log shipping directory, SQL Database and create the SQL user.
  SQL sysadmin user's password is defined in the function to allow remote script 
  execution.

  .EXAMPLE
  CreateTraxDB -BIC CLIENTBIC -pwd 'somepolicyapprovedpassword' 

  .PARAMETER BIC
  The eight character client ID

  .PARAMETER pwd
  SQL database client user's password
 
  .NOTES
		Version:		1.0
		Author:			Anicet SAULET
		Creation Date:	June 15th, 2016
#>

[CmdletBinding()]
Param (
       [Parameter(Mandatory=$True)] #Enforce the use of bic and password
	   [string]$bic,
   	   [string]$passwd
       )

# Declare the permanent sources and destination paths
$proda = "SQLTEST"
$prodl = "SQLITB"
$SourcePath = "D:\Scripts\Deployment\"
$MPFullbkpfolder = "E:\MSSQL\Backup\Full"
$LSpath = 'D:\LSTestToITB'
$sqlitblocalusr='sqlsystest'
$sqlitbusrpwd='HB$EV!xZ3aq6sW7'

# Validate LS folders on primary and secondary server
if ((Test-Path "$LSpath\trax_$bic") -and (Test-Path "\\$prodl\$LSpath\trax_$bic")){
    Get-ChildItem "$LSpath" -Filter "trax_$bic" | Remove-Item -Recurse -Force
    Get-ChildItem "\\$prodl\LSITBtoTest" -Filter "trax_$bic" | Remove-Item -Recurse -Force  
}else {}

# Create clients's log shipping directory
$LSbicdir = New-Item -Path "$LSpath" -name "trax_$bic" -ItemType Directory -ErrorAction Stop
	Write-Host "trax_$bic folder created on $proda" -ForegroundColor Black -BackgroundColor Green
        
# Create Log Shipping directory on secondary server
$LSbicdir2 = New-Item -Path "Microsoft.PowerShell.Core\FileSystem::\\$prodl\LSITBtoTest" -name "trax_$bic" -ItemType Directory -ErrorAction Stop
	Write-Host " Client $bic folder has been created on $prodl " -ForegroundColor Black -BackgroundColor Green
		 
# Getting all sql files and copy them to the destination folder
$sqlfiles = Get-ChildItem -Path $SourcePath -Include *.sql -Recurse -ErrorAction Stop
	Copy-Item $sqlfiles $LSbicdir -ErrorAction Stop

# Collect files in Log Shipping directory
$cpfilez = Get-ChildItem $LSbicdir -Filter *.sql                            
	Write-Host "Changing sql files content to match $bic" -ForegroundColor Black -BackgroundColor Green

Foreach ($filez in $cpfilez) {
    (Get-Content $filez.FullName) | ForEach-Object { $_ -replace 'clientbic', "$bic" -replace 'Azerty123', "$passwd" -replace 'LSmainfolder', "$LSpath" -replace 'proda', "$proda" -replace 'prodl', "$prodl" -replace 'lsfolder', "$LSbicdir" -replace 'lsfoldr2', "$LSbicdir2" -replace 'ls1to2', 'LSTestToITB' -replace 'ls2to1', 'LSITBtoTest' -replace 'mpfdir', "$MPFullbkpfolder" } | Set-Content $filez.FullName
}

###############################################################################################################
################################## HERE BEGINS SQL CONFIGURATION ##############################################

# 1 # Test primary DB exists then run scripts according to one of each scenario
$testDB = & {Add-Type -AssemblyName "Microsoft.SqlServer.Smo, Version=10.0.0.0, Culture=neutral, PublicKeyToken=89845dcd8080cc91"
$testsrv = New-Object Microsoft.SqlServer.Management.Smo.Server ("$proda")
if(($testsrv.Databases["trax_$bic"].IsAccessible -eq $true)) {
    $true
} else { $false }
}
if(($testDB -eq $true ) -or (Test-Path $MPFullbkpfolder\*trax_$bic.bak)){
	(gci $MPFullbkpfolder -Filter *.bak | %{Copy-Item $_.FullName $LSbicdir})
	Invoke-sqlcmd -InputFile "$LSbicdir\__01_On_Primary_Conf_ExistingDB_.sql" -ServerInstance "$proda" -ErrorAction Stop
		Write-Host " The database and user trax_$bic configured on $proda" -ForegroundColor Black -BackgroundColor Green
}else{Invoke-sqlcmd -InputFile "$LSbicdir\__01_On_Primary_CreateDB_.sql" -ServerInstance "$proda" -ErrorAction Stop
        Write-Host " The database and user trax_$bic created on $proda" -ForegroundColor Black -BackgroundColor Green}

# 2 # Configure trax_clientbic database on primary server as primary log shipping database
Invoke-sqlcmd -InputFile "$LSbicdir\__02_On_Primary_Set_LS_DB_svr1.sql" -ServerInstance "$proda" -ErrorAction Stop
    Write-Host " trax_$bic is now the primary log shipping database " -ForegroundColor Black -BackgroundColor Green 

# 3 # Full backup of trax_clientbic primary database
(Set-location $LSbicdir)
if (Test-Path $MPFullbkpfolder\*trax_$bic.bak){
	Get-ChildItem $MPFullbkpfolder -Filter *$bic.bak | %{Copy-Item $_.FullName $LSbicdir2} -ErrorAction Stop
		Write-Host " trax_$bic Full backup copied to $prodl " -ForegroundColor Black -BackgroundColor Green
}else{(Invoke-sqlcmd -InputFile "$LSbicdir\__03_On_Primary_BakDBFull_svr1.sql" -ServerInstance "$proda" -ErrorAction Stop)
	  Get-ChildItem $LSbicdir -Filter *$bic.bak | %{Copy-Item $_.FullName $LSbicdir2 -ErrorAction Stop} 
		Write-Host " trax_$bic full backup succeed" -ForegroundColor Black -BackgroundColor Green}

# 4 # Create trax_clientbic database on secondary server by restoring the full backup for primary
Invoke-sqlcmd -InputFile "$LSbicdir\__01_On_Secondary_CreateDB2_srv2.sql" -ServerInstance "$prodl" -Username "$sqlitblocalusr" -Password "$sqlitbusrpwd" -ErrorAction Stop
    Write-Host " trax_$bic is now restored to $prodl " -ForegroundColor Black -BackgroundColor Green

# 5 # Configure trax_clientbic database on secondary server as secondary log shipping database
Invoke-sqlcmd -InputFile "$LSbicdir\__02_On_Secondary_Set_LSDB2_srv2.sql" -ServerInstance "$prodl" -Username "$sqlitblocalusr" -Password "$sqlitbusrpwd" -ErrorAction Stop
    Write-Host " trax_$bic is now set as the secondary log shipping database " -ForegroundColor Black -BackgroundColor Green
		 
Set-location c:\
}
