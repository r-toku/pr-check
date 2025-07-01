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
    echo "| PR# | タイトル | 作成者 | レビュワー | 作成日 | 更新日 |"
    echo "| --- | -------- | ------ | --------- | ------ | ------ |"
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
    PR_AUTHOR=$(echo "$PR_LIST" | jq -r ".[$i].author.login")
    PR_CREATED=$(echo "$PR_LIST" | jq -r ".[$i].createdAt" | cut -d'T' -f1)
    PR_UPDATED=$(echo "$PR_LIST" | jq -r ".[$i].updatedAt" | cut -d'T' -f1)
    PR_IS_DRAFT=$(echo "$PR_LIST" | jq -r ".[$i].isDraft")

    DETAILS=$(gh pr view "$PR_NUMBER" --json reviews,reviewRequests)
    # 個別 PR の詳細情報を標準出力へ表示
    echo "DETAILS for PR ${PR_NUMBER}=${DETAILS}"
    REVIEWS=$(echo "$DETAILS" | jq -c '.reviews')
    REQUESTED_REVIEWERS=$(echo "$DETAILS" | jq -r '.reviewRequests[].login' | tr '\n' ' ')

    # レビュワーごとの状態を格納する連想配列
    declare -A reviewer_states=()

    if [[ "$REVIEWS" != "[]" ]]; then
        # `author.login` と `user.login` のどちらかが存在するので併用する
        UNIQUE_REVIEWERS=$(
            echo "$REVIEWS" |
                jq -r '.[] | (.author.login // .user.login)' \
                | sort -u
        )
        for reviewer in $UNIQUE_REVIEWERS; do
            LATEST_STATE=$(
                echo "$REVIEWS" |
                    jq -r ".[] | select((.author.login // .user.login)==\"$reviewer\") | .state // \"COMMENTED\"" \
                    | tail -n1
            )
            reviewer_states["$reviewer"]="$LATEST_STATE"
        done
    fi

    # レビューの再依頼があれば Pending 状態で上書き
    for reviewer in $REQUESTED_REVIEWERS; do
        reviewer_states["$reviewer"]="PENDING"
    done

    # レビュワー情報を整形
    REVIEWER_INFO=""
    for reviewer in $(printf '%s\n' "${!reviewer_states[@]}" | sort); do
        [[ -n "$REVIEWER_INFO" ]] && REVIEWER_INFO+="<br>"
        REVIEWER_INFO+=$(format_reviewer_status "$reviewer" "${reviewer_states[$reviewer]}")
    done
    [[ -z "$REVIEWER_INFO" ]] && REVIEWER_INFO="未割当"

    PR_STATUS=$(determine_pr_status "$REVIEWS" "$PR_IS_DRAFT")

    echo "| #$PR_NUMBER | [$PR_TITLE]($PR_URL)<br>($PR_STATUS) | $PR_AUTHOR | $REVIEWER_INFO | $PR_CREATED | $PR_UPDATED |" >> "$OUTPUT_FILE"
done

echo "PR 情報を $OUTPUT_FILE に出力しました"

