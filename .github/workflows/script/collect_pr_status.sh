#!/bin/bash

# ==========================================
# collect_pr_status.sh
# ------------------------------------------
# オープン中のプルリクエストを取得し
# GitHub Wiki の Markdown ページにステータスを
# まとめるスクリプトです。GitHub Actions 上で
# gh コマンドを使って実行する想定です。
# ==========================================

set -euxo pipefail

# 必要なコマンドの存在確認
command -v gh >/dev/null 2>&1 || { echo "gh コマンドが見つかりません"; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "jq コマンドが見つかりません"; exit 1; }

# ----- 関数定義 --------------------------------------------------------------

# レビュー結果とドラフト状態から PR のステータスを判定する
# 引数:
#   $1 - レビュー情報(JSON 配列)
#   $2 - ドラフトかどうか(true/false)
determine_pr_status() {
    local reviews="$1"
    local is_draft="$2"

    if [[ "$is_draft" == "true" ]]; then
        echo "ドラフト"
        return
    fi

    local approved_count=$(echo "$reviews" | jq '[.[] | select(.state=="APPROVED")] | length')
    local changes_requested=$(echo "$reviews" | jq '[.[] | select(.state=="CHANGES_REQUESTED")] | length')
    local review_count=$(echo "$reviews" | jq 'length')

    if [[ $approved_count -gt 0 ]]; then
        echo "承認済み"
    elif [[ $changes_requested -gt 0 ]]; then
        echo "修正依頼"
    elif [[ $review_count -gt 0 ]]; then
        echo "レビュー中"
    else
        echo "未レビュー"
    fi
}

# レビュワーの状態を絵文字付きで整形する
# 引数:
#   $1 - レビュワーのログイン名
#   $2 - レビューの状態(APPROVED など)
format_reviewer_status() {
    local reviewer="$1"
    local state="$2"
    case "$state" in
        "APPROVED") echo "${reviewer}✅" ;;
        "CHANGES_REQUESTED") echo "${reviewer}❌" ;;
        "COMMENTED") echo "${reviewer}💬" ;;
        "PENDING"|"") echo "${reviewer}⏳" ;;
        *) echo "${reviewer}" ;;
    esac
}

# -----------------------------------------------------------------------------
# 出力先ディレクトリの設定
# 引数でディレクトリが指定されていない場合はカレントディレクトリを使用
# -----------------------------------------------------------------------------
OUTPUT_DIR="${1:-.}"
mkdir -p "$OUTPUT_DIR"
OUTPUT_FILE="$OUTPUT_DIR/PR_Status.md"

# Markdown テーブルのヘッダーを書き出し
{
    echo "# Pull Request Status"
    echo ""
    echo "Updated: $(date '+%Y-%m-%d %H:%M:%S')"
    echo ""
    echo "| PR | Title | 状態 | Reviewers | Assignees | Priority | Target Date | Sprint |"
    echo "| --- | ----- | ---- | --------- | --------- | -------- | ----------- | ------ |"
} > "$OUTPUT_FILE"

# -----------------------------------------------------------------------------
# PR 情報の収集
# -----------------------------------------------------------------------------
PR_LIST=$(gh pr list --state open --limit 100 \
    --json number,title,author,createdAt,updatedAt,url,isDraft)
# gh CLI の結果を標準出力へ表示
echo "PR_LIST=${PR_LIST}"
PR_COUNT=$(echo "$PR_LIST" | jq 'length')

for i in $(seq 0 $((PR_COUNT - 1))); do
    PR_NUMBER=$(echo "$PR_LIST" | jq -r ".[$i].number")
    PR_TITLE=$(echo "$PR_LIST" | jq -r ".[$i].title" | tr '\n' ' ' | sed 's/|/\\|/g')
    PR_URL=$(echo "$PR_LIST" | jq -r ".[$i].url")
    PR_IS_DRAFT=$(echo "$PR_LIST" | jq -r ".[$i].isDraft")

    DETAILS=$(gh pr view "$PR_NUMBER" --json reviews,reviewRequests,assignees)
    # 個別 PR の詳細情報を標準出力へ表示
    echo "DETAILS for PR ${PR_NUMBER}=${DETAILS}"
    REVIEWS=$(echo "$DETAILS" | jq -c '.reviews')
    REQUESTED_REVIEWERS=$(echo "$DETAILS" | jq -r '.reviewRequests[].login' | tr '\n' ' ')
    ASSIGNEES=$(echo "$DETAILS" | jq -r '.assignees[].login' | tr '\n' ' ')
    [[ -z "$ASSIGNEES" ]] && ASSIGNEES="未割当"

    # レビュワー情報を整形
    REVIEWER_INFO=""
    for reviewer in $REQUESTED_REVIEWERS; do
        [[ -n "$REVIEWER_INFO" ]] && REVIEWER_INFO+="<br>"
        REVIEWER_INFO+=$(format_reviewer_status "$reviewer" "PENDING")
    done
    if [[ "$REVIEWS" != "[]" ]]; then
        UNIQUE_REVIEWERS=$(echo "$REVIEWS" | jq -r '.[].user.login' | sort -u)
        for reviewer in $UNIQUE_REVIEWERS; do
            LATEST_STATE=$(echo "$REVIEWS" | jq -r ".[] | select(.user.login==\"$reviewer\") | .state" | tail -n1)
            [[ -n "$REVIEWER_INFO" ]] && REVIEWER_INFO+="<br>"
            REVIEWER_INFO+=$(format_reviewer_status "$reviewer" "$LATEST_STATE")
        done
    fi
    [[ -z "$REVIEWER_INFO" ]] && REVIEWER_INFO="未割当"

    PR_STATUS=$(determine_pr_status "$REVIEWS" "$PR_IS_DRAFT")

    # --- Projects フィールドの取得 -------------------------------------------
    PR_NODE_ID=$(gh pr view "$PR_NUMBER" --json id -q .id)
    # PR の node ID を標準出力へ表示
    echo "PR_NODE_ID for PR ${PR_NUMBER}=${PR_NODE_ID}"
    PROJECT_JSON=$(gh api graphql \
      -f query='
        query($prId: ID!) {
          node(id: $prId) {
            __typename
            ... on PullRequest {
              projectItems(first: 20) {
                nodes {
                  project {
                    id
                    title
                    number
                    url
                  }
                }
              }
            }
          }
        }
      ' \
      -f prId="$PR_NODE_ID")

    # プロジェクト情報の取得結果を標準出力へ表示
    echo "PROJECT_JSON for PR ${PR_NUMBER}=${PROJECT_JSON}"

    TARGET_DATE=$(echo "$PROJECT_JSON" | jq -r '.data.node.projectItems.nodes[]? | .targetDate | .date // .text // empty' | head -n1)
    PRIORITY=$(echo "$PROJECT_JSON" | jq -r '.data.node.projectItems.nodes[]? | .priority | .name // .text // empty' | head -n1)
    SPRINT=$(echo "$PROJECT_JSON" | jq -r '.data.node.projectItems.nodes[]? | .sprint | .name // .text // empty' | head -n1)

    TARGET_DATE=${TARGET_DATE:-"-"}
    PRIORITY=${PRIORITY:-"-"}
    SPRINT=${SPRINT:-"-"}

    echo "| #$PR_NUMBER | [$PR_TITLE]($PR_URL) | $PR_STATUS | $REVIEWER_INFO | $ASSIGNEES | $PRIORITY | $TARGET_DATE | $SPRINT |" >> "$OUTPUT_FILE"
done

echo "PR 情報を $OUTPUT_FILE に出力しました"
