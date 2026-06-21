# NSDを用いた内部DNS冗長構成構築

------------------------------

## 1. ドキュメント情報

| 項目 | 内容 |
|------|------|
| 手順書名 | NSDを用いた内部DNS冗長構成構築 |
| 作成日 | 2026-06-18 |
| 最終更新日 | 2026-06-18 |
| バージョン | v1.2 |
| 対象環境 | AWS（Amazon Linux 2023） |

> **改訂履歴**
>
> | バージョン | 日付 | 変更内容 |
> |-----------|------|---------|
> | v1.0 | 2026-06-18 | 初版作成（テンプレートに沿って再構成．構成図（AXFRフロー含む）追加．Primary側・Secondary側を4-A／4-Bに整理．各Stepに【実施対象】明示．パラメータ定義表を統合．プレースホルダーを意味ベースに統一．句読点を「，．」に統一．サーバー表記を「サーバー」に統一．付録A〜D追加．） |
> | v1.1 | 2026-06-18 | ファイル名を`nsd-internal-redundancy.md`から`nsd-private-redundancy.md`に変更（対外公開DNSの手順書`nsd-public-letsencrypt.md`と命名を対比させるため）．手順書のタイトル・本文中の「内部DNS」という技術用語は業界慣用表現として維持． |
> | v1.2 | 2026-06-20 | 構築・検証中はキャッシュ保持時間を短くする目的で，Primaryゾーンファイルの `$TTL` と SOAの `refresh` / `retry` / `minimum` を **3600 → 60** に変更．`expire` のみ RFC 1035の SOA 設計原則（`expire > refresh`）に従い **3600** を維持．動作確認完了後の本番運用向け推奨値（`$TTL=3600` / `refresh=3600` / `retry=900` / `expire=604800` / `minimum=300`）を本文 Primary Step 5 および付録Bに併記． |

------------------------------

## 2. 目的・概要

### 2-1. 目的

> 本手順書では，AWSのEC2インスタンス上に「NSD（Name Server Daemon）」を用いた内部DNS（権威DNS）サーバーを2台構築し，AZ2をPrimary，AZ4をSecondaryとする冗長構成を組む手順について説明する．
> 内部ドメイン `ex.local` の名前解決を提供し，VPC内の各サーバー（Web／AP／DB／Zabbix／SMTP等）が `<ホスト名>.ex.local` 形式のFQDNで相互通信できる状態を目指す．
> ゾーンファイルはPrimaryでのみ作成・管理し，SecondaryはAXFR（ゾーン転送）で取得する．

### 2-2. 構成概要（アーキテクチャ）

```
                        ┌─── NOTIFY ───►
[EC2: Primary DNS]      │                [EC2: Secondary DNS]
  AZ2 / az2-dns         │                  AZ4 / az4-dns
  ┌───────────────┐     │     ┌───────────────┐
  │  NSD (master) ├─────┴─────► NSD (slave)   │
  │  ex.local.zone│   AXFR    │  ex.local.zone│
  │  (手動作成)    │ (TCP 53)  │  (AXFRで取得)  │
  └───────┬───────┘           └───────┬───────┘
          │                           │
          │ UDP/53                    │ UDP/53
          │ DNS問い合わせ              │ DNS問い合わせ
          ▼                           ▼
  ┌──────────────────────────────────────────┐
  │  VPC内クライアント                          │
  │  (Web / AP / DB / Zabbix / SMTP 等)        │
  │  systemd-resolved → Primary→Secondary順    │
  └──────────────────────────────────────────┘
```

### 2-3. 完成イメージ（ゴール定義）

- [ ] Primary・Secondary両方で`nsd.service` が`active (running)`かつ自動起動有効である
- [ ] Primary・Secondary両方でUDP/53・TCP/53がLISTENしている
- [ ] Primaryでゾーンファイル `ex.local.zone` が読み込まれ，`nsd-control zonestatus ex.local` が `state: ok` を返す
- [ ] SecondaryでAXFRが成功し，`nsd-control zonestatus ex.local` が `state: ok` かつPrimaryと同じシリアル番号を返す
- [ ] VPC内の任意のサーバーから `dig @<Primary DNSのIP> <任意のホスト名>.ex.local +short` で正しいIPが返る
- [ ] 同様にSecondaryに対しても同じ結果が返る

------------------------------

## 3. 前提条件・準備

### 3-1. 環境要件

| 項目 | 要件 |
|------|------|
| OS | Amazon Linux 2023 |
| Primary配置サブネット | AZ2 / internal-ap サブネット（APサーバーと同居可） |
| Secondary配置サブネット | AZ4 / internal-ap サブネット（APサーバーと同居可） |
| CPU | 1コア以上 |
| メモリ | 1GB以上 |
| ストレージ | 8GB以上 |
| 依存パッケージ | `spal-release`，`nsd` |

> **補足：** `spal-release` はAmazon Linux 2023専用の追加リポジトリ．本構成ではNSDの導入に使用する．

### 3-2. セキュリティグループ設定

#### 3-2-1. Primary DNSのインバウンドルール

