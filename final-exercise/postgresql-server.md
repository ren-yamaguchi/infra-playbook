# PostgreSQL 15 サーバー構築

------------------------------

## 1. ドキュメント情報

| 項目 | 内容 |
|------|------|
| 手順書名 | PostgreSQL 15 サーバー構築 |
| 作成日 | 2026-06-19 |
| 最終更新日 | 2026-06-20 |
| バージョン | v1.2 |
| 対象環境 | AWS（Amazon Linux 2023） |

> **改訂履歴**
>
> | バージョン | 日付 | 変更内容 |
> |-----------|------|---------|
> | v1.0 | 2026-06-19 | 初版作成（元`DB_構築手順書.md`のフェーズ0を基にテンプレートに沿って再構成．データディレクトリを`/data/pgdata`に分離する設計を維持．`listen_addresses = '*'`設定をStepに含める．DB／ユーザー作成・`pg_hba.conf`設定は利用側手順書の責務として切り離す．構成図追加．プレースホルダーを意味ベース日本語に統一．各Stepに【実施対象】明示．句読点を「，．」に統一．サーバー表記を「サーバー」に統一．付録A〜D追加．） |
> | v1.1 | 2026-06-19 | 整合性チェックにより参考リソース・リンク一覧に`war-deploy-migration.md`への参照を追加（PostgreSQL→アプリ移行のフロー明示）． |
> | v1.2 | 2026-06-20 | データディレクトリを標準パス `/var/lib/pgsql/data` に統一．カスタムパス `/data/pgdata` 設計を廃止．これに伴いStep 5（systemd override）を削除（パッケージ標準のunit ファイルがそのまま使えるため）．データ用EBSボリュームのアタッチ・マウント前提を削除．付録B（systemd override 解説），付録D-1，付録D-4を更新．`<データディレクトリパス>` `<マウントポイント>` プレースホルダーを廃止し，標準パスで記述． |

------------------------------

## 2. 目的・概要

### 2-1. 目的

> 本手順書では，AWSのEC2インスタンス上にPostgreSQL 15をインストールし，標準データディレクトリ（`/var/lib/pgsql/data`）でデータベースクラスタを初期化した上で，外部からの接続を受け付ける状態（`listen_addresses = '*'`）にする手順について説明する．
> 本手順書のゴールは「**空のPostgreSQL 15が初期化済みで起動しており，外部からTCP/5432で接続可能な状態**」とする．
> DB・ロール・`pg_hba.conf`の認証エントリ・データ投入については，利用目的に応じて以下の別手順書で実施する．
>
> - データ移行の場合：`postgresql-migration.md`
> - Zabbix用DB構築の場合：`zabbix-db-postgresql.md`
> - その他アプリ用DBの場合：個別手順書を参照

### 2-2. 構成概要（アーキテクチャ）

```
┌────────────────────────── VPC ──────────────────────────┐
│                                                          │
│  [接続元クライアント（各種）]                                │
│    ├─ Zabbixサーバー                                      │
│    ├─ APサーバー（Tomcat等）                                │
│    └─ その他アプリケーション                                 │
│           │                                              │
│           │ TCP/5432（認証は利用側手順書で設定）              │
│           ▼                                              │
│  [EC2: DBサーバー]                                         │
│    ├─ Amazon Linux 2023                                  │
│    ├─ PostgreSQL 15                                      │
│    │     ├─ postgres プロセス（5432番）                    │
│    │     ├─ listen_addresses = '*'                       │
│    │     └─ password_encryption = scram-sha-256          │
│    │                                                     │
│    └─ /var/lib/pgsql/data （PostgreSQLデータディレクトリ）  │
│         ├─ postgresql.conf                               │
│         ├─ pg_hba.conf                                   │
│         ├─ base/  (DBファイル本体)                         │
│         ├─ pg_wal/                                       │
│         └─ ...                                           │
│                                                          │
└──────────────────────────────────────────────────────────┘
```

### 2-3. 完成イメージ（ゴール定義）

- [ ] PostgreSQL 15がインストールされている（`/usr/bin/psql --version` で `psql (PostgreSQL) 15.x`）
- [ ] `/var/lib/pgsql/data` でクラスタが初期化されている
- [ ] `postgresql-15.service` が `active (running)` かつ自動起動有効
- [ ] 5432番ポートがLISTENしている
- [ ] `SHOW data_directory;` が `/var/lib/pgsql/data` を返す
- [ ] `SHOW listen_addresses;` が `*` を返す
- [ ] `SHOW password_encryption;` が `scram-sha-256` を返す

