# PostgreSQL データ移行（11.2 → 15）

------------------------------

## 1. ドキュメント情報

| 項目 | 内容 |
|------|------|
| 手順書名 | PostgreSQL データ移行（11.2 → 15） |
| 作成日 | 2026-06-19 |
| 最終更新日 | 2026-06-20 |
| バージョン | v1.1 |
| 対象環境 | AWS（Amazon Linux 2023） |

> **改訂履歴**
>
> | バージョン | 日付 | 変更内容 |
> |-----------|------|---------|
> | v1.0 | 2026-06-19 | 初版作成（元`DB_構築手順書.md`のフェーズ1〜6を基にテンプレートに沿って再構成．フェーズ0（PostgreSQL本体構築）は別手順書`postgresql-server.md`に分離．構成図追加．プレースホルダーを意味ベース日本語に統一．`pg_hba.conf`への接続許可エントリ追加Stepを明示的に追加．句読点を「，．」に統一．サーバー表記を「サーバー」に統一．付録A〜D追加．） |
> | v1.1 | 2026-06-20 | `postgresql-server.md` の改訂（標準パス `/var/lib/pgsql/data` への統一）に追従．`<データディレクトリパス>` `<マウントポイント>` プレースホルダー参照を実パス（`/var/lib/pgsql/data` / `/`）に置換．本演習ではEBS拡張を行わない方針のため，付録D-5（EBSオンライン拡張の概要）を削除．付録D-4のディスク監視コマンドをルートボリューム監視に変更． |

------------------------------

## 2. 目的・概要

### 2-1. 目的

> 本手順書では，旧PostgreSQL 11.2上のデータベース（`<移行元DB名>`）を，新PostgreSQL 15へ論理移行（`pg_dump` / `pg_restore`）する手順について説明する．
> ロール定義は `pg_dumpall --roles-only`，データ本体は `pg_dump -Fc`（カスタム形式）でダンプし，新環境で `pg_restore` によりリストアする．投入順序は「ロール → データベース → データ → 権限付与」とする．
> 本手順書は **計画停止** を前提とする．
>
> **本手順書の前提：** 新PostgreSQL 15サーバーが既に起動している（`postgresql-server.md` 完了）．
> **本手順書の範囲外：** 新PostgreSQL本体の構築（`postgresql-server.md`を参照），アプリケーションの接続先切替（`war-deploy-migration.md`を参照）．

### 2-2. 構成概要（アーキテクチャ）

```
┌────────── 旧VPC（または同一VPC） ──────────────┐
│  [EC2: 移行元DBサーバー]                       │
│    └─ PostgreSQL 11.2                         │
│         └─ <移行元DB名>                        │
│              └─ <移行元ロール>                 │
│  実行コマンド：                                │
│   pg_dumpall --roles-only → roles.sql         │
│   pg_dump -Fc <移行元DB名> → <DB名>.dump       │
└─────────┬─────────────────────────────────────┘
          │  scp(踏み台経由)
          ▼
┌────────── 踏み台サーバー ──────────────────────┐
│  /tmp/pg_migrate_stage/                       │
│     ├─ roles.sql                              │
│     └─ <DB名>.dump                            │
└─────────┬─────────────────────────────────────┘
          │  scp
          ▼
┌────────── 新VPC ──────────────────────────────┐
│  [EC2: 新DBサーバー]                           │
│    └─ PostgreSQL 15（postgresql-server.md完了）│
│         実行コマンド：                         │
│         1. psql -f roles.sql （ロール作成）    │
│         2. createdb <移行先DB名>               │
│         3. pg_hba.conf エントリ追加            │
│         4. pg_restore （データ投入）           │
│         5. 権限付与（USAGE/CREATE/SELECT等）   │
│         6. 所有者を <移行先ロール> に変更       │
└───────────────────────────────────────────────┘
```

### 2-3. 完成イメージ（ゴール定義）

- [ ] 新DBサーバーに `<移行先DB名>` が作成されている
- [ ] 新DBサーバーに `<移行先ロール>` が作成されている
- [ ] `pg_hba.conf` にアプリケーションサーバーからの接続許可エントリが追加されている
- [ ] 全テーブルのデータが移行され，主要テーブルの件数が移行元と一致している
- [ ] 全テーブル・シーケンスの所有者が `<移行先ロール>` になっている
- [ ] `<移行先ロール>` で接続して `SELECT` ／ `INSERT` ／ `UPDATE` ／ `DELETE` が可能
- [ ] `\l+ <移行先DB名>` でロケールが `<ロケール>`（`en_US.utf8`）になっている