| タイプ | プロトコル | ポート範囲 | ソース | 説明 |
|-------|------------|----------|--------|------|
| SSH | TCP | 22 | マイIP | ローカルPCからSSHで接続（踏み台経由） |
| DNS (UDP) | UDP | 53 | VPC CIDR | VPC内部からのDNS問い合わせ |
| DNS (TCP) | TCP | 53 | Secondary DNSのSG | **AXFR（ゾーン転送）に必須** |
| DNS (TCP) | TCP | 53 | VPC CIDR | 512バイト超のDNS応答用 |

#### 3-2-2. Secondary DNSのインバウンドルール

| タイプ | プロトコル | ポート範囲 | ソース | 説明 |
|-------|------------|----------|--------|------|
| SSH | TCP | 22 | マイIP | ローカルPCからSSHで接続 |
| DNS (UDP) | UDP | 53 | VPC CIDR | VPC内部からのDNS問い合わせ |
| DNS (TCP) | TCP | 53 | VPC CIDR | 512バイト超のDNS応答用 |

#### 3-2-3. Primary・Secondary共通のアウトバウンドルール

| タイプ | プロトコル | ポート範囲 | 送信先 | 説明 |
|-------|------------|----------|--------|------|
| HTTPS | TCP | 443 | 0.0.0.0/0 | dnf／パッケージダウンロード |
| HTTP | TCP | 80 | 0.0.0.0/0 | dnfミラー |
| DNS | UDP | 53 | 0.0.0.0/0 | 外部問い合わせ（必要に応じて） |
| DNS | TCP | 53 | Primary DNSのSG | **Secondary→Primary方向のAXFR要求** |

> **重要：** TCP/53の許可漏れはAXFR失敗の典型原因．Primary側SGで「Secondary DNSのSGからのTCP/53」を必ず許可すること．

### 3-3. パラメータ定義表

> **注意：** 以下の値は作業前に環境に合わせて記入してから作業を開始すること．

#### 共通パラメータ

| パラメータ名 | 値 | 説明 |
|------------|---|------|
| `<DNSサーバーのホスト名(Primary)>` | `<記入する>` | Primary DNSのホスト名（例：`<任意の名前>-dns`） |
| `<DNSサーバーのホスト名(Secondary)>` | `<記入する>` | Secondary DNSのホスト名 |
| `<Primary DNSのIP>` | `<記入する>` | AZ2 PrimaryのプライベートIP |
| `<Secondary DNSのIP>` | `<記入する>` | AZ4 SecondaryのプライベートIP |
| `<内部ドメイン名>` | `ex.local` | 内部DNSで管理するドメイン名 |
| `<ゾーンシリアル番号>` | 例：`20260618` | ゾーンの更新日（YYYYMMDDnn形式推奨） |
| `<SOA管理者メール>` | 例：`test.gmail.com.` | SOAレコードの管理者メール（`@`→`.`に置換，末尾`.`必須） |

#### ゾーンファイルAレコード（Primary側のみ使用）

| パラメータ名 | 値 | 説明 |
|------------|---|------|
| `<AZ1のWeb系IP>` | `<記入する／未確定なら空欄>` | AZ1の web/dns/smtp 共通IP |
| `<AZ2のAP系IP>` | `<記入する>` | AZ2の ap/dns 共通IP（`<Primary DNSのIP>` と同値） |
| `<AZ2のDB系IP>` | `<記入する>` | AZ2の db/ntp/nfs 共通IP |
| `<AZ3のWeb系IP>` | `<記入する／未確定なら空欄>` | AZ3の web/dns/smtp 共通IP |
| `<AZ4のAP系IP>` | `<記入する>` | AZ4の ap/dns 共通IP（`<Secondary DNSのIP>` と同値） |
| `<AZ4のZabbix IP>` | `<記入する／未確定なら空欄>` | AZ4の zabbix サーバーIP |

#### ロールバック用（任意）

| パラメータ名 | 値 | 説明 |
|------------|---|------|
| `<元のホスト名>` | `<記入する>` | 構築前のホスト名（戻す場合のみ記入） |
| `<元のタイムゾーン>` | `<記入する>` | 構築前のタイムゾーン（戻す場合のみ記入） |

### 3-4. リンク一覧

| 項目名 | 目的 |
|-------|------|
| https://www.nlnetlabs.nl/projects/nsd/about/ | NSD公式 |
| https://nsd.docs.nlnetlabs.nl/en/latest/ | NSD公式ドキュメント |
| https://docs.aws.amazon.com/ja_jp/linux/al2023/ug/ | Amazon Linux 2023 ガイド |

------------------------------

## 4. 構築手順（詳細）

> **注意事項**
> - コマンド中の `<山カッコ>` は自分の環境の値（パラメータ定義表の値）に置き換えること
> - **必ず Primary → Secondary の順に構築すること**（Secondaryは構築時にPrimaryへAXFR要求するため）
> - 各Stepの見出し末尾に **【実施対象：●●】** を明示しているので，対象のサーバーで実施すること
> - 他の手順書（`tomcat-basic.md` 等）で同居サーバーの`system-setup`を既に実施済みの場合，Step 1はスキップ可能

------------------------------

## 4-A. Primary DNS側構築

------------------------------

### Primary Step 1：system-setup（共通システム設定）【実施対象：Primary DNS】