------------------------------

## 3. 前提条件・準備

### 3-1. 環境要件

| 項目 | 要件 |
|------|------|
| OS | Amazon Linux 2023 |
| CPU | 2コア以上推奨 |
| メモリ | 4GB以上推奨 |
| ストレージ | ルートボリューム50GB以上（OS＋PostgreSQLデータ用） |
| ロケール | `en_US.utf8`（後続のデータ移行手順との互換性のため） |

### 3-2. セキュリティグループ設定

#### 3-2-1. DBサーバーのインバウンドルール

| タイプ | プロトコル | ポート範囲 | ソース | 説明 |
|-------|------------|----------|--------|------|
| SSH | TCP | 22 | マイIP（踏み台経由） | 構築作業用 |
| カスタムTCP | TCP | 5432 | VPC CIDR（または接続元SG） | PostgreSQL接続用 |

> **補足：** 接続元の特定（ZabbixサーバーのSG／APサーバーのSG等）は利用側手順書で行うため，本手順書では一旦VPC CIDR範囲で開放する．本番環境では利用側手順書完了後に最小権限化を推奨．

#### 3-2-2. DBサーバーのアウトバウンドルール

| タイプ | プロトコル | ポート範囲 | 送信先 | 説明 |
|-------|------------|----------|--------|------|
| HTTPS | TCP | 443 | 0.0.0.0/0 | dnf／パッケージダウンロード |
| HTTP | TCP | 80 | 0.0.0.0/0 | dnfミラー |

### 3-3. パラメータ定義表

> **注意：** 以下の値は作業前に環境に合わせて記入してから作業を開始すること．

#### 共通

| パラメータ名 | 値 | 説明 |
|------------|---|------|
| `<DBサーバーのホスト名>` | `<記入する>` | このサーバーのホスト名（例：`db-server-1`） |
| `<PostgreSQLバージョン>` | `15` | インストールするPostgreSQLのメジャーバージョン |
| `<ロケール>` | `en_US.utf8` | データベースクラスタのロケール |
| `<文字セット>` | `UTF8` | データベースクラスタのエンコーディング |

> **補足：** データディレクトリは Amazon Linux 2023 の `postgresql15-server` パッケージ標準である `/var/lib/pgsql/data` を使用するため，プレースホルダー化していない．

#### ロールバック用（任意）

| パラメータ名 | 値 | 説明 |
|------------|---|------|
| `<作業前AMI名>` | `<記入する>` | 作業前スナップショット名（戻す場合のみ記入） |
| `<元のホスト名>` | `<記入する>` | 構築前のホスト名（戻す場合のみ記入） |

### 3-4. リンク一覧

| 項目名 | 目的 |
|-------|------|
| https://www.postgresql.org/docs/15/ | PostgreSQL 15 公式ドキュメント |
| https://docs.aws.amazon.com/ja_jp/linux/al2023/ug/ | Amazon Linux 2023 ガイド |
| 別手順書：データ移行 | `postgresql-migration.md` |
| 別手順書：Zabbix用DB構築 | `zabbix-db-postgresql.md` |
| 別手順書：アプリケーション移行 | `war-deploy-migration.md` |

### 3-5. 事前確認

#### 3-5-1. ルートボリュームの空き容量確認【実施対象：DBサーバー】

```bash
df -h /
```

> **期待する結果：** 50GB以上のボリュームがマウントされており，十分な空き容量がある．

#### 3-5-2. 作業前スナップショット取得（必須）【実施対象：AWSコンソール】

```
AWS コンソール → EC2 → 対象インスタンス（DBサーバー）を選択
→ アクション → イメージとテンプレート → イメージを作成
→ イメージ名： postgresql-server-before-install-<日付>
→ 「イメージを作成」をクリック
```

> **注意：** スナップショット取得完了を確認してから構築作業を開始すること．

------------------------------

## 4. 構築手順（詳細）

