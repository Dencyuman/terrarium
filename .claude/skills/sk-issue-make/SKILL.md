---
name: sk-issue-make
description: "GitHub Issue を作成し、GitHub Project に適切なフィールド付きで追加する"
argument-hint: "[タスク概要]"
disable-model-invocation: true
allowed-tools:
  - Bash
  - Glob
  - Grep
  - Read
---

# Issue Make - GitHub Issue & Project タスク作成

## 使用方法

```
/sk-issue-make [タスク概要]
```

引数:

- `タスク概要`: 作成したいタスクの簡単な説明（任意、省略時は対話で聞く）

ARGUMENTS: $ARGUMENTS

## 動作フロー

1. **ヒアリング**: タスクの概要をユーザーから聞く（引数で渡された場合はスキップ）
2. **コード調査**: 関連するソースコードを Glob / Grep / Read で調査し、現状の実装を把握する
3. **テンプレート選定 & 下書き生成**: 内容に基づきテンプレート・タイトル・フィールドを決定し、Issue 本文を生成する
4. **ユーザー確認**: 生成した内容を提示し、修正依頼があれば反映して再提示する
5. **Issue 作成**: 承認後、`gh issue create` で Issue を作成する
6. **Project 追加 & フィールド設定**: `gh project item-add` → `gh project item-edit` でフィールドを設定する
7. **完了報告**: Issue URL と設定したフィールドを表示する

## テンプレート選定

**実行時に必ず `.github/ISSUE_TEMPLATE/` 配下のテンプレートファイルを Read で読み込むこと。**

```
.github/ISSUE_TEMPLATE/task.yml        → タスク
.github/ISSUE_TEMPLATE/feature_request.yml → 機能要望
.github/ISSUE_TEMPLATE/bug_report.yml  → バグ報告
```

手順:

1. `Glob` で `.github/ISSUE_TEMPLATE/*.yml` を検索し、存在するテンプレート一覧を取得する
2. ユーザーの説明内容に最も適合するテンプレートを選定する
3. 選定したテンプレートファイルを `Read` で読み込む
4. テンプレートの `body` セクションを解析し、各フィールドに沿った Issue 本文を生成する

## GitHub Project フィールド

以下のフィールドを内容から推定し、提案する:

| フィールド | 選択肢 | 判断基準 |
|---|---|---|
| **Status** | `バックログ` (デフォルト) / `進行中` | 即着手するなら進行中 |
| **優先度** | `優先度高` / `優先度中` / `優先度低` | 影響範囲・緊急度から判断 |
| **Size** | `XS` / `S` / `M` / `L` / `XL` | 変更ファイル数・複雑度から推定 |
| **カテゴリ** | `リファクタリング` / `CI/CD` / `リリース` / `クラウド` / `バグ修正` / `開発` / `ドキュメント` / `オンプレ` / `調査` | タスクの作業領域から判断 |

## フィールド ID 参照テーブル

**Status** (field: `PVTSSF_lADOCeq0Ac4BGdf6zg3gBHw`):

| 値 | option-id |
|---|---|
| バックログ | `f75ad846` |
| 進行中 | `47fc9ee4` |
| レビュー中 | `7c896ec0` |
| staging | `79cc33b9` |
| staging検証完了 | `0297407d` |
| リリース済み | `98236657` |

**優先度** (field: `PVTSSF_lADOCeq0Ac4BGdf6zg3gBLc`):

| 値 | option-id |
|---|---|
| 優先度高 | `79628723` |
| 優先度中 | `0a877460` |
| 優先度低 | `da944a9c` |

**Size** (field: `PVTSSF_lADOCeq0Ac4BGdf6zg3gBLg`):

| 値 | option-id |
|---|---|
| XS | `6c6483d2` |
| S | `f784b110` |
| M | `7515a9f1` |
| L | `817d0097` |
| XL | `db339eb2` |

**カテゴリ** (field: `PVTSSF_lADOCeq0Ac4BGdf6zg_3c5o`):

| 値 | option-id |
|---|---|
| リファクタリング | `139e7b29` |
| CI/CD | `1e6153ae` |
| リリース | `8e1f7bd2` |
| クラウド | `d9443a94` |
| バグ修正 | `bc145d5a` |
| 開発 | `ec388842` |
| ドキュメント | `234733bb` |
| オンプレ | `f31cd16e` |
| 調査 | `f8f6126e` |

## 境界

**実施すること:**

- ユーザーの説明に基づく適切なテンプレート選定
- 関連ソースコードの調査と Issue 本文への反映
- Project フィールド（Status / 優先度 / Size / カテゴリ）の推定と設定
- ユーザー承認を得てからの Issue 作成

**実施しないこと:**

- ユーザーの承認なしで Issue を作成
- Assignee の自動設定（ユーザーが明示的に指定した場合のみ）
- Issue 作成後のブランチ作成や実装着手
- 既存 Issue の編集や削除
