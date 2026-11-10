[CmdletBinding()]
param(
    [switch]$Uninstall,
    [switch]$Extract,
    [switch]$NoRestart,
    [switch]$PauseAtEnd
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$packDir = Join-Path $scriptDir "..\data"
$backupDir = Join-Path ([System.IO.Path]::GetTempPath()) "claude-zh-cn-backup"
$utf8NoBom = [System.Text.UTF8Encoding]::new($false)

function Test-IsAdministrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Ensure-Administrator {
    param(
        [string[]]$Arguments = @()
    )

    if (Test-IsAdministrator) {
        return
    }

    $argumentList = @(
        "-NoProfile",
        "-ExecutionPolicy",
        "Bypass",
        "-File",
        "`"$PSCommandPath`""
    ) + $Arguments

    Start-Process -FilePath "powershell.exe" -Verb RunAs -ArgumentList $argumentList | Out-Null
    exit
}

function Wait-BeforeExit {
    if (-not $PauseAtEnd) {
        return
    }

    Write-Host ""
    [void](Read-Host "按回车关闭窗口")
}

function Write-Utf8File {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Content
    )

    $parent = Split-Path -Parent $Path
    if ($parent) {
        [System.IO.Directory]::CreateDirectory($parent) | Out-Null
    }

    [System.IO.File]::WriteAllText($Path, $Content, $utf8NoBom)
}

function Find-ClaudePath {
    try {
        $pkg = Get-AppxPackage -Name Claude -ErrorAction Stop |
            Sort-Object Version -Descending |
            Select-Object -First 1
        if ($pkg -and $pkg.InstallLocation -and (Test-Path -LiteralPath $pkg.InstallLocation)) {
            return $pkg.InstallLocation
        }
    }
    catch {
    }

    try {
        $deployments = Get-ChildItem "HKLM:\Software\Microsoft\Windows\CurrentVersion\Appx\AppxAllUserStore\Deployments" -ErrorAction Stop |
            Where-Object { $_.PSChildName -like "Claude*" } |
            Sort-Object PSChildName -Descending

        foreach ($deployment in $deployments) {
            $candidate = Join-Path ${env:ProgramFiles} "WindowsApps\$($deployment.PSChildName)"
            if (Test-Path -LiteralPath $candidate) {
                return $candidate
            }
        }
    }
    catch {
    }

    $windowsApps = Join-Path ${env:ProgramFiles} "WindowsApps"
    if (Test-Path -LiteralPath $windowsApps) {
        $candidate = Get-ChildItem -LiteralPath $windowsApps -Directory -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -like "Claude*" } |
            Sort-Object Name -Descending |
            Select-Object -First 1

        if ($candidate) {
            return $candidate.FullName
        }
    }

    return $null
}

function Get-ResourcesPath {
    param(
        [Parameter(Mandatory = $true)][string]$ClaudePath
    )

    $resourcesPath = Join-Path $ClaudePath "app\resources"
    if (Test-Path -LiteralPath $resourcesPath) {
        return $resourcesPath
    }

    return $null
}

function Grant-WriteAccess {
    param(
        [Parameter(Mandatory = $true)][string]$Path
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        return
    }

    try {
        $item = Get-Item -LiteralPath $Path -ErrorAction Stop
        $takeownArgs = @("/f", $Path, "/a")
        if ($item.PSIsContainer) {
            $takeownArgs += @("/r", "/d", "Y")
        }

        & takeown.exe @takeownArgs | Out-Null

        $identity = [Security.Principal.WindowsIdentity]::GetCurrent().Name
        if ($identity) {
            & icacls.exe $Path "/grant" "${identity}:(F)" "/t" "/c" | Out-Null
        }
    }
    catch {
    }
}

function Backup-File {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $false)][string]$RelativeTo = ""
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return
    }

    # 保留相对路径结构，避免多个同名文件互相覆盖
    if ($RelativeTo -and $Path.StartsWith($RelativeTo, [System.StringComparison]::OrdinalIgnoreCase)) {
        $relative = $Path.Substring($RelativeTo.Length).TrimStart("\")
    }
    else {
        $relative = Split-Path $Path -Leaf
    }

    $dest = Join-Path $backupDir $relative
    [System.IO.Directory]::CreateDirectory((Split-Path -Parent $dest)) | Out-Null
    Copy-Item -LiteralPath $Path -Destination $dest -Force
}

function Get-BackupPath {
    param(
        [Parameter(Mandatory = $true)][string]$OriginalPath,
        [Parameter(Mandatory = $false)][string]$RelativeTo = ""
    )

    if ($RelativeTo -and $OriginalPath.StartsWith($RelativeTo, [System.StringComparison]::OrdinalIgnoreCase)) {
        $relative = $OriginalPath.Substring($RelativeTo.Length).TrimStart("\")
    }
    else {
        $relative = Split-Path $OriginalPath -Leaf
    }

    return Join-Path $backupDir $relative
}

function Patch-JsLanguage {
    param(
        [Parameter(Mandatory = $true)][string]$ResourcesPath
    )

    $assetsDir = Join-Path $ResourcesPath "ion-dist\assets\v1"
    if (-not (Test-Path -LiteralPath $assetsDir -PathType Container)) {
        Write-Host "  [警告] 未找到 assets 目录，跳过 JS 补丁" -ForegroundColor Yellow
        return $false
    }

    $jsFiles = Get-ChildItem -LiteralPath $assetsDir -Filter "*.js" -File -ErrorAction SilentlyContinue
    if (-not $jsFiles) {
        Write-Host "  [警告] 未找到 JS 文件，跳过 JS 补丁" -ForegroundColor Yellow
        return $false
    }

    # 只用正则匹配，不依赖硬编码变量名（每次 Claude 打包变量名都会变）
    $regexAdd = [regex]'((?:[\w$]+)=\["en-US"(?:,"[^"]+")+)\]'

    $patched = $false

    foreach ($jsFile in $jsFiles) {
        Grant-WriteAccess -Path $jsFile.FullName

        $content = [System.IO.File]::ReadAllText($jsFile.FullName)
        if ($content.Contains('"zh-CN"')) {
            Write-Host "  已注册: $($jsFile.Name)"
            $patched = $true
            continue
        }

        $newContent = $regexAdd.Replace($content, '$1,"zh-CN"]', 1)
        if ($newContent -ne $content) {
            Backup-File -Path $jsFile.FullName -RelativeTo $ResourcesPath
            Write-Utf8File -Path $jsFile.FullName -Content $newContent
            Write-Host "  JS补丁已应用: $($jsFile.Name)"
            $patched = $true
            continue
        }
    }

    if (-not $patched) {
        Write-Host "  [警告] 未匹配到语言列表 (Claude 可能已更新)" -ForegroundColor Yellow
    }

    return $patched
}

function Unpatch-JsLanguage {
    param(
        [Parameter(Mandatory = $true)][string]$ResourcesPath
    )

    $assetsDir = Join-Path $ResourcesPath "ion-dist\assets\v1"
    if (-not (Test-Path -LiteralPath $assetsDir -PathType Container)) {
        Write-Host "  [警告] 未找到 assets 目录" -ForegroundColor Yellow
        return
    }

    $jsFiles = Get-ChildItem -LiteralPath $assetsDir -Filter "*.js" -File -ErrorAction SilentlyContinue
    # 只用正则移除，不依赖硬编码变量名
    $regexRemove = [regex]'((?:[\w$]+)=\[(?:"[^"]+",)+)"zh-CN"\]'

    foreach ($jsFile in $jsFiles) {
        $backupPath = Get-BackupPath -OriginalPath $jsFile.FullName -RelativeTo $ResourcesPath

        if (Test-Path -LiteralPath $backupPath -PathType Leaf) {
            Grant-WriteAccess -Path $jsFile.FullName
            Copy-Item -LiteralPath $backupPath -Destination $jsFile.FullName -Force
            Write-Host "  从备份恢复: $($jsFile.Name)"
            continue
        }

        Grant-WriteAccess -Path $jsFile.FullName
        $content = [System.IO.File]::ReadAllText($jsFile.FullName)

        if (-not $content.Contains('"zh-CN"')) {
            continue
        }

        $newContent = $regexRemove.Replace($content, '$1]', 1)
        if ($newContent -ne $content) {
            Write-Utf8File -Path $jsFile.FullName -Content $newContent
            Write-Host "  语言注册已恢复: $($jsFile.Name)"
            continue
        }

        Write-Host "  [警告] 无法移除 zh-CN: $($jsFile.Name)" -ForegroundColor Yellow
        Write-Host "  建议重新安装 Claude Desktop" -ForegroundColor Yellow
    }

    if (Test-Path -LiteralPath $backupDir -PathType Container) {
        Remove-Item -LiteralPath $backupDir -Recurse -Force -ErrorAction SilentlyContinue
        Write-Host "  备份已清理"
    }
}

function Update-Config {
    param(
        [Parameter(Mandatory = $true)][string]$Locale
    )

    $base = Join-Path ${env:LOCALAPPDATA} "Packages\Claude_pzs8sxrjxfjjc"
    $configPaths = @(
        (Join-Path $base "LocalCache\Roaming\Claude\config.json"),
        (Join-Path $base "LocalCache\Roaming\Claude-3p\config.json")
    )

    foreach ($configPath in $configPaths) {
        if (-not (Test-Path -LiteralPath $configPath -PathType Leaf)) {
            continue
        }

        try {
            $raw = Get-Content -LiteralPath $configPath -Raw -Encoding UTF8

            # 用正则原地替换 locale 值，保留原始格式和其他字段不变
            if ($raw -match '"locale"\s*:') {
                $newRaw = $raw -replace '("locale"\s*:\s*)"[^"]*"', "`$1`"$Locale`""
            }
            else {
                # locale 字段不存在，在最后一个 } 前插入
                $newRaw = $raw -replace '(\s*)\}(\s*)$', ",`r`n  `"locale`": `"$Locale`"`$1}`$2"
            }

            Write-Utf8File -Path $configPath -Content $newRaw
            Write-Host "  $(Split-Path $configPath -Leaf)"
        }
        catch {
            Write-Host "  [警告] 配置更新失败: $(Split-Path $configPath -Leaf) ($($_.Exception.Message))" -ForegroundColor Yellow
        }
    }
}