> **注意事項**
> - コマンド中の `<山カッコ>` は自分の環境の値（パラメータ定義表の値）に置き換えること
> - 各Stepの見出し末尾に **【実施対象：DBサーバー】** を明示しているので，対象のサーバーで実施すること
> - 本手順書の作業対象はすべて **DBサーバー** である

------------------------------

### Step 1：PostgreSQL 15 のインストール【実施対象：DBサーバー】

**目的：** PostgreSQLサーバー本体・クライアント・contrib をインストールする

#### 操作手順

```bash
# rootユーザーにスイッチ
sudo su -

# パッケージを最新化
dnf update -y

# 利用可能なバージョン確認（任意）
dnf list available | grep -i postgresql<PostgreSQLバージョン>

# PostgreSQL本体・クライアント・contribをインストール
dnf install -y postgresql<PostgreSQLバージョン> postgresql<PostgreSQLバージョン>-server postgresql<PostgreSQLバージョン>-contrib

# インストール確認
/usr/bin/psql --version
```

> **期待する結果：** `psql (PostgreSQL) 15.x` が表示される．

> **補足：** `postgresql<バージョン>-contrib` には拡張モジュール（`pg_stat_statements`等）が含まれる．後で追加することも可能．

------------------------------

### Step 2：ロケールの確認・追加【実施対象：DBサーバー】

**目的：** `initdb` 時に指定するロケール（`<ロケール>`）がOSで利用可能であることを確認する

#### 操作手順

```bash
locale -a | grep -i en_US
```

> **期待する結果：** `en_US.utf8` が表示される．

表示されない場合は以下でインストール：

```bash
dnf install -y glibc-langpack-en
locale -a | grep -i en_US
```

> **重要：** `initdb` のロケールは後から変更できない．データ移行を予定している場合は，**移行元と同じロケール**を指定すること．

------------------------------

### Step 3：データベースクラスタの初期化（initdb）【実施対象：DBサーバー】

**目的：** 標準データディレクトリ `/var/lib/pgsql/data` でPostgreSQLのデータベースクラスタを初期化する

#### 操作手順

AL2023のラッパー（`postgresql-15-setup`）を使う方法（推奨）：

```bash
PGSETUP_INITDB_OPTIONS="-E <文字セット> --locale=<ロケール>" \
    /usr/bin/postgresql-<PostgreSQLバージョン>-setup --initdb
```

> **補足：** `postgresql-15-setup --initdb` を実行すると，systemd unit ファイルが参照する標準パス（`/var/lib/pgsql/data`）にデータディレクトリが自動作成される．ディレクトリ作成・所有者設定・パーミッション設定もラッパーが代行する．

ラッパーが使えない場合は postgres ユーザーで直接初期化（標準パス指定）：

```bash
sudo -u postgres /usr/bin/initdb \
    -D /var/lib/pgsql/data \
    -E <文字セット> \
    --locale=<ロケール>
```

#### 初期化確認

```bash
ls -la /var/lib/pgsql/data/
```

> **期待する結果：** `PG_VERSION`，`postgresql.conf`，`pg_hba.conf`，`base`，`global`，`pg_wal` 等が作成されている．

```bash
cat /var/lib/pgsql/data/PG_VERSION
```

> **期待する結果：** `15`

```bash
ls -ld /var/lib/pgsql/data
```

> **期待する結果：** `drwx------ ... postgres postgres ... /var/lib/pgsql/data` （パーミッション700，所有者postgres）

> **重要：** ロケール・エンコーディングは後から変更できない．間違えた場合はディレクトリを削除してinitdbをやり直す必要がある．

------------------------------

### Step 4：listen_addresses の設定【実施対象：DBサーバー】

**目的：** PostgreSQLが外部（localhost以外）からの接続を受け付けるようにする

#### 操作手順

```bash
# postgresql.conf を編集
vi /var/lib/pgsql/data/postgresql.conf
```

`listen_addresses` の設定を以下に変更（既存行のコメントアウト解除＋値変更，または末尾に追記）：

```
listen_addresses = '*'
```

#### 確認

```bash
grep -E "^listen_addresses|^#listen_addresses" /var/lib/pgsql/data/postgresql.conf
```

> **期待する結果：** `listen_addresses = '*'` が（コメントアウトされず）表示される．

> **重要：** 同時に `pg_hba.conf` も適切に設定しないと，外部からの接続は認証段階で拒否される．`pg_hba.conf` のエントリは利用側手順書（`postgresql-migration.md` / `zabbix-db-postgresql.md`）で追加する．

