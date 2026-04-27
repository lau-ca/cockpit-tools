# ─────────────────────────────────────────────────
# Cockpit Tools - Windows 构建下载脚本
# 从 GitHub Actions 下载最新的 Windows 安装包
# 在 Windows/Mac/Linux 上执行: powershell -ExecutionPolicy Bypass -File scripts\download-windows.ps1
# ─────────────────────────────────────────────────

$ErrorActionPreference = "Stop"

$Repo = "lau-ca/cockpit-tools"
$OutputDir = "$PSScriptRoot\..\windows-build"

Write-Host "========================================="
Write-Host "  Cockpit Tools - Windows 下载"
Write-Host "========================================="
Write-Host ""

# 查找最新构建的 run
Write-Host "> 查找最新构建..."
$Headers = @{ Authorization = "Bearer $env:GITHUB_TOKEN" }
if (-not $env:GITHUB_TOKEN) {
    Write-Host "[X] 未设置 GITHUB_TOKEN 环境变量" -ForegroundColor Red
    Write-Host "   请先运行: gh auth login" -ForegroundColor Yellow
    exit 1
}

$Runs = Invoke-RestMethod -Uri "https://api.github.com/repos/$Repo/actions/runs" -Headers $Headers -Method GET
$Run = $Runs.workflow_runs | Where-Object { $_.conclusion -eq "success" } | Select-Object -First 1

if (-not $Run) {
    Write-Host "[X] 找不到成功的构建" -ForegroundColor Red
    Write-Host "   最新的构建状态: $($Runs.workflow_runs[0].conclusion)" -ForegroundColor Yellow
    exit 1
}

$RunId = $Run.id
$Branch = $Run.head_branch
Write-Host "  Run ID: $RunId" -ForegroundColor Green
Write-Host "  Branch: $Branch" -ForegroundColor Green
Write-Host ""

# 查找 Windows artifact
Write-Host "> 查找 Windows 构建产物..."
$Artifacts = Invoke-RestMethod -Uri "https://api.github.com/repos/$Repo/actions/runs/$RunId/artifacts" -Headers $Headers -Method GET
$Artifact = $Artifacts.artifacts | Where-Object { $_.name -like "*windows*" } | Select-Object -First 1

if (-not $Artifact) {
    Write-Host "[X] 找不到 Windows 构建产物" -ForegroundColor Red
    Write-Host "   可用的 artifacts: $($Artifacts.artifacts.name -join ', ')" -ForegroundColor Yellow
    exit 1
}

$ArtifactId = $Artifact.id
$ArtifactName = $Artifact.name
Write-Host "  Artifact: $ArtifactName" -ForegroundColor Green
Write-Host ""

# 创建输出目录
if (Test-Path $OutputDir) {
    Remove-Item -Recurse -Force $OutputDir
}
New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null

# 下载 artifact
Write-Host "> 下载构建产物..."
$ZipPath = "$OutputDir\artifact.zip"
Invoke-RestMethod -Uri "https://api.github.com/repos/$Repo/actions/artifacts/$ArtifactId/zip" -Headers $Headers -Method GET -OutFile $ZipPath

# 解压
Write-Host "> 解压..."
Expand-Archive -Path $ZipPath -DestinationPath $OutputDir -Force
Remove-Item $ZipPath -Force

# 查找安装包
Write-Host ""
Write-Host "> Windows 安装包:" -ForegroundColor Cyan
$Installers = Get-ChildItem -Path $OutputDir -Recurse -Include "*.exe", "*.msi"

if ($Installers) {
    foreach ($Installer in $Installers) {
        $Size = "{0:N1} MB" -f ($Installer.Length / 1MB)
        Write-Host "  $($Installer.Name) ($Size)" -ForegroundColor Green
    }
} else {
    Write-Host "  未找到 .exe 或 .msi 文件" -ForegroundColor Yellow
}

Write-Host ""
Write-Host "========================================="
Write-Host "  下载完成！"
Write-Host "  输出目录: $OutputDir"
Write-Host "========================================="
Write-Host ""
