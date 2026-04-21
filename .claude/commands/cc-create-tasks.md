---

name: create-tasks

description: "GitHub Issue を作成し、GitHub Project に適切なフィールド付きで追加する"

argument-hint: "[タスク概要]"

category: git

complexity: standard

mcp-servers: []

personas: []

---

# /cc:create-tasks - GitHub Issue & Project タスク作成

## トリガー

- 新しいタスク・機能要望・バグ報告を Issue として起票したい
- GitHub Project (DataBuddy #5) にフィールド付きで追加したい

## 使用方法

```
/cc:create-tasks [タスク概要]
```

引数:

- `タスク概要`: 作成したいタスクの簡単な説明（任意、省略時は対話で聞く）

## 動作フロー

1. **ヒアリング**: タスクの概要をユーザーから聞く（引数で渡された場合はスキップ）
2. **コード調査**: 関連するソースコードを Glob / Grep / Read で調査し、現状の実装を把握する
3. **テンプレート選定 & 下書き生成**: 内容に基づきテンプレート・タイトル・フィールドを決定し、Issue 本文を生成する
4. **ユーザー確認**: 生成した内容を提示し、修正依頼があれば反映して再提示する
5. **Issue 作成**: 承認後、`gh issue create` で Issue を作成する
6. **Project 追加 & フィールド設定**: `gh project item-add` → `gh project item-edit` でフィールドを設定する
7. **完了報告**: Issue URL と設定したフィールドを表示する

---

## ステップ詳細

### 1. ヒアリング

引数が空の場合、ユーザーに以下を質問する:

- 「どんなタスクを作りたいですか？概要を教えてください」

回答から以下を判断する:

- タスクの種類（実装タスク / 機能要望 / バグ報告）
- 関連しそうなコード領域

### 2. コード調査

ユーザーの説明から関連するソースコードを特定し、調査する:

- **Glob**: 関連ファイルの探索
- **Grep**: キーワードでのコード検索
- **Read**: 主要ファイルの内容確認

調査結果から以下を把握する:

- 現状の実装状況
- 関連ファイルのパス一覧
- 影響範囲の推定

### 3. テンプレート選定 & 下書き生成

#### テンプレート読み込み

**実行時に必ず `.github/ISSUE_TEMPLATE/` 配下のテンプレートファイルを Read で読み込むこと。**
テンプレートの追加・削除・変更に追従するため、ベタ書きせずファイルから都度取得する。

```
# テンプレート所在
.github/ISSUE_TEMPLATE/task.yml        → 🔧 タスク
.github/ISSUE_TEMPLATE/feature_request.yml → ✨ 機能要望
.github/ISSUE_TEMPLATE/bug_report.yml  → 🐛 バグ報告
```

手順:

1. `Glob` で `.github/ISSUE_TEMPLATE/*.yml` を検索し、存在するテンプレート一覧を取得する
2. ユーザーの説明内容に最も適合するテンプレートを選定する
3. 選定したテンプレートファイルを `Read` で読み込む
4. テンプレートの `body` セクション（各 `textarea` / `input` / `dropdown` の `label` と `description`）を解析し、各フィールドに沿った Issue 本文を生成する

#### テンプレート選定基準

| 種類 | テンプレートファイル | タイトルプレフィックス | 自動ラベル |
|---|---|---|---|
| 実装・調査タスク | `task.yml` | `[Task] ` | テンプレートの `labels` に従う |
| 新機能・改善提案 | `feature_request.yml` | `[Feature] ` | テンプレートの `labels` に従う |
| バグ・不具合 | `bug_report.yml` | `[Bug] ` | テンプレートの `labels` に従う |

**注意**: テンプレートファイルに `labels` キーが定義されていればそれを使う。定義されていなければラベルなし。
テンプレートが上記3種以外に増えている場合も、ファイルの `name` / `description` / `title` を読み取って適切に対応すること。

#### GitHub Project フィールド

以下のフィールドを内容から推定し、提案する:

| フィールド | 選択肢 | 判断基準 |
|---|---|---|
| **Status** | `バックログ` (デフォルト) / `進行中` | 即着手するなら進行中 |
| **優先度** | `優先度高` / `優先度中` / `優先度低` | 影響範囲・緊急度から判断 |
| **Size** | `XS` / `S` / `M` / `L` / `XL` | 変更ファイル数・複雑度から推定 |
| **カテゴリ** | `リファクタリング` / `CI/CD` / `リリース` / `クラウド` / `バグ修正` / `開発` / `ドキュメント` / `オンプレ` / `調査` | タスクの作業領域から判断 |

Size の目安:

- **XS**: 1-2 ファイル、単純な修正
- **S**: 3-5 ファイル、小規模な実装
- **M**: 5-10 ファイル、中規模な実装
- **L**: 10+ ファイル、大規模な実装
- **XL**: アーキテクチャ変更を伴う大規模実装

### 4. ユーザー確認

以下の形式で提示する:

```
## Issue プレビュー

**テンプレート**: 🔧 タスク / ✨ 機能要望 / 🐛 バグ報告
**タイトル**: [Task] 〇〇する
**ラベル**: enhancement
**Project フィールド**:
  - Status: バックログ
  - 優先度: 優先度中
  - Size: M
  - カテゴリ: 開発

---

[Issue 本文]

---

この内容で Issue を作成してよいですか？修正があれば指示してください。
```

修正依頼があった場合:

- 指摘箇所を修正して再度プレビューを提示する
- 承認されるまで繰り返す

### 5. Issue 作成

承認後、以下のコマンドで Issue を作成する:

```bash
gh issue create \
  --repo dencyuinc/databuddy \
  --title "[Task] 〇〇する" \
  --body "$(cat <<'EOF'
Issue本文
EOF
)" \
  --label "enhancement"
```

ラベルの付与:

- 🔧 タスク: ラベルなし（内容に応じて任意で付与）
- ✨ 機能要望: `enhancement`
- 🐛 バグ報告: `bug`

### 6. Project 追加 & フィールド設定

```bash
# Issue を Project に追加し、アイテムIDを取得
ITEM_ID=$(gh project item-add 5 --owner dencyuinc --url <issue-url> --format json | jq -r '.id')

# フィールドを設定
# Status
gh project item-edit --project-id PVT_kwDOCeq0Ac4BGdf6 --id $ITEM_ID \
  --field-id PVTSSF_lADOCeq0Ac4BGdf6zg3gBHw --single-select-option-id <option-id>

# 優先度
gh project item-edit --project-id PVT_kwDOCeq0Ac4BGdf6 --id $ITEM_ID \
  --field-id PVTSSF_lADOCeq0Ac4BGdf6zg3gBLc --single-select-option-id <option-id>

# Size
gh project item-edit --project-id PVT_kwDOCeq0Ac4BGdf6 --id $ITEM_ID \
  --field-id PVTSSF_lADOCeq0Ac4BGdf6zg3gBLg --single-select-option-id <option-id>

# カテゴリ
gh project item-edit --project-id PVT_kwDOCeq0Ac4BGdf6 --id $ITEM_ID \
  --field-id PVTSSF_lADOCeq0Ac4BGdf6zg_3c5o --single-select-option-id <option-id>
```

#### フィールド ID 参照テーブル

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

### 7. 完了報告

```
✅ Issue を作成し、Project に追加しました

- Issue: <issue-url>
- Status: バックログ
- 優先度: 優先度中
- Size: M
- カテゴリ: 開発
```

## ツール連携

- **Bash**: gh issue create, gh project item-add, gh project item-edit
- **Glob**: 関連ファイルの探索
- **Grep**: キーワードでのコード検索
- **Read**: ソースコードの内容確認

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
