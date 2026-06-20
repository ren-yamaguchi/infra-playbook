# Zabbix用PostgreSQLデータベース構築

------------------------------

## 1. ドキュメント情報

| 項目 | 内容 |
|------|------|
| 手順書名 | Zabbix用PostgreSQLデータベース構築 |
| 作成日 | 2026-06-18 |
| 最終更新日 | 2026-06-18 |
| バージョン | v1.0 |
| 対象環境 | AWS（Amazon Linux 2023） |

> **改訂履歴**
>
> | バージョン | 日付 | 変更内容 |
> |-----------|------|---------|
> | v1.0 | 2026-06-18 | 初版作成（テンプレートに沿って再構成．構成図追加．プレースホルダーを意味ベース日本語に統一．パラメータ定義表を整理．SG設定セクションを追加．ロールバック手順を新設．各Stepに【実施対象】明示．句読点を「，．」に統一．「Zabbixサーバー」（長音記号あり）に統一．付録A〜D追加．） |

------------------------------

## 2. 目的・概要

### 2-1. 目的

> 本手順書では，既に稼働しているPostgreSQLサーバー（DBサーバー）上にZabbix用のデータベースとユーザーを作成し，Zabbixサーバーからの接続を許可する手順について説明する．
> 本手順書はDBサーバー側の作業のみを対象とする．Zabbixサーバー本体の構築は別手順書（`zabbix-server.md`）を参照すること．

### 2-2. 構成概要（アーキテクチャ）

```
┌────────────────────────── VPC ──────────────────────────┐
│                                                          │
│  [EC2: Zabbixサーバー]                                    │
│    └─ zabbix-server-pgsql                                │
│           │                                              │
│           │ TCP/5432                                     │
│           │ Zabbix用ユーザーでmd5認証                       │
│           ▼                                              │
│  [EC2: DBサーバー]                                        │
│    └─ PostgreSQL                                         │
│         ├─ <Zabbix用DB名>（DB）                            │
│         │    └─ public スキーマ                            │
│         ├─ <Zabbix用DBユーザー名>（ユーザー）                 │
│         └─ pg_hba.conf                                   │
│              └─ host <Zabbix用DB名> <Zabbix用DBユーザー名>   │
│                   <ZabbixサーバーのプライベートIP>/32 md5   │
│                                                          │
└──────────────────────────────────────────────────────────┘
```

### 2-3. 完成イメージ（ゴール定義）

- [ ] DBサーバー上に `<Zabbix用DB名>` データベースが作成されている
- [ ] DBサーバー上に `<Zabbix用DBユーザー名>` ユーザーが作成され，`<Zabbix用DB名>` への権限がある
- [ ] `<Zabbix用DBユーザー名>` が `public` スキーマへの全権限を持つ
- [ ] `pg_hba.conf` に「`<ZabbixサーバーのプライベートIP>/32` から `<Zabbix用DBユーザー名>` で `<Zabbix用DB名>` へ md5認証で接続許可」のエントリが追加されている
- [ ] `postgresql.conf` の `listen_addresses` が `'*'` に設定されている
- [ ] Zabbixサーバー側から `psql -h <DBサーバーのIP> -U <Zabbix用DBユーザー名> -d <Zabbix用DB名>` で接続でき，`Did not find any relations.`（スキーマ投入前の正常状態）が返る

------------------------------

## 3. 前提条件・準備

### 3-1. 環境要件

| 項目 | 要件 |
|------|------|
| OS | Amazon Linux 2023 |
| PostgreSQL | バージョン15以降を推奨 |
| 実行ユーザー | `postgres` ユーザーまたはsudo権限を持つユーザー |

### 3-2. セキュリティグループ設定

#### 3-2-1. DBサーバーのインバウンドルール

| タイプ | プロトコル | ポート範囲 | ソース | 説明 |
|-------|------------|----------|--------|------|
| SSH | TCP | 22 | マイIP | ローカルPCからSSHで接続（踏み台経由） |
| カスタムTCP | TCP | 5432 | ZabbixサーバーのSG | Zabbixサーバーからの PostgreSQL接続許可 |

#### 3-2-2. DBサーバーのアウトバウンドルール

| タイプ | プロトコル | ポート範囲 | 送信先 | 説明 |
|-------|------------|----------|--------|------|
| HTTPS | TCP | 443 | 0.0.0.0/0 | dnf／パッケージダウンロード |
| HTTP | TCP | 80 | 0.0.0.0/0 | dnfミラー |

