#!/bin/bash
set -euo pipefail

REPO="lau-ca/cockpit-tools"
OUTPUT_DIR="./windows-build"

echo "==> 查找最新构建..."
RUN=$(gh api repos/$REPO/actions/runs \
    --jq '.workflow_runs | to_entries | .[0].value')
RUN_ID=$(echo "$RUN" | jq -r '.id')
STATUS=$(echo "$RUN" | jq -r '.status')
CONCLUSION=$(echo "$RUN" | jq -r '.conclusion')
BRANCH=$(echo "$RUN" | jq -r '.head_branch')

echo "Run ID: $RUN_ID"
echo "Branch: $BRANCH"
echo "Status: $STATUS"

# 如果构建还在进行中，等待完成
if [ "$STATUS" = "in_progress" ]; then
    echo ""
    echo "==> 构建进行中，等待完成（最多 60 分钟）..."
    INTERVAL=30
    ELAPSED=0

    while [ $ELAPSED -lt 3600 ]; do
        sleep $INTERVAL
        ELAPSED=$((ELAPSED + INTERVAL))

        RUN=$(gh api repos/$REPO/actions/runs/$RUN_ID --jq '.')
        STATUS=$(echo "$RUN" | jq -r '.status')
        CONCLUSION=$(echo "$RUN" | jq -r '.conclusion')

        echo "[$(date '+%H:%M:%S')] $STATUS"

        if [ "$STATUS" = "completed" ]; then
            echo "构建完成: $CONCLUSION"
            break
        fi
    done

    if [ "$STATUS" != "completed" ]; then
        echo "构建超时"
        exit 1
    fi
fi

if [ "$CONCLUSION" != "success" ]; then
    echo "构建失败: $CONCLUSION"
    exit 1
fi

echo ""
echo "==> 下载构建产物到 $OUTPUT_DIR..."
mkdir -p "$OUTPUT_DIR"

# 列出所有 artifacts
echo "Artifacts:"
ARTIFACTS=$(gh api repos/$REPO/actions/runs/$RUN_ID/artifacts --jq '.artifacts')
echo "$ARTIFACTS" | jq -r '.[].name'

# 下载 Windows artifact
ARTIFACT_ID=$(echo "$ARTIFACTS" | jq -r '.[] | select(.name | contains("windows-latest")) | .id')

if [ -z "$ARTIFACT_ID" ] || [ "$ARTIFACT_ID" = "null" ]; then
    echo "找不到 Windows 构建产物"
    exit 1
fi

echo ""
echo "下载 artifact ID: $ARTIFACT_ID"

gh api repos/$REPO/actions/artifacts/$ARTIFACT_ID/zip \
    --output "$OUTPUT_DIR/bundles-windows-latest.zip"

cd "$OUTPUT_DIR"
unzip -o bundles-windows-latest.zip
rm bundles-windows-latest.zip

echo ""
echo "==> Windows 安装包:"
find . -type f \( -name "*.exe" -o -name "*.msi" \) 2>/dev/null
