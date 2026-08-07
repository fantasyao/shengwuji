<#
.SYNOPSIS
    从开发仓库同步到公开发布仓库（无 git 历史）

.DESCRIPTION
    双仓库架构：
    - 开发仓库（S:\CodeProject\my_first_app）保留全部历史继续维护
    - 发布仓库（默认 S:\CodeProject\my_first_app_release）由本脚本一键同步

    发布仓库不含：
    - 开发仓库的 git 历史（每次同步生成新的快照 commit）
    - 日志、聊天记录、缓存（.waylog、logs、build_output.log 等）
    - 构建产物（build、.dart_tool、.gradle 等）
    - 个人开发配置（.claude、CLAUDE.md、todo 等）
    - 大模型文件（assets/model.int8.onnx，229MB，超 GitHub 单文件限制）

    模型文件单独走 GitHub Release 上传（用 -UploadModel 开关）。
    APK 产物走 GitHub Release 上传（用 -UploadApk 开关），每个版本独立 tag。

.PARAMETER ReleaseRepoPath
    发布仓库本地路径，默认 S:\CodeProject\my_first_app_release

.PARAMETER CommitMsg
    发布仓库的 commit message。默认为空，运行时交互式获取（GUI 对话框优先，
    预填开发仓最近一次 commit message 并剥离开头 claude: 前缀；GUI 不可用
    则回退终端 Read-Host）。命令行显式传值则非交互直接使用。

.PARAMETER GitAuthorName
    发布仓库 git 作者名

.PARAMETER GitAuthorEmail
    发布仓库 git 作者邮箱（建议用 GitHub noreply）

.PARAMETER GitHubRepo
    GitHub 仓库标识 username/repo，用于 gh release 和 README 链接

.PARAMETER Push
    加此开关执行 git push 到 origin main（force-with-lease）

.PARAMETER UploadModel
    加此开关上传 model.int8.onnx 到 GitHub Release（自动创建 v1.0.0 tag）

.PARAMETER UploadApk
    加此开关上传 APK 产物到 GitHub Release（每个版本独立 tag，自动从 pubspec.yaml 读 version 拼 vX.Y.Z）

.PARAMETER ApkPath
    APK 文件路径，默认空 = 自动找 build/app/outputs/apk/release/app-arm64-v8a-release.apk

.PARAMETER VersionTag
    Release tag 名称，默认空 = 自动从 pubspec.yaml 读 version: X.Y.Z 拼成 vX.Y.Z

.PARAMETER ApkLabel
    APK 规范文件名里的「功能备注」段，如「晴空蓝主题版」。空则文件名省略备注段

.EXAMPLE
    .\sync-to-release.ps1
    # 干跑，仅生成发布仓库本地副本

.EXAMPLE
    .\sync-to-release.ps1 -Push -UploadModel
    # 首次发布：推送源码 + 上传模型

.EXAMPLE
    .\sync-to-release.ps1 -Push -UploadApk -ApkLabel "晴空蓝主题版"
    # 同步源码+推送+上传当前版本 APK

.EXAMPLE
    .\sync-to-release.ps1 -CommitMsg "v1.1.0 更新" -Push
    # 后续更新：仅推送源码

.EXAMPLE
    .\sync-to-release.ps1
    # 不传 -CommitMsg，运行时弹对话框确认提交信息（预填最近 commit）
#>

[CmdletBinding()]
param(
    [string]$ReleaseRepoPath = "S:\CodeProject\my_first_app_release",
    [string]$CommitMsg = "",
    [string]$GitAuthorName = "fantasyao",
    [string]$GitAuthorEmail = "fantasyao@users.noreply.github.com",
    [string]$GitHubRepo = "fantasyao/shengwuji",
    [switch]$Push,
    [switch]$UploadModel,
    [switch]$UploadApk,
    [string]$ApkPath = "",          # 空=自动找 build/app/outputs/apk/release/app-arm64-v8a-release.apk
    [string]$VersionTag = "",       # 空=自动从 pubspec.yaml 读 version: X.Y.Z 拼成 vX.Y.Z
    [string]$ApkLabel = ""          # APK 规范文件名里的「功能备注」，如「晴空蓝主题版」。空则文件名省略备注段
)