### 3-3. パラメータ定義表

> **注意：** 以下の値は作業前に環境に合わせて記入してから作業を開始すること．
> **重要：** **本手順書に実際のパスワードを直接記載しないこと**．パスワードはパスワード管理ツール経由で取り扱うこと．

#### 共通

| パラメータ名 | 値 | 説明 |
|------------|---|------|
| `<DBサーバーのIP>` | `<記入する>` | DBサーバーのプライベートIP |
| `<Zabbix用DB名>` | `<記入する>` | Zabbix用のデータベース名（例：`zabbix`） |
| `<Zabbix用DBユーザー名>` | `<記入する>` | Zabbix用のDBユーザー名（例：`zabbix`） |
| `<DBパスワード>` | パスワード管理ツール参照 | DBユーザー用パスワード（本書には記載しない） |
| `<ZabbixサーバーのプライベートIP>` | `<記入する>` | ZabbixサーバーのプライベートIP |
| `<pg_hba.confパス>` | `<記入する>` | `pg_hba.conf` の絶対パス（Step事前確認で取得） |

#### ロールバック用（任意）

| パラメータ名 | 値 | 説明 |
|------------|---|------|
| `<作業前AMI名>` | `<記入する>` | 作業前スナップショット名（戻す場合のみ記入） |

### 3-4. リンク一覧

| 項目名 | 目的 |
|-------|------|
| https://www.postgresql.org/docs/ | PostgreSQL公式ドキュメント |
| https://www.zabbix.com/documentation/current/jp/manual | Zabbix公式ドキュメント |
| https://docs.aws.amazon.com/ja_jp/AWSEC2/latest/UserGuide/ec2-instance-lifecycle.html | AWS EC2 AMI作成手順 |

### 3-5. 作業前スナップショット取得（必須）

> **重要：** DB変更作業のため，作業前にEC2のAMIスナップショットを取得すること．

```
AWS コンソール → EC2 → 対象インスタンス（DBサーバー）を選択
→ アクション → イメージとテンプレート → イメージを作成
→ イメージ名： zabbix-db-before-install-<日付>
→ 「イメージを作成」をクリック
```

> **注意：** スナップショット取得完了を確認してから構築作業を開始すること．

### 3-6. PostgreSQL起動確認・設定ファイル確認

#### 3-6-1. PostgreSQLの起動確認【実施対象：DBサーバー】

```bash
systemctl status postgresql --no-pager
```

> **確認：** `Active: active (running)` であること．

#### 3-6-2. `pg_hba.conf` のパス確認【実施対象：DBサーバー】

環境によってパスが異なるため必ず確認する．

```bash
sudo -u postgres psql -c "SHOW hba_file;"
```

> **重要：** 表示されたパスをパラメータ定義表の `<pg_hba.confパス>` に記入すること．

#### 3-6-3. `listen_addresses` の確認と修正【実施対象：DBサーバー】

```bash
grep listen_addresses /var/lib/pgsql/data/postgresql.conf
```

`#listen_addresses = 'localhost'`（コメントアウト状態）の場合は修正が必要：

```bash
sed -i "s/#listen_addresses = 'localhost'/listen_addresses = '*'/" \
    /var/lib/pgsql/data/postgresql.conf

# 確認
grep listen_addresses /var/lib/pgsql/data/postgresql.conf
# → listen_addresses = '*' になっていること

# PostgreSQLを再起動して反映
systemctl restart postgresql
```

> **注意：** 他のシステムがこのDBサーバーを参照している場合，再起動は短時間の断を伴うため事前に影響確認すること．

------------------------------

## 4. 構築手順（詳細）

> **注意事項**
> - コマンド中の `<山カッコ>` は自分の環境の値（パラメータ定義表の値）に置き換えること
> - 各Stepの見出し末尾に **【実施対象：DBサーバー】** を明示しているので，対象のサーバーで実施すること
> - 本手順書の作業対象はすべて **DBサーバー** である

------------------------------

### Step 1：データベース作成【実施対象：DBサーバー】

**目的：** Zabbix用のデータベースを作成する

#### 操作手順

```bash
sudo -u postgres psql -c "CREATE DATABASE <Zabbix用DB名>;"
```

> **期待する結果：**
>
> ```
> CREATE DATABASE
> ```

