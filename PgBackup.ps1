# PostgreSQL Backup Script
# Script for automatic PostgreSQL database backup

# Setting console encoding
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

# Add PostgreSQL path to current session
$env:Path += ";E:\Program Files\PostgreSQL\16.4-5.1C\bin"

# PostgreSQL connection parameters
$PostgresServer = "localhost"
$PostgresDB = "prod_zup"
$PostgresUser = "postgres"

# Backup path parameters
$BackupBasePath = "\\nas-synology\1c\zup"
$DailyBackupPath = Join-Path $BackupBasePath "daily_backups"
$MonthlyBackupPath = Join-Path $BackupBasePath "monthly_backups"

# Retention parameters
$DailyRetentionDays = 30
$MonthlyRetentionDays = 365

# Logging parameters
$LogPath = "C:\PostgresBackup\Logs"
$LogFile = Join-Path $LogPath "backup_$(Get-Date -Format 'yyyy-MM-dd').log"

# Email notification parameters
$SmtpServer = "mx.gdz.aero"
$EmailFrom = "postgres-backup@gdz.aero"
$EmailTo = @("a.paltyshev@gdz.aero", "help@gdz.aero")

# Function to retrieve stored credentials
function Get-StoredCredential {
    param (
        [string]$Target
    )
    
    $credPath = "C:\PostgresBackup\Credentials\$Target.json"
    
    if (Test-Path $credPath) {
        $credData = Get-Content -Path $credPath | ConvertFrom-Json
        
        # Convert encrypted string back to SecureString
        $securePassword = ConvertTo-SecureString -String $credData.Password
        
        # Create PSCredential object
        return New-Object System.Management.Automation.PSCredential($credData.Username, $securePassword)
    } else {
        return $null
    }
}

# Logging function
function Write-Log {
    param(
        [string]$Message,
        [string]$Level = "INFO"
    )
    
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $logMessage = "[$timestamp] [$Level] $Message"
    
    # Create log directory if it doesn't exist
    if (!(Test-Path $LogPath)) {
        New-Item -ItemType Directory -Path $LogPath -Force | Out-Null
    }
    
    # Log rotation if size exceeds 100MB
    if ((Test-Path $LogFile) -and ((Get-Item $LogFile).Length -gt 100MB)) {
        $oldLog = Join-Path $LogPath "backup_$(Get-Date -Format 'yyyy-MM-dd_HHmmss').old.log"
        Move-Item -Path $LogFile -Destination $oldLog -Force
    }
    
    # Use UTF8 for proper encoding
    Add-Content -Path $LogFile -Value $logMessage -Encoding UTF8
    
    # Display message in console
    Write-Host $logMessage
}

# Email notification function
function Send-NotificationEmail {
    param(
        [string]$Subject,
        [string]$Body
    )
    
    try {
        $emailParams = @{
            From = $EmailFrom
            To = $EmailTo
            Subject = $Subject
            Body = $Body
            SmtpServer = $SmtpServer
            ErrorAction = "Stop"
        }
        Send-MailMessage @emailParams
        Write-Log "Email notification sent successfully" "INFO"
    }
    catch {
        Write-Log "Failed to send email notification: $_" "ERROR"
    }
}

# Backup path availability check function
function Test-BackupPath {
    param(
        [string]$Path
    )
    
    try {
        if (!(Test-Path $Path)) {
            New-Item -ItemType Directory -Path $Path -Force | Out-Null
            Write-Log "Created backup directory: $Path" "INFO"
        }
        
        return $true
    }
    catch {
        Write-Log "Failed to access or create backup path $Path : $_" "ERROR"
        return $false
    }
}

# Backup filename generation function
function Get-BackupFileName {
    $timestamp = Get-Date -Format "yyyy_MM_dd_HHmmss"
    $random = Get-Random -Minimum 1000000 -Maximum 9999999
    return "gdz_1c_prod_zup_backup_${timestamp}_${random}.backup"
}

# Backup integrity check function
function Test-BackupIntegrity {
    param(
        [string]$BackupFile
    )
    
    try {
        # Using direct path in case PATH variable doesn't work
        $pgRestorePath = "E:\Program Files\PostgreSQL\16.4-5.1C\bin\pg_restore.exe"
        if (!(Test-Path $pgRestorePath)) {
            # Fall back to PATH if direct path doesn't exist
            $pgRestorePath = "pg_restore"
        }
        
        $result = & $pgRestorePath --list $BackupFile 2>&1
        Write-Log "Backup integrity check completed with exit code: $LASTEXITCODE" "INFO"
        return $LASTEXITCODE -eq 0
    }
    catch {
        Write-Log "Backup integrity check failed: $_" "ERROR"
        return $false
    }
}

