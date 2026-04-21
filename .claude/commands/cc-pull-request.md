---

name: pull-request

description: "現在のブランチからstagingブランチへのプルリクエストを作成"

argument-hint: "[title] [issue-number]"

category: git

complexity: standard

mcp-servers: []

personas: []

---

# /cc:pull-request - プルリクエスト作成

## トリガー

- 機能実装やバグ修正が完了し、PRを作成したい
- ブランチの変更をstagingブランチへマージする準備ができた
- レビューを依頼したい

## 使用方法

```
/cc:pull-request [title] [issue-number]
```

引数:

- `title`: PRのタイトル（任意、指定しない場合は自動生成）
- `issue-number`: 関連する GitHub Issue 番号（任意、例: `123`）

## 動作フロー

1. **事前チェック**: PRテンプレート、未コミット、未push、コンフリクト、差分の確認
2. **情報収集**: ブランチ名、コミット履歴、diff、関連 Issue 情報を収集
3. **生成**: PRタイトルと説明文を自動生成
4. **確認**: 生成内容をユーザーに提示
5. **作成**: 承認後、gh pr create でPR作成
6. **出力**: PR URLを表示

主要な動作:

- PRテンプレートの存在確認
- あらゆる情報源からの簡潔なタイトル生成
- コミット+diff分析による詳細な説明文生成
- GitHub Issue との連携（タスクセクションに `#<issue-number>` で参照。マージ時に GitHub Actions が Project ステータスを自動更新）
- コンフリクト検出と自動push

## ツール連携

- **Bash**: git status, git diff, git push, gh pr create, gh issue view
- **Read**: PRテンプレート、コミットメッセージの読み込み

## 主要パターン

### 事前チェック

1. **PRテンプレート確認**: `.github/pull_request_template.md`
  - 存在しない → 警告して続行（テンプレートなしでPR作成）
  - 存在する → 読み込んでPR本文生成に使用
2. **未コミット確認**: `git status`
  - 未コミットファイルあり → 警告して終了
  - コミット済み → 次へ
3. **未push確認**: `git status`
  - 未push → 自動push実行
  - push済み → 次へ
4. **コンフリクト確認**: `git fetch origin staging && git merge-base --is-ancestor origin/staging HEAD`
  - コンフリクトあり → 警告して終了
  - なし → 次へ
5. **差分確認**: `git diff origin/staging...HEAD`
  - 差分なし → 作成不要で終了
  - 差分あり → PR作成へ

### 情報収集

- **ブランチ名**: `git branch --show-current`
- **コミット履歴**: `git log origin/staging..HEAD`
- **差分**: `git diff origin/staging...HEAD --stat` と詳細diff
- **関連 Issue**:
  - Issue番号提供あり → `gh issue view <number>` でタイトル・本文を取得
  - Issue番号提供なし → 「関連する Issue 番号はありますか？」と確認
  - なし → Issue リンクなしで続行
  - **重要**: `closes` キーワードは使わないこと。単純参照 `#123` でタスクセクションに記載する。PRマージ時の Project ステータス更新は GitHub Actions (`project-status.yml`) が自動で行う

### PRタイトル生成

以下の情報を統合して簡潔なタイトルを生成:

- ブランチ名の意図（feature/fix/refactor/docs）
- 主要なコミットメッセージ
- 変更ファイルの領域
- 関連 Issue のタイトル（あれば）

例:

- `feature/add-create-tasks-command` + "create-tasksコマンドの追加" → "create-tasksコマンドの追加"
- `fix/api-error` + "APIエラーハンドリング修正" → "APIエラーハンドリングの修正"

### PR説明文生成

`.github/pull_request_template.md` を読み込み、そのセクション構造に沿って生成する。

現在のテンプレート構造:

```markdown
## タスク

- #<issue-number>

## やりたいこと

[コミットとdiffから目的を簡潔に記述]

## やったこと

[変更内容を箇条書きで記述]

## やらなかったこと

[スコープ外とした内容があれば記述]

## 確認方法

[動作確認手順があれば記述]

## キャプチャ

| Before          | After          |
| --------------- | -------------- |
| <!-- Before --> | <!-- After --> |

## マージ後にやること

[マイグレーション等、マージ後に必要な作業があれば記述]

# その他

[レビュー時の注意点、懸念事項があれば記述]
```

**重要**: テンプレートが更新された場合は、実際のファイル内容に従うこと。上記は参考用。

## 例

### 基本的な使用

```
/cc:pull-request
# 現在のブランチからstagingへPRを作成
# 関連 Issue を確認
# 自動でタイトルと説明文を生成
```

### Issue番号付き

```
/cc:pull-request 123
# gh issue view 123 で Issue 情報を取得
# Issue タイトルをPRタイトルに反映
# 背景・関連リンクに #123 を記載
```

## エラー処理

### 未コミットコードがある

```
⚠️ 未コミットの変更があります

以下のファイルをコミットしてください:
- application/src/app/api/route.ts
- application/src/components/Button.tsx

コミット後に再度実行してください。
```

### 差分がない

```
ℹ️ stagingブランチとの差分がありません

PRを作成する必要はありません。
```

### コンフリクトがある

```
⚠️ stagingブランチとコンフリクトがあります

以下のコマンドでコンフリクトを解決してください:

git fetch origin staging
git merge origin/staging

解決後に再度実行してください。
```

### 同名PRが存在

```
⚠️ 同名のPRが既に存在します

タイトルを変更して作成します:
元: "create-tasksコマンドの追加"
新: "create-tasksコマンドの追加 (2)"
```

## 境界

**実施すること:**

- PRテンプレートの確認と読み込み
- 未コミット・未push・コンフリクト・差分の確認
- あらゆる情報源からの簡潔なタイトル生成
- コミット+diff分析による詳細な説明文生成
- GitHub Issue との連携（関連 Issue のリンク）
- 自動pushとPR作成

**実施しないこと:**

- 未コミットコードの自動コミット（ユーザーに委ねる）
- コンフリクトの自動解決（手動解決を促す）
- レビュアーやラベルの自動アサイン
- PR作成後の追加アクション（マージ等）
