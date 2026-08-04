<#
.SYNOPSIS
    上传 APK（可选含模型）到 GitHub Release

.DESCRIPTION
    本地构建 APK 后，一键上传到 GitHub Release，配合 build-workflow 使用：
    版本号自增 → flutter build → 命名复制到同步盘 → 本脚本上传。

    首次发版用 -IncludeModel 同时上传 229MB 模型；后续版本只传 APK。
    模型长期不变，一直复用首版 Release，避免每次重传 229MB。

    前置（一次性）：
      winget install GitHub.cli
      gh auth login

.PARAMETER Version
    版本号 tag，如 v1.1.0（不带 v 也行，会自动补）

.PARAMETER ApkPath
    要上传的 APK 文件路径。不传则按命名规则
    "声物记_vX.Y.Z_*_arm64.apk" 在 同步盘/迅雷同步盘/build 输出目录 自动查找。

.PARAMETER Notes
    Release 说明（功能备注），可选。不填则用版本号作标题。

.PARAMETER IncludeModel
    同时上传 assets/model.int8.onnx（仅首版 v1.0.0 用）

.PARAMETER GitHubRepo
    GitHub 仓库标识，默认 fantasyao/shengwuji

.PARAMETER SrcRepoPath
    开发仓库路径，用于定位模型文件和同步盘，默认 S:\CodeProject\my_first_app

.EXAMPLE
    .\publish-apk.ps1 -Version v1.0.0 -Notes "首个公开版本" -IncludeModel
    # 首版：自动找 声物记_v1.0.0_*_arm64.apk + 上传模型

.EXAMPLE
    .\publish-apk.ps1 -Version v1.1.0 -ApkPath "同步盘\声物记_v1.1.0_搬家模式_arm64.apk" -Notes "新增搬家模式"
    # 后续版本：指定 APK 路径，只传 APK

.EXAMPLE
    .\publish-apk.ps1 v1.2.0 "修复日记导出"
    # 最简：位置参数（Version, Notes），APK 自动查找
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory=$true, Position=0)]
    [string]$Version,

    [Parameter(Position=1)]
    [string]$ApkPath,

    [Parameter(Position=2)]
    [string]$Notes = "",

    [switch]$IncludeModel,

    [string]$GitHubRepo = "fantasyao/shengwuji",

    [string]$SrcRepoPath = "S:\CodeProject\my_first_app"
)

$ErrorActionPreference = "Stop"
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

# 标准化版本号（补 v 前缀）
if (-not $Version.StartsWith("v")) {
    $Version = "v$Version"
}

Write-Host "================================" -ForegroundColor Cyan
Write-Host "  上传 APK 到 GitHub Release" -ForegroundColor Cyan
Write-Host "================================" -ForegroundColor Cyan
Write-Host "版本 tag : $Version"
Write-Host "GitHub   : $GitHubRepo"
Write-Host "含模型   : $IncludeModel"
Write-Host ""

# ===== 前置检查 =====
Write-Host "[检查] 前置依赖..." -ForegroundColor Yellow

# gh CLI
$ghCmd = Get-Command gh -ErrorAction SilentlyContinue
if (-not $ghCmd) {
    Write-Error "未找到 gh CLI。请先安装并登录："
    Write-Host "  winget install GitHub.cli"
    Write-Host "  gh auth login"
    exit 1
}

# 自动查找 APK（未指定 ApkPath 时）
if (-not $ApkPath) {
    Write-Host "[查找] 未指定 -ApkPath，按命名规则自动查找..." -ForegroundColor DarkGray
    $pattern = "声物记_${Version}_*_arm64.apk"
    $searchDirs = @(
        (Join-Path $SrcRepoPath "同步盘"),
        (Join-Path $SrcRepoPath "迅雷同步盘"),
        (Join-Path $SrcRepoPath "build\app\outputs\flutter-apk"),
        (Get-Location).Path
    )
    $found = $null
    foreach ($dir in $searchDirs) {
        if (Test-Path $dir) {
            $found = Get-ChildItem -Path $dir -Filter $pattern -File -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($found) {
                $ApkPath = $found.FullName
                Write-Host "[查找] 命中: $ApkPath" -ForegroundColor DarkGray
                break
            }
        }
    }
    if (-not $ApkPath) {
        Write-Error "未找到匹配 '$pattern' 的 APK。请用 -ApkPath 显式指定路径。"
        exit 1
    }
}

