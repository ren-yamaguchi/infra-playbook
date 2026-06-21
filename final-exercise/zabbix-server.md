# Zabbix 7.0 サーバー構築

------------------------------

## 1. ドキュメント情報

| 項目 | 内容 |
|------|------|
| 手順書名 | Zabbix 7.0 サーバー構築 |
| 作成日 | 2026-06-18 |
| 最終更新日 | 2026-06-18 |
| バージョン | v1.1 |
| 対象環境 | AWS（Amazon Linux 2023） |

> **改訂履歴**
>
> | バージョン | 日付 | 変更内容 |
> |-----------|------|---------|
> | v1.0 | 2026-06-18 | 初版作成（テンプレートに沿って再構成．構成図追加．プレースホルダーを意味ベース日本語に統一．`zabbix-db-postgresql.md`と命名を整合．パラメータ定義表を整理．SG設定セクションを追加．ロールバック手順を新設．各Stepに【実施対象】明示．句読点を「，．」に統一．「Zabbixサーバー」（長音記号あり）に統一．`systemctl enable --now`に統一．付録A〜D追加．） |
> | v1.1 | 2026-06-20 | 内部DNS（`nsd-private-redundancy.md`）の名前解決設定漏れに対応．Step 1を「タイムゾーン設定」から「システム設定（タイムゾーン・ホスト名・名前解決）」に拡張．パラメータ表に `<Zabbixサーバーのホスト名>` `<Primary DNSのIP>` `<Secondary DNSのIP>` 追加．ロールバック手順8-6「systemd-resolvedのDNS設定削除」を追加し，旧8-6〜8-8を8-7〜8-9に繰り上げ． |

------------------------------

## 2. 目的・概要

### 2-1. 目的

> 本手順書では，Amazon Linux 2023上にZabbix 7.0サーバーを構築し，別サーバー上のPostgreSQL（外部DB）に接続して監視を開始できる状態にする手順について説明する．
> 本手順書はZabbixサーバー側の作業のみを対象とする．DB作成は別手順書（`zabbix-db-postgresql.md`），エージェント側の設定は別手順書（`zabbix-agent2.md`）を参照すること．

### 2-2. 構成概要（アーキテクチャ）

```
[ローカルPC（ブラウザ）]
       │
       │ SSH ポートフォワーディング（8080→80）
       │
       ▼
[EC2: 踏み台サーバー（Public）]
       │
       │
┌──────┼─────────────── VPC ─────────────────────────────────┐
│      │                                                     │
│      ▼                                                     │
│  [EC2: Zabbixサーバー（Private）]                           │
│      ├─ zabbix-server-pgsql（10051番ポート）                │
│      ├─ httpd / php-fpm（80番ポート → Web GUI）             │
│      └─ zabbix-agent2（10050番ポート → 自身を監視）          │
│             │                                              │
│             │ TCP/5432（md5認証）                           │
│             ▼                                              │
│  [EC2: DBサーバー]                                          │
│      └─ PostgreSQL（<Zabbix用DB名>）                        │
│                                                            │
│                                                            │
│  [各監視対象サーバー]──────────────10050/10051───────────┐   │
│      └─ zabbix-agent2                                  │   │
│                                                        ▼   │
│                                          (Zabbixサーバーへ) │
└────────────────────────────────────────────────────────────┘
```

### 2-3. 完成イメージ（ゴール定義）

- [ ] `zabbix-server` サービスが `active (running)` かつ自動起動有効である
- [ ] `zabbix-agent2` サービスが `active (running)` かつ自動起動有効である
- [ ] `httpd` / `php-fpm` サービスが `active (running)` かつ自動起動有効である
- [ ] 10050番／10051番／80番ポートがLISTENしている
- [ ] DBへスキーマが正常投入されている（テーブル数150以上）
- [ ] 踏み台経由のポートフォワーディングでブラウザから Zabbix GUI にアクセスできる
- [ ] Web GUI 上で Admin ユーザーでログインできる
- [ ] Web GUI 上で Zabbix server ホストの ZBX アイコンが緑になっている

------------------------------

## 3. 前提条件・準備

### 3-1. 環境要件

| 項目 | 要件 |
|------|------|
| OS | Amazon Linux 2023 |
| CPU | 2コア以上推奨 |
| メモリ | 4GB以上推奨 |
| ストレージ | 20GB以上（監視データの蓄積量に応じて増加） |
| 依存パッケージ | `zabbix-server-pgsql`／`zabbix-web-pgsql`／`zabbix-apache-conf`／`zabbix-sql-scripts`／`zabbix-agent2`／`httpd`／`php-fpm`／`postgresql15`（クライアント） |

### 3-2. セキュリティグループ設定

#### 3-2-1. Zabbixサーバーのインバウンドルール