> **補足（冪等性）：** 既に存在する場合は `ERROR: database "<Zabbix用DB名>" already exists` となる．既存DBを再利用する場合はそのままStep 2へ進む．

------------------------------

### Step 2：ユーザー作成【実施対象：DBサーバー】

**目的：** Zabbix用のDBユーザーを作成する

#### 操作手順

```bash
sudo -u postgres psql -c "CREATE USER <Zabbix用DBユーザー名> WITH PASSWORD '<DBパスワード>';"
```

> **重要：** `<DBパスワード>` は本番環境では強力なものを使用すること．本手順書には記載しないこと．

> **補足（既存ユーザーの場合）：** ユーザーが既に存在する場合は，以下でパスワードのみ更新する．

```bash
sudo -u postgres psql -c "ALTER USER <Zabbix用DBユーザー名> WITH PASSWORD '<DBパスワード>';"
```

------------------------------

### Step 3：DBへの権限付与【実施対象：DBサーバー】

**目的：** 作成したユーザーに `<Zabbix用DB名>` への全権限を付与する

#### 操作手順

```bash
sudo -u postgres psql -c "GRANT ALL PRIVILEGES ON DATABASE <Zabbix用DB名> TO <Zabbix用DBユーザー名>;"
```

> **期待する結果：**
>
> ```
> GRANT
> ```

------------------------------

### Step 4：publicスキーマへの権限付与【実施対象：DBサーバー】

**目的：** PostgreSQL 15以降ではpublicスキーマ権限が厳格化されているため，明示的に権限を付与する

#### 操作手順

```bash
sudo -u postgres psql -d <Zabbix用DB名> -c "GRANT ALL ON SCHEMA public TO <Zabbix用DBユーザー名>;"
```

> **重要：** `-d <Zabbix用DB名>` で接続先DBを指定してから実行すること．省略すると `postgres` データベースのpublicスキーマに対する権限付与になってしまう．

> **補足：** Step 1〜4をまとめて実行する場合：

```bash
sudo -u postgres psql << EOF
CREATE DATABASE <Zabbix用DB名>;
CREATE USER <Zabbix用DBユーザー名> WITH PASSWORD '<DBパスワード>';
GRANT ALL PRIVILEGES ON DATABASE <Zabbix用DB名> TO <Zabbix用DBユーザー名>;
\c <Zabbix用DB名>
GRANT ALL ON SCHEMA public TO <Zabbix用DBユーザー名>;
EOF
```

------------------------------

### Step 5：pg_hba.confに接続許可エントリを追加【実施対象：DBサーバー】

**目的：** Zabbixサーバーからの接続を `pg_hba.conf` で許可する

#### 操作手順

```bash
# pg_hba.conf のパスを取得（3-6-2で確認したパス）
PG_HBA=$(sudo -u postgres psql -tAc "SHOW hba_file;" | tr -d ' ')

# バックアップ作成
cp "${PG_HBA}" "${PG_HBA}.bak.$(date +%Y%m%d%H%M%S)"

# エントリ追加用に編集
vi "${PG_HBA}"
```

設定ファイルの追記内容（ファイル末尾に追記）：

```
# Zabbix Server からの接続許可
host    <Zabbix用DB名>    <Zabbix用DBユーザー名>    <ZabbixサーバーのプライベートIP>/32    md5
```

各フィールドの説明：

| フィールド | 設定値 | 説明 |
|---|---|---|
| TYPE | `host` | TCP/IP接続（リモート接続） |
| DATABASE | `<Zabbix用DB名>` | 接続を許可するDB名 |
| USER | `<Zabbix用DBユーザー名>` | 接続を許可するユーザー名 |
| ADDRESS | `<ZabbixサーバーのプライベートIP>/32` | 接続元IP（`/32` で単一ホスト指定） |
| METHOD | `md5` | パスワード認証 |

> **補足：** PostgreSQL 14以降は `scram-sha-256` が推奨される認証方式．`md5` から `scram-sha-256` への移行は付録Dを参照．

------------------------------

### Step 6：pg_hba.confの設定を反映【実施対象：DBサーバー】

**目的：** `pg_hba.conf` の変更を再起動なしで反映する

#### 操作手順

```bash
sudo -u postgres psql -c "SELECT pg_reload_conf();"
```

> **期待する結果：**
>
> ```
>  pg_reload_conf
> ----------------
>  t
> (1 row)
> ```

