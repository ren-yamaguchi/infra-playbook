# 【Ansibleを用いたZabbix + PostgreSQL】環境構築手順書

---

## 1. ドキュメント情報

| 項目 | 内容 |
|------|------|
| 手順書名 | Ansibleを用いたZabbix + PostgreSQL 環境構築手順書 |
| 作成日 | 2026-06-16 |
| 最終更新日 | 2026-06-16 |
| バージョン | v1.0 |
| 対象環境 | AWS |

> **改訂履歴**
>
> | バージョン | 日付 | 変更内容 |
> |-----------|------|---------|
> | v1.0 | 2026-06-16 | 初版作成 |

---

## 2. 目的・概要

### 2-1. 目的

本手順書では、**Ansible** を用いて Zabbix サーバと PostgreSQL を同一サーバ内に自動構築する。
Ansible を使うことで、手動での構築作業（OSパッケージ更新、DBインストール、Zabbix インストール、各種設定ファイルの編集など）を **1コマンドで再現可能** にする。

### 2-2. Ansible とは（初学者向けの補足）

Ansible は、サーバの構築・設定を **コード（YAML）で自動化** するためのツールである。
主な特徴は以下のとおり。

| 用語 | 説明 |
|------|------|
| **操作端末（コントロールノード）** | Ansible 本体をインストールして、構築コマンドを実行する側のサーバ |
| **ターゲットノード（マネージドノード）** | Ansible によって構築される側のサーバ。Ansible 本体のインストールは不要 |
| **Playbook（プレイブック）** | 「何をどう構築するか」を YAML で書いた手順書ファイル（本手順書では `zabbix-server.yml`） |
| **Inventory（インベントリ）** | 「どのサーバに対して構築するか」を書いたファイル（本手順書では `inventory.ini`） |
| **モジュール** | Ansible が用意している部品。`dnf`、`systemd`、`lineinfile` など、用途別に多数存在 |
| **冪等性（べきとうせい）** | 「何度実行しても同じ結果になる」性質。Ansible のタスクは原則これを満たすため、途中で失敗しても再実行できる |

### 2-3. 構成概要（アーキテクチャ）

```
        [操作端末 EC2]                       [ターゲットノード EC2]
   (Ansible コントロール)                    (Zabbix-Server + PostgreSQL)
        ┌──────────────┐    SSH (22)        ┌──────────────────────┐
        │  ansible     │ ─────────────────> │  Zabbix Server       │
        │  inventory   │                    │  Zabbix Agent2       │
        │  playbook    │                    │  Apache (httpd)      │
        └──────────────┘                    │  PostgreSQL 15       │
                                            └──────────────────────┘
                                                プライベートIP:
                                                <ターゲットノードのプライベートIP>
```

### 2-4. 完成イメージ（ゴール定義）

- [ ] 操作端末に Ansible がインストールされている
- [ ] `ansible-playbook` コマンドが正常に完了する（failed=0）
- [ ] ターゲットノードに PostgreSQL 15 がインストールされ、起動している
- [ ] ターゲットノードに Zabbix Server / Agent2 / Apache がインストールされ、起動している
- [ ] ブラウザから `http://<ターゲットノードのパブリックIP>/zabbix` でログイン画面が表示される

---

## 3. 前提条件・準備

### 3-1. 環境要件

| 項目 | 操作端末 | ターゲットノード |
|------|----------|-----------------|
| OS | Amazon Linux 2023 | Amazon Linux 2023 |
| インスタンスタイプ | t2.micro | t2.small 以上推奨 |
| Ansible | 本手順書内でインストール | 不要 |
| Python3 | プリインストール済み | プリインストール済み |
| SSH鍵 | ターゲットノードにログインできる鍵を配置 | 上記の鍵で `ec2-user` がログインできる状態 |

### 3-2. ネットワーク設定（軽く説明）

最低限、以下の通信が許可されている必要がある。
詳細なセキュリティグループの設定は別途行うこと。

| 通信元 | 通信先 | ポート | 用途 |
|--------|--------|--------|------|
| 操作端末 | ターゲットノード | TCP 22 | Ansible による SSH 接続 |
| ローカルPC | ターゲットノード | TCP 80 | ブラウザから Zabbix WebUI へアクセス |
| ローカルPC | 操作端末 | TCP 22 | 操作端末への SSH ログイン |

> **補足:** 操作端末とターゲットノードは同一 VPC 内に配置することを想定。
> プライベートIP `<ターゲットノードのプライベートIP>` で SSH 接続できる状態にしておくこと。