| タイプ | プロトコル | ポート範囲 | ソース | 説明 |
|-------|------------|----------|--------|------|
| SSH | TCP | 22 | 踏み台のSG | 踏み台経由のSSH接続 |
| HTTP | TCP | 80 | 踏み台のSG | Web GUI（ポートフォワーディング経由） |
| カスタムTCP | TCP | 10050 | 踏み台のSG | 自身のzabbix-agent2への接続 |
| カスタムTCP | TCP | 10051 | VPC CIDR | 各監視対象エージェントからのアクティブ接続 |

#### 3-2-2. Zabbixサーバーのアウトバウンドルール

| タイプ | プロトコル | ポート範囲 | 送信先 | 説明 |
|-------|------------|----------|--------|------|
| HTTPS | TCP | 443 | 0.0.0.0/0 | dnf／パッケージダウンロード |
| HTTP | TCP | 80 | 0.0.0.0/0 | dnfミラー |
| カスタムTCP | TCP | 5432 | DBサーバーのSG | DBへの接続 |
| カスタムTCP | TCP | 10050 | VPC CIDR | エージェントへのPassive接続 |

### 3-3. パラメータ定義表

> **注意：** 以下の値は作業前に環境に合わせて記入してから作業を開始すること．
> **重要：** **本手順書に実際のパスワードを直接記載しないこと**．パスワードはパスワード管理ツール経由で取り扱うこと．

#### 共通

| パラメータ名 | 値 | 説明 |
|------------|---|------|
| `<DBサーバーのIP>` | `<記入する>` | DBサーバーのプライベートIP |
| `<Zabbix用DB名>` | `<記入する>` | Zabbix用のデータベース名（`zabbix-db-postgresql.md`と揃える） |
| `<Zabbix用DBユーザー名>` | `<記入する>` | Zabbix用のDBユーザー名 |
| `<DBパスワード>` | パスワード管理ツール参照 | DBユーザー用パスワード（本書には記載しない） |
| `<ZabbixサーバーのプライベートIP>` | `<記入する>` | ZabbixサーバーのプライベートIP |
| `<Zabbixサーバーのホスト名>` | `<記入する>` | Zabbixサーバーのホスト名（例：`zabbix-server-1`） |
| `<Primary DNSのIP>` | `<記入する>` | 内部DNSプライマリ（AZ2のAPサーバー）のIP |
| `<Secondary DNSのIP>` | `<記入する>` | 内部DNSセカンダリ（AZ4のAPサーバー）のIP |
| `<踏み台サーバーのパブリックIP>` | `<記入する>` | 踏み台サーバーのパブリックIP（GUIアクセス用） |
| `<SSH鍵パス>` | `<記入する>` | ローカルPCのSSH秘密鍵パス（例：`~/.ssh/id_rsa`） |

#### ロールバック用（任意）

| パラメータ名 | 値 | 説明 |
|------------|---|------|
| `<作業前AMI名>` | `<記入する>` | 作業前スナップショット名（戻す場合のみ記入） |

### 3-4. リンク一覧

| 項目名 | 目的 |
|-------|------|
| https://www.zabbix.com/documentation/7.0/jp/manual | Zabbix 7.0公式ドキュメント |
| https://repo.zabbix.com/zabbix/7.0/amazonlinux/2023/x86_64/ | Zabbix公式リポジトリ |
| https://docs.aws.amazon.com/ja_jp/AWSEC2/latest/UserGuide/ec2-instance-lifecycle.html | AWS EC2 AMI作成手順 |

### 3-5. 作業前スナップショット取得（必須）

> **重要：** 構築作業前にEC2のAMIスナップショットを取得すること．

```
AWS コンソール → EC2 → 対象インスタンス（Zabbixサーバー）を選択
→ アクション → イメージとテンプレート → イメージを作成
→ イメージ名： zabbix-server-before-install-<日付>
→ 「イメージを作成」をクリック
```

> **注意：** スナップショット取得完了を確認してから構築作業を開始すること．

### 3-6. 事前確認

#### 3-6-1. PostgreSQL 15 クライアントインストール【実施対象：Zabbixサーバー】

DB接続確認とスキーマ投入のため，`psql` コマンドをインストールする．

```bash
# rootユーザーにスイッチ
sudo su -

# パッケージを最新化
dnf update -y

# PostgreSQL 15 クライアントインストール
dnf install -y postgresql15-server

# バージョン確認
psql --version
```

> **期待する結果：** `psql (PostgreSQL) 15.x` が表示される．

#### 3-6-2. DBサーバーへの疎通確認【実施対象：Zabbixサーバー】

