#!/bin/bash

# ==========================================
# update_wiki.sh
# ------------------------------------------
# 引数で渡された Wiki リポジトリのディレクトリで
# PR_Status.md をコミットしプッシュします。
# ==========================================

set -euo pipefail

WIKI_DIR="${1?Wiki リポジトリのパスを指定してください}"

cd "$WIKI_DIR"

# GITHUB_TOKEN が設定されていれば push 用の URL を設定
if [ -n "${GITHUB_TOKEN:-}" ]; then
    git remote set-url origin "https://x-access-token:${GITHUB_TOKEN}@github.com/${GITHUB_REPOSITORY}.wiki.git"
fi

if [ ! -f PR_Status.md ]; then
    echo "PR_Status.md が見つかりません"
    exit 1
fi

git add PR_Status.md
if ! git diff --cached --quiet; then
    git config user.name "${GITHUB_ACTOR:-github-actions}"
    git config user.email "${GITHUB_ACTOR:-github-actions}@users.noreply.github.com"
    git commit -m "Update PR status"
    git push
else
    echo "更新内容がないためコミットしません"
fi