> **補足：** AL2023のデフォルトでは `pg_hba.conf` で `host all all 127.0.0.1/32 scram-sha-256` のようにlocalhostのみが許可されている．`listen_addresses = '*'` で外部リスニング自体は開始されるが，認証エントリが無いと接続できない（セキュリティ的にも望ましい）．

------------------------------

### Step 5：PostgreSQLサービスの起動・自動起動設定【実施対象：DBサーバー】

**目的：** PostgreSQLを起動し，OS再起動時にも自動起動する設定にする

#### 操作手順

```bash
systemctl enable --now postgresql-<PostgreSQLバージョン>.service
systemctl status postgresql-<PostgreSQLバージョン>.service --no-pager
systemctl is-enabled postgresql-<PostgreSQLバージョン>.service
```

> **期待する結果：** `Active: active (running)` および `enabled`．

> **注意：** 起動失敗時は `journalctl -u postgresql-<PostgreSQLバージョン> -n 50` でログを確認．データディレクトリのパーミッション・`postgresql.conf` の構文ミスが主な原因．

------------------------------

### Step 6：起動・接続確認【実施対象：DBサーバー】

**目的：** PostgreSQLが正常起動し，データディレクトリ・listen_addresses等の設定が反映されていることを確認する

#### 操作手順

作業ディレクトリを `/tmp` に移動（postgres ユーザーが書込可能な場所にしないと警告が出る）：

```bash
cd /tmp
```

#### バージョン確認

```bash
sudo -u postgres /usr/bin/psql -c "SELECT version();"
```

> **期待する結果：** `PostgreSQL 15.x on x86_64-pc-linux-gnu, ...` が返る．

#### データディレクトリ確認

```bash
sudo -u postgres /usr/bin/psql -c "SHOW data_directory;"
```

> **期待する結果：** `/var/lib/pgsql/data` が返る．

#### listen_addresses 確認

```bash
sudo -u postgres /usr/bin/psql -c "SHOW listen_addresses;"
```

> **期待する結果：** `*` が返る．

#### パスワード暗号化方式の確認

```bash
sudo -u postgres /usr/bin/psql -c "SHOW password_encryption;"
```

> **期待する結果：** `scram-sha-256` が返る（PostgreSQL 14以降のデフォルト）．

------------------------------

## 5. 動作確認・検証

### 5-1. 確認チェックリスト

- [ ] **確認①**：`postgresql-15.service` が `active (running)` かつ自動起動有効
- [ ] **確認②**：5432番ポートでLISTENしている
- [ ] **確認③**：`SHOW data_directory;` が `/var/lib/pgsql/data` を返す
- [ ] **確認④**：`SHOW listen_addresses;` が `*` を返す
- [ ] **確認⑤**：`SHOW password_encryption;` が `scram-sha-256` を返す
- [ ] **確認⑥**：PostgreSQL ログにエラーが出ていない

------------------------------

### 確認①：サービス状態確認

```bash
systemctl status postgresql-<PostgreSQLバージョン>.service --no-pager
systemctl is-enabled postgresql-<PostgreSQLバージョン>.service
```

> **期待する結果：** `active (running)` および `enabled`．

------------------------------

### 確認②：リッスンポート確認

```bash
ss -tlnp | grep :5432
```

> **期待する結果：** `0.0.0.0:5432` がLISTEN．

------------------------------

### 確認③〜⑤：PostgreSQL設定確認

```bash
cd /tmp
sudo -u postgres /usr/bin/psql -c "SHOW data_directory;"
sudo -u postgres /usr/bin/psql -c "SHOW listen_addresses;"
sudo -u postgres /usr/bin/psql -c "SHOW password_encryption;"
```

------------------------------

### 確認⑥：ログ確認

```bash
tail -n 50 /var/lib/pgsql/data/log/postgresql-*.log
```

> **注意：** `FATAL` や `ERROR` が頻発していないか目視確認．

------------------------------

### 5-2. 次のステップ

本手順書での作業が完了したら，用途に応じて以下のいずれかの手順書に進む：

- データ移行が必要な場合 → `postgresql-migration.md`
- Zabbix用DB／ユーザーを作りたい場合 → `zabbix-db-postgresql.md`
- 他アプリ用DBを作る場合 → 個別の手順書

