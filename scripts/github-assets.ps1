function Resolve-GitHubAssets($repo) {
    $api = "https://api.github.com/repos/$repo/releases/latest"
    
    # 添加 GitHub API 认证头以提高速率限制
    $headers = @{
        "Accept" = "application/vnd.github.v3+json"
        "User-Agent" = "winget-auto-updater"
    }
    if ($env:GITHUB_TOKEN) {
        $headers["Authorization"] = "token $env:GITHUB_TOKEN"
    }
    
    try {
        $release = Invoke-RestMethod $api -Headers $headers -ErrorAction Stop
    } catch {
        Write-Error "Failed to fetch GitHub release for $repo: $_"
        return $null
    }
    
    $version = $release.tag_name.TrimStart("v")
    $assets = $release.assets
    $downloads = @()
    $allowedExt = @(
        ".exe",".msi",".msix",".msixbundle",
        ".appx",".appxbundle",".zip",".7z"
    )
    $excludeKeywords = @(
        "source","src","linux","mac","darwin","osx",
        "android","ios","portable","debug","symbols","pdb"
    )
    foreach ($a in $assets) {
        $name = $a.name.ToLower()
        $ext = [System.IO.Path]::GetExtension($name)
        if ($allowedExt -notcontains $ext) { continue }
        $skip = $false
        foreach ($k in $excludeKeywords) {
            if ($name -match $k) { $skip = $true; break }
        }
        if ($skip) { continue }
        $arch = "x64"
        if ($name -match "arm64|aarch64") { $arch = "arm64" }
        elseif ($name -match "x86|win32") { $arch = "x86" }
        elseif ($name -match "x64|amd64|win64") { $arch = "x64" }
        switch ($ext) {
            ".exe" { $type = "exe" }
            ".msi" { $type = "msi" }
            ".msix" { $type = "msix" }
            ".msixbundle" { $type = "msix" }
            ".appx" { $type = "msix" }
            ".appxbundle" { $type = "msix" }
            ".zip" { $type = "zip" }
            ".7z" { $type = "zip" }
            default { $type = "exe" }
        }
        $downloads += [PSCustomObject]@{
            arch = $arch
            url  = $a.browser_download_url
            type = $type
            name = $a.name
        }
    }
    return [PSCustomObject]@{
        version   = $version
        downloads = $downloads
    }
}
