#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

REMOTE="${REMOTE:-my}"
BRANCH="${BRANCH:-feature/build-windows-run}"
WORKFLOW_FILE="${WORKFLOW_FILE:-build-matrix.yml}"
ARTIFACT_NAME="${ARTIFACT_NAME:-bundles-windows-latest}"
OUTPUT_DIR="${OUTPUT_DIR:-$PROJECT_ROOT/windows-build}"
REPO="${REPO:-}"
SKIP_PUSH="${SKIP_PUSH:-0}"
BUILD_TARGET="${BUILD_TARGET:-windows}"
TIMEOUT_SECONDS="${TIMEOUT_SECONDS:-3600}"
INTERVAL_SECONDS="${INTERVAL_SECONDS:-20}"

usage() {
  cat <<EOF
用法:
  bash scripts/build-windows.sh

可选环境变量:
  REPO=owner/repo                 GitHub 仓库，默认根据 git remote 自动识别
  REMOTE=my                       Git 远程名，默认 my
  BRANCH=feature/build-windows-run 推送到 GitHub Actions 的目标分支
  WORKFLOW_FILE=build-matrix.yml  目标 workflow 文件名
  ARTIFACT_NAME=bundles-windows-latest
                                  Windows 构建产物名称
  OUTPUT_DIR=/abs/path            本地下载目录
  BUILD_TARGET=windows            workflow_dispatch 的构建目标，默认只打 Windows
  SKIP_PUSH=1                     跳过 push，只等待并下载
  TIMEOUT_SECONDS=3600            最长等待秒数
  INTERVAL_SECONDS=20             轮询间隔秒数
EOF
}

step() {
  printf '\n==> %s\n' "$1"
}

warn() {
  printf '[!] %s\n' "$1" >&2
}

require_command() {
  local command="$1"
  local hint="$2"
  if ! command -v "$command" >/dev/null 2>&1; then
    echo "[X] 未找到 $command"
    echo "    $hint"
    exit 1
  fi
}

ensure_clean_worktree() {
  if [[ -n "$(git status --short)" ]]; then
    echo "[X] 检测到未提交改动，当前脚本不会把工作区改动自动带到 GitHub。"
    echo "    请先提交后再执行远程打包。未提交文件："
    git status --short
    exit 1
  fi
}

resolve_repo_from_remote() {
  local remote_name="$1"
  local remote_url
  remote_url="$(git remote get-url "$remote_name" 2>/dev/null || true)"
  if [[ -z "$remote_url" ]]; then
    return 1
  fi

  remote_url="${remote_url%.git}"
  if [[ "$remote_url" =~ github\.com[:/]([^/]+/[^/]+)$ ]]; then
    printf '%s\n' "${BASH_REMATCH[1]}"
    return 0
  fi

  return 1
}

gh_json() {
  gh "$@" --json databaseId,headBranch,status,conclusion,createdAt,displayTitle
}

find_run() {
  gh run list \
    --repo "$REPO" \
    --workflow "$WORKFLOW_FILE" \
    --branch "$BRANCH" \
    --limit 20 \
    --json databaseId,headBranch,status,conclusion,createdAt,displayTitle,event
}

wait_for_run() {
  local elapsed=0
  local run_json=""

  while (( elapsed < TIMEOUT_SECONDS )); do
    local runs
    runs="$(find_run)"

    if [[ "$runs" != "[]" ]]; then
      run_json="$(echo "$runs" | jq '[.[] | select(.event == "workflow_dispatch")] | .[0]')"
      if [[ "$run_json" == "null" || -z "$run_json" ]]; then
        echo "[$(date '+%H:%M:%S')] 已发现历史构建，等待本次 workflow_dispatch 任务生成..." >&2
        sleep "$INTERVAL_SECONDS"
        elapsed=$((elapsed + INTERVAL_SECONDS))
        continue
      fi
      local run_id status conclusion title
      run_id="$(echo "$run_json" | jq -r '.databaseId')"
      status="$(echo "$run_json" | jq -r '.status')"
      conclusion="$(echo "$run_json" | jq -r '.conclusion // empty')"
      title="$(echo "$run_json" | jq -r '.displayTitle')"

      if [[ -n "$conclusion" ]]; then
        echo "[$(date '+%H:%M:%S')] Run #$run_id $title -> $status / $conclusion" >&2
      else
        echo "[$(date '+%H:%M:%S')] Run #$run_id $title -> $status" >&2
      fi

      if [[ "$status" == "completed" ]]; then
        echo "$run_json"
        return 0
      fi
    else
      echo "[$(date '+%H:%M:%S')] 等待 workflow 启动..." >&2
    fi

    sleep "$INTERVAL_SECONDS"
    elapsed=$((elapsed + INTERVAL_SECONDS))
  done

  echo "[X] 等待 GitHub Actions 超时，超过 ${TIMEOUT_SECONDS} 秒仍未完成。" >&2
  exit 1
}