------------------------------

## 6. トラブルシューティング

------------------------------

#### エラー①：`postgresql-15.service: Failed to start`

**原因：**

- データディレクトリのパーミッションが `700` でない
- データディレクトリの所有者が `postgres` でない
- `postgresql.conf` の構文ミス

**対処法：**

```bash
# ログ確認
journalctl -u postgresql-<PostgreSQLバージョン>.service -n 50 --no-pager

# パーミッション・所有者確認
ls -ld /var/lib/pgsql/data
# → drwx------ postgres postgres であること
```

> **補足：** `postgresql-15-setup --initdb` ラッパーを使えば，パーミッション・所有者は自動で正しく設定される．直接 `initdb` を実行した場合は手動確認が必要．

------------------------------

#### エラー②：`initdb` で `directory "..." is not empty`

**原因：** データディレクトリに既にファイルがある．

**対処法：**

```bash
# データディレクトリの中身確認
ls -la /var/lib/pgsql/data/

# 空にする（既存環境を再利用しない場合）
rm -rf /var/lib/pgsql/data/*
# → その後 Step 3 から再実行
```

> **注意：** 既存データを誤って削除しないよう，事前にバックアップを必ず確認すること．

------------------------------

#### エラー③：外部から接続できない

**原因：**

- `listen_addresses` が `localhost` のまま
- `pg_hba.conf` に接続元のエントリが無い
- SGで5432番が拒否されている

**対処法：**

```bash
# postgresql.conf 確認
grep -E "^listen_addresses" /var/lib/pgsql/data/postgresql.conf

# pg_hba.conf 確認（接続元のエントリが必要）
sudo -u postgres /usr/bin/psql -c "SHOW hba_file;"
```

> **補足：** `pg_hba.conf` のエントリ追加は利用側手順書で実施．

------------------------------

### ログの確認場所

| ログの種類 | 場所 |
|-----------|------|
| PostgreSQL ログ | `/var/lib/pgsql/data/log/postgresql-*.log` |
| systemd ログ | `journalctl -u postgresql-<PostgreSQLバージョン>` |

------------------------------

## 7. 参考リソース・関連資料

| 資料名 | URL / 場所 | 補足 |
|-------|-----------|------|
| PostgreSQL 15 公式ドキュメント | https://www.postgresql.org/docs/15/ | PostgreSQL全般 |
| `initdb` リファレンス | https://www.postgresql.org/docs/15/app-initdb.html | クラスタ初期化 |
| `postgresql.conf` リファレンス | https://www.postgresql.org/docs/15/runtime-config.html | サーバー設定 |
| Amazon Linux 2023 ガイド | https://docs.aws.amazon.com/ja_jp/linux/al2023/ug/ | OS全般 |
| 別手順書：データ移行 | `postgresql-migration.md` | 旧PostgreSQLからのデータ移行 |
| 別手順書：Zabbix用DB構築 | `zabbix-db-postgresql.md` | Zabbix用DB／ユーザー作成 |
| 別手順書：アプリケーション移行 | `war-deploy-migration.md` | 本DBサーバーへのアプリ接続切替 |

------------------------------

## 8. ロールバック手順

### 8-1. PostgreSQLサービスの停止と無効化【実施対象：DBサーバー】

```bash
systemctl disable --now postgresql-<PostgreSQLバージョン>.service
```

### 8-2. データディレクトリの削除【実施対象：DBサーバー】

> **重要：** 既にデータが投入されている場合，必要なバックアップを取ってから削除すること．

```bash
ls -la /var/lib/pgsql/data/
rm -rf /var/lib/pgsql/data
```

### 8-3. PostgreSQLパッケージのアンインストール【実施対象：DBサーバー】

```bash
dnf remove -y postgresql<PostgreSQLバージョン> postgresql<PostgreSQLバージョン>-server postgresql<PostgreSQLバージョン>-contrib
```

### 8-4. 完全リカバリ：AMIスナップショットからの復元（任意）【実施対象：AWSコンソール】

```
AWS コンソール → EC2 → AMI → <作業前AMI名> を選択
→ 「AMIからインスタンスを起動」
→ 既存DBサーバーを停止／削除し，新インスタンスに切替
```