**目的：** タイムゾーン，ホスト名，通信確認ツール，名前解決先を設定する

#### 操作手順

```bash
# rootユーザーにスイッチ
sudo su -

# パッケージを最新化
dnf update -y

# タイムゾーンを Asia/Tokyo に設定
timedatectl set-timezone Asia/Tokyo

# ホスト名を設定
hostnamectl set-hostname <DNSサーバーのホスト名(Primary)>

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
```

> **注意：** ホスト名をシェルのプロンプトに反映させるため，一度SSHを切断して再接続すること．

------------------------------

### Primary Step 2：NSDのインストール【実施対象：Primary DNS】

**目的：** spal-releaseリポジトリを追加し，NSD本体をインストールする

#### 操作手順

```bash
# spal-release リポジトリのインストール
dnf install -y spal-release

# NSD 本体のインストール
dnf install -y nsd

# バージョン確認
nsd -v
```

> **補足：** `spal-release` はAmazon Linux 2023専用の追加リポジトリ．NSDパッケージを提供する．

------------------------------

### Primary Step 3：nsd.confのバックアップ【実施対象：Primary DNS】

**目的：** 既存の `nsd.conf` をバックアップする（ロールバック時に使用）

#### 操作手順

```bash
# 存在確認
ls /etc/nsd/nsd.conf 2>/dev/null

# 存在する場合のみバックアップ
cp -p /etc/nsd/nsd.conf /etc/nsd/nsd.conf.org

# バックアップ確認
ls -l /etc/nsd/nsd.conf.org
```

------------------------------

### Primary Step 4：nsd.confの作成（Primary用）【実施対象：Primary DNS】

**目的：** Primary（master）として動作させるためのNSD設定ファイルを作成する

#### 操作手順

```bash
# nsd.conf を編集（既存内容は全削除して全置換）
vi /etc/nsd/nsd.conf
```

設定ファイルの記述内容（vi上で `:1,$d` で全行削除した後，以下を貼り付け）：

```
server:
    server-count: 1
    ip-address: 0.0.0.0
    ip-address: ::0
    port: 53
    username: nsd
    zonesdir: "/etc/nsd"
    zonelistfile: "/var/lib/nsd/zone.list"
    logfile: "/var/log/nsd.log"

    database: ""
    pidfile: "/var/run/nsd/nsd.pid"

    statistics: 3600
    round-robin: yes
    minimal-responses: yes
    refuse-any: yes

    include: "/etc/nsd/server.d/*.conf"

include: "/etc/nsd/conf.d/*.conf"

remote-control:
    control-enable: yes
    control-interface: /run/nsd/nsd.ctl

pattern:
    name: "master-wplocal"
    provide-xfr: <Secondary DNSのIP> NOKEY
    notify: <Secondary DNSのIP> NOKEY

zone:
    name: "ex.local"
    zonefile: "ex.local.zone"
    include-pattern: "master-wplocal"
```

```bash
# 構文チェック
nsd-checkconf /etc/nsd/nsd.conf
# → 何も表示されなければ成功
```

> **重要：** `provide-xfr` と `notify` の値には **Secondary DNSのIP** を指定する（Primary用設定）．逆にしないよう注意．

> **補足：** インデントはスペースで統一．タブとスペースの混在は構文エラーの原因になる．

------------------------------

### Primary Step 5：ゾーンファイルの作成【実施対象：Primary DNS】

**目的：** `ex.local` ゾーンのAレコードを定義する

#### 操作手順

```bash
# ゾーンファイルを編集
vi /etc/nsd/ex.local.zone
```

設定ファイルの記述内容：

```
$TTL 60
@ IN SOA ns1.ex.local. <SOA管理者メール> (
        <ゾーンシリアル番号> ; serial
        60                  ; refresh
        60                  ; retry
        3600                ; expire
        60 )                ; minimum

        IN NS ns1.ex.local.
        IN NS ns2.ex.local.

ns1        IN A <Primary DNSのIP>
ns2        IN A <Secondary DNSのIP>

az1-web    IN A <AZ1のWeb系IP>
az1-dns    IN A <AZ1のWeb系IP>
az1-smtp   IN A <AZ1のWeb系IP>

az2-ap     IN A <AZ2のAP系IP>
az2-dns    IN A <AZ2のAP系IP>

az2-db     IN A <AZ2のDB系IP>
az2-ntp    IN A <AZ2のDB系IP>
az2-nfs    IN A <AZ2のDB系IP>

az3-web    IN A <AZ3のWeb系IP>
az3-dns    IN A <AZ3のWeb系IP>
az3-smtp   IN A <AZ3のWeb系IP>

az4-ap     IN A <AZ4のAP系IP>
az4-dns    IN A <AZ4のAP系IP>

az4-zabbix IN A <AZ4のZabbix IP>
```