require_command git "请先安装 Git。"
require_command gh "请先安装 GitHub CLI: https://cli.github.com/"
require_command jq "请先安装 jq: brew install jq"
require_command unzip "macOS 默认自带 unzip，如缺失请安装命令行工具。"

if ! gh auth status >/dev/null 2>&1; then
  echo "[X] gh 未登录"
  echo "    请先执行: gh auth login"
  exit 1
fi

if [[ -z "$REPO" ]]; then
  if ! REPO="$(resolve_repo_from_remote "$REMOTE")"; then
    echo "[X] 无法从 git remote 自动识别 GitHub 仓库"
    echo "    请手动指定: REPO=owner/repo bash scripts/build-windows.sh"
    exit 1
  fi
fi

cd "$PROJECT_ROOT"
ensure_clean_worktree

echo "========================================="
echo "  Cockpit Tools - Windows 远程构建"
echo "========================================="
echo "Repo:     $REPO"
echo "Remote:   $REMOTE"
echo "Branch:   $BRANCH"
echo "Workflow: $WORKFLOW_FILE"
echo "Artifact: $ARTIFACT_NAME"
echo "Output:   $OUTPUT_DIR"
echo "Target:   $BUILD_TARGET"

if [[ "$SKIP_PUSH" != "1" ]]; then
  step "推送当前代码到 $REMOTE/$BRANCH"
  git push "$REMOTE" "HEAD:refs/heads/$BRANCH" --force
else
  step "跳过推送，直接等待远端 workflow"
fi

step "触发 GitHub Actions，只构建 ${BUILD_TARGET}"
dispatch_error_file="$(mktemp)"
if ! gh workflow run "$WORKFLOW_FILE" \
  --repo "$REPO" \
  --ref "$BRANCH" \
  -f "build_target=$BUILD_TARGET" 2>"$dispatch_error_file"; then
  if grep -q 'Unexpected inputs provided' "$dispatch_error_file"; then
    warn "远端默认分支 workflow 尚未识别 build_target，自动降级为无入参触发。"
    gh workflow run "$WORKFLOW_FILE" \
      --repo "$REPO" \
      --ref "$BRANCH"
  else
    cat "$dispatch_error_file" >&2
    rm -f "$dispatch_error_file"
    exit 1
  fi
fi
rm -f "$dispatch_error_file"

sleep 5

step "等待 GitHub Actions 完成 Windows 构建"
RUN_JSON="$(wait_for_run)"
RUN_ID="$(echo "$RUN_JSON" | jq -r '.databaseId')"
RUN_CONCLUSION="$(echo "$RUN_JSON" | jq -r '.conclusion // empty')"

if [[ "$RUN_CONCLUSION" != "success" ]]; then
  echo "[X] 构建失败: ${RUN_CONCLUSION:-unknown}"
  echo "    查看日志: gh run view $RUN_ID --repo $REPO --log"
  exit 1
fi

step "下载 Windows 构建产物"
rm -rf "$OUTPUT_DIR"
mkdir -p "$OUTPUT_DIR"

gh run download "$RUN_ID" \
  --repo "$REPO" \
  --name "$ARTIFACT_NAME" \
  --dir "$OUTPUT_DIR"

mapfile -t installers < <(find "$OUTPUT_DIR" -type f \( -name "*.exe" -o -name "*.msi" \) | sort)

echo
echo "========================================="
echo "  Windows 构建完成"
echo "  Run ID: $RUN_ID"
echo "  输出目录: $OUTPUT_DIR"
echo "========================================="

if (( ${#installers[@]} == 0 )); then
  echo "[!] 已下载 artifact，但未找到 .exe 或 .msi 文件"
  exit 0
fi

echo
echo "安装包列表:"
for installer in "${installers[@]}"; do
  if stat_output="$(stat -f '%z' "$installer" 2>/dev/null)"; then
    size_mb="$(awk "BEGIN { printf \"%.1f\", $stat_output / 1048576 }")"
    echo "  $(basename "$installer")  (${size_mb} MB)"
  else
    echo "  $(basename "$installer")"
  fi
done
