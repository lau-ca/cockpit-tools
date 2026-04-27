#!/bin/bash
set -euo pipefail

REPO="lau-ca/cockpit-tools"
BRANCH="feature/build-matrix-win"
OUTPUT_DIR="./windows-build"

echo "==> 1. 推送代码..."
git push git@github.com:lau-ca/cockpit-tools.git HEAD:"$BRANCH" --force

echo ""
echo "==> 2. 等待构建完成（最多 60 分钟）..."

# 轮询检查构建状态
check_status() {
    gh api repos/$REPO/actions/runs \
        --jq ".workflow_runs | map(select(.head_branch == \"$BRANCH\" and .status != \"completed\")) | .[0]" 2>/dev/null
}

check_completed() {
    gh api repos/$REPO/actions/runs \
        --jq ".workflow_runs | map(select(.head_branch == \"$BRANCH\" and .conclusion != null)) | .[0]" 2>/dev/null
}

TIMEOUT=3600
INTERVAL=30
ELAPSED=0

while [ $ELAPSED -lt $TIMEOUT ]; do
    # 检查是否有进行中的 run
    RUN=$(check_status)
    if [ -n "$RUN" ]; then
        STATUS=$(echo "$RUN" | jq -r '.status')
        NAME=$(echo "$RUN" | jq -r '.name')
        echo "[$(date '+%H:%M:%S')] $NAME: $STATUS"
    else
        # 检查是否完成
        RUN=$(check_completed)
        if [ -n "$RUN" ]; then
            CONCLUSION=$(echo "$RUN" | jq -r '.conclusion')
            RUN_ID=$(echo "$RUN" | jq -r '.id')
            echo ""
            echo "==> 构建完成: $CONCLUSION (Run ID: $RUN_ID)"
            break
        fi
        echo "[$(date '+%H:%M:%S')] 等待 workflow 启动..."
    fi

    sleep $INTERVAL
    ELAPSED=$((ELAPSED + INTERVAL))
done

if [ -z "$RUN" ]; then
    echo "构建超时"
    exit 1
fi

if [ "$CONCLUSION" != "success" ]; then
    echo "构建失败: $CONCLUSION"
    exit 1
fi

echo ""
echo "==> 3. 下载构建产物到 $OUTPUT_DIR..."
mkdir -p "$OUTPUT_DIR"

# 查找 Windows artifact
ARTIFACT_ID=$(gh api repos/$REPO/actions/runs/$RUN_ID/artifacts \
    --jq ".artifacts[] | select(.name == \"bundles-windows-latest\") | .id")

if [ -z "$ARTIFACT_ID" ]; then
    echo "找不到 Windows 构建产物"
    exit 1
fi

echo "下载 artifact ID: $ARTIFACT_ID"

# 下载并解压
gh api repos/$REPO/actions/artifacts/$ARTIFACT_ID/zip \
    --output "$OUTPUT_DIR/bundles-windows-latest.zip"

cd "$OUTPUT_DIR"
unzip -o bundles-windows-latest.zip
rm bundles-windows-latest.zip

echo ""
echo "==> Windows 安装包:"
find . -name "*.exe" -o -name "*.msi" 2>/dev/null