### 3-3. 用意する2つのファイル

本手順書では、以下の2つのファイルを使用する。
ファイルの中身は **「付録 A. Playbook の各タスク解説」** で詳しく説明する。

| ファイル名 | 役割 |
|-----------|------|
| `inventory.ini` | 構築対象のサーバ情報（IPアドレスなど） |
| `zabbix-server.yml` | 構築手順本体（Playbook） |

---

## 4. 構築手順

> **注意事項**
> - コマンド中の `<山カッコ>` は自分の環境の値に置き換えること
> - 操作端末・ターゲットノードを取り違えないよう、各 Step の **「作業場所」** を必ず確認してから実行すること

---

### Step 1: 操作端末への Ansible インストール

**作業場所:** 操作端末（コントロールノード）

**目的:** Playbook を実行するための Ansible 本体をインストールする。

#### 操作手順

```bash
# 1. パッケージ全体を更新
sudo dnf update -y

# 2. Ansible のインストール
sudo dnf install -y ansible

# 3. インストール確認（バージョンが表示されればOK）
ansible --version
```

#### 補足

- Amazon Linux 2023 の標準リポジトリに Ansible が含まれているため、追加リポジトリは不要。
- `ansible --version` で Python のパスと Ansible のバージョンが確認できる。

---

### Step 2: Ansible Collection の追加インストール

**作業場所:** 操作端末

**目的:** Playbook で使用する **community 系モジュール** を利用可能にする。

Playbook 内では `community.general.timezone` や `community.postgresql.postgresql_user` など、標準モジュール以外を使用している。これらは **Collection** という形式で別途インストールする必要がある。

#### 操作手順

```bash
# community.general（timezoneモジュール用）
ansible-galaxy collection install community.general

# community.postgresql（PostgreSQL操作モジュール用）
ansible-galaxy collection install community.postgresql

# インストール済みCollectionの確認
ansible-galaxy collection list
```

#### 補足

| Collection名 | 含まれる主なモジュール | 本手順書での用途 |
|--------------|----------------------|-----------------|
| `community.general` | `timezone` | タイムゾーンを Asia/Tokyo に設定 |
| `community.postgresql` | `postgresql_user` `postgresql_db` `postgresql_pg_hba` | DBユーザ作成、DB作成、pg_hba.conf 編集 |

---

### Step 3: SSH鍵の配置と疎通確認

**作業場所:** 操作端末

**目的:** Ansible がターゲットノードに SSH 接続できる状態を確立する。

#### 操作手順

```bash
# 1. 秘密鍵を操作端末に配置（ローカルPCからscp等で転送）
#    例: ~/.ssh/zabbix-key.pem に配置したと仮定

# 2. 秘密鍵のパーミッションを600に設定
chmod 600 ~/.ssh/zabbix-key.pem

# 3. ターゲットノードへSSH接続テスト
ssh -i ~/.ssh/zabbix-key.pem ec2-user@<ターゲットノードのプライベートIP>

# 接続できたら exit で戻る
exit
```

#### 補足

- パーミッションが甘い（644など）と SSH 側で鍵が拒否される。必ず `600` に設定。
- 初回接続時に `Are you sure you want to continue connecting?` と聞かれたら `yes` を入力。

---

### Step 4: 作業ディレクトリの作成と2ファイルの配置

**作業場所:** 操作端末

**目的:** Ansible 実行用のディレクトリを作成し、`inventory.ini` と `zabbix-server.yml` を配置する。

#### 操作手順

```bash
# 1. 作業ディレクトリ作成
mkdir -p ~/ansible-zabbix
cd ~/ansible-zabbix

# 2. inventory.ini を配置（vi等で作成、または scp 等で転送）
vi inventory.ini

# 3. zabbix-server.yml を配置（vi等で作成、または scp 等で転送）
vi zabbix-server.yml

# 4. ファイル一覧確認
ls -l
```

#### inventory.ini の中身

```ini
[zabbix_servers]
zabbix_server ansible_host=<ターゲットノードのプライベートIP>

[zabbix_servers:vars]
#ansible_user=ec2-user
db_host=<ターゲットノードのプライベートIP>
zabbix_server_host=<ターゲットノードのプライベートIP>
```

> **注意:** `zabbix-server.yml` の中の `vars` セクションにある `zabbix_server_host` / `db_host` も、ターゲットノードのプライベートIPに合わせて修正すること。

---

### Step 5: ansible.cfg の作成（任意だが推奨）

**作業場所:** 操作端末（`~/ansible-zabbix` 配下）

