Import-Module powershell-yaml
. "$PSScriptRoot/resolve-version.ps1"
. "$PSScriptRoot/scan-url-version.ps1"

function Compare-Versions {
    param(
        [string]$v1,
        [string]$v2
    )
    
    # 预处理：移除 v 前缀和空白字符
    $v1 = $v1.Trim() -replace '^v', ''
    $v2 = $v2.Trim() -replace '^v', ''
    
    # 如果版本相同，直接返回 false
    if ($v1 -eq $v2) {
        return $false
    }
    
    try {
        # 尝试使用 .NET 的 Version 类进行精确比较
        $ver1 = [System.Version]::Parse($v1)
        $ver2 = [System.Version]::Parse($v2)
        return $ver1 -gt $ver2
    } catch {
        # 降级到逐段比较（处理非标准版本号）
        $parts1 = $v1.Split('.') | ForEach-Object { 
            $num = 0
            if ([int]::TryParse($_, [ref]$num)) { $num } else { 0 }
        }
        $parts2 = $v2.Split('.') | ForEach-Object { 
            $num = 0
            if ([int]::TryParse($_, [ref]$num)) { $num } else { 0 }
        }
        
        $max = [Math]::Max($parts1.Count, $parts2.Count)
        for ($i = 0; $i -lt $max; $i++) {
            $p1 = if ($i -lt $parts1.Count) { $parts1[$i] } else { 0 }
            $p2 = if ($i -lt $parts2.Count) { $parts2[$i] } else { 0 }
            
            if ($p1 -gt $p2) { return $true }
            if ($p1 -lt $p2) { return $false }
        }
        return $false
    }
}

$packages = Get-ChildItem "$PSScriptRoot/../packages/*.yaml"
$result = @()
$logFile = "$PSScriptRoot/../logs/check-$(Get-Date -Format 'yyyyMMdd-HHmmss').log"

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

# 定义日志级别
enum LogLevel {
    INFO
    WARNING
    ERROR
}

function Write-Log {
    param(
        [string]$message,
        [ValidateSet("INFO", "WARNING", "ERROR")]
        [string]$level = "INFO"
    )
    
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $logMessage = "[$timestamp] [$level] $message"
    
    # 根据级别设置颜色
    switch ($level) {
        "INFO" { Write-Host $logMessage -ForegroundColor Green }
        "WARNING" { Write-Host $logMessage -ForegroundColor Yellow }
        "ERROR" { Write-Host $logMessage -ForegroundColor Red }
    }
    
    Add-Content -Path $logFile -Value $logMessage
}

Write-Log "Starting version check for $($packages.Count) packages"

foreach ($pkg in $packages) {
    try {
        $config = Get-Content $pkg | ConvertFrom-Yaml
        $id = $config.id
        Write-Log "Checking $id" -level "INFO"
        
        $version = Resolve-Version $config
        
        # 如果主要方法失败，尝试备用方法
        if (-not $version) {
            try {
                Write-Log "  Primary version check failed, trying fallback..." -level "WARNING"
                $html = Invoke-WebRequest $config.checkver.url -UseBasicParsing -ErrorAction Stop
                $version = Scan-UrlVersion $html.Content
            } catch {
                Write-Log "  Warning: Failed to scan URL for version: $_" -level "WARNING"
            }
        }
        
        if (-not $version) {
            Write-Log "  Skipped: Could not determine version" -level "ERROR"
            continue
        }
        
        Write-Log "  Remote version: $version" -level "INFO"
        
        # 从 winget-pkgs 仓库获取当前版本（更可靠）
        $currentVersion = "0.0.0"
        try {
            # 尝试从 GitHub 获取 winget manifest 版本
            $manifestUrl = "https://raw.githubusercontent.com/microsoft/winget-pkgs/master/manifests/$($id.Split('.')[0])/$($id.Replace('.', '.'))"
            $response = Invoke-WebRequest -Uri $manifestUrl -UseBasicParsing -ErrorAction Stop
            if ($response.Content -match 'Version:\s*([0-9.]+)') {
                $currentVersion = $matches[1].Trim()
                Write-Log "  Current version (from manifest): $currentVersion" -level "INFO"
            } else {
                # 如果 manifest 中没有找到版本号，使用 winget show 作为后备
                $current = winget show --id $id --exact 2>&1 | Select-String "Version:"
                if ($current -match "([0-9.]+)") {
                    $currentVersion = $matches[1]
                } else {
                    $currentVersion = "0.0.0"
                }
                Write-Log "  Current version (from winget): $currentVersion" -level "INFO"
            }
        } catch {
            # 如果所有方法都失败，使用 winget show 作为后备
            try {
                $current = winget show --id $id --exact 2>&1 | Select-String "Version:"
                if ($current -match "([0-9.]+)") {
                    $currentVersion = $matches[1]
                }
                Write-Log "  Current version (fallback): $currentVersion" -level "INFO"
            } catch {
                Write-Log "  Warning: Could not determine current version: $_" -level "WARNING"
            }
        }
        
        if (Compare-Versions -v1 $version -v2 $currentVersion) {
            $result += [PSCustomObject]@{
                id = $id
                version = $version
                file = $pkg.Name
            }
            Write-Log "  UPDATE AVAILABLE: $currentVersion -> $version" -level "WARNING"
        } else {
            Write-Log "  Up to date" -level "INFO"
        }
    } catch {
        Write-Log "  Error processing $($pkg.Name): $_" -level "ERROR"
    }
}

Write-Log "Check complete. Found $($result.Count) updates."

$outputPath = "$PSScriptRoot/../updates.json"
$result | ConvertTo-Json | Out-File $outputPath -Encoding UTF8
Write-Log "Results saved to $outputPath"

return $result
