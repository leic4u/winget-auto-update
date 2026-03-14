Import-Module powershell-yaml

. "$PSScriptRoot/resolve-download.ps1"
. "$PSScriptRoot/calc-hash.ps1"
. "$PSScriptRoot/check-existing-pr.ps1"

# 函数：更新 YAML 文件中的 current_package 信息
function Update-PackageCurrentInfo {
    param(
        [string]$filePath,
        [string]$version,
        [array]$downloads
    )
    
    $yaml = Get-Content $filePath -Raw
    $yamlLines = $yaml -split "`r?`n"
    $newLines = @()
    
    $i = 0
    while ($i -lt $yamlLines.Count) {
        $line = $yamlLines[$i]
        $indent = $line.Length - $line.TrimStart().Length
        
        # 跳过旧的 current_package 部分，稍后重新添加
        if ($line -match '^current_package:') {
            $currentPackageIndent = $indent
            $i++
            # 跳过 current_package 下的所有内容
            while ($i -lt $yamlLines.Count) {
                $nextLine = $yamlLines[$i]
                $nextIndent = $nextLine.Length - $nextLine.TrimStart().Length
                if ($nextLine.Trim() -ne '' -and $nextIndent -le $currentPackageIndent) {
                    break
                }
                $i++
            }
            # 添加新的 current_package 部分
            $newLines += "current_package:"
            $newLines += "  version: `"$version`""
            $newLines += "  architecture:"
            # 添加下载信息
            foreach ($d in $downloads) {
                $archName = $d.arch
                $newLines += "    ${archName}:"
                $newLines += "      url: $($d.url)"
                # 如果 downloads 中有 hash 信息，使用它
                if ($d.hash) {
                    $newLines += "      hash: $($d.hash)"
                } else {
                    $newLines += '      hash: ""'
                }
            }
            continue
        }
        
        # 跳过旧的 current_version 和 architecture（顶层）
        if ($line -match '^(current_version|architecture):') {
            $oldKeyIndent = $indent
            $i++
            while ($i -lt $yamlLines.Count) {
                $nextLine = $yamlLines[$i]
                $nextIndent = $nextLine.Length - $nextLine.TrimStart().Length
                if ($nextLine.Trim() -ne '' -and $nextIndent -le $oldKeyIndent) {
                    break
                }
                $i++
            }
            continue
        }
        
        $newLines += $line
        $i++
    }
    
    $newLines -join "`n" | Set-Content $filePath -Encoding UTF8
}

$updatesFile = "$PSScriptRoot/../updates.json"
$logFile = "$PSScriptRoot/../logs/submit-$(Get-Date -Format 'yyyyMMdd-HHmmss').log"

# 确保日志目录存在
$logDir = Split-Path $logFile -Parent
if (-not (Test-Path $logDir)) {
    New-Item -ItemType Directory -Path $logDir -Force | Out-Null
}

# 清理超过 30 天的日志文件
$maxLogAge = 30
$oldLogs = Get-ChildItem $logDir -Filter "*.log" -ErrorAction SilentlyContinue | Where-Object { $_.LastWriteTime -lt (Get-Date).AddDays(-$maxLogAge) }
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
            Write-Log " PR already exists, skipping $id $version"
            continue
        }

        Write-Log " Processing $id -> $version"

        $downloads = Resolve-Download $config $version
        if (-not $downloads -or $downloads.Count -eq 0) {
            Write-Log " Warning: No download URLs found"
            continue
        }

        $urlParts = @()
        foreach ($d in $downloads) {
            Write-Log " Downloading $($d.url) for hash calculation..."
            try {
                $hash = Get-InstallerHash $d.url
                # 格式：URL|架构|哈希
                $urlParts += "$($d.url)|$($d.arch)|$($hash)"
                Write-Log " Hash: $hash"
            }
            catch {
                Write-Log " Error calculating hash: $_"
                continue
            }
        }

        if ($urlParts.Count -eq 0) {
            Write-Log " Error: No valid downloads after hash calculation"
            continue
        }

        $urlString = $urlParts -join ","
        Write-Log " Submitting to winget-pkgs..." -level "INFO"

        # 添加重试机制
        $maxRetries = 3
        $retryCount = 0
        $success = $false

        while (-not $success -and $retryCount -lt $maxRetries) {
            try {
                # 直接执行命令，不捕获输出到变量
                wingetcreate update $id `
                    --version $version `
                    --urls $urlString `
                    --submit `
                    --token $env:WINGET_TOKEN `
                    2>&1

                if ($LASTEXITCODE -eq 0) {
                    $success = $true
                    Write-Log " Successfully submitted $id $version" -level "INFO"
                    
                    # 更新 YAML 文件中的 current_package
                    Write-Log " Updating current_package in $file" -level "INFO"
                    try {
                        # 构建 downloads 数组（包含 hash）
                        $downloadsWithHash = @()
                        for ($j = 0; $j -lt $downloads.Count; $j++) {
                            $d = $downloads[$j]
                            $hash = $urlParts[$j].Split('|')[2]
                            $downloadsWithHash += [PSCustomObject]@{
                                arch = $d.arch
                                url = $d.url
                                hash = $hash
                            }
                        }
                        Update-PackageCurrentInfo -filePath $file -version $version -downloads $downloadsWithHash
                        Write-Log " Successfully updated current_package" -level "INFO"
                    } catch {
                        Write-Log " Warning: Failed to update current_package: $_" -level "WARNING"
                    }
                } else {
                    throw "wingetcreate exited with code $LASTEXITCODE"
                }
            }
            catch {
                $retryCount++
                Write-Log " Attempt $retryCount failed: $_" -level "ERROR"
                if ($retryCount -lt $maxRetries) {
                    $delay = 30 * $retryCount # 指数退避
                    Write-Log " Retrying in $delay seconds..." -level "WARNING"
                    Start-Sleep -Seconds $delay
                }
                else {
                    Write-Log " Error: Failed after $maxRetries attempts" -level "ERROR"
                    Write-Log " Last error: $_" -level "ERROR"
                }
            }
        }
    }
    catch {
        Write-Log " Error processing $($item.id): $_"
    }
}

Write-Log "Submission process complete"