**目的:** SSH鍵の指定や `ec2-user` の指定を毎回コマンドオプションで渡さなくて済むようにする。

#### 操作手順

```bash
cat > ansible.cfg << 'EOF'
[defaults]
inventory = ./inventory.ini
remote_user = ec2-user
private_key_file = ~/.ssh/zabbix-key.pem
host_key_checking = False
EOF
```

#### 補足

- `host_key_checking = False` にしておくと、初回接続時の `yes/no` プロンプトをスキップできる。
- 鍵のパスは環境に合わせて修正すること。

---

### Step 6: Ansible からターゲットノードへの疎通確認（ping）

**作業場所:** 操作端末

**目的:** Playbook を実行する前に、Ansible 自体がターゲットに到達できるか確認する。

#### 操作手順

```bash
cd ~/ansible-zabbix
ansible zabbix_servers -m ping
```

#### 期待される結果

```
zabbix_server | SUCCESS => {
    "ansible_facts": {
        "discovered_interpreter_python": "/usr/bin/python3"
    },
    "changed": false,
    "ping": "pong"
}
```

`SUCCESS` と `pong` が表示されれば疎通OK。
失敗する場合は **6. トラブルシューティング** を参照。

---

### Step 7: Playbook の構文チェック（dry-run）

**作業場所:** 操作端末

**目的:** YAML の文法エラーや、明らかな記述ミスを実行前に検出する。

#### 操作手順

```bash
cd ~/ansible-zabbix

# 構文チェックのみ
ansible-playbook zabbix-server.yml --syntax-check
```

#### 期待される結果

```
playbook: zabbix-server.yml
```

エラーが何も表示されなければOK。

---

### Step 8: Playbook の実行

**作業場所:** 操作端末

**目的:** Zabbix サーバと PostgreSQL を自動構築する。

#### 操作手順

```bash
cd ~/ansible-zabbix
ansible-playbook zabbix-server.yml
```

#### 期待される結果

実行が進むと、Playbook 内の各タスクが順に表示される。
最後に以下のような **PLAY RECAP** が出力され、`failed=0` であれば成功。

```
PLAY RECAP *********************************************************************
zabbix_server : ok=20  changed=18  unreachable=0  failed=0  skipped=0  rescued=0  ignored=0
```

#### 補足

- 初回実行はパッケージダウンロードや DB スキーマ投入があり、**5〜10分程度** かかる。
- 途中で失敗した場合、原因を修正して **同じコマンドを再実行** すればよい（冪等性により、成功済みのタスクはスキップされる）。

---

## 5. 動作確認・検証

### 5-1. 確認チェックリスト

- [ ] **確認①**: ターゲットノードで PostgreSQL が起動している
- [ ] **確認②**: ターゲットノードで Zabbix Server / Agent2 / httpd が起動している
- [ ] **確認③**: ブラウザから Zabbix WebUI のセットアップ画面が表示される

---

### 確認①: PostgreSQL の起動確認

**作業場所:** ターゲットノード（SSH でログインして実行）

```bash
sudo systemctl status postgresql
```

`Active: active (running)` と表示されればOK。

---

### 確認②: Zabbix 関連サービスの起動確認

**作業場所:** ターゲットノード

```bash
sudo systemctl status zabbix-server zabbix-agent2 httpd
```

3つすべてが `Active: active (running)` であればOK。

---

### 確認③: WebUI の表示確認

**作業場所:** ローカルPCのブラウザ

```
http://<ターゲットノードのパブリックIP>/zabbix
```

Zabbix のセットアップウィザード（または ログイン画面）が表示されればOK。

> **補足:** 初回アクセス時はセットアップウィザードが表示される。
> Playbook ですでに DB スキーマと接続設定は投入済みのため、DB接続情報を入力して進めればすぐに利用開始できる。
> デフォルトログインは `Admin` / `zabbix`。

---

## 6. トラブルシューティング

### よくあるエラーと対処法

---

#### エラー①: `UNREACHABLE` (Step 6 の ping で失敗)

**原因:** SSH 鍵のパス間違い、パーミッション、IPアドレス間違い、SG設定ミスのいずれか

**対処法:**
```bash
# 鍵パーミッション確認
ls -l ~/.ssh/zabbix-key.pem  # → 600 になっているか

# 手動でSSH接続できるか確認
ssh -i ~/.ssh/zabbix-key.pem ec2-user@<ターゲットノードのプライベートIP>

# SG確認: 操作端末から22番ポートが許可されているか
```

---

#### エラー②: `community.postgresql.postgresql_user` でモジュールが見つからない