$ErrorActionPreference = "Stop"
$SrcRepoPath = "S:\CodeProject\my_first_app"

# 交互式获取 commit message：GUI InputBox 优先，失败回退终端 Read-Host
# 返回最终字符串；用户取消则返回 $null
function Get-CommitMsgInteractive {
    param(
        [string]$Prompt,
        [string]$Title,
        [string]$Default
    )
    # 优先 GUI 对话框（预填默认值，可编辑，可取消）
    $useGui = $true
    try {
        Add-Type -AssemblyName Microsoft.VisualBasic -ErrorAction Stop
    } catch {
        $useGui = $false
        Write-Warning "GUI 程序集不可用，回退到终端输入"
    }

    if ($useGui) {
        try {
            $result = [Microsoft.VisualBasic.Interaction]::InputBox($Prompt, $Title, $Default)
            # InputBox 取消/关闭返回空字符串，约定空 = 取消
            if ([string]::IsNullOrEmpty($result)) {
                return $null
            }
            return $result
        } catch {
            Write-Warning "GUI 对话框异常，回退到终端输入: $_"
        }
    }

    # 终端 fallback（Read-Host 不支持取消，空 = 用默认）
    Write-Host $Prompt -ForegroundColor Cyan
    if (-not [string]::IsNullOrEmpty($Default)) {
        Write-Host "  默认: $Default" -ForegroundColor DarkGray
    }
    $line = Read-Host "提交信息 (回车使用默认)"
    if ([string]::IsNullOrWhiteSpace($line)) {
        return $Default
    }
    return $line
}

# 输出编码（Windows 中文环境）
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

Write-Host "================================" -ForegroundColor Cyan
Write-Host "  双仓库发布同步" -ForegroundColor Cyan
Write-Host "================================" -ForegroundColor Cyan
Write-Host "源（开发仓库）: $SrcRepoPath"
Write-Host "目标（发布仓库）: $ReleaseRepoPath"
Write-Host "Git 作者: $GitAuthorName <$GitAuthorEmail>"
Write-Host "GitHub 仓库: $GitHubRepo"
Write-Host "Push: $Push"
Write-Host "UploadModel: $UploadModel"
Write-Host ""

# ===== Phase 0: 前置检查 =====
Write-Host "[Phase 0] 前置检查..." -ForegroundColor Yellow

if (-not (Test-Path $SrcRepoPath)) {
    Write-Error "开发仓库不存在: $SrcRepoPath"
    exit 1
}

$modelSrc = Join-Path $SrcRepoPath "assets\model.int8.onnx"
if (-not (Test-Path $modelSrc)) {
    Write-Warning "开发仓库 assets/model.int8.onnx 不存在（-UploadModel 会失败）"
}

# 检查发布仓库目录
$releaseExists = Test-Path $ReleaseRepoPath
$releaseHasGit = $false
if ($releaseExists) {
    $releaseHasGit = Test-Path (Join-Path $ReleaseRepoPath ".git")
    $existingItems = Get-ChildItem -Force $ReleaseRepoPath -ErrorAction SilentlyContinue
    if ($existingItems -and -not $releaseHasGit) {
        Write-Warning "发布仓库目录非空且无 .git: $ReleaseRepoPath"
        $confirm = Read-Host "继续会清空该目录，确认？(y/N)"
        if ($confirm -ne "y" -and $confirm -ne "Y") {
            Write-Host "已取消"
            exit 0
        }
        Get-ChildItem -Force $ReleaseRepoPath | Remove-Item -Recurse -Force
    }
} else {
    New-Item -ItemType Directory -Path $ReleaseRepoPath -Force | Out-Null
    Write-Host "已创建发布仓库目录: $ReleaseRepoPath"
}

