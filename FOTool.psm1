Function FailoverTraxDB{ 

[CmdletBinding()]
Param (
       [Parameter(Mandatory=$True)] #Enforce the use of bic number
	   [string]$bic
      )

# Defining variables
$proda = "SQLTEST"
$prodl = "SQLITB"
$SourcePath = "D:\Scripts\Failover"
$DRLogShippingfolder = "D:\DRITBtoTest"
$DRLogsfolder2 = "D:\DRTestToITB"
$LSbicdir = "\\$proda\D$\LSTestToITB\trax_$bic"
$MPdifffolder="\\$proda\E`$\MSSQL\Backup\Differential"
$MPbkpfolder="\\$proda\E`$\MSSQL\Backup\Full"
$sqltestlocalusr='sqlsystest'
$sqltestusrpwd='HB$EV!xZ3aq6sW7'

if ((Test-Path "D:\DRITBtoTest\trax_$bic") -and (Test-Path "\\$proda\D$\DRTestToITB\trax_$bic")){
    Get-ChildItem $DRLogShippingfolder -Filter "trax_$bic" | Remove-Item -Recurse -Force
    Get-ChildItem "\\$proda\D$\DRTestToITB" -Filter "trax_$bic" | Remove-Item -Recurse -Force  
}
else {}

# Create clients's Disaster Recovery (DR) folder on primary server [error action continue if the folder exist]
$DRbicdir2 = New-Item -Path $DRLogShippingfolder -name "trax_$bic" -ItemType Directory -ErrorAction Continue
    Write-Host " trax_$bic folder for Disaster Recovery created on $prodl" -ForegroundColor Black -BackgroundColor Green

# Create clients's Disaster Recovery (DR) folder on secondary server[error action continue if the folder exist]
$DRbicdir = New-Item -Path "Microsoft.PowerShell.Core\FileSystem::\\$proda\D$\DRTestToITB" -name "trax_$bic" -ItemType Directory -ErrorAction Stop
    Write-Host " Client $bic folder for Disaster Recovery created on $proda " -ForegroundColor Black -BackgroundColor Green
  		
# Getting all sql files and copy them to the destination folder
$sqlfiles = Get-ChildItem $SourcePath\* -Include __01*, __02*, __03*, __04* -ErrorAction Stop
# Copy command from source library to newly created folder
Copy-Item $sqlfiles $DRbicdir2 -ErrorAction Stop
    Write-Host " SQL files copy succeed. " -ForegroundColor Black -BackgroundColor Green

# Replace trax_clientbicdb, sqlitb1 et 2, paths 
$rpfiles = @(Get-ChildItem -Force $DRbicdir2\* -Include *.sql)
if ($rpfiles -ne $null) {               
	Foreach ($files in $rpfiles) {
            (Get-Content $files.PSPath) | ForEach-Object { $_ -replace 'clientbic', "$bic" -replace 'proda', "$proda" -replace 'prodl', "$prodl" -replace 'ppth', "$DRLogShippingfolder" -replace 'DRrep1to2', 'DRITBtoTest' -replace 'DRrep2to1', 'DRTestToITB' -replace 'DRbicdir2', "$DRbicdir2" -replace 'DRbicdir', "$DRbicdir" -replace 'drlogrep2', "$DRLogsfolder2" } | Set-Content $files.PSPath }
            Write-Host " SQL files modified" -ForegroundColor Black -BackgroundColor Green 
}
    else { Write-Host " No files were edited to match $bic " -ForegroundColor Black -BackgroundColor Red }

# Copy Edited SQL script onto secondary(TEST/DR) server
$cpfile = Get-ChildItem $DRbicdir2
Copy-Item $cpfile.FullName $DRbicdir -ErrorAction Continue

########################################################################################################################################
########################################### TEST PRIMARY DB STATE BEFORE CONTINUING  ###################################################
# Verify DB state before proceeding: DB is online and not in ReadOnly
$testDB = & {Add-Type -AssemblyName "Microsoft.SqlServer.Smo, Version=10.0.0.0, Culture=neutral, PublicKeyToken=89845dcd8080cc91"
$testsrv = New-Object Microsoft.SqlServer.Management.Smo.Server ("$proda")
if(($testsrv.Databases["trax_$bic"].IsAccessible -eq $true) -and ($testsrv.Databases["trax_$bic"].ReadOnly -eq $false)) {
    $true
} else { $false }
}
if($testDB){
    Write-Host " trax_$bic is ONLINE on $proda " -ForegroundColor Green
}
else{
    Write-Warning " trax_$bic is either in NORECOVERY mode or STANDBY mode "
    BREAK # This to stop script execution if DB is in NORECOVERY or STANDBY
}


##########################################################################################################################################
################################################### HERE BEGINS SQL CONFIGURATION ########################################################

# 1 # Update prodl DB with latest transaction log
Invoke-Sqlcmd -InputFile "$DRbicdir\__01_DR_Run_BackupJob.sql" -ServerInstance "$proda" -Username "$sqltestlocalusr" -Password "$sqltestusrpwd" -ErrorAction Stop
Invoke-Sqlcmd -InputFile "$DRbicdir2\__01_DR_Run_CopyJob.sql" -ServerInstance "$prodl" -ErrorAction Stop
Invoke-Sqlcmd -InputFile "$DRbicdir2\__01_DR_Run_RestoreJob.sql" -ServerInstance "$prodl" -ErrorAction Stop
    Write-Host " Secondary trax_$bic DB on $prodl has been synced with primary on $proda" -ForegroundColor Black -BackgroundColor Green

# 2 # Disable backup copy & restore LogShipping job on primary (proda - In The initial Log shipping scenario) and secondary (prodl - In the initial Log shipping scenario) 
Invoke-Sqlcmd -InputFile "$DRbicdir\__02_DR_Disable_BackupJob.sql" -ServerInstance "$proda" -Username "$sqltestlocalusr" -Password "$sqltestusrpwd" -ErrorAction Stop
Invoke-Sqlcmd -InputFile "$DRbicdir2\__02_DR_Disable_CopyJob.sql" -ServerInstance "$prodl" -ErrorAction Stop
Invoke-Sqlcmd -InputFile "$DRbicdir2\__02_DR_Disable_RestoreJob.sql" -ServerInstance "$prodl" -ErrorAction Stop
    Write-Host " Log Shipping jobs disabled " -ForegroundColor Black -BackgroundColor Green

# 3 # Put secondary (prodl) DB ONLINE
Invoke-Sqlcmd -Query " USE [master]; ALTER DATABASE [trax_$bic] SET SINGLE_USER WITH ROLLBACK IMMEDIATE;
 ALTER DATABASE [trax_$bic] SET MULTI_USER; RESTORE DATABASE [trax_$bic] WITH RECOVERY; " -ServerInstance "$prodl" -ErrorAction Stop
    Write-Host " trax_$bic is now ONLINE on server $prodl " -ForegroundColor Black -BackgroundColor Green

# 4 # Configure database on prodl server as primary log shipping database in the DR solution
Invoke-sqlcmd -InputFile "$DRbicdir2\__04_On_Primary_Set_DR_DB_srv1.sql" -ServerInstance "$prodl" -ErrorAction Stop
    Write-Host " trax_$bic is now the primary log shipping FAILOVER database on $prodl " -ForegroundColor Black -BackgroundColor Green

# 5 # Configure client database on proda server as secondary log shipping database in the DR solution
   Invoke-sqlcmd -InputFile "$DRbicdir\__04_On_Secondary_Set_DR_DB_srv1.sql" -ServerInstance "$proda" -Username "$sqltestlocalusr" -Password "$sqltestusrpwd" -ErrorAction Stop
         Write-Host " trax_$bic is now set as the secondary log shipping FAILOVER database on $proda" -ForegroundColor Black -BackgroundColor Green

# 6 # Making sure primary server (proda - In The initial Log shipping scenario) database is either NORECOVERY or STANDBY mode
# The assemblyname key is a general value found on the net
#(Set-Location $DRbicdir2)
$testFODB = & {Add-Type -AssemblyName "Microsoft.SqlServer.Smo, Version=10.0.0.0, Culture=neutral, PublicKeyToken=89845dcd8080cc91"
                $testFO = New-Object Microsoft.SqlServer.Management.Smo.Server ("$proda")
                if(($testFO.Databases["trax_$bic"].IsAccessible -eq $true) -and ($testFO.Databases["trax_$bic"].ReadOnly -eq $false)) {
                    $true} 
                else { $false }
}
    # Fixing primary server (proda - In The initial Log shipping scenario) DB state after DR log shipping configuration
    #If DB is still online on proda then get the last full backup file, copy and rename it into DR folder on proda
    Set-Location C:\ 
   if ($testFODB -eq $true){
        Invoke-sqlcmd -InputFile "$DRbicdir2\__04_DR_Database_Backup.sql" -ServerInstance "$prodl" -ErrorAction Stop
        Get-ChildItem $DRbicdir2 -Filter *.bak | ForEach-Object {Copy-Item $_.FullName $DRbicdir}
        Rename-Item "$DRbicdir\Full_trax_$bic.bak" -NewName "trax_$bic.bak" -ErrorAction Stop
        Copy-Item "$DRbicdir\trax_$bic.bak" -Destination "$DRbicdir\trax_$bic.diff" -ErrorAction Stop
        Invoke-sqlcmd -InputFile "$DRbicdir\__04_On_Secondary_Validate_DB_State.sql" -ServerInstance "$proda" -Username "$sqltestlocalusr" -Password "$sqltestusrpwd" -ErrorAction Stop
            Write-Host " Logs Shipping in FAILOVER state set for trax_$bic" -ForegroundColor Green
            }
   # Otherwise,
   else{
         Write-Host " trax_$bic FAILOVER configuration on $proda checks succeed. secondary DB ready!! "}

cd c:\        
}