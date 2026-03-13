if (-not (Get-Module -ListAvailable -Name powershell-yaml)) {
    Write-Error "Required module 'powershell-yaml' is not installed. Install it with: Install-Module powershell-yaml -Scope CurrentUser -Force"
    exit 1
}

Import-Module powershell-yaml

. "$PSScriptRoot/resolve-version.ps1"
. "$PSScriptRoot/scan-url-version.ps1"
. "$PSScriptRoot/calc-hash.ps1"
. "$PSScriptRoot/github-assets.ps1"

function Compare-Versions {
    param(
        [string]$v1,
        [string]$v2
    )

    $v1 = $v1.Trim() -replace '^v', ''
    $v2 = $v2.Trim() -replace '^v', ''

    if ($v1 -eq $v2) { return $false }

    try {
        $ver1 = [System.Version]::Parse($v1)
        $ver2 = [System.Version]::Parse($v2)
        return $ver1 -gt $ver2
    }
    catch {
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

function Update-YamlConfig {
    param(
        [string]$filePath,
        [string]$newVersion,
        [object]$config,
        [object]$githubInfo = $null
    )

    $yaml = Get-Content $filePath -Raw
    $yamlLines = $yaml -split "`n"
    $newLines = @()
    $archsToUpdate = @{}
    $newArchs = @{}

    # 如果有 GitHub 信息，使用 assets 中的 URL
    if ($githubInfo -and $githubInfo.downloads) {
        foreach ($download in $githubInfo.downloads) {
            if (-not [string]::IsNullOrWhiteSpace($download.url)) {
                try {
                    $hash = Get-InstallerHash $download.url
                    $archsToUpdate[$download.arch] = @{
                        url = $download.url
                        hash = $hash
                    }
                } catch {
                    Write-Host "  Warning: Failed to compute hash for $($download.url): $_"
                }
            }
        }
    }
    elseif ($config.autoupdate -and $config.autoupdate.architecture) {
        # 使用模板生成 URL
        foreach ($arch in $config.autoupdate.architecture.PSObject.Properties) {
            $archName = $arch.Name
            $template = $arch.Value.url
            $newUrl = $template -replace '\$version', $newVersion
            if (-not [string]::IsNullOrWhiteSpace($newUrl)) {
                try {
                    $hash = Get-InstallerHash $newUrl
                    $archsToUpdate[$archName] = @{
                        url = $newUrl
                        hash = $hash
                    }
                } catch {
                    Write-Host "  Warning: Failed to compute hash for ${newUrl}: $_"
                }
            }
        }
    }

    # 检查是否有新架构需要添加
    $existingArchs = @()
    if ($config.architecture) {
        $existingArchs = $config.architecture.PSObject.Properties.Name
    }

    foreach ($archName in $archsToUpdate.Keys) {
        if ($existingArchs -notcontains $archName) {
            $newArchs[$archName] = $archsToUpdate[$archName]
            Write-Host "  New architecture detected: $archName"
        }
    }

    # 重新构建 YAML 内容
    $i = 0
    while ($i -lt $yamlLines.Count) {
        $line = $yamlLines[$i]

        # 更新 current_version
        if ($line -match '^current_version:') {
            $newLines += "current_version: `"$newVersion`""
            $i++
            continue
        }

        # 处理 architecture 部分
        if ($line -match '^architecture:') {
            $newLines += $line
            $i++
            # 跳过旧的 architecture 内容，稍后重新添加
            while ($i -lt $yamlLines.Count -and $yamlLines[$i] -match '^\s+\w+:|^\s+url:|^\s+hash:') {
                $i++
            }
            # 添加更新后的 architecture
            foreach ($archName in ($archsToUpdate.Keys | Sort-Object)) {
                $archInfo = $archsToUpdate[$archName]
                $newLines += "  ${archName}:"
                $newLines += "    url: $($archInfo['url'])"
                $newLines += "    hash: $($archInfo['hash'])"
            }
            # 添加新架构
            foreach ($archName in ($newArchs.Keys | Sort-Object)) {
                $archInfo = $newArchs[$archName]
                $newLines += "  ${archName}:"
                $newLines += "    url: $($archInfo['url'])"
                $newLines += "    hash: $($archInfo['hash'])"
            }
            continue
        }

        $newLines += $line
        $i++
    }

    $newLines -join "`n" | Set-Content $filePath -Encoding UTF8
}

$packages = Get-ChildItem "$PSScriptRoot/../packages/*.yaml"
$result = @()
$hasError = $false
$logFile = "$PSScriptRoot/../logs/check-$(Get-Date -Format 'yyyyMMdd-HHmmss').log"

$logDir = Split-Path $logFile -Parent
if (-not (Test-Path $logDir)) {
    New-Item -ItemType Directory -Path $logDir -Force | Out-Null
}

$maxLogAge = 30
$oldLogs = Get-ChildItem $logDir -Filter "*.log" -ErrorAction SilentlyContinue | Where-Object { $_.LastWriteTime -lt (Get-Date).AddDays(-$maxLogAge) }
if ($oldLogs) {
    $oldLogs | Remove-Item -Force -ErrorAction SilentlyContinue
    Write-Host "Cleaned up $($oldLogs.Count) old log files"
}

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

        $currentVersion = if ($config.current_version) { $config.current_version } else { "0.0.0" }
        Write-Log " Current version (from config): $currentVersion" -level "INFO"

        $version = Resolve-Version $config

        if (-not $version) {
            try {
                Write-Log " Primary version check failed, trying fallback..." -level "WARNING"
                $html = Invoke-WebRequest $config.checkver.url -UseBasicParsing -ErrorAction Stop
                $version = Get-VersionFromUrl $html.Content
            }
            catch {
                Write-Log " Warning: Failed to scan URL for version: $_" -level "WARNING"
            }
        }

        if (-not $version) {
            Write-Log " Skipped: Could not determine version" -level "ERROR"
            continue
        }

        Write-Log " Remote version: $version" -level "INFO"

        if (Compare-Versions -v1 $version -v2 $currentVersion) {
            $result += [PSCustomObject]@{
                id      = $id
                version = $version
                file    = $pkg.Name
            }
            Write-Log " UPDATE AVAILABLE: $currentVersion -> $version" -level "WARNING"

            # 对于 GitHub 项目，获取 assets 信息
            $githubInfo = $null
            if ($config.checkver.url -match "github.com") {
                $repo = $config.checkver.url.Replace("https://github.com/", "")
                Write-Log " Fetching GitHub assets for $repo..." -level "INFO"
                $githubInfo = Resolve-GitHubAssets $repo
                if ($githubInfo) {
                    Write-Log " Found $($githubInfo.downloads.Count) assets from GitHub" -level "INFO"
                }
            }

            # 更新 YAML 配置文件
            Update-YamlConfig -filePath $pkg.FullName -newVersion $version -config $config -githubInfo $githubInfo
            Write-Log " Updated config file with new version, urls and hashes" -level "INFO"
        }
        else {
            Write-Log " Up to date" -level "INFO"
        }
    }
    catch {
        $hasError = $true
        Write-Log " Error processing $($pkg.Name): $_" -level "ERROR"
    }
}

Write-Log "Check complete. Found $($result.Count) updates."

if ($result.Count -gt 0) {
    $outputPath = "$PSScriptRoot/../updates.json"
    $result | ConvertTo-Json | Out-File $outputPath -Encoding UTF8
    Write-Log "Results saved to $outputPath" -level "INFO"
    $result | Format-Table -AutoSize
    Write-Log "Updates found, exiting with code 0 for further processing" -level "INFO"
} else {
    Write-Log "No updates found, exiting normally" -level "INFO"
}

if ($hasError) {
    Write-Log "One or more errors occurred during check-version" -level "ERROR"
    exit 1
}

exit 0