```bash
# ping 確認
ping -c 3 <DBサーバーのIP>

# ポート5432の疎通確認
timeout 5 bash -c "echo >/dev/tcp/<DBサーバーのIP>/5432" && echo "ポート OK" || echo "ポート NG"
```

> **期待する結果：** packet loss 0% および「ポート OK」．

#### 3-6-3. DBサーバーのlisten_addresses確認【実施対象：DBサーバー】

DBサーバー側で実行：

```bash
grep listen_addresses /var/lib/pgsql/data/postgresql.conf
```

> **期待する結果：** `listen_addresses = '*'` が表示される．

> **補足：** 修正が必要な場合は別手順書（`zabbix-db-postgresql.md`の3-6-3）を参照．

#### 3-6-4. DB接続確認【実施対象：Zabbixサーバー】

```bash
# .pgpass を作成（パスワードを平文で環境変数に出さない）
echo "<DBサーバーのIP>:5432:<Zabbix用DB名>:<Zabbix用DBユーザー名>:<DBパスワード>" > ~/.pgpass
chmod 600 ~/.pgpass

# 接続テスト
psql -h <DBサーバーのIP> -U <Zabbix用DBユーザー名> -d <Zabbix用DB名> -c "\dt"
```

> **期待する結果：** `Did not find any relations.`（スキーマ投入前の正常状態）．

------------------------------

## 4. 構築手順（詳細）

> **注意事項**
> - コマンド中の `<山カッコ>` は自分の環境の値（パラメータ定義表の値）に置き換えること
> - 各Stepの見出し末尾に **【実施対象：●●】** を明示しているので，対象のサーバーで実施すること
> - **DB側の構築（`zabbix-db-postgresql.md`）が完了していることを前提とする**

------------------------------

### Step 1：システム設定（タイムゾーン・ホスト名・名前解決）【実施対象：Zabbixサーバー】

**目的：** タイムゾーン，ホスト名，内部DNSの名前解決先を設定する

#### 操作手順

```bash
# rootユーザーにスイッチ
sudo su -

# パッケージを最新化
dnf update -y

# タイムゾーンを Asia/Tokyo に設定
timedatectl set-timezone Asia/Tokyo
timedatectl status

# ホスト名を設定
hostnamectl set-hostname <Zabbixサーバーのホスト名>

# 通信確認ツール（nc）の存在確認
command -v nc
# → 何も表示されなければ未インストール

# nc が未インストールの場合のみ実行
dnf install -y nmap-ncat

# systemd-resolved 設定用ディレクトリ作成
mkdir -p /etc/systemd/resolved.conf.d

# 内部DNSを参照する設定ファイルを作成
vi /etc/systemd/resolved.conf.d/ex-local.conf
```

設定ファイルの記述内容：

```
[Resolve]
DNS=<Primary DNSのIP> <Secondary DNSのIP>
```

```bash
# systemd-resolved を再起動
systemctl restart systemd-resolved

# 名前解決確認
resolvectl status | grep -A 2 "Current DNS"
```

> **期待する結果：** `Time zone: Asia/Tokyo (JST, +0900)` および `Current DNS Server: <Primary DNSのIP>` が表示される．

> **注意：** ホスト名をシェルのプロンプトに反映させるため，作業途中で一度SSHを切断して再接続すること．

> **注意：** 本ステップは `nsd-private-redundancy.md` で内部DNSが構築されていることが前提．未構築の場合は名前解決確認はスキップして次のStepに進む．

------------------------------

### Step 2：Zabbix 7.0 リポジトリ追加【実施対象：Zabbixサーバー】

**目的：** Zabbix公式リポジトリをAmazon Linux 2023に登録する

#### 操作手順

```bash
rpm -Uvh https://repo.zabbix.com/zabbix/7.0/amazonlinux/2023/x86_64/zabbix-release-latest-7.0.amzn2023.noarch.rpm
```

> **補足：** `rpm -Uvh` の `-U` は「アップグレード（無ければインストール）」フラグ．`-v` は詳細表示，`-h` は進行状況のハッシュ表示．

> **注意：** 既にリポジトリが登録済みの場合はエラーになるが，そのまま続行して問題ない．

------------------------------

### Step 3：Zabbixパッケージインストール【実施対象：Zabbixサーバー】

**目的：** Zabbixサーバー本体・Webフロントエンド・エージェント等をインストールする

#### 操作手順

```bash
dnf install -y zabbix-server-pgsql zabbix-web-pgsql \
               zabbix-apache-conf zabbix-sql-scripts zabbix-agent2
```

> **期待する結果：** 5パッケージ＋依存関係がインストールされる．

------------------------------

### Step 4：DBテーブル確認（スキーマ投入前チェック）【実施対象：Zabbixサーバー】

**目的：** スキーマ投入前にDBが空であることを確認する

