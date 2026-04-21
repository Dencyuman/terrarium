---
name: sk-pr-fix
description: "PR修正（CI失敗の修正 + レビューコメント対応）を一括で実施"
argument-hint: "[PR番号]"
disable-model-invocation: true
allowed-tools:
  - Bash
  - Read
  - Edit
  - Grep
  - Glob
---

# PR Fix - PR修正（CI + レビューコメント対応）

## 使用方法

```
/sk-pr-fix [PR番号]
```

引数:

- `PR番号`: 修正対象のPR（省略時は現在のブランチのPR）

ARGUMENTS: $ARGUMENTS

## タスク文脈の取得

修正前に、現在のブランチに紐づくタスクプランを確認する:

```bash
BRANCH=$(git branch --show-current)
# tasks/ 内のファイルから branch: $BRANCH を含むプランを検索
grep -rl "branch: $BRANCH" tasks/*.md 2>/dev/null
```

該当するタスクファイルがあれば読み込み、修正の文脈として活用する。

## 動作フロー

1. **PR特定**: 引数のPR番号、または `gh pr view` で現在のブランチのPRを特定
2. **CI状況確認**: `gh pr checks` でCI結果を取得。失敗があればログを取得・分析
3. **レビューコメント取得**: `gh api` でレビューコメントとレビューサマリーを取得
4. **状況一覧表示**: CI失敗内容 + レビューコメント一覧をユーザーに提示
5. **対応方針提案**: 各問題に対する修正方針を提案
6. **ユーザー承認**: 方針の確認・調整
7. **コード修正**: 承認された方針に基づいてコードを修正
8. **コミット＆push**: 修正をコミットしてpush
9. **レビューコメント返信**: 対応したコメントに `gh api` で返信（修正コミットリンク付き）

## レビューコメント取得

```bash
# PRコメント（inline コメント）
gh api repos/{owner}/{repo}/pulls/<PR番号>/comments

# レビュー（approve / request changes / comment）
gh api repos/{owner}/{repo}/pulls/<PR番号>/reviews
```

- `PENDING` 状態のレビューは除外
- 既に resolved のコメントは対応済みとしてスキップ
- コメントの `in_reply_to_id` でスレッドをグループ化

## レビューコメント返信

返信には必ず修正コミットリンクを含める:

- 基本: `修正しました。 https://github.com/{owner}/{repo}/commit/{sha}`
- 補足が必要な場合: `修正しました。{補足説明} https://github.com/{owner}/{repo}/commit/{sha}`

## 境界

**実施すること:**

- CI失敗ログの取得と原因分析
- レビューコメントの取得と分類
- 修正方針の提案とユーザー承認
- コード修正の実行
- コミットとpush
- レビューコメントへの返信

**実施しないこと:**

- ユーザーの承認なしでコード修正を実行
- PRのマージやクローズ
- レビュアーへのメンション追加や re-review リクエスト
- CI設定ファイル自体の変更（テストコードやアプリコードのみ修正）