------------------------------

## 3. 前提条件・準備

### 3-1. 環境要件

| 項目 | 要件 |
|------|------|
| 移行元 | PostgreSQL 11.2 |
| 移行先 | PostgreSQL 15（`postgresql-server.md`で構築済み） |
| 移行元・移行先のネットワーク | 踏み台サーバーから両方へSSH到達可能 |
| 計画停止 | アプリケーションは停止状態で実施 |
| ロケール | 移行元・移行先で `en_US.utf8` |
| 想定停止時間 | データ量に応じて30分〜数時間 |

### 3-2. セキュリティグループ設定

#### 3-2-1. 移行元DBサーバーのインバウンドルール

| タイプ | プロトコル | ポート | ソース | 説明 |
|-------|------------|-------|--------|------|
| SSH | TCP | 22 | 踏み台サーバーのSG | ダンプファイル取得用 |

#### 3-2-2. 新DBサーバーのインバウンドルール

| タイプ | プロトコル | ポート | ソース | 説明 |
|-------|------------|-------|--------|------|
| SSH | TCP | 22 | 踏み台サーバーのSG | ダンプファイル配置用 |
| カスタムTCP | TCP | 5432 | アプリサーバーのSG | 移行後のアプリ接続用 |

### 3-3. パラメータ定義表

> **注意：** 以下の値は作業前に環境に合わせて記入してから作業を開始すること．
> **重要：** **本手順書に実際のパスワードを直接記載しないこと**．パスワードはパスワード管理ツール経由で取り扱うこと．

#### 共通

| パラメータ名 | 値 | 説明 |
|------------|---|------|
| `<移行元DBサーバーのIP>` | `<記入する>` | 旧PostgreSQL 11.2サーバーのIP |
| `<新DBサーバーのIP>` | `<記入する>` | 新PostgreSQL 15サーバーのIP |
| `<踏み台サーバーのIP>` | `<記入する>` | 踏み台のIP（中継用） |
| `<SSH鍵パス>` | `<記入する>` | 踏み台用のSSH鍵パス（例：`~/.ssh/<KEY>.pem`） |
| `<移行元psqlパス>` | `/usr/local/postgresql-11.2/bin/psql` | 移行元のpsqlフルパス |
| `<移行元pg_dumpパス>` | `/usr/local/postgresql-11.2/bin/pg_dump` | 移行元のpg_dumpフルパス |
| `<移行元pg_dumpallパス>` | `/usr/local/postgresql-11.2/bin/pg_dumpall` | 移行元のpg_dumpallフルパス |
| `<移行元DB名>` | `<記入する>` | 移行元のDB名（例：`dash_replace`） |
| `<移行先DB名>` | `<記入する>` | 移行先のDB名（移行元と同名推奨） |
| `<移行先ロール>` | `<記入する>` | アプリケーションが使用するロール（例：`hr_dash_user`） |
| `<移行先ロールのパスワード>` | パスワード管理ツール参照 | （本書には記載しない） |
| `<ロケール>` | `en_US.utf8` | DB初期化時のロケール（移行元と同じに揃える） |
| `<文字セット>` | `UTF8` | エンコーディング |
| `<アプリサーバーのIP>` | `<記入する>` | 移行後にDBへ接続するアプリサーバーIP |
| `<件数チェック対象テーブル>` | `articles` | 整合性チェックのために件数比較するテーブル |

#### ロールバック用（任意）

| パラメータ名 | 値 | 説明 |
|------------|---|------|
| `<作業前AMI名>` | `<記入する>` | 作業前スナップショット名 |

### 3-4. リンク一覧

| 項目名 | 目的 |
|-------|------|
| https://www.postgresql.org/docs/15/backup-dump.html | pg_dump公式ドキュメント |
| https://www.postgresql.org/docs/15/app-pgrestore.html | pg_restore公式ドキュメント |
| https://www.postgresql.org/docs/15/auth-pg-hba-conf.html | pg_hba.conf仕様 |
| 別手順書：PostgreSQL構築 | `postgresql-server.md` |
| 別手順書：アプリ移行 | `war-deploy-migration.md` |

