---

name: fix-pr

description: "PR修正（CI失敗の修正 + レビューコメント対応）を一括で実施"

argument-hint: "[PR番号]"

category: git

complexity: standard

mcp-servers: []

personas: []

---

# /cc:fix-pr - PR修正（CI + レビューコメント対応）

## トリガー

- PRのCIが失敗している
- PRにレビューコメントが来ている
- CI修正とレビュー対応を一括で行いたい

## 使用方法

```
/cc:fix-pr [PR番号]
```

引数:

- `PR番号`: 修正対象のPR（省略時は現在のブランチのPR）

## 動作フロー

1. **PR特定**: 引数のPR番号、または `gh pr view` で現在のブランチのPRを特定
2. **CI状況確認**: `gh pr checks` でCI結果を取得。失敗があればログを取得・分析
3. **レビューコメント取得**: `gh api` でレビューコメントとレビューサマリーを取得
4. **状況一覧表示**: CI失敗内容 + レビューコメント一覧をユーザーに提示
5. **対応方針提案**: 各問題に対する修正方針を提案
6. **ユーザー承認**: 方針の確認・調整
7. **コード修正**: 承認された方針に基づいてコードを修正
8. **コミット＆push**: 修正をコミットしてpush
9. **レビューコメント返信**: 対応したコメントに `gh api` で返信

主要な動作:

- CI失敗ログの自動取得と原因分析
- レビューコメントの一括取得と分類
- 修正方針の提案とユーザー承認
- コード修正、コミット、push、コメント返信までの一括実行

## ツール連携

- **Bash**: gh pr view, gh pr checks, gh api, gh run view --log-failed, git add, git commit, git push
- **Read**: 変更対象ファイルの読み込み、CI設定ファイルの確認
- **Edit**: コード修正
- **Grep/Glob**: 関連コードの検索、影響範囲の調査

## 主要パターン

### PR特定

```bash
# 引数あり
gh pr view <PR番号> --json number,title,headRefName,url,state

# 引数なし（現在のブランチ）
gh pr view --json number,title,headRefName,url,state
```

### CI状況確認

```bash
# チェック結果の取得
gh pr checks <PR番号>

# 失敗したワークフローのログ取得
gh run view <run-id> --log-failed
```

- 失敗がない場合はCI確認をスキップ
- 複数の失敗がある場合は全て取得して分析

### レビューコメント取得

```bash
# PRコメント（inline コメント）
gh api repos/{owner}/{repo}/pulls/<PR番号>/comments

# レビュー（approve / request changes / comment）
gh api repos/{owner}/{repo}/pulls/<PR番号>/reviews
```

- `PENDING` 状態のレビューは除外
- 既に resolved のコメントは対応済みとしてスキップ
- コメントの `in_reply_to_id` でスレッドをグループ化

### 状況表示

CI失敗とレビューコメントを以下の形式で提示:

```markdown
## PR #150 の状況

### CI失敗

| # | ジョブ | エラー概要 |
|---|--------|-----------|
| 1 | lint | `src/app/page.tsx:15` - unused import |
| 2 | test | `tests/api.test.ts` - expect(...).toBe() assertion failed |

### レビューコメント

| # | ファイル | コメント | 投稿者 |
|---|---------|---------|--------|
| 1 | src/api/route.ts:30 | エラーハンドリングを追加してください | reviewer1 |
| 2 | src/utils/helper.ts:12 | この関数名はもう少し具体的にしたい | reviewer2 |
```

### 対応方針提案

各問題に対して具体的な修正方針を提案:

```markdown
## 対応方針

### CI修正
1. **lint エラー**: `src/app/page.tsx:15` の未使用import `Button` を削除
2. **テスト失敗**: `tests/api.test.ts` のアサーション値を修正（期待値: 200 → 201）

### レビュー対応
1. **src/api/route.ts:30**: try-catch でエラーハンドリングを追加
2. **src/utils/helper.ts:12**: `helper` → `formatUserDisplayName` にリネーム

上記の方針で修正してよいですか？
```

### レビューコメント返信

コミット＆push後、対応したコメントに返信する。

**返信には必ず修正コミットリンクを含めること。** レビュアーがワンクリックで修正内容を確認できるようにする。

```bash
# コミットURLの組み立て
# https://github.com/{owner}/{repo}/commit/{commit-sha}

# 対応完了を返信
gh api repos/{owner}/{repo}/pulls/<PR番号>/comments \
  -X POST \
  -f body="修正しました。 <commit-url>" \
  -F in_reply_to=<comment-id>
```

返信フォーマット:
- 基本: `修正しました。 https://github.com/{owner}/{repo}/commit/{sha}`
- 補足が必要な場合: `修正しました。{補足説明} https://github.com/{owner}/{repo}/commit/{sha}`

## 例

### 現在のブランチのPRを修正

```
/cc:fix-pr
# 現在のブランチのPRを自動検出
# CI状況とレビューコメントを取得
# 方針提案 → 承認 → 修正 → push → 返信
```

### PR番号を指定して修正

```
/cc:fix-pr 150
# PR #150 のCI失敗とレビューコメントを取得
# 方針提案 → 承認 → 修正 → push → 返信
```

### CIのみ失敗している場合

```
/cc:fix-pr 150
# レビューコメントなし → CI修正のみ実施
# CI失敗ログを分析 → 方針提案 → 修正 → push
```

### レビューコメントのみの場合

```
/cc:fix-pr 150
# CI全パス → レビュー対応のみ実施
# コメント一覧表示 → 方針提案 → 修正 → push → 返信
```

## エラー処理

### PRが見つからない

```
⚠️ PRが見つかりません

現在のブランチに紐づくPRがありません。
PR番号を指定して再度実行してください:
/cc:fix-pr <PR番号>
```

### CIもコメントもない

```
✅ 対応が必要な項目はありません

- CI: 全チェック通過
- レビューコメント: なし
```

### 未コミットの変更がある

```
⚠️ 未コミットの変更があります

先にコミットするか、stash してから再度実行してください。
```

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