#### 操作手順

```bash
psql -h <DBサーバーのIP> -U <Zabbix用DBユーザー名> -d <Zabbix用DB名> -c "\dt"
```

> **期待する結果：** `Did not find any relations.`

> **注意：** 既存テーブルがある場合は重複エラーの原因になるため，必ず空であることを確認すること．

------------------------------

### Step 5：DBスキーマ投入【実施対象：Zabbixサーバー】

**目的：** Zabbixの初期テーブル群をDBに作成する

#### 操作手順

```bash
zcat /usr/share/zabbix-sql-scripts/postgresql/server.sql.gz | \
  psql -h <DBサーバーのIP> -U <Zabbix用DBユーザー名> -d <Zabbix用DB名>
```

> **注意：** 投入に数分かかる場合がある．

> **確認：** 投入後にテーブルが作成されたか確認する．

```bash
psql -h <DBサーバーのIP> -U <Zabbix用DBユーザー名> -d <Zabbix用DB名> -c "\dt" | wc -l
# → 150以上の行数が返れば正常
```

------------------------------

### Step 6：zabbix_server.conf設定【実施対象：Zabbixサーバー】

**目的：** Zabbixサーバーがリモートの外部DBへ接続するための設定を行う

#### 操作手順

```bash
# バックアップ作成
cp -p /etc/zabbix/zabbix_server.conf /etc/zabbix/zabbix_server.conf.org

# 編集
vi /etc/zabbix/zabbix_server.conf
```

設定ファイルの記述内容（既存のコメントアウト行を以下に置き換え）：

```
DBHost=<DBサーバーのIP>
DBName=<Zabbix用DB名>
DBUser=<Zabbix用DBユーザー名>
DBPassword=<DBパスワード>
DBPort=5432
```

> **重要：** 編集後のファイルパーミッションを確認すること（600 または 640 が望ましい）．

```bash
ls -la /etc/zabbix/zabbix_server.conf
chmod 640 /etc/zabbix/zabbix_server.conf
chown root:zabbix /etc/zabbix/zabbix_server.conf
```

> **補足：** パスワードを含む設定ファイルのため，グループ `zabbix` のみが読めるように制限する．

------------------------------

### Step 7：Zabbixサービス起動【実施対象：Zabbixサーバー】

**目的：** Zabbixサーバーとエージェントを起動し，自動起動を有効化する

#### 操作手順

```bash
systemctl enable --now zabbix-server zabbix-agent2
systemctl status zabbix-server --no-pager
systemctl status zabbix-agent2 --no-pager
```

> **期待する結果：** いずれも `Active: active (running)` および `enabled` が表示される．

------------------------------

### Step 8：httpdとphp-fpmの起動【実施対象：Zabbixサーバー】

**目的：** Web GUI を提供するhttpdとphp-fpmを起動する

#### 操作手順

```bash
systemctl enable --now httpd php-fpm
systemctl status httpd --no-pager
systemctl status php-fpm --no-pager
```

> **期待する結果：** いずれも `Active: active (running)` および `enabled` が表示される．

------------------------------

### Step 9：Web GUI 初期セットアップ【実施対象：ローカルPC・Web GUI】

**目的：** ブラウザの初期セットアップウィザードでDB接続情報を入力し，`zabbix.conf.php` を自動生成する

#### 操作手順

ローカルPCで以下のSSHコマンドを実行し，踏み台経由のポートフォワーディングを開始する：

```bash
ssh -i <SSH鍵パス> \
    -L 8080:<ZabbixサーバーのプライベートIP>:80 \
    ec2-user@<踏み台サーバーのパブリックIP> \
    -N
```

ブラウザで以下にアクセス：

```
http://localhost:8080/zabbix
```

ウィザードの各画面で以下を入力：

| 画面 | 入力内容 |
|------|---------|
| Welcome | 「Next step」をクリック |
| Check of pre-requisites | 全項目「OK」になっていることを確認．「Next step」をクリック |
| Configure DB connection | Database type: PostgreSQL／Database host: `<DBサーバーのIP>`／Database port: 5432／Database name: `<Zabbix用DB名>`／User: `<Zabbix用DBユーザー名>`／Password: `<DBパスワード>` |
| Settings | Zabbix server name: 任意の名前（例：`zabbix-server`）／Default time zone: `Asia/Tokyo` |
| Summary | 入力内容を確認して「Next step」 |
| Install | 「Finish」をクリック |

> **補足：** 入力した値は自動的に `/etc/zabbix/web/zabbix.conf.php` に書き込まれる．

------------------------------

### Step 10：Web GUI 設定ファイル確認【実施対象：Zabbixサーバー】

**目的：** ウィザードで生成されたWeb GUI設定ファイルを確認する