### 3-5. 事前確認

#### 3-5-1. 移行元・移行先の起動確認【実施対象：両サーバー】

```bash
# 移行元
ssh -i <SSH鍵パス> ec2-user@<移行元DBサーバーのIP> "sudo systemctl is-active postgresql"

# 移行先
ssh -i <SSH鍵パス> ec2-user@<新DBサーバーのIP> "sudo systemctl is-active postgresql-15"
```

> **期待する結果：** どちらも `active`．

#### 3-5-2. 計画停止の確認

- [ ] アプリケーション側で計画停止が周知されている
- [ ] アプリケーション（Tomcat等）が停止されている
- [ ] 移行作業中の問い合わせ窓口が設置されている

#### 3-5-3. 新DBサーバーの空状態確認【実施対象：新DBサーバー】

```bash
sudo su -
cd /tmp
sudo -u postgres /usr/bin/psql -l | grep <移行先DB名>
```

> **期待する結果：** `<移行先DB名>` が存在しない（空状態）．存在する場合は事前に削除するか，本手順書を実施しない．

#### 3-5-4. 作業前スナップショット取得【実施対象：AWSコンソール】

新DBサーバーのAMIを取得（万一の切戻し用）．

```
AWS コンソール → EC2 → 新DBサーバーを選択
→ アクション → イメージとテンプレート → イメージを作成
→ イメージ名： postgresql-migration-before-<日付>
```

------------------------------

## 4. 構築手順（詳細）

> **注意事項**
> - コマンド中の `<山カッコ>` は自分の環境の値に置き換えること
> - 各Stepの見出し末尾に **【実施対象：●●】** を明示
> - **必ず以下の順序で実施すること**：移行元ダンプ → 転送 → ロール作成 → DB作成 → pg_hba.conf → リストア → 権限付与 → 整合性チェック
> - 計画停止中の作業のため，途中で中断しないこと

------------------------------

## 4-A. 移行元でダンプ取得

------------------------------

### Step 1：DB一覧の確認【実施対象：移行元DBサーバー】

```bash
sudo su -
cd /tmp
sudo -u postgres <移行元psqlパス> -l
```

> **期待する結果：** `<移行元DB名>` がUTF8 / en_US.UTF-8 で存在する．

------------------------------

### Step 2：ロール定義のダンプ【実施対象：移行元DBサーバー】

```bash
sudo -u postgres <移行元pg_dumpallパス> --roles-only -f /tmp/roles.sql
ls -lh /tmp/roles.sql
```

> **期待する結果：** `roles.sql` が作成され，中身に `CREATE ROLE <移行元ロール>` が含まれる．

> **補足：** `--roles-only` でロール定義のみダンプ．データやスキーマは含まれない．

------------------------------

### Step 3：データ本体のダンプ（カスタム形式・圧縮込み）【実施対象：移行元DBサーバー】

```bash
sudo -u postgres <移行元pg_dumpパス> -Fc <移行元DB名> -f /tmp/<移行元DB名>.dump
ls -lh /tmp/<移行元DB名>.dump
```

> **期待する結果：** ダンプファイルが作成される．

> **補足：** `-Fc`（カスタム形式）はダンプと同時に圧縮するため別途gzip不要．`pg_restore` で柔軟にリストアできる．

------------------------------

### Step 4：移行元の件数を記録【実施対象：移行元DBサーバー】

整合性チェック用に，主要テーブルの件数を記録する．

```bash
sudo -u postgres <移行元psqlパス> -d <移行元DB名> -c "SELECT count(*) FROM <件数チェック対象テーブル>;"
```

> **重要：** 出力された件数を控えておく．Step 14で新DBと突き合わせる．

------------------------------

## 4-B. ファイル転送（踏み台経由）

------------------------------

### Step 5：移行元 → 踏み台への取得【実施対象：踏み台サーバー】

```bash
# 踏み台でステージング用ディレクトリ作成
mkdir -p /tmp/pg_migrate_stage

# 移行元から取得
scp -i <SSH鍵パス> \
  ec2-user@<移行元DBサーバーのIP>:/tmp/roles.sql \
  ec2-user@<移行元DBサーバーのIP>:/tmp/<移行元DB名>.dump \
  /tmp/pg_migrate_stage/

ls -lh /tmp/pg_migrate_stage/
```