> **補足：** `pg_reload_conf()` の返り値 `t` は true（成功）を意味する．

------------------------------

## 5. 動作確認・検証

> 構築完了後，以下の確認をすべてパスしたら構築成功とみなす．

### 5-1. 確認チェックリスト

- [ ] **確認①**：`<Zabbix用DB名>` データベースが作成されている
- [ ] **確認②**：`<Zabbix用DBユーザー名>` ユーザーが作成されている
- [ ] **確認③**：`pg_hba.conf` に接続許可エントリが追加されている
- [ ] **確認④**：`listen_addresses` が `'*'` になっている
- [ ] **確認⑤**：Zabbixサーバーから本DBへ接続できる

------------------------------

### 確認①：DB作成確認【実施対象：DBサーバー】

```bash
sudo -u postgres psql -c "\l <Zabbix用DB名>"
```

> **期待する結果：** `<Zabbix用DB名>` の行が表示される．

------------------------------

### 確認②：ユーザー作成確認【実施対象：DBサーバー】

```bash
sudo -u postgres psql -c "\du <Zabbix用DBユーザー名>"
```

> **期待する結果：** `<Zabbix用DBユーザー名>` の行が表示される．

------------------------------

### 確認③：pg_hba.confの確認【実施対象：DBサーバー】

```bash
PG_HBA=$(sudo -u postgres psql -tAc "SHOW hba_file;" | tr -d ' ')
grep <Zabbix用DBユーザー名> "${PG_HBA}"
```

> **期待する結果：** Step 5で追加したエントリが表示される．

------------------------------

### 確認④：listen_addressesの確認【実施対象：DBサーバー】

```bash
grep listen_addresses /var/lib/pgsql/data/postgresql.conf
```

> **期待する結果：** `listen_addresses = '*'` が表示される．

------------------------------

### 確認⑤：Zabbixサーバーからの接続テスト【実施対象：Zabbixサーバー】

> **前提：** Zabbixサーバー側に `postgresql15` クライアントパッケージがインストール済みであること（`zabbix-server.md` を参照）．

```bash
# .pgpass を作成（パスワードを平文で環境変数に出さない）
echo "<DBサーバーのIP>:5432:<Zabbix用DB名>:<Zabbix用DBユーザー名>:<DBパスワード>" > ~/.pgpass
chmod 600 ~/.pgpass

# 接続テスト
psql -h <DBサーバーのIP> -U <Zabbix用DBユーザー名> -d <Zabbix用DB名> -c "\dt"
```

> **期待する結果：**
>
> ```
> Did not find any relations.
> ```
>
> （Zabbixスキーマ投入前の正常状態．スキーマ投入後はテーブル一覧が表示される．）

> **重要：** `~/.pgpass` のパーミッションは必ず `600` にすること．それ以外だと PostgreSQLが警告を出して認証に使ってくれない．

------------------------------

## 6. トラブルシューティング

### よくあるエラーと対処法

------------------------------

#### エラー①：`FATAL: password authentication failed`

**原因：** パスワード不一致，またはpg_hba.confのMETHODが期待と異なる．

**対処法：**

```bash
# pg_hba.conf にZabbix用エントリがあるか確認
PG_HBA=$(sudo -u postgres psql -tAc "SHOW hba_file;" | tr -d ' ')
grep <Zabbix用DBユーザー名> "${PG_HBA}"

# 設定リロード
sudo -u postgres psql -c "SELECT pg_reload_conf();"

# パスワードリセット
sudo -u postgres psql -c "ALTER USER <Zabbix用DBユーザー名> WITH PASSWORD '<DBパスワード>';"
```

------------------------------

#### エラー②：`FATAL: no pg_hba.conf entry for host`

**原因：** pg_hba.confに該当する接続元IP／DB／ユーザーの組合せが無い．

**対処法：**

```bash
PG_HBA=$(sudo -u postgres psql -tAc "SHOW hba_file;" | tr -d ' ')
grep <Zabbix用DB名> "${PG_HBA}"
# Step 5でエントリを追加し，リロード
sudo -u postgres psql -c "SELECT pg_reload_conf();"
```

------------------------------

#### エラー③：`Connection refused`

**原因：** `listen_addresses` が `localhost` のまま，もしくはSGで5432未許可．

**対処法：**