#### 操作手順

```bash
cat /etc/zabbix/web/zabbix.conf.php
```

> **確認：** 以下のような行があること：
>
> ```php
> $DB['TYPE']     = 'POSTGRESQL';
> $DB['SERVER']   = '<DBサーバーのIP>';
> $DB['DATABASE'] = '<Zabbix用DB名>';
> $DB['USER']     = '<Zabbix用DBユーザー名>';
> $DB['PASSWORD'] = '<DBパスワード>';
> ```

> **重要：** このファイルはパスワードを含むためパーミッションを確認すること．

```bash
ls -la /etc/zabbix/web/zabbix.conf.php
# → -rw-r----- root:apache であること
```

------------------------------

### Step 11：Web GUI ログイン【実施対象：ローカルPC・Web GUI】

**目的：** Web GUI に初回ログインし，初期パスワードを変更する

#### 操作手順

ブラウザで `http://localhost:8080/zabbix` にアクセスし，以下でログイン：

| 項目 | 値 |
|------|----|
| ユーザー名 | `Admin`（A は大文字） |
| パスワード | `zabbix` |

> **重要：** 初回ログイン後，**必ずパスワードを変更すること**．デフォルト認証情報のまま運用してはならない．
>
> 変更方法： Web GUI → 右上ユーザーアイコン → User profile → Change password

------------------------------

## 5. 動作確認・検証

> 構築完了後，以下の確認をすべてパスしたら構築成功とみなす．

### 5-1. 確認チェックリスト

- [ ] **確認①**：`zabbix-server` が `active (running)` かつ自動起動有効
- [ ] **確認②**：`zabbix-agent2` が `active (running)` かつ自動起動有効
- [ ] **確認③**：`httpd` / `php-fpm` が `active (running)` かつ自動起動有効
- [ ] **確認④**：10050／10051／80番ポートがLISTENしている
- [ ] **確認⑤**：踏み台経由でWeb GUIにアクセスできる
- [ ] **確認⑥**：Adminでログインできる（パスワード変更済み）
- [ ] **確認⑦**：「Zabbix server」ホストでZBXアイコンが緑になっている

------------------------------

### 確認①〜③：サービス状態確認【実施対象：Zabbixサーバー】

```bash
systemctl status zabbix-server --no-pager
systemctl status zabbix-agent2 --no-pager
systemctl status httpd --no-pager
systemctl status php-fpm --no-pager
```

> **期待する結果：** いずれも `active (running)` および `enabled`．

------------------------------

### 確認④：リッスンポート確認【実施対象：Zabbixサーバー】

```bash
ss -tlnp | grep -E ":(80|10050|10051) "
```

> **期待する結果：**
>
> ```
> LISTEN 0 ... 0.0.0.0:80    ...   users:(("httpd",pid=...))
> LISTEN 0 ... 0.0.0.0:10050 ...   users:(("zabbix_agent2",pid=...))
> LISTEN 0 ... 0.0.0.0:10051 ...   users:(("zabbix_server",pid=...))
> ```

------------------------------

### 確認⑤：Web GUI アクセス確認【実施対象：ローカルPC】

ローカルPCで以下を実行（既にStep 9で起動済みなら継続）：

```bash
ssh -i <SSH鍵パス> \
    -L 8080:<ZabbixサーバーのプライベートIP>:80 \
    ec2-user@<踏み台サーバーのパブリックIP> \
    -N
```

ブラウザで以下にアクセス：

```
http://localhost:8080/zabbix
```

> **期待する結果：** Zabbixのログイン画面が表示される．

------------------------------

### 確認⑥：Adminログイン確認【実施対象：Web GUI】

Step 11で変更したパスワードでログインできることを確認．

------------------------------

### 確認⑦：Zabbix server ホスト の状態確認【実施対象：Web GUI】

```
Web GUI → データ収集 → ホスト → Zabbix server
→ インターフェースの IP が 127.0.0.1:10050 になっていること
→ Availability列のZBXアイコンが緑になっていること
```

エージェント側の設定確認（参考）：

```bash
grep "^Hostname="     /etc/zabbix/zabbix_agent2.conf
grep "^Server="       /etc/zabbix/zabbix_agent2.conf
grep "^ServerActive=" /etc/zabbix/zabbix_agent2.conf
```

> **重要：** `Hostname` の値は Web GUI のホスト登録名と一致している必要がある．

------------------------------

### 5-2. ログ確認

```bash
tail -n 50 /var/log/zabbix/zabbix_server.log
tail -n 50 /var/log/httpd/error_log
tail -n 50 /var/log/zabbix/zabbix_agent2.log
```

> **注意：** `Error` や `Failed` といったログが出ていないか確認．

------------------------------

## 6. トラブルシューティング