> **期待する結果：** `roles.sql` と `<移行元DB名>.dump` が踏み台に存在．

------------------------------

### Step 6：踏み台 → 新DBサーバーへの送信【実施対象：踏み台サーバー】

```bash
scp -i <SSH鍵パス> \
  /tmp/pg_migrate_stage/roles.sql \
  /tmp/pg_migrate_stage/<移行元DB名>.dump \
  ec2-user@<新DBサーバーのIP>:/tmp/
```

------------------------------

## 4-C. 新DBサーバーでリストア

------------------------------

### Step 7：ファイル権限の付与【実施対象：新DBサーバー】

転送したファイルを postgres ユーザーが読めるようにする．

```bash
sudo chmod 644 /tmp/roles.sql /tmp/<移行元DB名>.dump
ls -l /tmp/roles.sql /tmp/<移行元DB名>.dump
```

------------------------------

### Step 8：ロールの作成【実施対象：新DBサーバー】

データ投入より先にロールを作成する．

```bash
sudo su -
cd /tmp
sudo -u postgres /usr/bin/psql -f /tmp/roles.sql
```

> **期待する結果：** `CREATE ROLE` が出力される．既存ロール（`postgres` 等）に対する「already exists」エラーは無害．

#### 確認

```bash
sudo -u postgres /usr/bin/psql -c "\du <移行先ロール>"
```

------------------------------

### Step 9：データベースの作成【実施対象：新DBサーバー】

ロケールを移行元と揃えるため `-T template0` を必須指定する．

```bash
sudo -u postgres createdb -O postgres -E <文字セット> --locale=<ロケール> -T template0 <移行先DB名>
```

#### 確認

```bash
sudo -u postgres /usr/bin/psql -l | grep <移行先DB名>
```

> **期待する結果：** `<移行先DB名>` が `UTF8 / en_US.utf8` で表示される．

------------------------------

### Step 10：pg_hba.conf にアプリサーバーからの接続許可エントリ追加【実施対象：新DBサーバー】

**目的：** 移行先DBへアプリサーバーから接続できるようにする

#### 操作手順

```bash
# pg_hba.conf のパスを取得
PG_HBA=$(sudo -u postgres /usr/bin/psql -tAc "SHOW hba_file;" | tr -d ' ')
echo "${PG_HBA}"

# バックアップ作成
cp "${PG_HBA}" "${PG_HBA}.bak.$(date +%Y%m%d%H%M%S)"

# エントリ追加用に編集
vi "${PG_HBA}"
```

設定ファイルの追記内容（ファイル末尾に追記）：

```
# Application Server からの接続許可（PostgreSQL 14以降推奨：scram-sha-256）
host    <移行先DB名>    <移行先ロール>    <アプリサーバーのIP>/32    scram-sha-256
```

#### 設定反映

```bash
sudo -u postgres /usr/bin/psql -c "SELECT pg_reload_conf();"
```

> **期待する結果：** `pg_reload_conf` 列に `t` が返る．

> **補足：** PostgreSQL 14以降のデフォルト認証は `scram-sha-256`．旧アプリケーションで `md5` が必要な場合は付録D-3を参照．

------------------------------

### Step 11：データのリストア【実施対象：新DBサーバー】

```bash
sudo -u postgres pg_restore --no-owner -d <移行先DB名> /tmp/<移行元DB名>.dump
```

> **注意：**
>
> - データ量に応じて数分〜数十分かかる場合がある
> - 実行中に中断しないこと
> - 進捗確認は別ターミナルで `watch -n 5 'df -h /'` で使用量の増加を確認

> **補足：** `--no-owner` で実行ユーザー（`postgres`）を一時的に所有者にする．後続Step（Step 13）で所有者を `<移行先ロール>` に付け替える．

------------------------------

## 4-D. 権限付与と所有者付け替え

> **重要：** PostgreSQL 15以降，`public` スキーマへの CREATE 権限がデフォルトで付与されない．アプリケーションが起動時にテーブルを CREATE する場合，CREATE 権限が無いと起動に失敗する．**本フェーズはアプリケーション起動前に必ず実施する**．

------------------------------

### Step 12：DBへ接続して権限付与とデフォルト権限を設定【実施対象：新DBサーバー】

```bash
sudo -u postgres /usr/bin/psql -d <移行先DB名>
```