### 8-5. 完了確認【実施対象：DBサーバー】

```bash
systemctl status postgresql-<PostgreSQLバージョン>.service 2>&1 | head -3
# → "Unit postgresql-15.service could not be found." であること

rpm -qa | grep postgresql
# → 何も表示されないこと
```

> **注意：** `dnf update` で適用したパッケージ更新は取り消さない（依存破壊リスク回避）．

------------------------------

## 付録

### A. コマンド解説

| コマンド | 説明 |
|---------|------|
| `dnf list available \| grep postgresql15` | dnfで利用可能なPostgreSQL 15関連パッケージを確認． |
| `dnf install -y postgresql15-server` | PostgreSQLサーバー本体をインストール． |
| `locale -a` | 利用可能なロケール一覧を表示． |
| `dnf install -y glibc-langpack-en` | 英語ロケール（`en_US.utf8`等）を追加． |
| `/usr/bin/postgresql-15-setup --initdb` | PostgreSQLクラスタの初期化（AL2023のラッパー）．標準パス `/var/lib/pgsql/data` に作成． |
| `sudo -u postgres /usr/bin/initdb -D <PATH>` | postgresユーザーとして直接initdbを実行． |
| `systemctl enable --now <サービス>` | サービスを起動し，自動起動を有効化． |
| `systemctl cat <サービス>` | unit ファイルの内容を表示． |
| `sudo -u postgres /usr/bin/psql` | postgresユーザーとして psql を起動． |
| `psql -c "<SQL>"` | 1つのSQLを実行して終了． |
| `SHOW <設定>;` | PostgreSQLの設定値をSQLで取得． |
| `SELECT version();` | PostgreSQLのバージョン情報をSQLで取得． |
| `ss -tlnp \| grep :5432` | 5432番ポートのLISTEN状態を確認． |

------------------------------

### B. 設定ファイル解説

**`/var/lib/pgsql/data/postgresql.conf`（DBサーバー）**

| ディレクティブ | 値 | 説明 |
|---|---|---|
| `listen_addresses` | `*` | LISTENするIPアドレス．`*`で全インターフェース，`localhost`でローカルのみ． |
| `port` | `5432` | LISTENするポート．デフォルト5432．通常変更不要． |
| `max_connections` | `100` | 同時接続数の上限．デフォルト100．重い処理が多いなら増やす． |
| `shared_buffers` | `128MB` | PostgreSQL専用のメモリキャッシュサイズ．物理メモリの25%程度が目安． |
| `password_encryption` | `scram-sha-256` | パスワード暗号化方式．PostgreSQL 14以降のデフォルト． |
| `data_directory` | `ConfigDir` | データファイルの保存先．`postgresql-15.service` の `Environment=PGDATA=/var/lib/pgsql/data` で指定される． |

**`/var/lib/pgsql/data/pg_hba.conf`（DBサーバー）**

書式：

```
TYPE  DATABASE  USER  ADDRESS  METHOD
```

本手順書では編集しない．デフォルトのlocalhostエントリのままにする．接続元のエントリ追加は利用側手順書（`postgresql-migration.md` / `zabbix-db-postgresql.md`）で実施．

**`/usr/lib/systemd/system/postgresql-15.service`（参考：パッケージ標準）**

AL2023の `postgresql15-server` パッケージは以下のunit ファイルを提供する．本手順書では編集しない．

```
[Service]
Environment=PGDATA=/var/lib/pgsql/data
...
```

> **補足：** カスタムパスを使う場合は `systemctl edit postgresql-15.service` で override が必要だが，本手順書では標準パスを使用するため不要．

------------------------------

### C. 用語解説

| 用語 | 説明 |
|------|------|
| PostgreSQL | オープンソースのリレーショナルデータベース管理システム（RDBMS）． |
| データベースクラスタ | 1つのPostgreSQLインスタンスが管理する複数DBの集合体．`initdb`で作成する単位． |
| `initdb` | データベースクラスタを初期化するコマンド．1度実行したらやり直しは難しい． |
| `PGDATA` | PostgreSQLのデータディレクトリを指す環境変数．AL2023の `postgresql15-server` パッケージでは `/var/lib/pgsql/data` がデフォルト． |
| ロケール | ソート順序や文字列比較ルール．`initdb`時のみ指定可能． |
| エンコーディング | 文字セット（UTF8等）．`initdb`時のみ指定可能． |
| テンプレートDB | 新規DB作成時の雛形（`template0`，`template1`）． |
| `postgresql-15-setup` | AL2023向けに用意された `initdb` のラッパースクリプト．標準パス `/var/lib/pgsql/data` に作成する． |
| `scram-sha-256` | PostgreSQL 14以降推奨のパスワード認証方式． |
| `pg_hba.conf` | クライアント認証設定ファイル．「どこからどのユーザーがどのDBにどう接続できるか」を定義． |

