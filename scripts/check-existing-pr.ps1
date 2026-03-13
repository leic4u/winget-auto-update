function Test-WingetPRExists {
    param(
        [string]$id,
        [string]$version
    )
    
    # 如果没有设置 WINGET_TOKEN，跳过检查
    if (-not $env:WINGET_TOKEN) {
        Write-Warning "WINGET_TOKEN not set, skipping PR existence check"
        return $false
    }
    
    try {
        # 设置认证
        $env:GH_TOKEN = $env:WINGET_TOKEN
        
        # 使用更精确的搜索
        $query = "$id $version"
        Write-Host "  Searching for existing PR with: $query"
        
        # 获取 PR 列表
        $prsJson = gh pr list `
            --repo microsoft/winget-pkgs `
            --state open `
            --search "$query" `
            --json number,title,headRefName,author `
            2>&1
        
        if (-not $prsJson) {
            return $false
        }
        
        $data = $prsJson | ConvertFrom-Json -ErrorAction SilentlyContinue
        if (-not $data) {
            return $false
        }
        
        # 遍历检查结果
        foreach ($pr in $data) {
            # 检查 PR 标题是否匹配
            $titleMatch = $pr.title -match [regex]::Escape($id) -and $pr.title -match [regex]::Escape($version)
            
            # 检查分支名是否匹配
            $branchMatch = $pr.headRefName -match [regex]::Escape($id) -or $pr.headRefName -match [regex]::Escape($version)
            
            if ($titleMatch -or $branchMatch) {
                Write-Host "  Found existing PR #$($pr.number): $($pr.title)"
                return $true
            }
        }
        
        Write-Host "  No existing PR found for $id $version"
        return $false
    } catch {
        Write-Warning "Failed to check existing PRs: $_"
        return $false
    } finally {
        # 清理环境变量
        if ($env:GH_TOKEN) {
            $env:GH_TOKEN = $null
        }
    }
}