#### 12-1：publicスキーマへの USAGE / CREATE 権限を付与

```sql
GRANT USAGE  ON SCHEMA public TO <移行先ロール>;
GRANT CREATE ON SCHEMA public TO <移行先ロール>;
```

#### 12-2：既存テーブル・シーケンスへの権限付与

```sql
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES    IN SCHEMA public TO <移行先ロール>;
GRANT USAGE, SELECT, UPDATE          ON ALL SEQUENCES IN SCHEMA public TO <移行先ロール>;
```

#### 12-3：新規オブジェクトへのデフォルト権限を設定

以降に作成されるオブジェクトにも自動で権限が付くようにする．

```sql
ALTER DEFAULT PRIVILEGES IN SCHEMA public
  GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES    TO <移行先ロール>;
ALTER DEFAULT PRIVILEGES IN SCHEMA public
  GRANT USAGE, SELECT, UPDATE          ON SEQUENCES TO <移行先ロール>;
```

------------------------------

### Step 13：所有者を移行先ロールに付け替え【実施対象：新DBサーバー（psql内）】

#### 13-1：テーブルの所有者を変更

```sql
DO $$
DECLARE r RECORD;
BEGIN
  FOR r IN SELECT tablename FROM pg_tables WHERE schemaname = 'public'
  LOOP
    EXECUTE 'ALTER TABLE public.' || quote_ident(r.tablename) || ' OWNER TO <移行先ロール>';
  END LOOP;
END $$;
```

#### 13-2：シーケンスの所有者を変更

```sql
DO $$
DECLARE r RECORD;
BEGIN
  FOR r IN SELECT sequencename FROM pg_sequences WHERE schemaname = 'public'
  LOOP
    EXECUTE 'ALTER SEQUENCE public.' || quote_ident(r.sequencename) || ' OWNER TO <移行先ロール>';
  END LOOP;
END $$;
```

#### 13-3：所有者の確認

```sql
SELECT schemaname, tablename, tableowner
FROM pg_tables
WHERE schemaname = 'public'
ORDER BY tablename;
```

> **期待する結果：** 全テーブルの `tableowner` が `<移行先ロール>` になっている．

psqlを終了：

```sql
\q
```

------------------------------

## 5. 動作確認・検証

### 5-1. 確認チェックリスト

- [ ] **確認①**：テーブル数が移行元と一致
- [ ] **確認②**：主要テーブルの件数が移行元と完全一致
- [ ] **確認③**：全テーブルの所有者が `<移行先ロール>`
- [ ] **確認④**：DBロケールが移行元と一致（`en_US.utf8`）
- [ ] **確認⑤**：`<移行先ロール>` で接続できる

------------------------------

### Step 14：整合性チェック

#### 確認①：テーブル数

```bash
sudo -u postgres /usr/bin/psql -d <移行先DB名> -c \
  "SELECT count(*) FROM pg_tables WHERE schemaname='public';"
```

> **確認：** 移行元と同じ件数．

------------------------------

#### 確認②：件数比較

```bash
sudo -u postgres /usr/bin/psql -d <移行先DB名> -c \
  "SELECT count(*) FROM <件数チェック対象テーブル>;"
```

> **確認：** Step 4で記録した移行元の件数と一致．

------------------------------

#### 確認③：所有者確認

```bash
sudo -u postgres /usr/bin/psql -d <移行先DB名> -c \
  "SELECT count(*) FROM pg_tables WHERE schemaname='public' AND tableowner='<移行先ロール>';"
```

> **確認：** 上記Step 14-①と同じ件数（全テーブルが `<移行先ロール>` 所有）．

------------------------------

#### 確認④：DBサイズ・ロケール

```bash
sudo -u postgres /usr/bin/psql -c "\l+ <移行先DB名>"
```

> **確認：** ロケールが `en_US.utf8`．

------------------------------

#### 確認⑤：移行先ロールでの接続テスト

```bash
# アプリサーバー側で実行（または新DBサーバーから自分宛て）
echo "<新DBサーバーのIP>:5432:<移行先DB名>:<移行先ロール>:<移行先ロールのパスワード>" > ~/.pgpass
chmod 600 ~/.pgpass

psql -h <新DBサーバーのIP> -U <移行先ロール> -d <移行先DB名> -c "\dt"
```

> **期待する結果：** テーブル一覧が表示される．`Permission denied` 等のエラーが出ないこと．