**原因:** community Collection 未インストール、またはターゲットノードに `python3-psycopg2` が無い

**対処法:**
```bash
# 操作端末側
ansible-galaxy collection install community.postgresql

# ターゲットノード側（Playbook内でインストールされているが、念のため確認）
sudo dnf list installed python3-psycopg2
```

---

#### エラー③: Playbook 途中で失敗 → 再実行したい

**原因:** 各種（ネットワーク瞬断、パッケージ取得失敗など）

**対処法:**
Ansible の **冪等性** により、同じコマンドで再実行可能。
```bash
ansible-playbook zabbix-server.yml
```
成功済みのタスクは `ok=` でスキップされ、未完了のタスクから再開される。

---

#### エラー④: WebUI にアクセスできない

**原因:** SG で 80番ポートが開いていない / httpd が起動していない

**対処法:**
```bash
# ターゲットノードで実行
sudo systemctl status httpd
sudo systemctl restart httpd

# SG確認: ローカルPCのIPから80番ポートが許可されているか
```

---

### ログの確認場所

| ログの種類 | 場所(パス) | 確認コマンド |
|-----------|------------|------------|
| Ansible 実行ログ | 標準出力（操作端末） | `ansible-playbook zabbix-server.yml -v` で詳細表示 |
| Zabbix サーバログ | `/var/log/zabbix/zabbix_server.log` | `sudo tail -f /var/log/zabbix/zabbix_server.log` |
| Zabbix エージェントログ | `/var/log/zabbix/zabbix_agent2.log` | `sudo tail -f /var/log/zabbix/zabbix_agent2.log` |
| PostgreSQL ログ | `/var/lib/pgsql/data/log/` | `sudo ls -l /var/lib/pgsql/data/log/` |
| Apache ログ | `/var/log/httpd/error_log` | `sudo tail -f /var/log/httpd/error_log` |

---

## 7. 参考リソース・関連資料

| 資料名 | URL | 補足 |
|-------|-----|------|
| Ansible 公式ドキュメント | https://docs.ansible.com/ | Ansible 全般のリファレンス |
| Ansible Galaxy | https://galaxy.ansible.com/ | Collection の検索 |
| community.general | https://docs.ansible.com/ansible/latest/collections/community/general/ | `timezone` モジュールなど |
| community.postgresql | https://docs.ansible.com/ansible/latest/collections/community/postgresql/ | PostgreSQL 操作モジュール |
| Zabbix 公式ドキュメント | https://www.zabbix.com/documentation/current/jp | Zabbix 7.0 の設定リファレンス |
| Zabbix 公式リポジトリ | https://repo.zabbix.com/zabbix/7.0/amazonlinux/2023/x86_64/zabbix-release-latest-7.0.amzn2023.noarch.rpm | Amazon Linux 2023 向けインストールパッケージ |

---

## 付録

### A. Playbook (`zabbix-server.yml`) の各タスク解説

ここでは Playbook 内の **各タスクが何をやっているか** を、初学者向けにブロックごとに解説する。

---

#### A-1. プレイのヘッダ部

```yaml
- name: Zabbix-Serverの構築
  hosts: zabbix_servers
  gather_facts: no
  become: true
```

| 項目 | 説明 |
|------|------|
| `hosts: zabbix_servers` | `inventory.ini` で定義したグループ名。このグループに属するサーバに対してタスクを実行 |
| `gather_facts: no` | ターゲットの情報収集（OS情報など）をスキップ。実行を高速化 |
| `become: true` | sudo（root権限）でタスクを実行 |

---

#### A-2. vars セクション（変数定義）

Playbook 全体で使う値を変数として定義している。
変数化することで、IPアドレスやバージョンを変更するときに **1箇所修正するだけで済む**。

| 変数名 | 用途 |
|--------|------|
| `timezone` | Asia/Tokyo（タイムゾーン設定値） |
| `pg_version` | PostgreSQL のメジャーバージョン（15） |
| `pg_data_dir` | PostgreSQL のデータディレクトリ |
| `zabbix_schema_file` | Zabbix の初期スキーマ（DB構造）ファイルのパス |
| `db_name` / `db_user` / `db_pass` | Zabbix が使うDB名・ユーザ・パスワード |
| `zabbix_server_confs` | `zabbix_server.conf` 内で書き換える行のリスト |
| `zabbix_agent_confs` | `zabbix_agent2.conf` 内で書き換える行のリスト |

---

#### A-3. システム設定（パッケージ更新・タイムゾーン）