```bash
# listen_addresses の確認・修正
grep listen_addresses /var/lib/pgsql/data/postgresql.conf
sed -i "s/#listen_addresses = 'localhost'/listen_addresses = '*'/" \
    /var/lib/pgsql/data/postgresql.conf
systemctl restart postgresql
```

SG側も確認：AWSコンソールでDBサーバーのSGインバウンドに `カスタムTCP / 5432 / ZabbixサーバーのSG` が追加されているか確認．

------------------------------

#### エラー④：`permission denied for schema public`

**原因：** PostgreSQL 15以降のpublicスキーマ権限の厳格化．

**対処法：**

```bash
sudo -u postgres psql -d <Zabbix用DB名> -c "GRANT ALL ON SCHEMA public TO <Zabbix用DBユーザー名>;"
```

------------------------------

#### エラー⑤：`~/.pgpass` でパスワード認証されない

**原因：** `~/.pgpass` のパーミッションが `600` ではない．

**対処法：**

```bash
chmod 600 ~/.pgpass
ls -l ~/.pgpass
# → -rw------- であること
```

------------------------------

### ログの確認場所

| ログの種類 | 場所（パス） |
|-----------|------------|
| PostgreSQL ログ | `/var/lib/pgsql/data/log/postgresql-*.log` |
| systemd ログ | `journalctl -u postgresql` |

------------------------------

## 7. 参考リソース・関連資料

| 資料名 | URL / 場所 | 補足 |
|-------|-----------|------|
| PostgreSQL公式ドキュメント | https://www.postgresql.org/docs/ | PostgreSQL全般 |
| `pg_hba.conf` 仕様 | https://www.postgresql.org/docs/current/auth-pg-hba-conf.html | 認証ファイルの書式 |
| Zabbix公式ドキュメント | https://www.zabbix.com/documentation/current/jp/manual | Zabbix全般 |
| 別手順書：Zabbixサーバー構築 | `zabbix-server.md` | DBへの接続元 |
| 別手順書：Zabbix Agent2構築 | `zabbix-agent2.md` | 監視エージェント |

------------------------------

## 8. ロールバック手順

### 8-1. 接続テスト用設定の削除【実施対象：Zabbixサーバー】

```bash
rm -f ~/.pgpass
```

### 8-2. pg_hba.confの復元【実施対象：DBサーバー】

```bash
# バックアップ存在確認
PG_HBA=$(sudo -u postgres psql -tAc "SHOW hba_file;" | tr -d ' ')
ls -lt "${PG_HBA}.bak."* 2>/dev/null | head -1

# 最新のバックアップから復元
LATEST_BAK=$(ls -t "${PG_HBA}.bak."* | head -1)
cp -f "${LATEST_BAK}" "${PG_HBA}"

# 設定リロード
sudo -u postgres psql -c "SELECT pg_reload_conf();"
```

### 8-3. ZabbixユーザーとDBの削除【実施対象：DBサーバー】

> **注意：** Zabbixサーバーが稼働中の場合，まずZabbixサーバーを停止してから実施すること．

```bash
sudo -u postgres psql << EOF
REVOKE ALL ON SCHEMA public FROM <Zabbix用DBユーザー名>;
REVOKE ALL PRIVILEGES ON DATABASE <Zabbix用DB名> FROM <Zabbix用DBユーザー名>;
DROP DATABASE IF EXISTS <Zabbix用DB名>;
DROP USER IF EXISTS <Zabbix用DBユーザー名>;
EOF
```

### 8-4. listen_addressesの復元（必要に応じて）【実施対象：DBサーバー】

> **注意：** 本DBサーバーが他のシステムからも接続されている場合は `listen_addresses = '*'` のまま維持すること．

```bash
sed -i "s/listen_addresses = '\*'/#listen_addresses = 'localhost'/" \
    /var/lib/pgsql/data/postgresql.conf
systemctl restart postgresql
```

### 8-5. 完全リカバリ：AMIスナップショットからの復元【実施対象：DBサーバー】

> **注意：** 部分的なロールバックで対応できない場合の最終手段．

```
AWS コンソール → EC2 → AMI → <作業前AMI名> を選択
→ 「AMIからインスタンスを起動」
→ 既存DBサーバーを停止／削除し，新インスタンスに切替
```

### 8-6. 完了確認【実施対象：DBサーバー】

