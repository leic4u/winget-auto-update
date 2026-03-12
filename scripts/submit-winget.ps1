Import-Module powershell-yaml
. "$PSScriptRoot/resolve-download.ps1"
. "$PSScriptRoot/calc-hash.ps1"
. "$PSScriptRoot/check-existing-pr.ps1"

$updatesFile = "$PSScriptRoot/../updates.json"
$logFile = "$PSScriptRoot/../logs/submit-$(Get-Date -Format 'yyyyMMdd-HHmmss').log"

# 确保日志目录存在
$logDir = Split-Path $logFile -Parent
if (-not (Test-Path $logDir)) {
    New-Item -ItemType Directory -Path $logDir -Force | Out-Null
}

# 清理超过 30 天的日志文件
$maxLogAge = 30
$oldLogs = Get-ChildItem $logDir -Filter "*.log" -ErrorAction SilentlyContinue | 
    Where-Object { $_.LastWriteTime -lt (Get-Date).AddDays(-$maxLogAge) }
if ($oldLogs) {
    $oldLogs | Remove-Item -Force -ErrorAction SilentlyContinue
    Write-Host "Cleaned up $($oldLogs.Count) old log files"
}

function Write-Log($message) {
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $logMessage = "[$timestamp] $message"
    Write-Host $logMessage
    Add-Content -Path $logFile -Value $logMessage
}

if (-not (Test-Path $updatesFile)) {
    Write-Log "Error: updates.json not found at $updatesFile"
    exit 1
}

$updates = Get-Content $updatesFile | ConvertFrom-Json

if (-not $updates -or $updates.Count -eq 0) {
    Write-Log "No updates to process"
    exit 0
}

Write-Log "Processing $($updates.Count) updates"

foreach ($item in $updates) {
    try {
        $file = "$PSScriptRoot/../packages/$($item.file)"
        
        if (-not (Test-Path $file)) {
            Write-Log "Warning: Package config not found: $file"
            continue
        }
        
        $config = Get-Content $file | ConvertFrom-Yaml
        $id = $config.id
        $version = $item.version

        Write-Log "Checking PR existence for $id $version"
        $exists = Test-WingetPRExists $id $version
        if ($exists) {
            Write-Log "  PR already exists, skipping $id $version"
            continue
        }

        Write-Log "  Processing $id -> $version"
        $downloads = Resolve-Download $config $version
        
        if (-not $downloads -or $downloads.Count -eq 0) {
            Write-Log "  Warning: No download URLs found"
            continue
        }

        $urlParts = @()
        foreach ($d in $downloads) {
            Write-Log "  Downloading $($d.url) for hash calculation..."
            try {
                $hash = Get-InstallerHash $d.url
                # 格式: URL|架构|哈希
                $urlParts += "$($d.url)|$($d.arch)|$($hash)"
                Write-Log "  Hash: $hash"
            } catch {
                Write-Log "  Error calculating hash: $_"
                continue
            }
        }

        if ($urlParts.Count -eq 0) {
            Write-Log "  Error: No valid downloads after hash calculation"
            continue
        }

        $urlString = $urlParts -join ","
        
        Write-Log "  Submitting to winget-pkgs..." -level "INFO"
        
        # 添加重试机制
        $maxRetries = 3
        $retryCount = 0
        $success = $false
        
        while (-not $success -and $retryCount -lt $maxRetries) {
            try {
                $output = wingetcreate update $id `
                    --version $version `
                    --urls $urlString `
                    --submit `
                    --token $env:WINGET_TOKEN `
                    2>&1
                
                if ($LASTEXITCODE -eq 0) {
                    $success = $true
                    Write-Log "  Successfully submitted $id $version" -level "INFO"
                } else {
                    throw "wingetcreate exited with code $LASTEXITCODE"
                }
            } catch {
                $retryCount++
                Write-Log "  Attempt $retryCount failed: $_" -level "ERROR"
                
                if ($retryCount -lt $maxRetries) {
                    $delay = 30 * $retryCount  # 指数退避
                    Write-Log "  Retrying in $delay seconds..." -level "WARNING"
                    Start-Sleep -Seconds $delay
                } else {
                    Write-Log "  Error: Failed after $maxRetries attempts" -level "ERROR"
                    Write-Log "  Last error: $_" -level "ERROR"
                }
            }
        }
        
    } catch {
        Write-Log "  Error processing $($item.id): $_"
    }
}

Write-Log "Submission process complete"