### よくあるエラーと対処法

------------------------------

#### エラー①：zabbix-serverが起動しない

**原因：** DB接続情報の誤り，もしくはDBへの疎通不可．

**対処法：**

```bash
journalctl -u zabbix-server -n 50

# DB接続情報を確認
grep -E "^DB" /etc/zabbix/zabbix_server.conf

# DBへの疎通確認
ping <DBサーバーのIP>
timeout 5 bash -c "echo >/dev/tcp/<DBサーバーのIP>/5432" && echo "OK" || echo "NG"
```

------------------------------

#### エラー②：Web GUI にアクセスできない

**原因：** httpdの停止，もしくはポートフォワーディング不通．

**対処法：**

```bash
# httpd 状態確認
systemctl status httpd
curl -I http://localhost/zabbix

# 必要なら再起動
systemctl restart httpd php-fpm
```

ローカルPC側のポートフォワーディングコマンドが起動中か確認．切断されていれば再実行．

------------------------------

#### エラー③：DB接続エラー（pg_hba.conf関連）

**原因：** DBサーバー側の`pg_hba.conf`に接続許可エントリがない．

**対処法（DBサーバー側）：**

```bash
# pg_hba.conf のパス確認
sudo -u postgres psql -c "SHOW hba_file;"

# 別手順書（zabbix-db-postgresql.md）のStep 5を参照してエントリを追加
# 追加後にリロード
sudo -u postgres psql -c "SELECT pg_reload_conf();"
```

------------------------------

#### エラー④：ZBXアイコンが灰色のまま

**原因：** `zabbix_agent2.conf` の `Hostname` 値とGUI登録ホスト名が不一致．

**対処法：**

```bash
# 現在のHostname確認
grep "^Hostname=" /etc/zabbix/zabbix_agent2.conf

# 必要なら修正
vi /etc/zabbix/zabbix_agent2.conf

# 再起動
systemctl restart zabbix-agent2
```

GUI 側でも：

```
データ収集 → ホスト → Zabbix server → 編集
→ インターフェースの IP を 127.0.0.1 に変更 → 更新
```

------------------------------

#### エラー⑤：SELinuxでDB接続が拒否される

**原因：** SELinuxが有効でhttpdからDBへの接続を許可していない．

**対処法：**

```bash
# SELinux状態確認
getenforce
# → Enforcing の場合は以下のbooleanを有効化

setsebool -P httpd_can_network_connect_db on
setsebool -P httpd_can_network_connect on
```

------------------------------

### ログの確認場所

| ログの種類 | 場所（パス） |
|-----------|------------|
| Zabbix Server ログ | `/var/log/zabbix/zabbix_server.log` |
| Zabbix Agent2 ログ | `/var/log/zabbix/zabbix_agent2.log` |
| httpd エラーログ | `/var/log/httpd/error_log` |
| httpd アクセスログ | `/var/log/httpd/access_log` |
| systemd ログ | `journalctl -u zabbix-server` 等 |

------------------------------

## 7. 参考リソース・関連資料

| 資料名 | URL / 場所 | 補足 |
|-------|-----------|------|
| Zabbix 7.0 公式ドキュメント | https://www.zabbix.com/documentation/7.0/jp/manual | Zabbix全般 |
| Zabbix 公式リポジトリ | https://repo.zabbix.com/zabbix/7.0/amazonlinux/2023/x86_64/ | パッケージ取得元 |
| Amazon Linux 2023 ガイド | https://docs.aws.amazon.com/ja_jp/linux/al2023/ug/ | OS全般 |
| 別手順書：Zabbix用DB構築 | `zabbix-db-postgresql.md` | DB側の構築（前提手順） |
| 別手順書：Zabbix Agent2 構築 | `zabbix-agent2.md` | 監視対象サーバー側の設定 |

------------------------------

## 8. ロールバック手順

### 8-1. サービスの停止と無効化【実施対象：Zabbixサーバー】

```bash
systemctl disable --now zabbix-server zabbix-agent2 httpd php-fpm
```

### 8-2. パッケージのアンインストール【実施対象：Zabbixサーバー】

```bash
dnf remove -y zabbix-server-pgsql zabbix-web-pgsql \
              zabbix-apache-conf zabbix-sql-scripts zabbix-agent2
```

### 8-3. 設定ファイルとログの削除（任意）【実施対象：Zabbixサーバー】

```bash
rm -rf /etc/zabbix /var/log/zabbix
```

### 8-4. リポジトリ登録の削除【実施対象：Zabbixサーバー】

```bash
rpm -e zabbix-release
```

### 8-5. DB側のクリーンアップ【実施対象：DBサーバー】

DB側のロールバックは別手順書（`zabbix-db-postgresql.md` の 8章）を参照．