> **注意（TTLについて）：** 本設定の `$TTL` および SOA の `refresh` / `retry` / `minimum` は **構築・検証中の暫定値（60秒）** である．キャッシュ保持時間を短くしてレコード変更の反映を早めるため．動作確認完了後は **本番運用向けの推奨値** に変更すること．
>
> | フィールド | 構築・検証中（暫定） | 動作確認完了後（推奨） |
> |---|---|---|
> | `$TTL` | 60 | 3600（1時間） |
> | `refresh` | 60 | 3600（1時間） |
> | `retry` | 60 | 900（15分） |
> | `expire` | 3600 | 604800（1週間） |
> | `minimum` | 60 | 300（5分） |
>
> `expire` のみ検証中も `3600` にしている理由：`expire ≤ refresh` の状態だと Primary が1分でも応答しないと Secondary がゾーンを破棄してしまうため．RFC 1035の SOA 設計原則に従い `expire > refresh` を維持する．
>
> 値変更時は `<ゾーンシリアル番号>` を必ずインクリメントし，`systemctl reload nsd` で反映すること．

> **注意：** IP値が未確定のレコードは，行頭に `;` を付けてコメントアウトすること（例：`;az1-web    IN A`）．後から追加可能．
>
> **重要：** ゾーンを更新するたびに `<ゾーンシリアル番号>` をインクリメントすること（YYYYMMDDnn形式が一般的．例：`20260618` → `20260619` または `2026061801` → `2026061802`）．シリアルを上げ忘れるとSecondaryへの転送が反映されない．

```bash
# ゾーンファイル構文チェック
nsd-checkzone ex.local /etc/nsd/ex.local.zone
# → zone ex.local is ok が出れば成功
```

------------------------------

### Primary Step 6：NSDの起動【実施対象：Primary DNS】

**目的：** NSDを起動し，自動起動を有効化する

#### 操作手順

```bash
# 起動 + 自動起動有効化
systemctl enable --now nsd.service

# 起動確認
systemctl status nsd.service --no-pager

# 自動起動確認
systemctl is-enabled nsd.service
```

> **期待する結果：** `active (running)` および `enabled` が表示される．

------------------------------

### Primary Step 7：Primary側の動作確認【実施対象：Primary DNS】

**目的：** ゾーンが読み込まれていることと，自身に対する名前解決ができることを確認する

#### 操作手順

```bash
# ゾーン状態確認
nsd-control zonestatus ex.local
```

> **期待する結果：**
> ```
> zone:    ex.local
>     state: ok
>     served-serial: "<ゾーンシリアル番号> since ..."
> ```

```bash
# 自身に対するdig問い合わせ
dig @127.0.0.1 az2-db.ex.local +short
```

> **期待する結果：** パラメータ定義表の `<AZ2のDB系IP>` の値が返る．

------------------------------

## 4-B. Secondary DNS側構築

> **前提：** Primary側のStep 1〜7が完了済みであること．

------------------------------

### Secondary Step 1：system-setup（共通システム設定）【実施対象：Secondary DNS】

Primary Step 1と同じ手順で実施する．ただしホスト名は `<DNSサーバーのホスト名(Secondary)>` を使用する．

#### 操作手順

```bash
sudo su -
dnf update -y
timedatectl set-timezone Asia/Tokyo
hostnamectl set-hostname <DNSサーバーのホスト名(Secondary)>

command -v nc
# 未インストールの場合のみ実行
dnf install -y nmap-ncat

mkdir -p /etc/systemd/resolved.conf.d
vi /etc/systemd/resolved.conf.d/ex-local.conf
```

設定ファイルの記述内容：

```
[Resolve]
DNS=<Primary DNSのIP> <Secondary DNSのIP>
```

```bash
systemctl restart systemd-resolved
```

> **注意：** SSHを切断して再接続後，Step 2以降に進むこと．

------------------------------

### Secondary Step 2：NSDのインストール【実施対象：Secondary DNS】

```bash
dnf install -y spal-release
dnf install -y nsd
nsd -v
```

------------------------------

### Secondary Step 3：nsd.confのバックアップ【実施対象：Secondary DNS】

```bash
ls /etc/nsd/nsd.conf 2>/dev/null && cp -p /etc/nsd/nsd.conf /etc/nsd/nsd.conf.org
ls -l /etc/nsd/nsd.conf.org
```

------------------------------

### Secondary Step 4：nsd.confの作成（Secondary用）【実施対象：Secondary DNS】

**目的：** Secondary（slave）として動作させるためのNSD設定ファイルを作成する

#### 操作手順

```bash
vi /etc/nsd/nsd.conf
```

設定ファイルの記述内容（`:1,$d` で全削除後に貼り付け）：

```
server:
    server-count: 1
    ip-address: 0.0.0.0
    ip-address: ::0
    port: 53
    username: nsd
    zonesdir: "/etc/nsd"
    zonelistfile: "/var/lib/nsd/zone.list"
    logfile: "/var/log/nsd.log"

    database: ""
    pidfile: "/var/run/nsd/nsd.pid"

    statistics: 3600
    round-robin: yes
    minimal-responses: yes
    refuse-any: yes

    include: "/etc/nsd/server.d/*.conf"

include: "/etc/nsd/conf.d/*.conf"

remote-control:
    control-enable: yes
    control-interface: /run/nsd/nsd.ctl

pattern:
    name: "slave-wplocal"
    request-xfr: <Primary DNSのIP> NOKEY
    allow-notify: <Primary DNSのIP> NOKEY

zone:
    name: "ex.local"
    zonefile: "ex.local.zone"
    include-pattern: "slave-wplocal"
```