Write-Host "[Phase 0] 前置检查通过" -ForegroundColor Green
Write-Host ""

# ===== 确定 commit message =====
Write-Host "[Phase 0.5] 确定 commit message..." -ForegroundColor Yellow

if (-not [string]::IsNullOrEmpty($CommitMsg)) {
    # 命令行显式传入，非交互直接用
    Write-Host "使用命令行传入的 commit message: $CommitMsg"
} else {
    # 智能推断默认值：取开发仓最近一次 commit 的 subject，剥离 claude: 前缀
    $recentSubject = ""
    try {
        $recentSubject = (git -C $SrcRepoPath log -1 --format='%s' 2>$null)
        if ($LASTEXITCODE -ne 0) { $recentSubject = "" }
    } catch { $recentSubject = "" }
    $defaultMsg = $recentSubject -replace '^claude:\s*', ''

    # 检测开发仓工作区是否有未提交改动（这些也会被 robocopy 同步）
    $isDirty = $false
    try {
        $dirtyOutput = git -C $SrcRepoPath status --porcelain 2>$null
        if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace($dirtyOutput)) {
            $isDirty = $true
        }
    } catch { }

    # 构造对话框提示文案
    $promptLines = @("请输入本次发布同步的 commit message：")
    if ($isDirty) {
        $promptLines += "⚠️ 开发仓有未提交改动，也会一并同步到发布仓。"
    }
    if (-not [string]::IsNullOrEmpty($defaultMsg)) {
        $promptLines += "（已预填最近一次提交，可直接确定或修改）"
    } else {
        $promptLines += "（未取到最近提交，请手动输入说明）"
    }
    $prompt = $promptLines -join "`r`n"

    Write-Host "默认 commit message: $defaultMsg"
    if ($isDirty) { Write-Host "⚠️ 开发仓工作区有未提交改动" -ForegroundColor Yellow }

    $finalMsg = Get-CommitMsgInteractive -Prompt $prompt -Title "发布同步 - commit message" -Default $defaultMsg

    if ($null -eq $finalMsg -or [string]::IsNullOrWhiteSpace($finalMsg)) {
        Write-Host "已取消同步，未做任何改动" -ForegroundColor Cyan
        exit 0
    }
    $CommitMsg = $finalMsg.Trim()
    Write-Host "本次 commit message: $CommitMsg" -ForegroundColor Green
}
Write-Host ""

# ===== Phase A: robocopy 拷贝 =====
Write-Host "[Phase A] 开始 robocopy 拷贝..." -ForegroundColor Yellow

# 排除目录（robocopy /XD 按目录名匹配，全路径任意层级生效）
$excludeDirs = @(
    ".git",
    "build",
    ".dart_tool",
    "logs",
    "同步盘",
    "迅雷同步盘",
    ".waylog",
    ".vscode",
    ".idea",
    ".claude",
    ".gradle",
    ".cxx",
    "Pods",
    "Flutter"
)

# 排除文件（robocopy /XF 支持通配符）
$excludeFiles = @(
    "model.int8.onnx",
    "build_output.log",
    "hs_err_pid*.log",
    "font_config_check.txt",
    "nul",
    "fix_icon_background.py",
    "*.bak",
    "todo",
    "CLAUDE.md",
    "*.iml",
    "local.properties",
    ".flutter-plugins",
    ".flutter-plugins-dependencies",
    "devtools_options.yaml",
    "*.tmp",
    "run.log",
    "run_utf8.log"
)

Write-Host "排除目录: $($excludeDirs -join ', ')"
Write-Host "排除文件: $($excludeFiles -join ', ')"