------------------------------

## 6. トラブルシューティング

------------------------------

#### エラー①：`pg_restore: error: could not execute query ... permission denied`

**原因：** `<移行先ロール>` が無い，もしくは `--no-owner` 指定漏れ．

**対処法：** Step 8（ロール作成）が完了しているか確認．`pg_restore` のオプションに `--no-owner` が付いているか確認．

------------------------------

#### エラー②：`createdb: error: ... new collation ... does not match collation of template database`

**原因：** `-T template0` の指定漏れ．`template1` がカスタマイズされていてロケール不一致．

**対処法：** Step 9のコマンドに `-T template0` を含めて再実行．既に空のDBを作っていたら `dropdb <移行先DB名>` で削除してからやり直す．

------------------------------

#### エラー③：アプリ接続時に `FATAL: password authentication failed`

**原因：**

- パスワード不一致
- pg_hba.conf の `METHOD` がアプリ実装と不一致（`scram-sha-256` vs `md5`）

**対処法：**

```bash
# パスワード再設定
sudo -u postgres /usr/bin/psql -c "ALTER USER <移行先ロール> WITH PASSWORD '<移行先ロールのパスワード>';"

# pg_hba.conf 確認
PG_HBA=$(sudo -u postgres /usr/bin/psql -tAc "SHOW hba_file;" | tr -d ' ')
grep <移行先ロール> "${PG_HBA}"

# リロード
sudo -u postgres /usr/bin/psql -c "SELECT pg_reload_conf();"
```

アプリのJDBCドライバが古い場合は `scram-sha-256` 非対応の可能性．付録D-3を参照．

------------------------------

#### エラー④：件数が移行元と一致しない

**原因：**

- リストア中に中断された
- ダンプ取得時とリストア時の間に移行元データが更新された

**対処法：** 移行元アプリケーションが本当に停止されているか確認し，ダンプから取り直し．

------------------------------

#### エラー⑤：`permission denied for schema public`

**原因：** PostgreSQL 15以降のpublicスキーマ権限の厳格化（Step 12-1未実施）．

**対処法：** Step 12を再実施．

------------------------------

### ログの確認場所

| ログの種類 | 場所 |
|-----------|------|
| PostgreSQLログ | `/var/lib/pgsql/data/log/postgresql-*.log` |
| pg_dump／pg_restore ログ | 標準出力（リダイレクトで保存推奨） |
| systemdログ | `journalctl -u postgresql-15` |

------------------------------

## 7. 参考リソース・関連資料

| 資料名 | URL / 場所 | 補足 |
|-------|-----------|------|
| pg_dump 公式 | https://www.postgresql.org/docs/15/app-pgdump.html | ダンプ取得 |
| pg_restore 公式 | https://www.postgresql.org/docs/15/app-pgrestore.html | リストア |
| pg_dumpall 公式 | https://www.postgresql.org/docs/15/app-pg-dumpall.html | クラスタ全体／ロールダンプ |
| pg_hba.conf 仕様 | https://www.postgresql.org/docs/15/auth-pg-hba-conf.html | 認証ファイル |
| 別手順書：PostgreSQL本体構築 | `postgresql-server.md` | 本手順書の前提 |
| 別手順書：アプリ移行 | `war-deploy-migration.md` | 本手順書完了後 |

------------------------------

## 8. ロールバック手順

> **重要：** データ移行のロールバックは「新DB側を空に戻す」だけで，移行元には影響しない．移行元のサービス再開は，旧サーバーで業務継続するという判断になる．

### 8-1. ロールバック判定基準

以下の場合はロールバックを検討：

- リストア中に致命的エラーが発生し復旧不能
- 整合性チェック（Step 14）で大きな差異が発見された
- アプリ接続テスト（Step 14-⑤）が失敗し原因特定困難

### 8-2. 新DB側のクリーンアップ【実施対象：新DBサーバー】

```bash
sudo su -
cd /tmp

# 移行先DBを削除
sudo -u postgres /usr/bin/psql -c "DROP DATABASE IF EXISTS <移行先DB名>;"

# ロールを削除（他DBで使われていない場合）
sudo -u postgres /usr/bin/psql -c "DROP ROLE IF EXISTS <移行先ロール>;"
```

### 8-3. pg_hba.confの復元【実施対象：新DBサーバー】