| タスク | モジュール | 何をやっているか |
|--------|-----------|-----------------|
| Upgrade all packages | `dnf` | `dnf update` 相当。全パッケージを最新化 |
| Change timezone | `community.general.timezone` | `timedatectl set-timezone Asia/Tokyo` 相当 |

---

#### A-4. PostgreSQL 設定

| タスク | モジュール | 何をやっているか |
|--------|-----------|-----------------|
| Install postgresql | `dnf` | `postgresql15-server` をインストール |
| Install python3-psycopg2 | `dnf` | community.postgresql モジュールが内部で使う Python ライブラリをインストール |
| Initialization of postgresql | `command` | `postgresql-setup --initdb` を実行。`creates:` 句により、既に初期化済みならスキップ（冪等性） |
| Start postgresql | `systemd` | サービス起動 + 自動起動有効化 |
| Edit postgresql.conf | `replace` | `listen_addresses = '*'` に変更し、外部からの接続を受け付ける |
| Add rule to pg_hba.conf | `community.postgresql.postgresql_pg_hba` | Zabbix サーバからの接続を許可するルールを追加 |
| Restart postgresql if configs changed | `systemd` | 設定変更時のみ再起動（`when:` で制御） |
| Create zabbix-user | `community.postgresql.postgresql_user` | Zabbix 用 DB ユーザを作成 |
| Create zabbix-db | `community.postgresql.postgresql_db` | Zabbix 用 DB を作成 |

> **ポイント:**
> `register:` でタスク結果を変数に保存し、次のタスクの `when:` 句で「設定が変わったときだけ再起動」を実現している。これにより、毎回の再実行で余計な再起動が走らない。

---

#### A-5. Zabbix Server 設定

| タスク | モジュール | 何をやっているか |
|--------|-----------|-----------------|
| Add zabbix 7.0 repository | `dnf` | Zabbix 公式リポジトリの RPM をインストール |
| Install zabbix packages | `dnf` | zabbix-server-pgsql、zabbix-web-pgsql、apache-conf、sql-scripts、web-japanese、agent2 を一括インストール |
| Include db schema | `community.postgresql.postgresql_db` | `server.sql.gz` のスキーマ（テーブル定義 + 初期データ）を DB に投入 |
| configure zabbix-server to database | `lineinfile` | `zabbix_server.conf` の DB接続情報（DBHost/DBName/DBUser/DBPassword）を書き換え |
| Start zabbix-server | `systemd` | Zabbix サーバ起動 + 自動起動有効化 |
| Configure zabbix-agent | `lineinfile` | `zabbix_agent2.conf` の Server / ServerActive / Hostname を書き換え |
| Start zabbix-agent | `systemd` | Zabbix エージェント起動 + 自動起動有効化 |
| Start httpd | `systemd` | Apache 起動 + 自動起動有効化（WebUI 用） |

> **ポイント:**
> `lineinfile` モジュールは、指定された正規表現にマッチする行を別の行に置換する。
> `loop:` で複数の置換を一気に処理している。

---

### B. inventory.ini の解説

```ini
[zabbix_servers]
zabbix_server ansible_host=<ターゲットノードのプライベートIP>

[zabbix_servers:vars]
#ansible_user=ec2-user
db_host=<ターゲットノードのプライベートIP>
zabbix_server_host=<ターゲットノードのプライベートIP>
```

| セクション | 説明 |
|-----------|------|
| `[zabbix_servers]` | グループ名。Playbook の `hosts:` でこの名前を指定する |
| `zabbix_server ansible_host=...` | グループに属するホスト。`zabbix_server` は Ansible 内部での識別名、`ansible_host` は実際の接続先IP |
| `[zabbix_servers:vars]` | このグループに属する全ホストで共通の変数を定義 |
| `#ansible_user=ec2-user` | `#` でコメントアウト。`ansible.cfg` 側で `remote_user = ec2-user` を指定している前提 |

---

### C. よく使う Ansible コマンドまとめ

| コマンド | 用途 |
|---------|------|
| `ansible-playbook zabbix-server.yml --syntax-check` | YAML構文チェックのみ |
| `ansible-playbook zabbix-server.yml --check` | dry-run（実際には変更を加えずシミュレーション） |
| `ansible-playbook zabbix-server.yml -v` | 詳細ログ出力（`-vvv` でさらに詳細） |
| `ansible-playbook zabbix-server.yml --start-at-task="タスク名"` | 指定タスクから実行を開始 |
| `ansible zabbix_servers -m ping` | 疎通確認 |
| `ansible zabbix_servers -m shell -a "uptime"` | 任意のコマンドを実行 |

---