# 如果发布仓库已有 .git，先清空工作区（保留 .git）
if ($releaseHasGit) {
    Write-Host "保留发布仓库 .git，清空其他内容..."
    # Remove-Item -Recurse 在 Windows 长路径（>260 字符，如 build\.transforms\...\*.dex）下
    # 会抛 DirectoryNotFoundException，改用 robocopy /MIR 镜像空目录清空（原生支持长路径），
    # /XD .git 保护 release 的 .git 目录不被删除
    $emptyMirror = Join-Path $env:TEMP ("empty_mirror_" + [System.Guid]::NewGuid().ToString("N"))
    New-Item -ItemType Directory -Path $emptyMirror -Force | Out-Null
    try {
        $cleanCmd = 'robocopy "{0}" "{1}" /MIR /XD .git /NFL /NDL /NJH /NJS /R:1 /W:1' -f $emptyMirror, $ReleaseRepoPath
        Write-Host "执行清空: $cleanCmd"
        Invoke-Expression $cleanCmd | Out-Null
        if ($LASTEXITCODE -ge 8) {
            Write-Error "清空发布仓库失败，robocopy 退出码 $LASTEXITCODE"
            exit 1
        }
    } finally {
        Remove-Item $emptyMirror -Recurse -Force -ErrorAction SilentlyContinue
    }
}

# robocopy 参数
$robocopyArgs = @(
    $SrcRepoPath,
    $ReleaseRepoPath,
    "/E",           # 含子目录（含空目录）
    "/XD" + $excludeDirs,
    "/XF" + $excludeFiles,
    "/NFL",         # 不列文件
    "/NDL",         # 不列目录
    "/NJH",         # 不显示 job header
    "/NP",          # 不显示进度
    "/R:1",         # 重试 1 次
    "/W:1"          # 等待 1 秒
)

