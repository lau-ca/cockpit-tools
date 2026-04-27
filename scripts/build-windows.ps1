param(
    [string]$Repo = "lau-ca/cockpit-tools",
    [string]$Remote = "origin",
    [string]$Branch = "feature/build-matrix-win",
    [string]$WorkflowFile = "build-matrix.yml",
    [string]$ArtifactName = "bundles-windows-latest",
    [string]$OutputDir = (Join-Path $PSScriptRoot ".." "windows-build"),
    [switch]$SkipPush
)

$ErrorActionPreference = "Stop"

function Write-Step {
    param([string]$Message)
    Write-Host ""
    Write-Host "==> $Message" -ForegroundColor Cyan
}

function Require-Command {
    param(
        [string]$Command,
        [string]$InstallHint
    )

    if (-not (Get-Command $Command -ErrorAction SilentlyContinue)) {
        Write-Host "[X] 未找到 $Command" -ForegroundColor Red
        Write-Host "    $InstallHint" -ForegroundColor Yellow
        exit 1
    }
}

function Invoke-GhJson {
    param([string[]]$Arguments)

    $output = gh @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "gh 命令执行失败: gh $($Arguments -join ' ')"
    }

    if ([string]::IsNullOrWhiteSpace($output)) {
        return $null
    }

    return $output | ConvertFrom-Json
}

function Find-WorkflowRun {
    param(
        [string]$Repository,
        [string]$Workflow,
        [string]$TargetBranch,
        [int]$Limit = 20
    )

    $runs = Invoke-GhJson @(
        "run", "list",
        "--repo", $Repository,
        "--workflow", $Workflow,
        "--branch", $TargetBranch,
        "--limit", "$Limit",
        "--json", "databaseId,headBranch,status,conclusion,createdAt,displayTitle"
    )

    if (-not $runs) {
        return $null
    }

    return $runs | Select-Object -First 1
}

function Wait-WorkflowRunCompleted {
    param(
        [string]$Repository,
        [string]$Workflow,
        [string]$TargetBranch,
        [int]$TimeoutSeconds = 3600,
        [int]$IntervalSeconds = 20
    )

    $elapsed = 0
    while ($elapsed -lt $TimeoutSeconds) {
        $run = Find-WorkflowRun -Repository $Repository -Workflow $Workflow -TargetBranch $TargetBranch
        if ($run) {
            $stamp = Get-Date -Format "HH:mm:ss"
            $statusText = $run.status
            if ($run.conclusion) {
                $statusText = "$statusText / $($run.conclusion)"
            }

            Write-Host "[$stamp] Run #$($run.databaseId) $($run.displayTitle) -> $statusText"

            if ($run.status -eq "completed") {
                return $run
            }
        } else {
            Write-Host "[$(Get-Date -Format 'HH:mm:ss')] 等待 workflow 启动..."
        }

        Start-Sleep -Seconds $IntervalSeconds
        $elapsed += $IntervalSeconds
    }

    throw "等待 GitHub Actions 超时，超过 $TimeoutSeconds 秒仍未完成。"
}

Write-Host "========================================="
Write-Host "  Cockpit Tools - Windows 远程构建"
Write-Host "========================================="
Write-Host "Repo:     $Repo"
Write-Host "Remote:   $Remote"
Write-Host "Branch:   $Branch"
Write-Host "Workflow: $WorkflowFile"
Write-Host "Artifact: $ArtifactName"
Write-Host ""

Require-Command -Command "git" -InstallHint "请先安装 Git。"
Require-Command -Command "gh" -InstallHint "请先安装 GitHub CLI: https://cli.github.com/"

$ghAuthStatus = gh auth status 2>&1
if ($LASTEXITCODE -ne 0) {
    Write-Host "[X] gh 未登录" -ForegroundColor Red
    Write-Host "    请先执行: gh auth login" -ForegroundColor Yellow
    exit 1
}

$ProjectRoot = Split-Path -Parent $PSScriptRoot
Set-Location $ProjectRoot

if (-not $SkipPush) {
    Write-Step "推送当前代码到 $Remote/$Branch"
    git push $Remote "HEAD:refs/heads/$Branch" --force
    if ($LASTEXITCODE -ne 0) {
        throw "推送分支失败。"
    }
} else {
    Write-Step "跳过推送，直接等待远端 workflow"
}

Write-Step "等待 GitHub Actions 完成 Windows 构建"
$run = Wait-WorkflowRunCompleted -Repository $Repo -Workflow $WorkflowFile -TargetBranch $Branch

if ($run.conclusion -ne "success") {
    Write-Host "[X] 构建失败: $($run.conclusion)" -ForegroundColor Red
    Write-Host "    查看日志: gh run view $($run.databaseId) --repo $Repo --log" -ForegroundColor Yellow
    exit 1
}

Write-Step "下载 Windows 构建产物"
if (Test-Path $OutputDir) {
    Remove-Item -Recurse -Force $OutputDir
}
New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null

gh run download $run.databaseId `
    --repo $Repo `
    --name $ArtifactName `
    --dir $OutputDir

if ($LASTEXITCODE -ne 0) {
    throw "下载 artifact 失败。"
}

$installers = Get-ChildItem -Path $OutputDir -Recurse -Include "*.exe", "*.msi" -File

Write-Host ""
Write-Host "========================================="
Write-Host "  Windows 构建完成"
Write-Host "  Run ID: $($run.databaseId)"
Write-Host "  输出目录: $OutputDir"
Write-Host "========================================="

if (-not $installers) {
    Write-Host "[!] 已下载 artifact，但未找到 .exe 或 .msi 文件" -ForegroundColor Yellow
    exit 0
}

Write-Host ""
Write-Host "安装包列表:" -ForegroundColor Green
foreach ($installer in $installers) {
    $size = "{0:N1} MB" -f ($installer.Length / 1MB)
    Write-Host "  $($installer.Name)  ($size)"
}
