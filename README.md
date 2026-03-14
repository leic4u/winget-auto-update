# Winget Auto Update

Winget Auto Update 是一个自动化工具集，用于检测、更新和提交 Winget 包的新版本到 Microsoft 的 [winget-pkgs](https://github.com/microsoft/winget-pkgs) 仓库。

## 功能特性

- **自动版本检测**：定期检查已配置软件包的新版本
- **智能更新机制**：自动从官方源获取最新版本信息和下载链接
- **哈希计算**：自动计算安装包的 SHA256 哈希值
- **GitHub 集成**：支持从 GitHub Releases 自动获取资产信息
- **自动提交**：使用 `wingetcreate` 工具自动向 winget-pkgs 提交更新请求
- **重复提交检查**：避免重复提交相同的版本更新
- **日志记录**：完整的操作日志便于追踪和调试

## 工作原理

1. **版本检查** (`scripts/check-version.ps1`)：
   - 遍历 `packages/` 目录下的所有 YAML 配置文件
   - 根据配置的 `checkver` 规则检查远程版本
   - 当发现新版本时，自动更新配置文件中的版本信息和下载链接

2. **提交更新** (`scripts/submit-winget.ps1`)：
   - 读取版本检查结果 (`updates.json`)
   - 检查是否已有相同的 PR 存在
   - 下载安装包并计算哈希值
   - 使用 `wingetcreate` 提交更新到 winget-pkgs

## 配置文件格式

每个软件包都需要一个 YAML 配置文件，放置在 `packages/` 目录下：

```yaml
id: Publisher.AppName
current_package:
  version: "1.0.0"
  architecture:
    x64:
      url: https://example.com/app-1.0.0-x64.exe
      hash: ""
checkver:
  url: https://example.com/releases
  # 版本检查规则...
autoupdate:
  architecture:
    x64:
      url: https://example.com/app-$version-x64.exe
```

### 字段说明

- `id`: Winget 包标识符
- `current_package.version`: 当前已知的最新版本
- `current_package.architecture`: 支持的架构及对应的下载信息
- `checkver`: 版本检查规则
- `autoupdate`: 自动更新模板

## 安装要求

- PowerShell 5.1 或更高版本
- [`powershell-yaml`](https://github.com/cloudbase/powershell-yaml) 模块
- [`wingetcreate`](https://github.com/microsoft/winget-create) 工具
- GitHub Personal Access Token (用于提交 PR)

安装依赖：
```powershell
# 安装 powershell-yaml 模块
Install-Module powershell-yaml -Scope CurrentUser -Force

# 安装 wingetcreate
winget install wingetcreate
```

## 使用方法

1. **设置环境变量**：
   ```powershell
   $env:WINGET_TOKEN="your_github_personal_access_token"
   ```

2. **运行版本检查**：
   ```powershell
   .\scripts\check-version.ps1
   ```

3. **提交更新**：
   ```powershell
   .\scripts\submit-winget.ps1
   ```

## 自动化部署

推荐使用计划任务或 CI/CD 系统定期运行此工具：

```powershell
# 每天检查一次更新
.\scripts\check-version.ps1

# 如果有更新，则提交
if (Test-Path updates.json) {
    .\scripts\submit-winget.ps1
}
```

## 日志管理

脚本会自动生成日志文件到 `logs/` 目录，并自动清理 30 天前的日志。

## 贡献

欢迎提交 Issue 和 Pull Request 来改进此工具。

## 许可证

MIT License