# Database backup function
function Backup-PostgresDatabase {
    param (
        [string]$BackupPath,
        [string]$BackupType
    )
    
    $backupFile = Join-Path $BackupPath (Get-BackupFileName)
    
    try {
        Write-Log "Starting $BackupType backup to $backupFile" "INFO"
        
        # Get password from stored credentials
        $pgCreds = Get-StoredCredential -Target "PostgreSQL"
        if (-not $pgCreds) {
            throw "Failed to get PostgreSQL credentials"
        }
        
        $env:PGPASSWORD = $pgCreds.GetNetworkCredential().Password
        
        # Using direct path in case PATH variable doesn't work
        $pgDumpPath = "E:\Program Files\PostgreSQL\16.4-5.1C\bin\pg_dump.exe"
        if (!(Test-Path $pgDumpPath)) {
            # Fall back to PATH if direct path doesn't exist
            $pgDumpPath = "pg_dump"
        }
        
        Write-Log "Using pg_dump from: $pgDumpPath" "INFO"
        $startTime = Get-Date
        & $pgDumpPath -h $PostgresServer -U $PostgresUser -d $PostgresDB -F c -Z 9 -f $backupFile
        
        if ($LASTEXITCODE -eq 0 -and (Test-BackupIntegrity -BackupFile $backupFile)) {
            $duration = (Get-Date) - $startTime
            Write-Log "$BackupType backup completed successfully. Duration: $($duration.TotalMinutes) minutes" "INFO"
            return $true
        } else {
            throw "Backup failed or integrity check failed with exit code: $LASTEXITCODE"
        }
    }
    catch {
        Write-Log "Error during $BackupType backup: $_" "ERROR"
        Send-NotificationEmail -Subject "PostgreSQL $BackupType Backup Failed" -Body "Error during backup: $_"
        return $false
    }
    finally {
        $env:PGPASSWORD = ""
    }
}

# Old backups cleanup function
function Remove-OldBackups {
    param (
        [string]$BackupPath,
        [int]$RetentionDays,
        [string]$BackupType
    )
    
    try {
        $removedCount = 0
        Get-ChildItem $BackupPath -Filter "gdz_1c_prod_zup_backup_*.backup" | 
        Where-Object {
            $age = (Get-Date) - $_.CreationTime
            $age.Days -gt $RetentionDays
        } | ForEach-Object {
            Remove-Item $_.FullName -Force
            $removedCount++
        }
        
        Write-Log "Removed $removedCount old $BackupType backup files" "INFO"
    }
    catch {
        Write-Log "Error during $BackupType backup cleanup: $_" "ERROR"
        Send-NotificationEmail -Subject "PostgreSQL $BackupType Backup - Cleanup Failed" -Body "Error during cleanup: $_"
    }
}

# Main execution block
try {
    Write-Log "Starting backup process" "INFO"
    Write-Log "PostgreSQL path: $env:Path" "INFO"
    
    # Test if pg_dump is accessible
    try {
        $pgDumpPath = "E:\Program Files\PostgreSQL\16.4-5.1C\bin\pg_dump.exe"
        if (Test-Path $pgDumpPath) {
            $pgDumpVersion = & $pgDumpPath --version 2>&1
            Write-Log "pg_dump version: $pgDumpVersion" "INFO"
        } else {
            Write-Log "WARNING: pg_dump not found at $pgDumpPath, will try to use from PATH" "WARNING"
            $pgDumpVersion = & pg_dump --version 2>&1
            Write-Log "pg_dump version from PATH: $pgDumpVersion" "INFO"
        }
    }
    catch {
        Write-Log "Warning: Could not check pg_dump version: $_" "WARNING"
    }
    
    # Check backup paths availability
    $pathsOK = @(
        (Test-BackupPath -Path $DailyBackupPath),
        (Test-BackupPath -Path $MonthlyBackupPath)
    ) -notcontains $false
    
    if (-not $pathsOK) {
        throw "Failed to access or create backup paths"
    }
    
    # Determine backup type
    $currentDate = Get-Date
    $isMonthlyBackupDay = ($currentDate.Day -eq 1) -or ($currentDate.Day -eq 15)
    $isNightBackup = $currentDate.Hour -eq 0
    $isDayBackup = $currentDate.Hour -eq 12
    
    # Create backup
    if ($isMonthlyBackupDay -and $isNightBackup) {
        $backupSuccess = Backup-PostgresDatabase -BackupPath $MonthlyBackupPath -BackupType "Monthly"
        if ($backupSuccess) {
            Remove-OldBackups -BackupPath $MonthlyBackupPath -RetentionDays $MonthlyRetentionDays -BackupType "Monthly"
        }
    } else {
        $backupSuccess = Backup-PostgresDatabase -BackupPath $DailyBackupPath -BackupType "Daily"
        if ($backupSuccess) {
            Remove-OldBackups -BackupPath $DailyBackupPath -RetentionDays $DailyRetentionDays -BackupType "Daily"
        }
    }
    
    if (-not $backupSuccess) {
        throw "Backup failed"
    }
}
catch {
    Write-Log "Critical error: $_" "ERROR"
    Send-NotificationEmail -Subject "PostgreSQL Backup - Critical Error" -Body "Critical error during backup process: $_"
    exit 1
}