```bash
sudo -u postgres psql -c "\l <Zabbix用DB名>" 2>&1 | head -5
# → does not exist もしくは何も表示されないこと

sudo -u postgres psql -c "\du <Zabbix用DBユーザー名>" 2>&1 | head -5
# → ユーザー一覧に表示されないこと
```

------------------------------

## 付録

### A. コマンド解説

| コマンド | 説明 |
|---------|------|
| `sudo -u postgres psql` | postgresユーザーとしてpsqlを起動．OSの認証を使うため対話プロンプトでパスワード不要． |
| `psql -c "<SQL>"` | 1つのSQLを実行して終了． |
| `psql -d <DB名>` | 指定DBに接続． |
| `psql -h <ホスト> -U <ユーザー> -d <DB名>` | ホスト・ユーザー・DBを指定して接続． |
| `\l` | データベース一覧表示（psql内コマンド）． |
| `\du` | ロール（ユーザー）一覧表示． |
| `\dt` | テーブル一覧表示． |
| `\c <DB名>` | 接続先DBを切り替え． |
| `\q` | psql終了． |
| `CREATE DATABASE <名>` | データベース作成． |
| `CREATE USER <名> WITH PASSWORD '<pw>'` | ユーザー作成． |
| `ALTER USER <名> WITH PASSWORD '<pw>'` | ユーザーのパスワード変更． |
| `GRANT ALL PRIVILEGES ON DATABASE <DB> TO <ユーザー>` | DBに対する全権限付与． |
| `GRANT ALL ON SCHEMA public TO <ユーザー>` | publicスキーマに対する全権限付与． |
| `SELECT pg_reload_conf();` | 設定ファイルを再読み込み（再起動なし）． |
| `SHOW hba_file;` | `pg_hba.conf` の絶対パスを表示． |
| `chmod 600 ~/.pgpass` | `.pgpass` のパーミッション設定（PostgreSQL認証に必須）． |

------------------------------

### B. 設定ファイル解説

**`/var/lib/pgsql/data/postgresql.conf`（DBサーバー）**

```
listen_addresses = '*'
```

- `listen_addresses`：PostgreSQLがLISTENするIPアドレスを指定．
  - `'localhost'`（デフォルト）：localhost のみ．外部から接続不可．
  - `'*'`：全インターフェース．VPC内部から接続可能になる．
  - `'<特定IP>'`：指定IPのみ．
- 本手順書では `'*'` を使用．SGで接続元を制限することでセキュリティを担保．

**`pg_hba.conf`（DBサーバー）**

書式：

```
TYPE  DATABASE  USER  ADDRESS  METHOD
```

- `TYPE`：
  - `local`：Unixドメインソケット経由（ローカル）
  - `host`：TCP/IP接続
  - `hostssl`：SSL必須のTCP/IP接続
  - `hostnossl`：SSL不可のTCP/IP接続
- `DATABASE`：接続を許可するDB名．`all` で全DB．
- `USER`：接続を許可するユーザー名．`all` で全ユーザー．
- `ADDRESS`：接続元IP．`/32`（IPv4単一）／`/24`（サブネット）等で範囲指定．
- `METHOD`：認証方式．
  - `trust`：パスワード不要．**本番では使用禁止**．
  - `md5`：md5ハッシュパスワード認証．本手順書で使用．
  - `scram-sha-256`：PostgreSQL 14以降推奨の強力な認証．
  - `peer`：OSユーザーと同名のDBユーザーで接続（local専用）．

**`~/.pgpass`（Zabbixサーバー）**

書式：

```
hostname:port:database:username:password
```

- ホスト・ポート・DB・ユーザーごとに対応するパスワードを記載．
- ワイルドカード `*` も使用可能．
- パーミッション `600` 必須（それ以外だとPostgreSQLが警告を出して認証に使わない）．

------------------------------

### C. 用語解説