```bash
# 最新のバックアップを確認
PG_HBA=$(sudo -u postgres /usr/bin/psql -tAc "SHOW hba_file;" | tr -d ' ')
ls -lt "${PG_HBA}.bak."* | head -1

# 復元
LATEST_BAK=$(ls -t "${PG_HBA}.bak."* | head -1)
cp -f "${LATEST_BAK}" "${PG_HBA}"

# リロード
sudo -u postgres /usr/bin/psql -c "SELECT pg_reload_conf();"
```

### 8-4. ダンプファイル・転送ファイルの削除（任意）【実施対象：新DBサーバー】

```bash
rm -f /tmp/roles.sql /tmp/<移行元DB名>.dump
```

### 8-5. 完全リカバリ：AMIスナップショットからの復元【実施対象：AWSコンソール】

```
AWS コンソール → EC2 → AMI → <作業前AMI名> を選択
→ 「AMIからインスタンスを起動」
```

### 8-6. 完了確認【実施対象：新DBサーバー】

```bash
sudo -u postgres /usr/bin/psql -l | grep <移行先DB名>
# → 表示されないこと

sudo -u postgres /usr/bin/psql -c "\du <移行先ロール>" 2>&1
# → ユーザーが存在しないメッセージ
```

------------------------------

## 付録

### A. コマンド解説

| コマンド | 説明 |
|---------|------|
| `pg_dumpall --roles-only -f <出力>` | クラスタのロール定義のみダンプ． |
| `pg_dump -Fc <DB名> -f <出力>` | カスタム形式（圧縮込み）でDBダンプ． |
| `pg_dump -Fp <DB名>` | プレーンSQL形式でDBダンプ． |
| `pg_restore --no-owner -d <DB名> <ダンプ>` | カスタム形式ダンプをリストア．`--no-owner` で実行ユーザーを所有者にする． |
| `pg_restore -l <ダンプ>` | ダンプ内容の一覧表示（リストア前確認）． |
| `createdb -O <所有者> -E UTF8 --locale=... -T template0 <DB名>` | ロケール指定でDB作成． |
| `dropdb <DB名>` | DB削除． |
| `psql -f <SQLファイル>` | SQLファイルを実行． |
| `psql -d <DB名> -c "<SQL>"` | 1つのSQLを実行． |
| `\du <ユーザー>` | psql内でユーザー情報表示． |
| `\l[+] [DB名]` | psql内でDB一覧表示（`+`で詳細）． |
| `\dt` | psql内でテーブル一覧表示． |
| `SHOW hba_file;` | psqlでpg_hba.confのパスを取得． |
| `SELECT pg_reload_conf();` | 設定ファイルをリロード（再起動なし）． |
| `ALTER DEFAULT PRIVILEGES IN SCHEMA <スキーマ> GRANT <権限> ON <種別> TO <ロール>` | 今後作成されるオブジェクトに自動で権限付与． |

------------------------------

### B. 設定ファイル解説

**`pg_hba.conf`（新DBサーバー）**

書式：

```
TYPE  DATABASE  USER  ADDRESS  METHOD
```

本手順書での追加：

```
host    <移行先DB名>    <移行先ロール>    <アプリサーバーのIP>/32    scram-sha-256
```

- `TYPE = host`：TCP/IP接続．
- `DATABASE = <移行先DB名>`：対象DB．`all` で全DB許可だが過剰．
- `USER = <移行先ロール>`：対象ロール．
- `ADDRESS = <アプリサーバーのIP>/32`：単一IPで最小権限．
- `METHOD = scram-sha-256`：PostgreSQL 14以降推奨．

> **補足：** `pg_hba.conf` のエントリ順序は重要．上から評価し，最初にマッチしたものが使われる．より厳格なエントリを上に置く．

**`~/.pgpass`（アプリサーバー側）**

書式：

```
hostname:port:database:username:password
```

- パーミッション `600` 必須．
- ホスト名・DB名は完全一致．

------------------------------

### C. 用語解説