```bash
# 構文チェック
nsd-checkconf /etc/nsd/nsd.conf
```

> **重要：** `request-xfr` と `allow-notify` の値には **Primary DNSのIP** を指定する（Secondary用設定）．Primary側の `provide-xfr` / `notify` の宛先と逆方向であることに注意．

> **重要：** Secondaryでは **ゾーンファイルを手動作成しない**．PrimaryからAXFRで自動取得される．

------------------------------

### Secondary Step 5：NSDの起動【実施対象：Secondary DNS】

```bash
systemctl enable --now nsd.service
systemctl status nsd.service --no-pager
systemctl is-enabled nsd.service
```

------------------------------

### Secondary Step 6：ゾーン転送の要求と確認【実施対象：Secondary DNS】

**目的：** PrimaryからAXFRでゾーンを取得し，正常状態になることを確認する

#### 操作手順

```bash
# ゾーンのリロード要求
nsd-control reload ex.local

# 少し待ってから確認
sleep 3
nsd-control zonestatus ex.local
```

> **期待する結果：**
> ```
> zone: ex.local
>     state: ok
>     served-serial: "<ゾーンシリアル番号> since ..."
> ```

> **注意：**
> - `state: refreshing` の場合は転送中．少し待って再確認すること．
> - `state: expired` の場合は転送失敗．**SGのTCP/53許可とPrimaryへの疎通**を再確認すること．

------------------------------

## 5. 動作確認・検証

> 構築完了後，以下の確認をすべてパスしたら構築成功とみなす．

### 5-1. 確認チェックリスト

- [ ] **確認①**：Primary・Secondary両方でNSDサービスが`active (running)`かつ自動起動有効
- [ ] **確認②**：両サーバーで53/udp および 53/tcpがLISTEN
- [ ] **確認③**：両サーバーでゾーンが `state: ok` かつ同じシリアル番号
- [ ] **確認④**：VPC内クライアントからPrimaryに `dig` で名前解決成功
- [ ] **確認⑤**：VPC内クライアントからSecondaryに `dig` で名前解決成功
- [ ] **確認⑥**：Primary停止時もSecondaryで名前解決継続（任意：フェイルオーバーテスト）

------------------------------

### 確認①：サービス状態確認（両サーバーで実施）

```bash
systemctl status nsd.service --no-pager
systemctl is-enabled nsd.service
```

**期待する結果：** `active (running)` および `enabled` が表示される．

------------------------------

### 確認②：リッスンポート確認（両サーバーで実施）

```bash
ss -lnp | grep :53
```

**期待する結果：** UDPとTCPの両方で `0.0.0.0:53` がLISTENしている．

------------------------------

### 確認③：ゾーン状態確認（両サーバーで実施）

```bash
nsd-control zonestatus ex.local
```

**期待する結果：** 両サーバーで同じ`served-serial`値かつ `state: ok`．

------------------------------

### 確認④：Primaryへの名前解決テスト（VPC内サーバーから）

```bash
dig @<Primary DNSのIP> az2-db.ex.local +short
```

**期待する結果：** ゾーンファイルに記載した `<AZ2のDB系IP>` の値が返る．

------------------------------

### 確認⑤：Secondaryへの名前解決テスト（VPC内サーバーから）

```bash
dig @<Secondary DNSのIP> az2-db.ex.local +short
```

**期待する結果：** Primaryと同じIPが返る．

------------------------------

### 確認⑥：フェイルオーバーテスト（任意）

Primary停止状態でSecondaryのみで解決できることを確認．

```bash
# Primary側で
systemctl stop nsd.service

# クライアント側で（systemd-resolvedがSecondaryにフォールバック）
getent hosts az2-db.ex.local

# Primary復旧
systemctl start nsd.service
```

> **注意：** 検証後は必ずPrimaryを起動状態に戻すこと．

------------------------------

## 6. トラブルシューティング

### よくあるエラーと対処法

------------------------------

#### エラー①：Secondaryで `state: expired` / AXFR失敗

**原因：** ほとんどの場合 **Primary側SGでTCP/53未開放**．

**対処法：**

1. Secondary→PrimaryへのTCP/53疎通確認：

   ```bash
   nc -zv <Primary DNSのIP> 53
   ```

2. NGの場合，AWSコンソールで **Primary側SGに「Secondary DNSのSGからのTCP/53」を追加**．
3. SG修正後，再度AXFRを要求：

   ```bash
   nsd-control reload ex.local
   nsd-control zonestatus ex.local
   ```

> **補足：** UDP/53のみではAXFRはできない．TCP/53は必須．

------------------------------

#### エラー②：`dig` で `SERVFAIL` / `NXDOMAIN`

**原因：** ゾーンファイルの記述漏れ，もしくはPrimary側のリロード忘れ．

**対処法：**

```bash
# 現在のゾーンファイル確認
cat /etc/nsd/ex.local.zone

# 必要なレコードを追加 + serialインクリメント
vi /etc/nsd/ex.local.zone

# 構文チェック
nsd-checkzone ex.local /etc/nsd/ex.local.zone

# リロード
nsd-control reload ex.local
```