| 用語 | 説明 |
|------|------|
| PostgreSQL | オープンソースのリレーショナルデータベース管理システム（RDBMS）． |
| データベース | テーブル・インデックス・関数等のオブジェクトを格納する単位． |
| スキーマ | データベース内でオブジェクトをグルーピングする名前空間． |
| publicスキーマ | PostgreSQLで作成されるデフォルトのスキーマ．PostgreSQL 15以降は権限が厳格化． |
| ロール | PostgreSQLでのユーザー／グループの抽象概念．`CREATE USER` は内部的にロールを作る． |
| `pg_hba.conf` | PostgreSQLのクライアント認証設定ファイル．「どこからどのユーザーがどのDBにどう接続できるか」を定義． |
| `listen_addresses` | PostgreSQLがLISTENするIPアドレスを指定する `postgresql.conf` のディレクティブ． |
| md5認証 | パスワードをmd5ハッシュ化して送信する認証方式．PostgreSQL 14以降は `scram-sha-256` 推奨． |
| scram-sha-256 | PostgreSQL 14以降推奨の強力なパスワード認証方式．SCRAM-SHA-256ベース． |
| `SHOW hba_file;` | psql内でpg_hba.confの絶対パスを表示するシステム関数． |
| `pg_reload_conf()` | PostgreSQLの設定ファイル群を再読み込みする関数．再起動不要． |
| `.pgpass` | パスワード保存ファイル．`psql` 等のクライアントが認証時に参照．`chmod 600` 必須． |
| AMI | Amazon Machine Image．EC2インスタンスのスナップショット．バックアップ／リストアに使用． |

------------------------------

### D. 補足解説

- **なぜZabbix用にDB／ユーザーを分けるか？**
  - 他システムと同居しているPostgreSQLで，Zabbix専用のDB／ユーザーを作成することで権限分離する．
  - Zabbix固有のテーブル群を専用DBに閉じ込めることで，バックアップ／リストア／削除が容易になる．
  - セキュリティ事故時の影響範囲を限定できる．

- **PostgreSQL 15以降のpublicスキーマ権限変更について**
  - PostgreSQL 14まで：`public` スキーマは「`PUBLIC`」ロール（全ユーザー）に対して `CREATE` と `USAGE` 権限がデフォルト付与されていた．
  - PostgreSQL 15以降：`CREATE` 権限が `PUBLIC` から取り消され，**DBオーナー以外がオブジェクトを作成するには明示的な `GRANT` が必要** になった．
  - Zabbixはスキーマ投入時に大量のテーブルを作成するため，Step 4で `GRANT ALL ON SCHEMA public` を明示的に実行する必要がある．

- **md5認証と scram-sha-256 の違い**
  - md5：パスワードのmd5ハッシュを送信．ハッシュ衝突攻撃に対しては弱い．
  - scram-sha-256：チャレンジレスポンス方式でパスワードハッシュをネットワークに流さない．より安全．
  - PostgreSQL 14以降のデフォルトは `scram-sha-256`．
  - 本手順書では既存環境との互換性のため `md5` を使用しているが，新規構築なら `scram-sha-256` への移行を推奨：

  ```bash
  # postgresql.conf
  password_encryption = scram-sha-256

  # pg_hba.conf
  host    <DB名>    <ユーザー名>    <IP>/32    scram-sha-256

  # 既存ユーザーのパスワードを再設定（scram-sha-256ハッシュで再保存される）
  ALTER USER <ユーザー名> WITH PASSWORD '<新パスワード>';
  ```

- **`~/.pgpass` のセキュリティ重要性**
  - パスワードを平文で保存するファイルのため，パーミッション `600`（オーナーのみ読み書き可能）を必ず設定する．
  - パーミッションが緩い（644等）と，PostgreSQLが警告して認証に使わない仕様．
  - 環境変数 `PGPASSWORD` でパスワードを渡す方法もあるが，シェル履歴に残るためお勧めしない．

- **AMIスナップショットによるロールバック戦略**
  - 部分ロールバック（ユーザー削除・pg_hba.conf復元）で対応できる範囲なら8-1〜8-4で十分．
  - スキーマ投入後の大規模リカバリや，複数の変更を一気に巻き戻したい場合は AMIから新インスタンスを起動して切替が確実．
  - スナップショットコストは最小限なので，本番作業前のAMI取得は必須．

- **DBサーバー側だけでも本手順書は完結する**
  - 接続テスト（確認⑤）はZabbixサーバー側でしか実施できないが，それ以外は全てDBサーバー側で完結する．
  - Zabbixサーバー構築前にDB準備だけ先行して進めることが可能．

- **冪等性について**
  - Step 1（CREATE DATABASE）はDBが既に存在するとエラー．存在チェックを入れたい場合は `CREATE DATABASE IF NOT EXISTS` は使えないため，アプリ側で事前チェックする．
  - Step 2（CREATE USER）も同様．既存ユーザーは `ALTER USER` で対応．
  - Step 3〜4（GRANT）は既に権限があっても成功するため冪等．