| 用語 | 説明 |
|------|------|
| 論理移行 | SQL文ベースの移行（`pg_dump`／`pg_restore`）．バージョン差異を吸収できる． |
| 物理移行 | データファイル単位の移行（`pg_basebackup`など）．同一バージョン間で高速だがバージョン差異に弱い． |
| `pg_dump` | 1つのDBをダンプ．`-Fc`（カスタム）／`-Fp`（プレーン）／`-Ft`（tar）などの形式を選べる． |
| `pg_dumpall` | クラスタ全体（全DB＋ロール／表領域）をダンプ．`--roles-only`でロール定義のみ取得可能． |
| `pg_restore` | カスタム形式（`-Fc`）／tar形式（`-Ft`）のダンプをリストア．プレーン形式（`-Fp`）には `psql -f` を使う． |
| `--no-owner` | リストア時に所有者指定をスキップ．実行ユーザーが所有者になる．多用される． |
| `template0` | カスタマイズ不可のテンプレートDB．`CREATE DATABASE -T template0` でクリーンな雛形からDB作成できる． |
| ロール | PostgreSQLでのユーザー／グループの統一概念．`CREATE USER` は内部的にロール作成と同義． |
| `scram-sha-256` | PostgreSQL 10以降の強力なパスワード認証方式．PostgreSQL 14以降のデフォルト． |
| `ALTER DEFAULT PRIVILEGES` | 今後作成されるオブジェクトの所有者・権限を予め設定する仕組み． |
| `pg_reload_conf()` | 設定ファイルを再読み込み（再起動不要）．`postgresql.conf`／`pg_hba.conf`の変更に有効． |

------------------------------

### D. 補足解説

#### D-1. なぜ `pg_dumpall --roles-only` を先に流すか？

- `pg_restore` がデータをリストアする際，テーブル所有者などとしてロールが参照される．
- ロールが存在しない状態でリストアすると `role "..." does not exist` でエラーになる．
- そのため **「ロール作成 → DB作成 → データリストア」の順序が必須**．

#### D-2. `-Fc`（カスタム形式）を選ぶ理由

- ダンプ＋圧縮が一度で完了．
- `pg_restore` で柔軟に並列リストア・部分リストアが可能（`-j` オプション等）．
- ファイルサイズも小さい．
- プレーンSQL（`-Fp`）と比べて運用上のメリットが大きい．

#### D-3. md5 vs scram-sha-256（旧アプリ互換性）

- 移行元（PostgreSQL 11）が `md5` を使っていた場合，旧アプリのJDBCドライバ等が `md5` 認証のみ対応していることがある．
- その場合の選択肢：
  - **推奨**：アプリのドライバを更新（JDBCなら42.2.5以降で `scram-sha-256` 対応）
  - **暫定**：`postgresql.conf` で `password_encryption = md5` に戻し，pg_hba.conf の `METHOD` も `md5` にする（セキュリティレベルは下がる）
- 本手順書はデフォルト `scram-sha-256` だが，アプリの状況に応じて選択すること．

#### D-4. リストア時のディスク容量

- ダンプファイル（圧縮済み）の約2〜5倍のディスク容量がリストアに必要．
- リストア中はルートボリュームの空き容量を別ターミナルで監視：

  ```bash
  watch -n 5 "df -h /"
  ```

- 容量不足の場合，本演習ではEBS拡張を行わない方針のため，事前にルートボリュームを十分な容量（50GB以上推奨）で確保しておくこと．

#### D-5. アプリケーション接続切替の流れ

本手順書完了後，アプリケーション側で以下を実施：

1. `application.yml` 等で DB接続URL を新DBサーバーに変更
2. JDBCドライバを最新版に差し替え（必要なら）
3. Tomcat再起動

詳細は別手順書 `war-deploy-migration.md` を参照．

#### D-6. 整合性チェックの強化

主要テーブルだけでなく，全テーブルの件数比較を行う高度な検証：

```sql
-- 全テーブルの件数を取得（移行元と新DB双方で実行）
SELECT
  schemaname,
  tablename,
  (xpath('/row/cnt/text()', xml_count))[1]::text::int AS count
FROM (
  SELECT
    schemaname,
    tablename,
    query_to_xml(format('SELECT count(*) AS cnt FROM %I.%I', schemaname, tablename), false, true, '') AS xml_count
  FROM pg_tables
  WHERE schemaname = 'public'
) t
ORDER BY tablename;
```

両DBの結果をdiff比較することで，より厳密な整合性チェックが可能．

#### D-7. `dnf update` と `dnf upgrade` の違い

- DNFベースのAmazon Linux 2023では両者は同義．本手順書ではOSパッケージ更新は実施しない．