### 8-6. systemd-resolvedのDNS設定削除【実施対象：Zabbixサーバー】

```bash
rm -f /etc/systemd/resolved.conf.d/ex-local.conf
systemctl restart systemd-resolved
```

> **重要：** 内部DNS停止状態で `systemd-resolved` が内部DNSを指したままだと，本サーバーの名前解決が失敗する．本Stepでデフォルトの解決経路に戻すこと．

### 8-7. 接続テスト用設定の削除【実施対象：Zabbixサーバー】

```bash
rm -f ~/.pgpass
```

### 8-8. 完全リカバリ：AMIスナップショットからの復元【実施対象：Zabbixサーバー】

```
AWS コンソール → EC2 → AMI → <作業前AMI名> を選択
→ 「AMIからインスタンスを起動」
→ 既存サーバーを停止／削除し，新インスタンスに切替
```

### 8-9. 完了確認【実施対象：Zabbixサーバー】

```bash
systemctl status zabbix-server 2>&1 | head -3
# → Unit zabbix-server.service could not be found.

rpm -qa | grep zabbix
# → 何も表示されないこと
```

> **注意：** `dnf update` で適用したパッケージ更新は取り消さない（依存破壊リスク回避）．

------------------------------

## 付録

### A. コマンド解説

| コマンド | 説明 |
|---------|------|
| `timedatectl set-timezone Asia/Tokyo` | システムのタイムゾーンを設定． |
| `rpm -Uvh <RPM URL>` | RPMパッケージをURLから取得しインストール／アップグレード．`-U`はアップグレード，`-v`は詳細，`-h`は進行バー． |
| `dnf install -y <パッケージ>` | dnfからパッケージを非対話インストール． |
| `dnf remove -y <パッケージ>` | dnfからパッケージを非対話アンインストール． |
| `zcat <gzファイル>` | gzipファイルを伸長して標準出力へ． |
| `psql -h <ホスト> -U <ユーザー> -d <DB>` | リモートPostgreSQLへ接続． |
| `systemctl enable --now <サービス>` | サービスを起動し，自動起動を有効化． |
| `systemctl status <サービス> --no-pager` | サービスの稼働状態を確認． |
| `systemctl is-enabled <サービス>` | 自動起動有効／無効の確認． |
| `ss -tlnp` | TCPでLISTEN中のポートとプロセスを一覧表示． |
| `journalctl -u <サービス> -n <行数>` | systemdログを末尾N行表示． |
| `getenforce` | SELinuxの動作モード表示（Enforcing／Permissive／Disabled）． |
| `setsebool -P <boolean> on` | SELinuxのbooleanを永続的に有効化． |
| `ssh -i <鍵> -L <ローカルポート>:<転送先>:<ポート> <ユーザー>@<踏み台> -N` | SSHポートフォワーディング．`-L`はローカル転送，`-N`はコマンド実行なし． |
| `chmod 640 <ファイル>` | パーミッション設定（オーナー読み書き，グループ読み，その他なし）． |
| `chown <ユーザー>:<グループ> <ファイル>` | 所有者・所有グループ変更． |

------------------------------

### B. 設定ファイル解説

**`/etc/zabbix/zabbix_server.conf`（Zabbixサーバー）**

```
DBHost=<DBサーバーのIP>
DBName=<Zabbix用DB名>
DBUser=<Zabbix用DBユーザー名>
DBPassword=<DBパスワード>
DBPort=5432
```

- `DBHost`：DB接続先のホスト名／IP．`localhost` の場合はUnixドメインソケット，それ以外はTCP接続．
- `DBName`：接続先のデータベース名．
- `DBUser`／`DBPassword`：接続用の認証情報．
- `DBPort`：接続先ポート．PostgreSQLの標準は5432．

**`/etc/zabbix/web/zabbix.conf.php`（Zabbixサーバー）**

Web GUIの初期セットアップウィザードで自動生成される．主要設定：

- `$DB['TYPE']`：DBエンジン種別（PostgreSQL／MySQL等）．
- `$DB['SERVER']`：DB接続先．
- `$DB['DATABASE']`／`$DB['USER']`／`$DB['PASSWORD']`：接続情報．

**`/etc/zabbix/zabbix_agent2.conf`（Zabbixサーバー上のagent2）**

- `Server=127.0.0.1`：Passiveチェック時の接続元（Zabbixサーバー自身の場合は127.0.0.1）．
- `ServerActive=127.0.0.1`：Activeチェックの送信先．
- `Hostname=Zabbix server`：このエージェントを識別する名前．**Web GUIのホスト登録名と一致必須**．

------------------------------

### C. 用語解説

