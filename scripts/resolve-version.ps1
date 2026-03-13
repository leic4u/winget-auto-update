. "$PSScriptRoot/github-assets.ps1"

function Resolve-Version($config) {
    $url = $config.checkver.url

    if ($url -match "github.com") {
        $repo = $url.Replace("https://github.com/", "")
        $gh = Resolve-GitHubAssets $repo
        if ($gh) {
            return $gh.version
        }
        return $null
    } elseif ($url -match "api.github.com") {
        # 支持直接使用 GitHub API URL
        $headers = @{
            "Accept" = "application/vnd.github.v3+json"
            "User-Agent" = "winget-auto-updater"
        }
        if ($env:GITHUB_TOKEN) {
            $headers["Authorization"] = "token $($env:GITHUB_TOKEN)"
        }
        
        try {
            $release = Invoke-RestMethod $url -Headers $headers -ErrorAction Stop
            # 支持从 tag_name 提取版本
            if ($release.tag_name) {
                return $release.tag_name.TrimStart("v")
            }
            # 支持从 name 提取版本
            if ($release.name) {
                return $release.name.TrimStart("v")
            }
        } catch {
            Write-Warning "Failed to fetch version from ${url}: $_"
            return $null
        }
    }else {
        try {
            Write-Host "  Fetching version from URL: $url"
            $resp = Invoke-WebRequest $url -UseBasicParsing -ErrorAction Stop
            $content = $resp.Content
            
            if (-not $config.checkver.regex) {
                Write-Warning "  No regex pattern specified in checkver"
                return $null
            }
            
            $regex = $config.checkver.regex
            
            # 验证正则表达式
            try {
                $compiledRegex = New-Object System.Text.RegularExpressions.Regex($regex)
            } catch {
                Write-Warning "  Invalid regex pattern: $regex - $_"
                return $null
            }
            
            if ($content -match $regex) {
                $version = $null
                
                # 优先使用命名捕获组
                if ($matches.version) {
                    $version = $matches.version.Trim()
                    Write-Host "  Found version (named group): $version"
                } elseif ($matches.Count -gt 1) {
                    # 使用第一个捕获组
                    $version = $matches[1].Trim()
                    Write-Host "  Found version (positional): $version"
                }
                
                # 验证版本号格式
                if ($version -and $version -match '^\d+(\.\d+)*(-[a-zA-Z0-9]+)?') {
                    return $version
                } elseif ($version) {
                    Write-Warning "  Version format looks unusual: $version"
                    return $version
                }
            } else {
                Write-Warning "  Regex pattern did not match any content"
            }
        } catch {
            Write-Warning "  Failed to fetch version from $url : $_"
            return $null
        }
    }
}
