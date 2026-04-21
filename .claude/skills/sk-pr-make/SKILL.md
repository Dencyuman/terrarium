---
name: sk-pr-make
description: "現在のブランチからstagingブランチへのプルリクエストを作成"
argument-hint: "[title] [issue-number]"
disable-model-invocation: true
allowed-tools:
  - Bash
  - Read
---

# PR Make - プルリクエスト作成

## 使用方法

```
/sk-pr-make [title] [issue-number]
```

引数:

- `title`: PRのタイトル（任意、指定しない場合は自動生成）
- `issue-number`: 関連する GitHub Issue 番号（任意、例: `123`）

ARGUMENTS: $ARGUMENTS

## タスク文脈の取得

PR作成前に、現在のブランチに紐づくタスクプランを確認する:

```bash
BRANCH=$(git branch --show-current)
grep -rl "branch: $BRANCH" tasks/*.md 2>/dev/null
```

該当するタスクファイルがあれば読み込み、Issue 番号やコンテキストを自動取得する。

## 動作フロー

1. **事前チェック**: PRテンプレート、未コミット、未push、コンフリクト、差分の確認
2. **情報収集**: ブランチ名、コミット履歴、diff、関連 Issue 情報を収集
3. **生成**: PRタイトルと説明文を自動生成
4. **確認**: 生成内容をユーザーに提示
5. **作成**: 承認後、gh pr create でPR作成
6. **出力**: PR URLを表示

## 事前チェック

1. **PRテンプレート確認**: `.github/pull_request_template.md`
2. **未コミット確認**: `git status` → あり → 警告して終了
3. **未push確認**: `git status` → 未push → 自動push実行
4. **コンフリクト確認**: `git fetch origin staging && git merge-base --is-ancestor origin/staging HEAD`
5. **差分確認**: `git diff origin/staging...HEAD` → なし → 作成不要で終了

## PR説明文生成

`.github/pull_request_template.md` を読み込み、そのセクション構造に沿って生成する。

**重要**:
- `closes` キーワードは使わないこと。単純参照 `#123` でタスクセクションに記載する
- PRマージ時の Project ステータス更新は GitHub Actions (`project-status.yml`) が自動で行う
- テンプレートが更新された場合は、実際のファイル内容に従うこと

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