| 用語 | 説明 |
|------|------|
| Zabbix | オープンソースの統合監視ソフトウェア．サーバー・ネットワーク・アプリ等を一元監視できる． |
| Zabbix Server | 監視データを集約・保存・評価する中央サーバー．`zabbix-server-pgsql`等のパッケージで提供． |
| Zabbix Agent2 | 監視対象サーバーで動作するエージェント．プラグイン対応．`zabbix-agent2` パッケージで提供． |
| Zabbix Web Frontend | Web GUI．`zabbix-web-pgsql` 等のパッケージで提供． |
| Passiveチェック | サーバー → エージェントの方向でメトリクスを問い合わせる方式．Agentがポート10050をLISTEN． |
| Activeチェック | エージェント → サーバーの方向でメトリクスを送信する方式．Serverがポート10051をLISTEN． |
| Item | 監視項目（CPU使用率，ディスク容量等）．テンプレートで束ねて管理可能． |
| Trigger | 監視項目の閾値判定式．条件成立で障害イベント発火． |
| Template | アイテム・トリガー・グラフ等をまとめたテンプレート．ホストに割り当てて再利用． |
| ZBXアイコン | Web GUI上でホストのZabbix Agent接続状態を示すアイコン．緑=正常，赤=接続不可，灰色=未試行． |
| Hostname | Zabbixエージェント設定の識別子．Web GUI上のホスト名と一致必須． |
| SSHポートフォワーディング | SSH越しにローカルポートと遠隔ポートをつなぐ機能．プライベートサブネット内のサービスに踏み台経由でアクセスする際に使用． |
| SELinux | RHEL系で標準のセキュリティ強化機構．`Enforcing`時はアクセス制御が厳格． |

------------------------------

### D. 補足解説

- **なぜDBを別サーバーに分けるか？**
  - Zabbix Server単体ならDBを同居させても動作するが，監視対象が増えるとDBへの書き込み負荷が大きくなる．
  - DBを別サーバーにすることで，DB側のリソースを独立スケールできる．
  - DBサーバーは複数のサービス（Zabbix以外）で共用しやすい．
  - 障害時の切り分けが容易（Zabbix Serverの障害とDBの障害を区別できる）．

- **Web GUI 初期セットアップウィザードの役割**
  - 入力された値を `/etc/zabbix/web/zabbix.conf.php` に書き出す．
  - DB接続確認 → スキーマ存在確認を自動で行う．
  - スキーマが投入されていない状態でウィザードを起動するとエラーになるため，必ずStep 5（スキーマ投入）の後にStep 9を実行すること．

- **SELinuxの `httpd_can_network_connect_db` について**
  - SELinuxが `Enforcing` の場合，httpdプロセスは標準ではネットワーク経由のDB接続を許可されない．
  - `httpd_can_network_connect_db` booleanを有効化することで，httpd → DBサーバーへのTCP接続が許可される．
  - `-P` オプションで永続化（再起動後も有効）．

- **ZBXアイコンの色の意味**
  - **緑**：エージェントへの接続成功，正常監視中．
  - **赤**：接続失敗（エージェント停止／ネットワーク／SG／Hostname不一致 等）．
  - **灰色**：まだ接続試行されていない（設定変更直後の一時的状態）．

- **HostnameとZabbix GUIホスト名の一致重要性**
  - Active接続時，エージェントは自分の `Hostname` 値をサーバーに送信する．
  - サーバーは送られてきた `Hostname` でGUI上のホストを検索し，マッチしたホストにメトリクスを紐付ける．
  - 不一致だとアクティブチェックが全て破棄され，ZBXアイコンが緑にならない．

- **初期パスワード `zabbix` のリスク**
  - インストール直後の `Admin / zabbix` はインターネット上で広く知られたデフォルト認証情報．
  - 本手順書ではポートフォワーディング経由でVPC内に閉じているが，**運用開始前に必ず変更すること**．
  - 加えて，Web GUI上で管理者以外のユーザーを作成し，必要最小権限を割り当てるのが望ましい．

- **ポートフォワーディングの仕組み**
  - `ssh -L 8080:<ZabbixサーバーのプライベートIP>:80 ec2-user@<踏み台>` の意味：
    - ローカルPCの8080番ポートへの接続を，SSHトンネル経由で踏み台サーバーまで送る．
    - 踏み台サーバーから `<ZabbixサーバーのプライベートIP>:80` へさらに転送する．
  - `-N` オプションはリモートコマンドを実行しない（トンネルだけ張る）指定．
  - ローカルブラウザから `http://localhost:8080/` にアクセスすると，あたかもZabbixサーバーに直接アクセスしているように見える．

- **`dnf update` と `dnf upgrade` の違い**
  - DNFベースのAmazon Linux 2023では両者は同義．本手順書では `dnf update -y` に統一．