> **重要：** serialをインクリメントしないとSecondaryへ転送されない．

------------------------------

#### エラー③：`nsd-checkconf` で構文エラー

**原因：** `nsd.conf` のインデント崩れ，もしくはタブとスペースの混在．

**対処法：** NSD設定ファイルはインデントが厳密．スペースで統一すること．Primary Step 4 / Secondary Step 4から再作成．

------------------------------

#### エラー④：`dnf install -y spal-release` で 404等のエラー

**原因：** `spal-release` パッケージのリポジトリが利用できない，もしくは命名が異なる．

**対処法：** 検証環境専用のリポジトリ設定が必要な場合がある．トレーナーまたは管理者に確認すること．

------------------------------

#### エラー⑤：NSDが起動しない（`port already in use`）

**原因：** `systemd-resolved` のDNSスタブが53番を占有している．

**対処法：**

```bash
# 53番LISTEN中のプロセスを確認
ss -lnp | grep :53

# systemd-resolved のスタブを無効化する場合
mkdir -p /etc/systemd/resolved.conf.d
cat > /etc/systemd/resolved.conf.d/disable-stub.conf << 'EOF'
[Resolve]
DNSStubListener=no
EOF
systemctl restart systemd-resolved
systemctl restart nsd.service
```

------------------------------

### ログの確認場所

| ログの種類 | 場所（パス） |
|-----------|------------|
| NSDログ | `/var/log/nsd.log` |
| systemdログ | `journalctl -u nsd.service` |
| ゾーン状態 | `nsd-control zonestatus ex.local` |

------------------------------

## 7. 参考リソース・関連資料

| 資料名 | URL / 場所 | 補足 |
|-------|-----------|------|
| NSD 公式 | https://www.nlnetlabs.nl/projects/nsd/about/ | NSDプロジェクトページ |
| NSD 公式ドキュメント | https://nsd.docs.nlnetlabs.nl/en/latest/ | 設定リファレンス |
| RFC 1035 | https://datatracker.ietf.org/doc/html/rfc1035 | DNS仕様 |
| Amazon Linux 2023 ガイド | https://docs.aws.amazon.com/ja_jp/linux/al2023/ug/ | OS全般 |
| 別手順書：Tomcat構築手順 | `tomcat-basic.md` | 同居APサーバー側 |
| 別手順書：Nginxリバースプロキシ構築 | `nginx-reverse-proxy.md` | Webサーバー側 |

------------------------------

## 8. ロールバック手順

> **実施順：** Secondary → Primaryの順で実施することを推奨（AXFR関連の不要動作を回避）．以下を各サーバーで実施する．

### 8-1. NSDサービスの停止と無効化【実施対象：Primary／Secondary】

```bash
systemctl stop nsd.service
systemctl disable nsd.service
```

### 8-2. ゾーンファイルの削除【実施対象：Primary／Secondary】

```bash
# 存在確認
ls /etc/nsd/ex.local.zone 2>/dev/null

# 存在する場合のみ削除
rm -f /etc/nsd/ex.local.zone
```

> **補足：** Primaryでは手動作成したファイル，SecondaryではAXFRで取得されたファイルを削除．

### 8-3. nsd.confの復元【実施対象：Primary／Secondary】

```bash
# バックアップ存在確認
ls /etc/nsd/nsd.conf.org 2>/dev/null

# 存在する場合は復元
mv -f /etc/nsd/nsd.conf.org /etc/nsd/nsd.conf

# 存在しない場合は削除
rm -f /etc/nsd/nsd.conf
```

### 8-4. パッケージの削除（任意）【実施対象：Primary／Secondary】

> **注意：** 完全に元の状態に戻したい場合のみ実施．依存破壊リスクがあるため本番環境では慎重に．

```bash
dnf remove -y nsd spal-release
```

### 8-5. systemd-resolvedのDNS設定削除【実施対象：Primary／Secondary】

```bash
rm -f /etc/systemd/resolved.conf.d/ex-local.conf
systemctl restart systemd-resolved
```

> **重要：** NSD停止状態で `systemd-resolved` がNSDを指したままだと，自サーバーの名前解決が失敗する．本Stepでデフォルトの解決経路に戻すこと．

### 8-6. ホスト名・タイムゾーンの復元（任意）【実施対象：Primary／Secondary】

```bash
hostnamectl set-hostname <元のホスト名>
timedatectl set-timezone <元のタイムゾーン>
```

### 8-7. 完了確認【実施対象：Primary／Secondary】

```bash
systemctl status nsd.service 2>&1 | head -3
```

> **期待する結果：** `Unit nsd.service could not be found.`（パッケージ削除済みの場合）

> **注意：** `dnf update` で適用したパッケージ更新は取り消さない（依存破壊リスクを避けるため）．

------------------------------

## 付録

### A. コマンド解説