------------------------------

### D. 補足解説

#### D-1. なぜ標準パス `/var/lib/pgsql/data` を使用するか？

Amazon Linux 2023 の `postgresql15-server` パッケージは `/var/lib/pgsql/data` を標準データディレクトリとして以下のように整備している：

- `postgresql-15-setup --initdb` ラッパーが `/var/lib/pgsql/data` に自動作成
- systemd unit ファイル（`/usr/lib/systemd/system/postgresql-15.service`）が `Environment=PGDATA=/var/lib/pgsql/data` を参照
- パーミッション（700）・所有者（postgres）も自動設定

標準パスを使用することで，以下のメリットがある：

- **構築がシンプル**：systemd override が不要
- **パッケージ更新と整合**：パッケージ管理外の設定が無く，更新時の不整合リスクが少ない
- **トラブルシューティングが容易**：公式ドキュメント・コミュニティ情報がそのまま使える

本演習ではEBS追加ボリュームを使わない方針のため，標準パスを採用している．

> **補足：** 本番運用でデータディレクトリを別ボリュームに分離するメリット（EBS拡張の容易さ・バックアップ戦略の独立・障害分離など）もあるが，その場合は systemd override が必要になる．

#### D-2. ロケール選択の指針

- 後続でデータ移行する予定がある場合：**移行元と同じロケール**を必ず指定．
- 新規構築のみの場合：日本語環境なら `C` または `C.UTF-8` も選択肢になる．
- 本手順書のデフォルト `en_US.utf8` は `DB_構築手順書.md` の流れに合わせている．

> **注意：** ロケールはクラスタ全体の設定であり，後から変更するには全データの再投入が必要．

#### D-3. template0 vs template1

PostgreSQL のテンプレートDBの違い：

| テンプレート | 用途 | 特徴 |
|-----------|------|------|
| `template0` | 純粋なテンプレート | 変更不可．カスタムロケール／エンコーディング指定の `CREATE DATABASE` に使う |
| `template1` | カスタマイズ可能なテンプレート | デフォルトの雛形．`CREATE DATABASE` の元になる．拡張をプリインストール可 |

データ移行時 `createdb -T template0 -E UTF8 --locale=en_US.utf8 <DB名>` のように `template0` を指定するのは，`template1` がカスタマイズされていてもロケールを正確に設定するため．

#### D-4. password_encryption の違い（md5 vs scram-sha-256）

| 方式 | セキュリティ | 互換性 |
|------|------------|--------|
| `md5` | 弱（ハッシュ衝突攻撃に弱い） | PostgreSQL 9以前から対応 |
| `scram-sha-256` | 強（SCRAM-SHA-256ベース，チャレンジレスポンス） | PostgreSQL 10以降 |

- PostgreSQL 14以降のデフォルトは `scram-sha-256`．
- 既存システムで `md5` を使っている場合は，`postgresql.conf` の `password_encryption = md5` で互換維持可能．
- 個別の利用側手順書では，アプリケーションのドライバ対応状況に応じて選択する．

#### D-5. バージョン15以外を使う場合の差異

- `<PostgreSQLバージョン>` を `14` や `16` に置き換えるだけで，本手順書はおおむね流用可能．
- ただし以下に注意：
  - `postgresql-14-setup` / `postgresql-16-setup` のラッパー存在を確認
  - パッケージ名のサフィックスが変わる（`postgresql14-server` 等）
  - `/usr/bin/psql` がそのバージョンを向いているか確認
  - データディレクトリ標準パスは `/var/lib/pgsql/data` で共通

#### D-6. `dnf update` と `dnf upgrade` の違い

- DNFベースのAmazon Linux 2023では両者は同義．本手順書では `dnf update -y` に統一．