function Get-ClaudeApplicationId {
    param(
        [Parameter(Mandatory = $true)][string]$ClaudePath
    )

    $manifestPath = Join-Path $ClaudePath "AppxManifest.xml"
    if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
        return $null
    }

    try {
        [xml]$manifest = Get-Content -LiteralPath $manifestPath -Raw
        $application = @($manifest.Package.Applications.Application | Select-Object -First 1)[0]
        if ($application -and $application.Id) {
            return [string]$application.Id
        }
    }
    catch {
    }

    return $null
}

function Get-ClaudePackageFamilyName {
    param(
        [Parameter(Mandatory = $true)][string]$ClaudePath
    )

    try {
        $resolvedClaudePath = [System.IO.Path]::GetFullPath($ClaudePath).TrimEnd("\")
        $pkg = Get-AppxPackage -Name Claude -ErrorAction Stop |
            Sort-Object Version -Descending |
            Where-Object {
                $_.InstallLocation -and
                ([System.IO.Path]::GetFullPath($_.InstallLocation).TrimEnd("\") -ieq $resolvedClaudePath)
            } |
            Select-Object -First 1

        if ($pkg -and $pkg.PackageFamilyName) {
            return [string]$pkg.PackageFamilyName
        }
    }
    catch {
    }

    try {
        [xml]$manifest = Get-Content -LiteralPath (Join-Path $ClaudePath "AppxManifest.xml") -Raw
        $identityName = [string]$manifest.Package.Identity.Name
        $folderName = Split-Path -Leaf $ClaudePath
        if ($identityName -and ($folderName -match "__([^_\\]+)$")) {
            return "$identityName`_$($Matches[1])"
        }
    }
    catch {
    }

    return $null
}

function Get-ClaudeAppUserModelId {
    param(
        [Parameter(Mandatory = $true)][string]$ClaudePath
    )

    $packageFamilyName = Get-ClaudePackageFamilyName -ClaudePath $ClaudePath
    $applicationId = Get-ClaudeApplicationId -ClaudePath $ClaudePath

    if ($packageFamilyName -and $applicationId) {
        return "$packageFamilyName!$applicationId"
    }

    return $null
}

function Start-ClaudeWithExplorer {
    param(
        [Parameter(Mandatory = $true)][string]$Target
    )

    try {
        $argument = $Target
        if ($Target -notlike "shell:*") {
            $argument = "`"$Target`""
        }

        Start-Process -FilePath "explorer.exe" -ArgumentList $argument | Out-Null
        return $true
    }
    catch {
        return $false
    }
}

function Start-ClaudeWithWmi {
    param(
        [Parameter(Mandatory = $true)][string]$ExePath
    )

    try {
        $workingDirectory = Split-Path -Parent $ExePath
        $result = Invoke-CimMethod -ClassName Win32_Process -MethodName Create -Arguments @{
            CommandLine      = "`"$ExePath`""
            CurrentDirectory = $workingDirectory
        }

        return ($result.ReturnValue -eq 0)
    }
    catch {
        return $false
    }
}

function Start-ClaudeDetached {
    param(
        [Parameter(Mandatory = $true)][string]$ClaudePath
    )

    $appUserModelId = Get-ClaudeAppUserModelId -ClaudePath $ClaudePath
    if ($appUserModelId) {
        if (Start-ClaudeWithExplorer -Target "shell:AppsFolder\$appUserModelId") {
            return $true
        }
    }

    $exe = Join-Path $ClaudePath "app\claude.exe"
    if (-not (Test-Path -LiteralPath $exe -PathType Leaf)) {
        return $false
    }

    if (Start-ClaudeWithExplorer -Target $exe) {
        return $true
    }

    return (Start-ClaudeWithWmi -ExePath $exe)
}

function Restart-Claude {
    try {
        Stop-Process -Name "claude" -Force -ErrorAction SilentlyContinue
    }
    catch {
    }

    Start-Sleep -Seconds 2

    $claudePath = Find-ClaudePath
    if (-not $claudePath) {
        return
    }

    if (Start-ClaudeDetached -ClaudePath $claudePath) {
        Start-Sleep -Seconds 3
        Write-Host "Claude Desktop 已重启"
    }
    else {
        Write-Host "  [警告] 自动启动 Claude 失败，请手动打开 Claude Desktop" -ForegroundColor Yellow
    }
}

function Get-RequiredTranslationFiles {
    $dataDir = Join-Path $PSScriptRoot "..\data"
    $required = @(
        [pscustomobject]@{ Name = "ion-dist"; Path = (Join-Path $dataDir "zh-CN.json") },
        [pscustomobject]@{ Name = "desktop-shell"; Path = (Join-Path $dataDir "shell\zh-CN.json") },
        [pscustomobject]@{ Name = "statsig"; Path = (Join-Path $dataDir "dynamic\zh-CN.json") }
    )

    foreach ($item in $required) {
        if (-not (Test-Path -LiteralPath $item.Path -PathType Leaf)) {
            $legacyPath = Join-Path $scriptDir "$($item.Name)\zh-CN.json"
            if (Test-Path -LiteralPath $legacyPath -PathType Leaf) {
                $item.Path = $legacyPath
            }
        }
    }

    return $required
}

function Resolve-ClaudeResources {
    $claudePath = Find-ClaudePath
    if (-not $claudePath) {
        throw "未检测到 Claude Desktop"
    }

    $resourcesPath = Get-ResourcesPath -ClaudePath $claudePath
    if (-not $resourcesPath) {
        throw "未找到 resources 目录"
    }

    return [pscustomobject]@{
        ClaudePath = $claudePath
        ResourcesPath = $resourcesPath
    }
}

function Print-Banner {
    Write-Host ""
    Write-Host "  Claude Desktop 简体中文包" -ForegroundColor Cyan
    Write-Host "  https://github.com/claude-desktop-zh" -ForegroundColor DarkGray
    Write-Host "  CC BY-NC-SA 4.0" -ForegroundColor DarkGray
    Write-Host "  本项目与 Anthropic 无关，仅供个人学习使用。" -ForegroundColor DarkGray
    Write-Host ""
}


function Find-PythonCommand {
    foreach ($cmd in @("python", "py", "python3")) {
        try {
            $null = & $cmd --version 2>$null
            if ($LASTEXITCODE -eq 0) { return $cmd }
        }
        catch {
        }
    }
    return $null
}

function Patch-ClaudeExeHash {
    # Claude Desktop (Windows) 在 claude.exe 中嵌入了 asar 头部 JSON 的 SHA-256,
    # 不一致时应用会静默拒绝启动。此处原位替换 64 字符哈希 (长度相同)。
    param(
        [Parameter(Mandatory = $true)][string]$ExePath,
        [Parameter(Mandatory = $true)][string]$OldHash,
        [Parameter(Mandatory = $true)][string]$NewHash
    )

    if ($OldHash -eq $NewHash) {
        Write-Host "  哈希未变化，跳过 exe 补丁"
        return $true
    }

    Grant-WriteAccess -Path $ExePath
    Backup-File -Path $ExePath -RelativeTo (Split-Path -Parent $ExePath)

    $bytes = [System.IO.File]::ReadAllBytes($ExePath)
    $enc = [System.Text.Encoding]::GetEncoding("ISO-8859-1")
    $text = $enc.GetString($bytes)

    $first = $text.IndexOf($OldHash, [System.StringComparison]::Ordinal)
    if ($first -lt 0) {
        Write-Host "  [警告] 未在 claude.exe 中找到完整性记录 ($OldHash)" -ForegroundColor Yellow
        return $false
    }
    if ($text.IndexOf($OldHash, $first + 1, [System.StringComparison]::Ordinal) -ge 0) {
        Write-Host "  [警告] 完整性记录出现多次，跳过 exe 补丁" -ForegroundColor Yellow
        return $false
    }

    $new = $enc.GetBytes($NewHash)
    for ($j = 0; $j -lt $new.Length; $j++) {
        $bytes[$first + $j] = $new[$j]
    }
    [System.IO.File]::WriteAllBytes($ExePath, $bytes)
    Write-Host "  claude.exe 完整性记录已更新 ($OldHash → $NewHash)"
    return $true
}

function Install-AsarPatch {
    # 新版 Claude Desktop: ion-dist.asar 打包了 i18n JSON 与 JS 语言列表
    param(
        [Parameter(Mandatory = $true)][string]$ClaudePath,
        [Parameter(Mandatory = $true)][string]$ResourcesPath,
        [Parameter(Mandatory = $true)][string]$AsarPath,
        [Parameter(Mandatory = $true)]$Required
    )

    Write-Host ""
    Write-Host "=== 检测到新版 Claude Desktop (asar 打包布局) ==="

    $python = Find-PythonCommand
    if (-not $python) {
        Write-Host "  [错误] 新版布局需要 Python 3 处理 asar，请安装后重新运行。" -ForegroundColor Red
        Write-Host "  https://www.python.org/downloads/"
        throw "缺少 Python 3"
    }

    $scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
    $asarTool = Join-Path $scriptDir "..\tools\asar_tool.py"
    if (-not (Test-Path -LiteralPath $asarTool -PathType Leaf)) {
        throw "缺少 tools\asar_tool.py"
    }

    Write-Host ""
    Write-Host "[1/6] 备份原文件..."
    Backup-File -Path $AsarPath -RelativeTo $ResourcesPath
    $claudeExe = Join-Path $ClaudePath "app\claude.exe"
    if (Test-Path -LiteralPath $claudeExe -PathType Leaf) {
        Backup-File -Path $claudeExe -RelativeTo (Split-Path -Parent $claudeExe)
    }

    Write-Host ""
    Write-Host "[2/6] 解包 ion-dist.asar 并注册中文语言..."
    $workDir = Join-Path ([System.IO.Path]::GetTempPath()) "claude-zh-asar-work"
    if (Test-Path -LiteralPath $workDir) {
        Remove-Item -LiteralPath $workDir -Recurse -Force -ErrorAction SilentlyContinue
    }
    & $python $asarTool "patch-js" $AsarPath $workDir
    if ($LASTEXITCODE -ne 0) { throw "asar 解包失败" }

    Write-Host ""
    Write-Host "[3/6] 安装翻译文件..."
    $ionTarget = Join-Path $workDir "i18n\zh-CN.json"
    [System.IO.Directory]::CreateDirectory((Split-Path -Parent $ionTarget)) | Out-Null
    Copy-Item -LiteralPath $Required[0].Path -Destination $ionTarget -Force
    Write-Host "  → i18n\zh-CN.json"
    $dynTarget = Join-Path $workDir "i18n\dynamic\zh-CN.json"
    [System.IO.Directory]::CreateDirectory((Split-Path -Parent $dynTarget)) | Out-Null
    Copy-Item -LiteralPath $Required[2].Path -Destination $dynTarget -Force
    Write-Host "  → i18n\dynamic\zh-CN.json"

    Write-Host ""
    Write-Host "[4/6] 重新打包 ion-dist.asar..."
    $newAsar = Join-Path ([System.IO.Path]::GetTempPath()) "ion-dist-patched.asar"
    if (Test-Path -LiteralPath $newAsar) {
        Remove-Item -LiteralPath $newAsar -Force -ErrorAction SilentlyContinue
    }
    & $python $asarTool "build" $AsarPath $workDir $newAsar
    if ($LASTEXITCODE -ne 0) { throw "asar 重打包失败" }

    Write-Host ""
    Write-Host "[5/6] 更新 claude.exe 完整性校验..."
    $oldHash = (& $python $asarTool "header" $AsarPath | Select-Object -Last 1).Trim()
    $newHash = (& $python $asarTool "header" $newAsar | Select-Object -Last 1).Trim()
    if (-not $oldHash -or -not $newHash) { throw "无法计算 asar 头部哈希" }
    if (Test-Path -LiteralPath $claudeExe -PathType Leaf) {
        if (-not (Patch-ClaudeExeHash -ExePath $claudeExe -OldHash $oldHash -NewHash $newHash)) {
            Write-Host "  [警告] 哈希未更新，Claude 将无法启动，正在回滚 asar..." -ForegroundColor Yellow
            $backup = Get-BackupPath -OriginalPath $AsarPath -RelativeTo $ResourcesPath
            if (Test-Path -LiteralPath $backup) {
                Copy-Item -LiteralPath $backup -Destination $AsarPath -Force
            }
            throw "claude.exe 完整性补丁失败"
        }
    }

    Write-Host ""
    Write-Host "[6/6] 写入补丁后的 ion-dist.asar..."
    Grant-WriteAccess -Path $AsarPath
    Copy-Item -LiteralPath $newAsar -Destination $AsarPath -Force

    Write-Host ""
    Write-Host "更新配置..."
    Update-Config -Locale "zh-CN"

    Remove-Item -LiteralPath $workDir -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $newAsar -Force -ErrorAction SilentlyContinue

    Write-Host ""
    Write-Host "=== 语言包安装完成 ==="
    Restart-Claude
}

function Install-Patch {
    Print-Banner
    Write-Host ""
    Write-Host "=== Claude Desktop 中文语言包安装 ==="
    Write-Host ""
    Write-Host "无需 Python，正在直接使用 PowerShell 安装。"

    $required = Get-RequiredTranslationFiles
    foreach ($item in $required) {
        if (-not (Test-Path -LiteralPath $item.Path -PathType Leaf)) {
            throw "缺少翻译文件: $($item.Path)"
        }

        $sizeKb = [math]::Floor((Get-Item -LiteralPath $item.Path).Length / 1KB)
        Write-Host ("  {0}: OK ({1}KB)" -f $item.Name, $sizeKb)
    }

    Write-Host ""
    Write-Host "[1/5] 查找 Claude Desktop..."
    $resolved = Resolve-ClaudeResources
    Write-Host "  Claude: $($resolved.ClaudePath)"
    # 新版布局: i18n 与 JS 打包在 ion-dist.asar 内
    $asarPath = Join-Path $resolved.ResourcesPath "ion-dist.asar"
    if (Test-Path -LiteralPath $asarPath -PathType Leaf) {
        Install-AsarPatch -ClaudePath $resolved.ClaudePath -ResourcesPath $resolved.ResourcesPath -AsarPath $asarPath -Required $required
        return
    }

    Write-Host ""
    Write-Host "[2/5] 获取写入权限..."
    $pathsToGrant = @(
        $resolved.ResourcesPath,
        (Join-Path $resolved.ResourcesPath "ion-dist"),
        (Join-Path $resolved.ResourcesPath "ion-dist\i18n"),
        (Join-Path $resolved.ResourcesPath "ion-dist\i18n\statsig"),
        (Join-Path $resolved.ResourcesPath "ion-dist\assets"),
        (Join-Path $resolved.ResourcesPath "ion-dist\assets\v1")
    )

    foreach ($path in $pathsToGrant) {
        Grant-WriteAccess -Path $path
    }

    $assetsDir = Join-Path $resolved.ResourcesPath "ion-dist\assets\v1"
    if (Test-Path -LiteralPath $assetsDir -PathType Container) {
        Get-ChildItem -LiteralPath $assetsDir -Filter "*.js" -File -ErrorAction SilentlyContinue |
            ForEach-Object { Grant-WriteAccess -Path $_.FullName }
    }

    Write-Host "  权限处理完成"

    Write-Host ""
    Write-Host "[3/5] 安装翻译文件..."
    $targets = @(
        [pscustomobject]@{
            Name   = "ion-dist"
            Source = $required[0].Path
            Target = (Join-Path $resolved.ResourcesPath "ion-dist\i18n\zh-CN.json")
        },
        [pscustomobject]@{
            Name   = "desktop-shell"
            Source = $required[1].Path
            Target = (Join-Path $resolved.ResourcesPath "zh-CN.json")
        },
        [pscustomobject]@{
            Name   = "statsig"
            Source = $required[2].Path
            Target = (Join-Path $resolved.ResourcesPath "ion-dist\i18n\statsig\zh-CN.json")
        }
    )

    foreach ($target in $targets) {
        [System.IO.Directory]::CreateDirectory((Split-Path -Parent $target.Target)) | Out-Null
        $relativeTarget = $target.Target.Substring($resolved.ResourcesPath.Length).TrimStart("\")
        Copy-Item -LiteralPath $target.Source -Destination $target.Target -Force
        Write-Host "  → $relativeTarget"
    }

    # 安装 overrides 文件（前端对非 en-US 语言会额外 fetch 此文件）
    $overridesSource = Join-Path $packDir "ion-dist\zh-CN.overrides.json"
    $overridesTarget = Join-Path $resolved.ResourcesPath "ion-dist\i18n\zh-CN.overrides.json"
    if (Test-Path -LiteralPath $overridesSource -PathType Leaf) {
        Copy-Item -LiteralPath $overridesSource -Destination $overridesTarget -Force
        Write-Host "  → ion-dist\i18n\zh-CN.overrides.json"
    }
    else {
        # overrides 文件不存在时写入空对象，避免前端 fetch 404 后静默失败
        Write-Utf8File -Path $overridesTarget -Content "{}`n"
        Write-Host "  → ion-dist\i18n\zh-CN.overrides.json (空占位)"
    }

    Write-Host ""
    Write-Host "[4/5] 注册中文语言..."
    [void](Patch-JsLanguage -ResourcesPath $resolved.ResourcesPath)

    Write-Host ""
    Write-Host "[5/5] 更新配置..."
    Update-Config -Locale "zh-CN"

    Write-Host ""
    Write-Host "=== 语言包安装完成 ==="
    if ($NoRestart) {
        Write-Host "请手动重启 Claude Desktop 使更改生效。"
    }
    else {
        Write-Host ""
        Restart-Claude
    }
}

function Uninstall-Patch {
    Print-Banner
    Write-Host ""
    Write-Host "=== Claude Desktop 中文语言包卸载 ==="
    Write-Host ""

    Write-Host "[1/4] 查找 Claude Desktop..."
    $resolved = Resolve-ClaudeResources
    Write-Host "  Claude: $($resolved.ClaudePath)"
    # 新版布局: i18n 与 JS 打包在 ion-dist.asar 内
    $asarPath = Join-Path $resolved.ResourcesPath "ion-dist.asar"
    if (Test-Path -LiteralPath $asarPath -PathType Leaf) {
        Install-AsarPatch -ClaudePath $resolved.ClaudePath -ResourcesPath $resolved.ResourcesPath -AsarPath $asarPath -Required $required
        return
    }

    Write-Host ""
    Write-Host "[2/4] 删除翻译文件..."
    foreach ($path in @(
            (Join-Path $resolved.ResourcesPath "ion-dist\i18n\zh-CN.json"),
            (Join-Path $resolved.ResourcesPath "ion-dist\i18n\zh-CN.overrides.json"),
            (Join-Path $resolved.ResourcesPath "zh-CN.json"),
            (Join-Path $resolved.ResourcesPath "ion-dist\i18n\statsig\zh-CN.json")
        )) {
        if (Test-Path -LiteralPath $path -PathType Leaf) {
            Grant-WriteAccess -Path $path
            Remove-Item -LiteralPath $path -Force
        }
    }
    Write-Host "  翻译文件已删除"

    Write-Host ""
    Write-Host "[3/4] 恢复语言注册..."
    Unpatch-JsLanguage -ResourcesPath $resolved.ResourcesPath

    Write-Host ""
    Write-Host "[4/4] 恢复配置..."
    Update-Config -Locale "en-US"

    Write-Host ""
    Write-Host "=== 语言包卸载完成 ==="
    if ($NoRestart) {
        Write-Host "请手动重启 Claude Desktop 使更改生效。"
    }
    else {
        Write-Host ""
        Restart-Claude
    }
}

function Extract-EnglishFiles {
    Print-Banner
    Write-Host ""
    Write-Host "=== Claude Desktop 英文文案提取 ==="
    Write-Host ""

    Write-Host "[1/3] 查找 Claude Desktop..."
    $resolved = Resolve-ClaudeResources
    Write-Host "  Claude: $($resolved.ClaudePath)"

    $dataDir = Join-Path $scriptDir "..\\data"
    $templateDir = Join-Path $dataDir "template"

    $asarPath = Join-Path $resolved.ResourcesPath "ion-dist.asar"
    if (Test-Path -LiteralPath $asarPath -PathType Leaf) {
        Write-Host ""
        Write-Host "[2/3] 从 ion-dist.asar 提取 (新版布局)..."
        $python = Find-PythonCommand
        if (-not $python) { throw "需要 Python 3" }
        $asarTool = Join-Path $scriptDir "..\\tools\\asar_tool.py"
        $workDir = Join-Path ([System.IO.Path]::GetTempPath()) "claude-zh-extract"
        if (Test-Path -LiteralPath $workDir) { Remove-Item -LiteralPath $workDir -Recurse -Force -ErrorAction SilentlyContinue }
        & $python $asarTool "extract" $asarPath $workDir
        if ($LASTEXITCODE -ne 0) { throw "asar 解包失败" }

        $pairs = @(
            @{ Source = Join-Path $workDir "i18n\en-US.json"; Target = Join-Path $templateDir "app-en-US.json" },
            @{ Source = Join-Path $workDir "i18n\dynamic\en-US.json"; Target = Join-Path $templateDir "dynamic-en-US.json" }
        )
        foreach ($p in $pairs) {
            if (Test-Path -LiteralPath $p.Source -PathType Leaf) {
                [System.IO.Directory]::CreateDirectory((Split-Path -Parent $p.Target)) | Out-Null
                Copy-Item -LiteralPath $p.Source -Destination $p.Target -Force
                Write-Host ("  -> " + (Split-Path -Leaf $p.Target))
            } else {
                Write-Host ("  [警告] 未找到 " + $p.Source) -ForegroundColor Yellow
            }
        }
        Remove-Item -LiteralPath $workDir -Recurse -Force -ErrorAction SilentlyContinue
    }
    else {
        Write-Host ""
        Write-Host "[2/3] 从散文件提取 (旧版布局)..."
        $pairs = @(
            @{ Source = Join-Path $resolved.ResourcesPath "ion-dist\i18n\en-US.json"; Target = Join-Path $templateDir "app-en-US.json" },
            @{ Source = Join-Path $resolved.ResourcesPath "en-US.json"; Target = Join-Path $templateDir "shell-en-US.json" },
            @{ Source = Join-Path $resolved.ResourcesPath "ion-dist\i18n\statsig\en-US.json"; Target = Join-Path $templateDir "dynamic-en-US.json" }
        )
        foreach ($p in $pairs) {
            if (Test-Path -LiteralPath $p.Source -PathType Leaf) {
                [System.IO.Directory]::CreateDirectory((Split-Path -Parent $p.Target)) | Out-Null
                Copy-Item -LiteralPath $p.Source -Destination $p.Target -Force
                Write-Host ("  -> " + (Split-Path -Leaf $p.Target))
            } else {
                Write-Host ("  [警告] 未找到 " + $p.Source) -ForegroundColor Yellow
            }
        }
    }

    Write-Host ""
    Write-Host "[3/3] 提取完成 -> $templateDir"
    Write-Host ""
    Write-Host "后续步骤:"
    Write-Host "  python tools/translator.py translate app"
    Write-Host "  然后重新运行安装器"
}

$scriptArgs = @()
if ($Uninstall) {
    $scriptArgs += "-Uninstall"
}
if ($Extract) {
    $scriptArgs += "-Extract"
}
if ($NoRestart) {
    $scriptArgs += "-NoRestart"
}
if ($PauseAtEnd) {
    $scriptArgs += "-PauseAtEnd"
}

Ensure-Administrator -Arguments $scriptArgs

$exitCode = 0
try {
    if ($Extract) {
        Extract-EnglishFiles
    }
    elseif ($Uninstall) {
        Uninstall-Patch
    }
    else {
        Install-Patch
    }
}
catch {
    Write-Host ""
    Write-Host "[错误] $($_.Exception.Message)" -ForegroundColor Red
    $exitCode = 1
}
finally {
    Wait-BeforeExit
}

exit $exitCode