| コマンド | 説明 |
|---------|------|
| `dnf install -y <パッケージ>` | dnfからパッケージを非対話インストール． |
| `nsd-checkconf <ファイル>` | NSD設定ファイル（`nsd.conf`）の構文チェック．エラー時のみ出力． |
| `nsd-checkzone <ゾーン名> <ファイル>` | ゾーンファイルの構文チェック．成功時 `zone <ゾーン名> is ok` を表示． |
| `nsd-control reload [<ゾーン名>]` | 指定ゾーン（省略時は全ゾーン）をリロード．ゾーンファイル変更やAXFR要求時に使用． |
| `nsd-control zonestatus <ゾーン名>` | ゾーンの状態確認．`state` と `served-serial` を表示． |
| `nsd-control stats` | NSDの統計情報を表示． |
| `systemctl enable --now <サービス>` | サービスを起動し，自動起動を有効化． |
| `systemctl status <サービス> --no-pager` | サービスの稼働状態を確認． |
| `dig @<DNSサーバーIP> <FQDN> +short` | 指定DNSサーバーに対する問い合わせ．`+short` で結果のみ表示． |
| `dig @<DNSサーバーIP> <ゾーン名> AXFR` | AXFR（ゾーン転送）の手動テスト． |
| `getent hosts <FQDN>` | systemの名前解決機能（`/etc/hosts`／DNS／LDAP等）でFQDN→IPを解決． |
| `nc -zv <IP> <ポート>` | ポートへの疎通確認．`-z` は接続のみ，`-v` で詳細表示． |
| `ss -lnp \| grep :53` | 53番でLISTEN中のプロセス確認． |

------------------------------

### B. 設定ファイル解説

**`/etc/nsd/nsd.conf`（Primary／Secondary共通）**

```
server:
    server-count: 1
    ip-address: 0.0.0.0
    ip-address: ::0
    port: 53
    username: nsd
    ...
```

- `server-count`：起動するワーカープロセス数．小規模環境では1で十分．
- `ip-address`：LISTENするIP．`0.0.0.0` でIPv4全てのインターフェース，`::0` でIPv6全て．
- `port`：DNSの標準ポート53．
- `username`：プロセス起動後にswitch-uidする実行ユーザー（権限分離）．
- `zonesdir`：ゾーンファイルを置くディレクトリ．
- `logfile`：ログ出力先．
- `pidfile`：NSDプロセスのPIDファイル．
- `statistics: 3600`：統計を1時間毎に出力．
- `round-robin: yes`：複数Aレコードがある場合に応答順をローテーション．
- `minimal-responses: yes`：応答パケットサイズを最小化．
- `refuse-any: yes`：ANYクエリを拒否（DNS増幅攻撃対策）．

```
remote-control:
    control-enable: yes
    control-interface: /run/nsd/nsd.ctl
```

- `nsd-control` コマンドを使うために必要な設定．Unixソケット経由でローカル操作．

**Primary用 pattern**

```
pattern:
    name: "master-wplocal"
    provide-xfr: <Secondary DNSのIP> NOKEY
    notify: <Secondary DNSのIP> NOKEY
```

- `provide-xfr`：AXFR要求を受け付ける相手．SecondaryのIPを指定．
- `notify`：ゾーン更新時に通知する相手．SecondaryのIPを指定．
- `NOKEY`：TSIG（認証鍵）なし．本番ではTSIG使用が望ましい．

**Secondary用 pattern**

```
pattern:
    name: "slave-wplocal"
    request-xfr: <Primary DNSのIP> NOKEY
    allow-notify: <Primary DNSのIP> NOKEY
```

- `request-xfr`：AXFRを要求する相手．PrimaryのIPを指定．
- `allow-notify`：NOTIFYの受信を許可する相手．PrimaryのIPを指定．

**`/etc/nsd/ex.local.zone`（Primaryのみ作成）**

```
$TTL 60
@ IN SOA ns1.ex.local. <SOA管理者メール> (
        <ゾーンシリアル番号> ; serial
        60                  ; refresh
        60                  ; retry
        3600                ; expire
        60 )                ; minimum
```

> **補足：** 上記は **構築・検証中の暫定値**．動作確認完了後は本番運用向けの推奨値（`$TTL=3600` / `refresh=3600` / `retry=900` / `expire=604800` / `minimum=300`）に変更すること．詳細は本文 Primary Step 5 の注意ブロックを参照．

- `$TTL`：レコードのデフォルトTTL（秒）．キャッシュ保持時間．
- `@`：ゾーン名のショートカット（ここでは `ex.local`）．
- `SOA`：ゾーンの管理情報レコード．
  - 第1引数：プライマリネームサーバー名（FQDN，末尾`.`必須）．
  - 第2引数：管理者メール（`@`を`.`に置換した形式，末尾`.`必須）．
  - `serial`：ゾーンのシリアル番号．**更新の度にインクリメント**．
  - `refresh`：Secondaryが更新確認する間隔．
  - `retry`：refresh失敗時の再試行間隔．
  - `expire`：Primaryと連絡取れない場合にゾーンを破棄するまでの時間．
  - `minimum`：ネガティブキャッシュTTL．
- `NS`：ネームサーバーレコード．
- `A`：ホスト名→IPアドレスのマッピング．

------------------------------

### C. 用語解説