# APK 文件存在性
if (-not (Test-Path $ApkPath)) {
    Write-Error "APK 文件不存在: $ApkPath"
    exit 1
}

# 模型文件（如需）
$modelPath = Join-Path $SrcRepoPath "assets\model.int8.onnx"
if ($IncludeModel) {
    if (-not (Test-Path $modelPath)) {
        Write-Error "模型文件不存在: $modelPath"
        exit 1
    }
}

$apkSize = [math]::Round((Get-Item $ApkPath).Length / 1MB, 1)
Write-Host "[检查] 通过" -ForegroundColor Green
Write-Host "APK      : $ApkPath ($apkSize MB)"
if ($IncludeModel) {
    $modelSize = [math]::Round((Get-Item $modelPath).Length / 1MB, 1)
    Write-Host "模型     : $modelPath ($modelSize MB)"
}
Write-Host ""

# ===== 上传 =====
Write-Host "[上传] 处理 Release $Version ..." -ForegroundColor Yellow

# gh CLI 在 Windows 上传中文文件名会丢字（参数 UTF-8 字节被 gh.exe 按 GBK 解读，中文字符被丢弃，
# 实测 "声物记_v1.0.13_晴空蓝主题版_arm64.apk" 上传后变成 "_v1.0.13_._arm64.apk"）。
# 上传前把 APK 复制成 ASCII 临时名；模型文件名本身已是 ASCII，无需处理。
$apkAsciiName = "shengwuji_${Version}_arm64.apk"
$apkAscii = Join-Path $env:TEMP $apkAsciiName
Copy-Item $ApkPath $apkAscii -Force
$origName = (Get-Item $ApkPath).Name
if ($origName -cne $apkAsciiName) {
    Write-Host "[上传] 本地 APK 名 '$origName' → GitHub asset 用 ASCII 名: $apkAsciiName（避免中文乱码）" -ForegroundColor DarkGray
}

# 组装 assets 列表（APK 用 ASCII 临时名）
$assets = @($apkAscii)
if ($IncludeModel) {
    $assets += $modelPath
}

# 判断 Release 是否已存在（如 v1.0.0 已有模型，追加 APK）
$existingRelease = gh release view $Version --repo $GitHubRepo 2>$null
$releaseExists = ($LASTEXITCODE -eq 0)

if ($releaseExists) {
    Write-Host "Release $Version 已存在，追加上传 assets（--clobber 覆盖同名）..."
    foreach ($asset in $assets) {
        $assetName = Split-Path $asset -Leaf
        Write-Host "  上传 $assetName ..."
        gh release upload $Version $asset --repo $GitHubRepo --clobber
        if ($LASTEXITCODE -ne 0) {
            Write-Error "上传失败: $asset"
            exit 1
        }
    }
} else {
    Write-Host "创建新 Release $Version ..."
    $ghArgs = @("release", "create", $Version) + $assets + @("--repo", $GitHubRepo, "--title", $Version)
    if ($Notes) {
        $ghArgs += @("--notes", $Notes)
    } else {
        $ghArgs += @("--notes", "$Version 版本发布")
    }
    & gh @ghArgs
    if ($LASTEXITCODE -ne 0) {
        Write-Error "创建 Release 失败（退出码 $LASTEXITCODE）。确认已 gh auth login 且仓库 $GitHubRepo 可访问。"
        exit 1
    }
}

Write-Host ""
Write-Host "================================" -ForegroundColor Green
Write-Host "  完成: Release $Version 已发布" -ForegroundColor Green
Write-Host "================================" -ForegroundColor Green
Write-Host "查看: https://github.com/$GitHubRepo/releases/tag/$Version"
Write-Host ""
if ($IncludeModel) {
    Write-Host "提示: 这是首版，模型已随 Release 上传。后续版本不要加 -IncludeModel，模型一直复用本次的。" -ForegroundColor DarkGray
}

# 清理 ASCII 临时 APK（本地原名不受影响）
Remove-Item $apkAscii -Force -ErrorAction SilentlyContinue
