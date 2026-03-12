function Scan-UrlVersion($html) {
    $urls = Select-String -InputObject $html -Pattern "https?://[^\s\"']+" -AllMatches
    $versions = @()
    foreach ($u in $urls.Matches.Value) {
        if ($u -match "([0-9]+\.[0-9]+\.[0-9]+(\.[0-9]+)?)") {
            $versions += $matches[1]
        }
    }
    if ($versions.Count -gt 0) {
        return ($versions | Sort-Object {[version]$_} -Descending)[0]
    }
}
