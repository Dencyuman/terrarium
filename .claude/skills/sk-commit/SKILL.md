---
name: sk-commit
description: "変更を分析して適切なコミットメッセージを生成し、コミットを作成"
argument-hint: "[ja|en] [single]"
disable-model-invocation: true
allowed-tools:
  - Bash
  - Read
  - Edit
---

# Commit - スマートコミット作成

## 使用方法

```
/sk-commit           # 日本語でコミット（デフォルト）
/sk-commit en        # 英語でコミット
/sk-commit single    # 全変更を1コミットにまとめる
/sk-commit en single # 英語 + 1コミット
```

ARGUMENTS: $ARGUMENTS

## 動作フロー

1. **分析**: `git status` と `git diff` で変更を確認
2. **分類**: 変更を責務・意味ごとにグループ化
3. **生成**: 各グループに対して簡潔なコミットメッセージを生成
4. **確認**: ユーザーに提案内容を提示
5. **実行**: 承認後、`git add` と `git commit` を順次実行
6. **完了**: タスクとして読み込んでいるドキュメントがあれば更新を行う

主要な動作:

- 変更内容の自動分析と責務による分類
- Backend/Frontend/Infrastructure/Docsなど領域ごとのグループ化
- 簡潔で意味のあるコミットメッセージ生成
- 多すぎる場合は関連変更をまとめて最適化

## ツール連携

- **Bash**: git status, git diff, git add, git commit の実行
- **Read**: 変更ファイルの内容確認（必要に応じて）

## 主要パターン

- **変更分析**: git diff → 責務ごとの変更分類
- **メッセージ生成**: 変更内容 → 簡潔な説明
- **分割判断**: 変更の性質 → 1つまたは複数のコミット
- **実行**: ユーザー承認 → git add + git commit

## コミットメッセージ形式

### 日本語（デフォルト）

```
変更の概要を1行で簡潔に

詳細な変更内容（必要に応じて）:
- 変更点1
- 変更点2
```

### 英語（--lang en）

```
Brief summary of changes in one line

Detailed changes (if needed):
- Change 1
- Change 2
```

## 分割の基準

以下の基準で変更をグループ化:

- **領域**: Backend / Frontend / Infrastructure / Docs
- **責務**: Feature / Fix / Refactor / Test / Docs
- **関連性**: 相互に依存する変更は同じコミット

多すぎる場合（5コミット以上）は関連変更をまとめて最適化。

## 境界

**実施すること:**

- 変更内容を分析して適切なコミットメッセージを生成
- 責務・意味ごとに変更を分割して複数コミット作成
- ユーザーに提案内容を提示して承認を得る

**実施しないこと:**

- ユーザーの承認なしでコミットを実行
- .env や credentials.json などシークレットファイルをコミット
- 既存コミットの修正（amend）や履歴の書き換え