# 用脚本块调用 robocopy（避免数组参数问题）
$xd = ($excludeDirs | ForEach-Object { ' "{0}"' -f $_ }) -join ''
$xf = ($excludeFiles | ForEach-Object { ' "{0}"' -f $_ }) -join ''
$cmd = 'robocopy "{0}" "{1}" /E /XD{2} /XF{3} /NFL /NDL /NJH /NP /R:1 /W:1' -f `
    $SrcRepoPath, $ReleaseRepoPath, $xd, $xf

Write-Host "执行: $cmd"
Invoke-Expression $cmd | Out-Null

if ($LASTEXITCODE -ge 8) {
    Write-Error "robocopy 失败，退出码 $LASTEXITCODE"
    exit 1
}

$copiedCount = (Get-ChildItem -Recurse $ReleaseRepoPath -File | Measure-Object).Count
Write-Host "[Phase A] 拷贝完成，共 $copiedCount 个文件" -ForegroundColor Green
Write-Host ""

# ===== Phase B: 写入发布仓库的 .gitignore =====
Write-Host "[Phase B] 写入发布仓库 .gitignore..." -ForegroundColor Yellow

$releaseGitignore = @"
# Flutter
.dart_tool/
build/
.flutter-plugins
.flutter-plugins-dependencies
devtools_options.yaml

# Android
android/.gradle/
android/local.properties
android/app/build/
android/build/
android/.cxx/

# iOS
ios/Pods/
ios/Flutter/
ios/build/

# IDE
.vscode/
.idea/
*.iml

# 大模型文件（走 GitHub Release，不进 git）
assets/model.int8.onnx

# 日志/临时
*.log
logs/
build_output.log

# 备份
*.bak
"@

$releaseGitignore | Out-File -FilePath (Join-Path $ReleaseRepoPath ".gitignore") -Encoding utf8 -Force
Write-Host "[Phase B] .gitignore 已写入" -ForegroundColor Green
Write-Host ""

# ===== Phase C: 在 README.md 末尾追加模型下载说明 =====
Write-Host "[Phase C] 更新 README.md..." -ForegroundColor Yellow

$readmePath = Join-Path $ReleaseRepoPath "README.md"
$downloadSection = @"

## 模型文件下载

本仓库不含 SenseVoice 语音识别模型（229MB，超 GitHub 单文件限制）。

1. 前往 [Releases 页面](https://github.com/$GitHubRepo/releases/latest)
2. 下载 ``model.int8.onnx``
3. 放到 ``assets/model.int8.onnx``
4. 运行 ``flutter pub get && flutter run``
"@

if (Test-Path $readmePath) {
    $readmeContent = Get-Content $readmePath -Raw -Encoding utf8
    if ($readmeContent -match "模型文件下载") {
        Write-Host "[Phase C] README 已含模型下载说明，跳过"
    } else {
        $readmeContent = $readmeContent.TrimEnd() + "`n" + $downloadSection + "`n"
        $readmeContent | Out-File -FilePath $readmePath -Encoding utf8 -Force -NoNewline
        Write-Host "[Phase C] README 已追加模型下载说明"
    }
} else {
    $downloadSection | Out-File -FilePath $readmePath -Encoding utf8 -Force
    Write-Host "[Phase C] README.md 不存在，已创建"
}
Write-Host ""

# ===== Phase D: git init / add / commit =====
Write-Host "[Phase D] 初始化 git..." -ForegroundColor Yellow

Push-Location $ReleaseRepoPath
try {
    if (-not $releaseHasGit) {
        git init -b main
        if ($LASTEXITCODE -ne 0) {
            # 老版本 git 不支持 -b，回退方案
            git init
            git checkout -b main 2>$null
        }
        Write-Host "git init 完成（main 分支）"
    }

    # 设置作者信息（本地配置，仅影响发布仓库）
    git config user.name $GitAuthorName
    git config user.email $GitAuthorEmail
    Write-Host "git 作者配置: $GitAuthorName <$GitAuthorEmail>"

    # 配置远程
    if ($Push) {
        $remoteUrl = "git@github.com:$GitHubRepo.git"
        $existingRemote = git remote get-url origin 2>$null
        if ($existingRemote) {
            if ($existingRemote -ne $remoteUrl) {
                git remote set-url origin $remoteUrl
                Write-Host "git remote 已更新: $remoteUrl"
            }
        } else {
            git remote add origin $remoteUrl
            Write-Host "git remote 已添加: $remoteUrl"
        }
    }

    # add + commit
    git add -A
    $commitResult = git commit --allow-empty -m $CommitMsg 2>&1
    Write-Host $commitResult

    Write-Host "[Phase D] git commit 完成" -ForegroundColor Green
    Write-Host ""

    # ===== Phase E: 可选 push =====
    if ($Push) {
        Write-Host "[Phase E] git push..." -ForegroundColor Yellow
        # 首次推送用 -u，后续 force-with-lease 防止误覆盖
        git ls-remote origin main 2>$null | Out-Null
        if ($LASTEXITCODE -eq 0) {
            # 远程有内容，force-with-lease
            git push -u origin main --force-with-lease
        } else {
            # 远程为空，首次推送
            git push -u origin main
        }
        if ($LASTEXITCODE -ne 0) {
            Write-Error "git push 失败（退出码 $LASTEXITCODE）"
            Write-Host "提示：确认 GitHub 仓库已创建且 SSH 密钥已配置"
            exit 1
        }
        Write-Host "[Phase E] push 完成" -ForegroundColor Green
    } else {
        Write-Host "[Phase E] 跳过 push（未指定 -Push）" -ForegroundColor DarkGray
    }
    Write-Host ""

    # ===== Phase F: 可选上传模型到 GitHub Release =====
    if ($UploadModel) {
        Write-Host "[Phase F] 上传模型到 GitHub Release..." -ForegroundColor Yellow

        if (-not (Test-Path $modelSrc)) {
            Write-Warning "开发仓库无 model.int8.onnx，跳过上传"
            Write-Warning "请将模型放到: $modelSrc"
        } else {
            $ghCmd = Get-Command gh -ErrorAction SilentlyContinue
            if (-not $ghCmd) {
                Write-Warning "未找到 gh CLI，请手动上传:"
                Write-Warning "  gh release create v1.0.0 `"$modelSrc`" --repo $GitHubRepo --title v1.0.0 --notes 'SenseVoice 模型文件'"
                Write-Warning "  或访问 https://github.com/$GitHubRepo/releases 网页上传"
            } else {
                $tag = "v1.0.0"
                Write-Host "上传 $modelSrc 到 Release $tag ..."
                gh release create $tag $modelSrc --repo $GitHubRepo --title $tag --notes "SenseVoice 语音识别模型（229MB）"
                if ($LASTEXITCODE -eq 0) {
                    Write-Host "[Phase F] 模型已上传到 Release $tag" -ForegroundColor Green
                } else {
                    Write-Warning "gh release create 失败（退出码 $LASTEXITCODE）"
                    Write-Warning "可能 Release 已存在，改用 gh release upload:"
                    Write-Warning "  gh release upload $tag `"$modelSrc`" --repo $GitHubRepo --clobber"
                }
            }
        }
    } else {
        Write-Host "[Phase F] 跳过模型上传（未指定 -UploadModel）" -ForegroundColor DarkGray
    }

    # ===== Phase G: 可选上传 APK 到 GitHub Release =====
    if ($UploadApk) {
        Write-Host "[Phase G] 上传 APK 到 GitHub Release..." -ForegroundColor Yellow

        # 解析 ApkPath：空=默认 build/app/outputs/apk/release/app-arm64-v8a-release.apk；相对路径基于 $SrcRepoPath 拼绝对
        if ([string]::IsNullOrEmpty($ApkPath)) {
            $resolvedApkPath = Join-Path $SrcRepoPath "build\app\outputs\apk\release\app-arm64-v8a-release.apk"
        } elseif (-not (Split-Path $ApkPath -IsAbsolute)) {
            $resolvedApkPath = Join-Path $SrcRepoPath $ApkPath
        } else {
            $resolvedApkPath = $ApkPath
        }
        if (-not (Test-Path $resolvedApkPath)) {
            Write-Warning "APK 不存在: $resolvedApkPath"
            Write-Warning "请先执行 flutter build apk --split-per-abi 生成"
        } else {
            # 解析 VersionTag：空=读 pubspec.yaml 的 version: X.Y.Z 拼 vX.Y.Z
            $resolvedTag = $VersionTag
            if ([string]::IsNullOrEmpty($resolvedTag)) {
                $pubspecPath = Join-Path $SrcRepoPath "pubspec.yaml"
                $pubspecVer = ""
                if (Test-Path $pubspecPath) {
                    try {
                        $pubspecContent = Get-Content $pubspecPath -Raw -Encoding utf8
                        if ($pubspecContent -match 'version:\s*(\d+\.\d+\.\d+)') {
                            $pubspecVer = $matches[1]
                        }
                    } catch {
                        Write-Warning "读取 pubspec.yaml 失败: $_"
                    }
                }
                if ([string]::IsNullOrEmpty($pubspecVer)) {
                    Write-Warning "未能从 pubspec.yaml 解析版本号，跳过 APK 上传"
                } else {
                    $resolvedTag = "v$pubspecVer"
                }
            }

            if (-not [string]::IsNullOrEmpty($resolvedTag)) {
                # 组装规范文件名：声物记_vX.Y.Z_功能备注_arm64.apk 或 声物记_vX.Y.Z_arm64.apk
                if ([string]::IsNullOrEmpty($ApkLabel)) {
                    $apkFileName = "声物记_${resolvedTag}_arm64.apk"
                } else {
                    $apkFileName = "声物记_${resolvedTag}_${ApkLabel}_arm64.apk"
                }

                # 复制到 TEMP 用规范名重命名（不污染原 build 目录）
                $tempApk = Join-Path $env:TEMP $apkFileName
                try {
                    Copy-Item $resolvedApkPath $tempApk -Force
                    Write-Host "源 APK: $resolvedApkPath"
                    Write-Host "临时副本: $tempApk"

                    # 生成默认 release notes：取最近 15 条 commit subject，剥离开头 claude: 前缀
                    $recentCommits = @()
                    try {
                        $rawCommits = git -C $SrcRepoPath log --oneline -15 2>$null
                        if ($LASTEXITCODE -eq 0 -and $rawCommits) {
                            foreach ($line in $rawCommits) {
                                # git --oneline 格式："<sha> <subject>"，先剥离 sha 前缀再去 claude: 前缀
                                $subjectOnly = ($line -replace '^[0-9a-f]+\s+', '') -replace '^claude:\s*', ''
                                $recentCommits += $subjectOnly
                            }
                        }
                    } catch { }
                    if ($recentCommits.Count -gt 0) {
                        $releaseNotes = $recentCommits -join "`n"
                    } else {
                        $releaseNotes = "声物记 $resolvedTag"
                    }

                    $ghCmd = Get-Command gh -ErrorAction SilentlyContinue
                    if (-not $ghCmd) {
                        Write-Warning "未找到 gh CLI，请手动上传:"
                        Write-Warning "  gh release create $resolvedTag `"$tempApk`" --repo $GitHubRepo --title `"声物记 $resolvedTag`" --notes `"...`""
                        Write-Warning "  或访问 https://github.com/$GitHubRepo/releases 网页上传"
                    } else {
                        Write-Host "上传 $tempApk 到 Release $resolvedTag ..."
                        gh release create $resolvedTag $tempApk --repo $GitHubRepo --title "声物记 $resolvedTag" --notes $releaseNotes
                        if ($LASTEXITCODE -eq 0) {
                            Write-Host "[Phase G] APK 已上传到 Release $resolvedTag" -ForegroundColor Green
                        } else {
                            Write-Warning "gh release create 失败（退出码 $LASTEXITCODE）"
                            Write-Warning "可能 Release 已存在，改用 gh release upload:"
                            Write-Warning "  gh release upload $resolvedTag `"$tempApk`" --repo $GitHubRepo --clobber"
                            gh release upload $resolvedTag $tempApk --repo $GitHubRepo --clobber
                            if ($LASTEXITCODE -eq 0) {
                                Write-Host "[Phase G] APK 已上传到 Release $resolvedTag（fallback upload 成功）" -ForegroundColor Green
                            } else {
                                Write-Warning "gh release upload 失败（退出码 $LASTEXITCODE）"
                            }
                        }
                    }
                } finally {
                    Remove-Item $tempApk -Force -ErrorAction SilentlyContinue
                }
            }
        }
    } else {
        Write-Host "[Phase G] 跳过 APK 上传（未指定 -UploadApk）" -ForegroundColor DarkGray
    }

} finally {
    Pop-Location
}

# ===== 总结 =====
Write-Host ""
Write-Host "================================" -ForegroundColor Cyan
Write-Host "  同步完成" -ForegroundColor Cyan
Write-Host "================================" -ForegroundColor Cyan
Write-Host "发布仓库: $ReleaseRepoPath"
Write-Host ""
Write-Host "后续手动步骤（按需）:"
if (-not $Push) {
    Write-Host "  - 推送源码: 重新运行加 -Push"
}
if (-not $UploadModel) {
    Write-Host "  - 上传模型: 重新运行加 -UploadModel"
}
if (-not $UploadApk) {
    Write-Host "  - 上传 APK: 重新运行加 -UploadApk"
}
Write-Host "  - 在 GitHub 创建空仓库: https://github.com/new （名称 $GitHubRepo）"
Write-Host ""
Write-Host "验证（在发布仓库内）:"
Write-Host "  cd $ReleaseRepoPath"
Write-Host "  git log --oneline               # 应只有同步生成的 commit"
Write-Host "  git config user.email           # 应是 noreply 邮箱"
Write-Host "  ls assets/model.int8.onnx 2>nul # 应不存在（已排除）"
Write-Host "  ls .waylog 2>nul                # 应不存在"
