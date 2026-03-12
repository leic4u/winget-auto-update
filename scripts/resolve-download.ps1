. "$PSScriptRoot/github-assets.ps1"

function Resolve-Download($config, $version) {
    $url = $config.checkver.url
    
    if ($url -match "github.com" -and -not $config.autoupdate) {
        $repo = $url.Replace("https://github.com/", "")
        $gh = Resolve-GitHubAssets $repo
        if ($gh) {
            return $gh.downloads
        }
        return @()
    }
    
    if (-not $config.autoupdate) {
        Write-Warning "No autoupdate config found for $($config.id)"
        return @()
    }
    
    $urls = @()
    foreach ($arch in $config.autoupdate.architecture.Keys) {
        $template = $config.autoupdate.architecture[$arch]
        $downloadUrl = $template.Replace('$version', $version)
        
        # Infer file type from URL
        $type = "exe"
        if ($downloadUrl -match "\.msi$") { $type = "msi" }
        elseif ($downloadUrl -match "\.msix|\.appx") { $type = "msix" }
        elseif ($downloadUrl -match "\.(zip|7z)$") { $type = "zip" }
        
        $urls += [PSCustomObject]@{
            arch = $arch
            url  = $downloadUrl
            type = $type
        }
    }
    return $urls
}