| 用語 | 説明 |
|------|------|
| DNS | Domain Name System．ドメイン名とIPアドレスを相互変換するシステム． |
| 権威DNS | 自分が管理するゾーンの情報に対して権威ある回答を返すDNSサーバー．NSDは権威DNS専用． |
| キャッシュDNS | 他のDNSへの問い合わせを代行し，結果をキャッシュするDNSサーバー（NSDではなくUnbound等が担当）． |
| NSD | Name Server Daemon．NLnet Labsが開発する権威DNS実装． |
| ゾーン | DNSで管理する名前空間の単位（例：`ex.local`）． |
| ゾーンファイル | ゾーンのレコード情報を記述したテキストファイル． |
| Primary（master） | ゾーンファイルを保持し，権威ある情報を提供するDNS． |
| Secondary（slave） | PrimaryからAXFRでゾーンを取得して提供するDNS．冗長化目的． |
| AXFR | Full Zone Transfer．ゾーン全体をTCPで転送するDNSプロトコル． |
| IXFR | Incremental Zone Transfer．差分のみ転送．NSDではAXFRがメイン． |
| NOTIFY | Primaryがゾーン更新時にSecondaryへ通知するDNSプロトコル． |
| SOAレコード | ゾーンの管理情報を保持するレコード（serial，refresh等）． |
| NSレコード | ゾーンを管轄するネームサーバーを示すレコード． |
| Aレコード | ホスト名からIPv4アドレスへのマッピング． |
| TTL | Time To Live．DNSキャッシュの保持時間（秒）． |
| シリアル番号 | ゾーンのバージョン番号．SecondaryはこれでPrimaryの更新を検知する． |
| TSIG | Transaction Signature．DNS通信を共通鍵で認証する仕組み．本手順書では`NOKEY`（未使用）． |
| FQDN | Fully Qualified Domain Name．完全修飾ドメイン名（例：`az2-db.ex.local`）． |
| systemd-resolved | systemd付属のローカルDNSキャッシュ／リゾルバ． |

------------------------------

### D. 補足解説

- **なぜUDP/53だけでなくTCP/53も必要か？**
  - 通常のDNS問い合わせはUDP/53で行うが，応答サイズが512バイト（EDNSなら4096バイト）を超える場合は自動的にTCP/53にフォールバックする．
  - **AXFR（ゾーン転送）は仕様上TCP/53必須**．UDP/53しか開放していないとSecondaryへのゾーン転送が失敗する．
  - SG設定では必ずUDP/53とTCP/53の両方を許可すること．

- **シリアル番号の運用ルール**
  - 形式：`YYYYMMDDnn`（例：`2026061801` ＝ 2026年6月18日の1回目の更新）が一般的．
  - ゾーンファイルを更新したら **必ずシリアルをインクリメント** する．忘れるとSecondaryへ転送されない．
  - インクリメント後 `nsd-control reload ex.local` を実行し，Secondaryで `nsd-control zonestatus ex.local` で新しいシリアルが反映されたか確認．

- **PrimaryとSecondaryの設定差分**
  - Primary側：`provide-xfr: <Secondary DNSのIP> NOKEY` / `notify: <Secondary DNSのIP> NOKEY`
  - Secondary側：`request-xfr: <Primary DNSのIP> NOKEY` / `allow-notify: <Primary DNSのIP> NOKEY`
  - **宛先が逆方向** であることに注意．Primaryは「Secondaryに対して提供／通知」，SecondaryはPrimaryに対して「要求／許可」．

- **`spal-release` の位置づけ**
  - Amazon Linux 2023の標準リポジトリではNSDが提供されないため，追加リポジトリ `spal-release` を使う．
  - これは検証環境向けの設定．本番環境では別の方法（自前ビルド，BIND/Unboundの併用等）を検討する場合がある．

- **systemd-resolvedとの関係**
  - systemd-resolved は `/etc/systemd/resolved.conf.d/ex-local.conf` の設定で内部DNSを参照する．
  - **NSDが落ちている状態で systemd-resolved が NSDを指したままだと自サーバーの名前解決が失敗する** ため，ロールバック時には先にresolved.conf.dのドロップインを削除すること．
  - また，systemd-resolved自身が53番のスタブリスナーを持つ場合がある（`DNSStubListener=yes`）．NSDが53番を使うのと競合する可能性があるため，NSDが起動しない場合は `DNSStubListener=no` を検討する．

- **NOTIFY と AXFR のフロー**

  ```
  1. Primary でゾーンファイル更新 + serialインクリメント
  2. Primary: nsd-control reload ex.local
  3. Primary → Secondary に NOTIFY 送信（UDP/53）
  4. Secondary がNOTIFYを受信
  5. Secondary → Primary に AXFR要求（TCP/53）
  6. Primary → Secondary にゾーン転送（TCP/53）
  7. Secondary: zonestatus で新シリアル反映を確認
  ```

- **`dnf update` と `dnf upgrade` の違い**
  - DNFベースのAmazon Linux 2023では両者は同義．本手順書では `dnf update -y` に統一．

- **同居構成の注意点**
  - 本構成ではPrimaryはAZ2のAPサーバーと，SecondaryはAZ4のAPサーバーと同居する．
  - Tomcat構築手順書（`tomcat-basic.md`）等で既に`system-setup`を実施済みの場合は重複実施を避けること．
