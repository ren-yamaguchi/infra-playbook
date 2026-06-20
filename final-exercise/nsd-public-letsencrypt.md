# NSDによる対外DNS構築とLet's Encrypt証明書取得

------------------------------

## 1. ドキュメント情報

| 項目 | 内容 |
|------|------|
| 手順書名 | NSDによる対外DNS構築とLet's Encrypt証明書取得 |
| 作成日 | 2026-06-18 |
| 最終更新日 | 2026-06-18 |
| バージョン | v1.0 |
| 対象環境 | AWS（Amazon Linux 2023） |

> **改訂履歴**
>
> | バージョン | 日付 | 変更内容 |
> |-----------|------|---------|
> | v1.0 | 2026-06-18 | 初版作成（元`ACM-ALB構築手順書.md`を機能分割して再構成．本手順書はNSDによる対外DNS構築とLet's Encrypt証明書取得までを範囲とする．ACMインポート以降は別手順書`alb-acm-https.md`を参照．構成図追加．プレースホルダーを意味ベース日本語に統一．パラメータ定義表を整理．各Stepに【実施対象】明示．句読点を「，．」に統一．サーバー表記を「サーバー」に統一．付録A〜D追加．） |

------------------------------

## 2. 目的・概要

### 2-1. 目的

> 本手順書では，AWSのEC2インスタンス上に構築したNSD（Name Server Daemon）に対して，対外公開する権威DNSゾーン（親ドメインおよびサブドメイン）を設定し，Let's EncryptのDNS-01認証を用いてサブドメイン用のSSL/TLS証明書を取得するまでの手順について説明する．
> 取得した証明書ファイル（`cert.pem` / `privkey.pem` / `chain.pem`）は，別手順書（`alb-acm-https.md`）でACMにインポートし，ALBに紐付けてHTTPS化に利用する．
>
> **本手順書の範囲：** NSD設定 → DNS委譲 → certbotで証明書取得まで．
> **本手順書の範囲外：** ACMへのインポート以降（`alb-acm-https.md`を参照）．

### 2-2. 構成概要（アーキテクチャ）

```
[インターネット] (Let's Encrypt の ACME サーバー)
       │
       │ ACME / DNS-01 認証
       │ 「_acme-challenge.<取得するサブドメイン>」のTXT問い合わせ
       │
┌──────┼─────── インターネット ──────┐
│      │                              │
│      ▼                              │
│  [Route53]                          │
│   <親ドメイン> NS ─→ ns.<親ドメイン>   │
│   ns.<サブドメイン> NS ─→ NSDサーバー │
│      │                              │
└──────┼──────────────────────────────┘
       │
       │ DNS委譲
       │
┌──────┼─────── VPC ───────────┐
│      ▼                       │
│  [EC2: 対外DNSサーバー(NSD)]    │
│      ├─ EIP                  │
│      ├─ UDP/TCP 53           │
│      └─ ゾーン定義             │
│           ├─ <親ドメイン>      │
│           └─ <サブドメイン>     │
│                 ├─ A          │
│                 └─ _acme-challenge TXT (certbot で追加) │
│                                │
│  [EC2: 操作元(同じNSDサーバーでも可)]  │
│      └─ certbot              │
│           └─ DNS-01 認証      │
│           └─ 証明書取得        │
│                ↓              │
│   /etc/letsencrypt/live/<取得するサブドメイン>/ │
│        ├─ cert.pem            │
│        ├─ privkey.pem         │
│        ├─ chain.pem           │
│        └─ fullchain.pem       │
│                ↓              │
│   別手順書 `alb-acm-https.md` へ │
└─────────────────────────────────┘
```

### 2-3. 完成イメージ（ゴール定義）

- [ ] NSDサーバーで`nsd.service` が`active (running)`かつ自動起動有効である
- [ ] `<親ドメイン>` のゾーンファイルが作成され`nsd-checkzone` が成功する
- [ ] `<取得するサブドメイン>` のゾーンファイルが作成され`nsd-checkzone` が成功する
- [ ] Route53で `<親ドメイン>` のNSレコード，および `<取得するサブドメイン>` のNS／A委譲が登録されている
- [ ] インターネットから `dig NS <取得するサブドメイン>` が `ns.<取得するサブドメイン>` を返す
- [ ] `certbot` がインストール済みで `certbot --version` が正常応答する
- [ ] `/etc/letsencrypt/live/<取得するサブドメイン>/` に4ファイル（`cert.pem` / `privkey.pem` / `chain.pem` / `fullchain.pem`）が存在する
- [ ] `openssl x509 -in cert.pem -noout -dates` で有効期限が表示される（取得から90日間）

------------------------------

## 3. 前提条件・準備

### 3-1. 環境要件

| 項目 | 要件 |
|------|------|
| OS | Amazon Linux 2023 |
| 配置サブネット | Public subnet（インターネットからのDNS問い合わせを受けるため） |
| Elastic IP | NSDサーバーに付与済み |
| ドメイン | `<親ドメイン>` がRoute53で管理されていること |
| NSD | インストール済み（`nsd-private-redundancy.md` または別途構築） |
| IAM | Route53にNSレコードを設定できる権限 |
| インターネット接続 | dnf／pip3／certbotのACME通信に必須 |

### 3-2. セキュリティグループ設定

#### 3-2-1. 対外DNSサーバーのインバウンドルール

| タイプ | プロトコル | ポート範囲 | ソース | 説明 |
|-------|------------|----------|--------|------|
| SSH | TCP | 22 | マイIP | 構築作業用 |
| DNS (UDP) | UDP | 53 | 0.0.0.0/0 | **インターネットからのDNS問い合わせ受信に必須** |
| DNS (TCP) | TCP | 53 | 0.0.0.0/0 | 512バイト超のDNS応答用 |

#### 3-2-2. 対外DNSサーバーのアウトバウンドルール

| タイプ | プロトコル | ポート範囲 | 送信先 | 説明 |
|-------|------------|----------|--------|------|
| HTTPS | TCP | 443 | 0.0.0.0/0 | dnf／pip3／Let's Encrypt ACME通信 |
| HTTP | TCP | 80 | 0.0.0.0/0 | dnfミラー |

> **重要：** 対外DNSサーバーは **Public subnet** に配置し，EIPを付与すること．Private subnetでは外部からのDNS問い合わせが届かない．

### 3-3. パラメータ定義表

> **注意：** 以下の値は作業前に環境に合わせて記入してから作業を開始すること．

#### 共通

| パラメータ名 | 値 | 説明 |
|------------|---|------|
| `<親ドメイン>` | `<記入する>` | 既にRoute53で管理しているルートドメイン（例：`example.net`） |
| `<取得するサブドメイン>` | `<記入する>` | 証明書取得対象のサブドメイン（例：`web.example.net`） |
| `<NSDサーバーのEIP>` | `<記入する>` | NSDサーバーに付与済みのElastic IP |
| `<SOA管理者メール>` | `<記入する>` | 例：`admin.example.net.`（`@`→`.`に置換，末尾`.`必須） |
| `<ゾーンシリアル>` | 例：`20260618` | ゾーンの更新日（YYYYMMDDnn形式推奨） |
| `<リージョン>` | 例：`us-west-2` | AWSリージョン |

#### ロールバック用（任意）

| パラメータ名 | 値 | 説明 |
|------------|---|------|
| `<NSDバックアップディレクトリ>` | `/etc/nsd/backup` | 作業前のNSD設定ファイルのバックアップ先 |

### 3-4. リンク一覧

| 項目名 | 目的 |
|-------|------|
| https://letsencrypt.org/docs/ | Let's Encrypt公式ドキュメント |
| https://eff-certbot.readthedocs.io/ | certbot公式ドキュメント |
| https://nsd.docs.nlnetlabs.nl/en/latest/ | NSD公式ドキュメント |
| https://datatracker.ietf.org/doc/html/rfc8555 | ACME（RFC 8555） |
| https://docs.aws.amazon.com/ja_jp/Route53/latest/DeveloperGuide/ | Route53公式ガイド |

### 3-5. 作業前バックアップ（必須）

> **重要：** NSD設定変更を伴うため，作業前に設定ファイルをバックアップする．

#### 操作手順【実施対象：対外DNSサーバー】

```bash
sudo su -

# バックアップディレクトリ作成
mkdir -p <NSDバックアップディレクトリ>

# 設定ファイル・ゾーンファイルのバックアップ
cp -p /etc/nsd/*.conf <NSDバックアップディレクトリ>/
cp -p /etc/nsd/*.zone <NSDバックアップディレクトリ>/ 2>/dev/null || true

# バックアップ確認
ls -lh <NSDバックアップディレクトリ>/
```

> **補足：** 既存ゾーンファイルが無い場合は `cp: *.zone: No such file or directory` と表示されるが問題なし．

### 3-6. 事前確認

#### 3-6-1. NSDの動作確認【実施対象：対外DNSサーバー】

```bash
nsd --version
systemctl status nsd --no-pager
```

> **確認：** `NSD version 4.x.x` および `active (running)`．

> **注意：** NSDが未インストールの場合は別手順書（`nsd-private-redundancy.md`等）を先に実施すること．

#### 3-6-2. Route53管理状態の確認【実施対象：ローカルPC】

```bash
# 親ドメインのNSレコードがRoute53で管理されているか確認
dig NS <親ドメイン> +short
```

> **期待する結果：** AWS Route53のネームサーバー（`ns-XXX.awsdns-XX.com` 等）が4件返る．

#### 3-6-3. ディスク空き容量確認【実施対象：対外DNSサーバー】

```bash
df -h /etc /var
```

> **確認：** `/etc` および `/var` に1GB以上の空き容量があること．

#### 3-6-4. certbotのインストール確認【実施対象：対外DNSサーバー】

```bash
certbot --version 2>/dev/null
```

- 未インストールの場合 → Step 1でインストールする
- インストール済みの場合 → Step 1はスキップ可

------------------------------

## 4. 構築手順（詳細）

> **注意事項**
> - コマンド中の `<山カッコ>` は自分の環境の値（パラメータ定義表の値）に置き換えること
> - 各Stepの見出し末尾に **【実施対象：●●】** を明示しているので，対象のサーバーで実施すること
> - DNS委譲（Step 4）はRoute53管理者の対応待ちが発生する可能性があるため，余裕を持って実施すること
> - 既に内部DNS（`nsd-private-redundancy.md`）でNSDを構築済みの場合は，`nsd.conf` の既存内容を維持しつつ本手順のzoneセクションを追加すること

------------------------------

### Step 1：certbotのインストール【実施対象：対外DNSサーバー】

**目的：** Let's Encrypt証明書取得ツール（certbot）をAmazon Linux 2023にインストールする

#### 操作手順

```bash
# pip3でインストール（AL2023標準リポジトリにはcertbotが含まれないため）
dnf install -y python3-pip
pip3 install certbot

# 動作確認
certbot --version
```

> **期待する結果：** `certbot 2.x.x` が表示される．

> **注意：** `dnf install -y certbot` はAL2023の標準リポジトリにパッケージが存在しないため失敗する．**必ず `pip3 install` を使用すること**．

------------------------------

### Step 2：NSD設定ファイル編集（親ドメインゾーン追加）【実施対象：対外DNSサーバー】

**目的：** NSDで `<親ドメイン>` を管理するための基本設定を追加する

#### 操作手順

```bash
vi /etc/nsd/nsd.conf
```

既に内部DNS構築済みの場合は，**既存の`server:`セクション・他のzoneセクションを維持** しつつ，以下のzoneセクションを追記する：

```
zone:
    name: "<親ドメイン>"
    zonefile: "<親ドメイン>.zone"
```

新規インストールの場合は，`server:` セクションを以下のように設定し，併せて上記zoneを追記する：

```
server:
    ip-address: 0.0.0.0
    ip-address: ::0
    port: 53
    username: nsd
    zonesdir: "/etc/nsd"
    logfile: "/var/log/nsd.log"
    pidfile: "/run/nsd/nsd.pid"

zone:
    name: "<親ドメイン>"
    zonefile: "<親ドメイン>.zone"
```

> **補足：** zone:セクションは複数記載可能．内部DNS手順書（`nsd-private-redundancy.md`）で `wp.local` ゾーンを既に定義している場合は，それを残したまま本zoneを追加する．

------------------------------

### Step 3：親ドメインのゾーンファイル作成【実施対象：対外DNSサーバー】

**目的：** `<親ドメイン>` のDNSレコードを定義する

#### 操作手順

```bash
vi /etc/nsd/<親ドメイン>.zone
```

設定ファイルの記述内容：

```
$TTL 3600
@ IN SOA ns.<親ドメイン>. <SOA管理者メール> (
    <ゾーンシリアル>     ; serial (YYYYMMDDNN 形式)
    3600                ; refresh
    3600                ; retry
    3600                ; expire
    3600 )              ; minimum

    IN NS ns.<親ドメイン>.

ns  IN A  <NSDサーバーのEIP>
www IN A  <NSDサーバーのEIP>
```

> **注意：**
> - Aレコードのアドレスは自分の環境に合わせて `<NSDサーバーのEIP>` に置き換える．
> - シリアルは `YYYYMMDDNN` 形式（末尾2桁が連番）．同日に複数回変更する場合は末尾をインクリメントしないとNSDが更新を認識しない．

------------------------------

### Step 4：DNS委譲申請（Route53）【実施対象：Route53管理者／AWSコンソール】

**目的：** Route53の `<親ドメイン>` ゾーンに，本NSDサーバーをネームサーバーとする委譲を設定する

#### 操作手順

Route53管理者に以下のレコード登録を依頼する：

```
対象ドメイン: <親ドメイン>

追加するレコード（Route53の<親ドメイン>ホストゾーン内）：
- NSレコード: <親ドメイン> → ns.<親ドメイン>（既存のRoute53 NSと並列で追加，もしくはサブドメイン委譲）
- Aレコード:  ns.<親ドメイン> → <NSDサーバーのEIP>
```

または，`<取得するサブドメイン>` のみNSDで管理する場合：

```
対象ドメイン: <取得するサブドメイン>

追加するレコード（Route53の<親ドメイン>ホストゾーン内）：
- NSレコード: <取得するサブドメイン> → ns.<取得するサブドメイン>
- Aレコード:  ns.<取得するサブドメイン> → <NSDサーバーのEIP>
```

#### 委譲反映確認

```bash
# Route53管理者の対応後（数分〜数十分かかる）
dig NS <取得するサブドメイン> +short
```

> **期待する結果：** `ns.<取得するサブドメイン>.` が返る．

> **注意：** 反映に時間がかかる場合があるため，返答が得られるまで定期的に確認する．EIP変更時はAレコードも再登録が必要．

------------------------------

### Step 5：サブドメインゾーンの追加【実施対象：対外DNSサーバー】

**目的：** Let's Encrypt認証用の `<取得するサブドメイン>` ゾーンを追加する

#### 操作手順

##### Step 5-1：nsd.confにzoneセクションを追記

```bash
vi /etc/nsd/nsd.conf
```

末尾に追記：

```
zone:
    name: "<取得するサブドメイン>"
    zonefile: "<取得するサブドメイン>.zone"
```

##### Step 5-2：ゾーンファイルを新規作成

```bash
vi /etc/nsd/<取得するサブドメイン>.zone
```

設定ファイルの記述内容：

```
$TTL 3600
@ IN SOA ns.<取得するサブドメイン>. <SOA管理者メール> (
    <ゾーンシリアル>     ; serial (YYYYMMDDNN 形式)
    3600                ; refresh
    3600                ; retry
    3600                ; expire
    3600 )              ; minimum

    IN NS ns.<取得するサブドメイン>.

ns  IN A  <NSDサーバーのEIP>
```

> **補足：** この時点では `_acme-challenge` のTXTレコードは不要．Step 6でcertbotから得た値を追記する．

##### Step 5-3：NSD設定ファイル検証

```bash
# nsd.conf 構文チェック
nsd-checkconf /etc/nsd/nsd.conf

# ゾーンファイル構文チェック
nsd-checkzone <親ドメイン> /etc/nsd/<親ドメイン>.zone
nsd-checkzone <取得するサブドメイン> /etc/nsd/<取得するサブドメイン>.zone
```

> **期待する結果：** `nsd-checkconf` は何も出力されない．`nsd-checkzone` は `zone <名前> is ok` が返る．

##### Step 5-4：NSD再起動

```bash
systemctl restart nsd
systemctl status nsd --no-pager
```

> **期待する結果：** `active (running)`．

> **重要：** `nsd-checkconf` / `nsd-checkzone` はNSD付属のツール．BIND用の `named-checkzone` とは別物なので混在させないこと．

------------------------------

### Step 6：Let's Encrypt証明書取得（DNS-01認証）【実施対象：対外DNSサーバー】

**目的：** certbotでDNS-01認証を実施し，`<取得するサブドメイン>` のSSL/TLS証明書を取得する

#### 操作手順

##### Step 6-1：certbot実行

```bash
certbot certonly --manual --preferred-challenges dns \
    -d <取得するサブドメイン> \
    --register-unsafely-without-email \
    --agree-tos
```

> **補足：** メール登録する場合は `--register-unsafely-without-email` を外し `-m <メールアドレス>` を指定．

##### Step 6-2：certbotが表示するTXTレコード値を控える

certbotが以下のような表示を出すので，**TXT値（ランダム文字列）を控える**：

```
Please deploy a DNS TXT record under the name:
_acme-challenge.<取得するサブドメイン>

with the following value:
<TXT値>

Before continuing, verify the record is deployed.
```

**この時点で次に進む前にcertbotを中断せずそのままにしておくこと**．

##### Step 6-3：ゾーンファイルにTXTレコードを追記（別のターミナルで作業）

別のターミナルセッションを開いて以下を実施：

```bash
sudo su -
vi /etc/nsd/<取得するサブドメイン>.zone
```

設定ファイルの編集内容（serialをインクリメント＋TXTレコード追加）：

```
$TTL 3600
@ IN SOA ns.<取得するサブドメイン>. <SOA管理者メール> (
    <ゾーンシリアル+1>   ; serial (同日2回目の変更なのでインクリメント)
    3600                ; refresh
    3600                ; retry
    3600                ; expire
    3600 )              ; minimum

    IN NS ns.<取得するサブドメイン>.

ns               IN A    <NSDサーバーのEIP>
_acme-challenge  IN TXT  "<TXT値>"
```

> **重要：** TXT値はダブルクォートで囲むこと．

##### Step 6-4：NSDに設定を反映

```bash
# ゾーンファイル構文チェック
nsd-checkzone <取得するサブドメイン> /etc/nsd/<取得するサブドメイン>.zone

# 再起動
systemctl restart nsd
```

##### Step 6-5：DNS伝播確認

```bash
# 自NSDに対して直接問い合わせて確認
dig TXT _acme-challenge.<取得するサブドメイン> @<NSDサーバーのEIP> +short
```

> **期待する結果：** `"<TXT値>"` が返る．

念のため，外部のリゾルバ経由でも確認：

```bash
dig TXT _acme-challenge.<取得するサブドメイン> +short
```

##### Step 6-6：certbotで認証続行

最初のcertbot画面に戻り，**Enterキーを押す**．

certbotがLet's EncryptのACMEサーバーに対してDNS-01認証を依頼し，成功すれば証明書が発行される．

##### Step 6-7：証明書ファイルの確認

```bash
ls -lh /etc/letsencrypt/live/<取得するサブドメイン>/
```

> **期待する結果：** 以下4ファイルが存在する：
>
> | ファイル | 用途 |
> |---|---|
> | `cert.pem` | サーバー証明書 |
> | `privkey.pem` | 秘密鍵 |
> | `chain.pem` | 中間CA証明書チェーン |
> | `fullchain.pem` | `cert.pem` + `chain.pem` の連結 |

> **有効期限：** 取得から90日間．期限前に `certbot renew` で更新する（付録D-4を参照）．

------------------------------

## 5. 動作確認・検証

### 5-1. 確認チェックリスト

- [ ] **確認①**：NSDサービスが`active (running)`かつ自動起動有効
- [ ] **確認②**：UDP/53とTCP/53がLISTEN
- [ ] **確認③**：両ゾーンが `state: ok` でロードされている
- [ ] **確認④**：自NSDに対する `dig` で名前解決成功
- [ ] **確認⑤**：DNS委譲済みでインターネット経由でも `dig NS` で応答
- [ ] **確認⑥**：`/etc/letsencrypt/live/<取得するサブドメイン>/` の4ファイルが存在
- [ ] **確認⑦**：証明書の有効期限が約90日後になっている

------------------------------

### 確認①：NSDサービス状態確認【実施対象：対外DNSサーバー】

```bash
systemctl status nsd --no-pager
systemctl is-enabled nsd
```

> **期待する結果：** `active (running)` および `enabled`．

------------------------------

### 確認②：リッスンポート確認【実施対象：対外DNSサーバー】

```bash
ss -lnp | grep :53
```

> **期待する結果：** UDP・TCP両方で `0.0.0.0:53` がLISTEN．

------------------------------

### 確認③：ゾーン状態確認【実施対象：対外DNSサーバー】

```bash
nsd-control zonestatus <親ドメイン>
nsd-control zonestatus <取得するサブドメイン>
```

> **期待する結果：** どちらも `state: ok` かつ `served-serial` が表示される．

------------------------------

### 確認④：自NSDへの名前解決テスト【実施対象：対外DNSサーバー】

```bash
dig @127.0.0.1 ns.<親ドメイン> A +short
dig @127.0.0.1 ns.<取得するサブドメイン> A +short
```

> **期待する結果：** `<NSDサーバーのEIP>` が返る．

------------------------------

### 確認⑤：インターネット経由のDNS委譲確認【実施対象：ローカルPC】

```bash
dig NS <取得するサブドメイン> +short
```

> **期待する結果：** `ns.<取得するサブドメイン>.`

> **注意：** Route53管理者の対応が完了し，DNS伝播が済むまで時間がかかる場合がある（数分〜数十分）．

------------------------------

### 確認⑥：証明書ファイル存在確認【実施対象：対外DNSサーバー】

```bash
ls -lh /etc/letsencrypt/live/<取得するサブドメイン>/
```

> **期待する結果：** `cert.pem` / `privkey.pem` / `chain.pem` / `fullchain.pem` の4ファイル．

------------------------------

### 確認⑦：証明書有効期限確認【実施対象：対外DNSサーバー】

```bash
openssl x509 -in /etc/letsencrypt/live/<取得するサブドメイン>/cert.pem -noout -dates
```

> **期待する結果：**
>
> ```
> notBefore=Jun  1 12:34:56 2026 GMT
> notAfter=Aug 30 12:34:56 2026 GMT
> ```
>
> 取得日から約90日後の `notAfter` が表示される．

------------------------------

### 5-2. 次のステップ

本手順書での作業が完了したら，別手順書 `alb-acm-https.md` に進み，取得した証明書ファイルをACMにインポートしてALBに紐付けること．

------------------------------

## 6. トラブルシューティング

### よくあるエラーと対処法

------------------------------

#### エラー①：`dig NS <取得するサブドメイン>` で応答が返らない

**原因：** Route53のDNS委譲がまだ反映されていない，もしくはNSレコードの値が誤っている．

**対処法：**

1. Route53コンソールで `<親ドメイン>` ホストゾーンを開き，`<取得するサブドメイン>` のNSレコードが登録されているか確認．
2. NSレコードの値が `ns.<取得するサブドメイン>.` になっているか確認（末尾の `.` も含む）．
3. AレコードでDNSサーバーのEIPが正しく指されているか確認．
4. 反映に数分〜数十分かかる場合があるため，しばらく待ってから再度 `dig` で確認．

------------------------------

#### エラー②：certbotで「DNS problem: NXDOMAIN looking up TXT for _acme-challenge」

**原因：** TXTレコードがNSDに登録されていない，またはNSDのリロード忘れ．

**対処法：**

```bash
# ゾーンファイルにTXTレコードが追記されているか確認
grep "_acme-challenge" /etc/nsd/<取得するサブドメイン>.zone

# serialがインクリメントされているか確認
grep "serial" /etc/nsd/<取得するサブドメイン>.zone

# 反映されていない場合
nsd-checkzone <取得するサブドメイン> /etc/nsd/<取得するサブドメイン>.zone
systemctl restart nsd

# 自NSDから直接TXTを引いてみる
dig TXT _acme-challenge.<取得するサブドメイン> @<NSDサーバーのEIP> +short
```

------------------------------

#### エラー③：DNS応答はあるが certbotで「Incorrect TXT record」エラー

**原因：** TXT値がcertbotが指示したものと異なっている（コピペミス／ダブルクォート抜け／serial未更新で前回値が応答）．

**対処法：**

```bash
# certbot画面の表示と /etc/nsd/<取得するサブドメイン>.zone のTXT値が一致しているか確認
# 一致していなければ修正＋serialをさらにインクリメント
vi /etc/nsd/<取得するサブドメイン>.zone

nsd-checkzone <取得するサブドメイン> /etc/nsd/<取得するサブドメイン>.zone
systemctl restart nsd
dig TXT _acme-challenge.<取得するサブドメイン> @<NSDサーバーのEIP> +short
```

------------------------------

#### エラー④：`pip3 install certbot` が失敗する

**原因：** Python3 / pip3が未インストール，もしくはネットワーク到達不可．

**対処法：**

```bash
# Python3とpip3のインストール状況
which python3
which pip3
dnf install -y python3-pip

# プロキシ環境下なら .pip/pip.conf 設定，もしくは pip3 install --proxy=... を使う
# SGアウトバウンドで443/80が許可されているか確認
```

------------------------------

#### エラー⑤：NSDが起動失敗（`address already in use`）

**原因：** systemd-resolvedのスタブリスナーがUDP/53を占有している．

**対処法：** `nsd-private-redundancy.md` のトラブルシューティング⑤を参照．

------------------------------

### ログの確認場所

| ログの種類 | 場所 |
|-----------|------|
| NSDログ | `/var/log/nsd.log` |
| systemdログ | `journalctl -u nsd` |
| certbotログ | `/var/log/letsencrypt/letsencrypt.log` |
| ゾーン状態 | `nsd-control zonestatus <ゾーン名>` |

------------------------------

## 7. 参考リソース・関連資料

| 資料名 | URL / 場所 | 補足 |
|-------|-----------|------|
| Let's Encrypt 公式 | https://letsencrypt.org/docs/ | プロジェクト全般 |
| certbot ユーザーガイド | https://eff-certbot.readthedocs.io/ | コマンド仕様 |
| NSD 公式ドキュメント | https://nsd.docs.nlnetlabs.nl/en/latest/ | NSD設定リファレンス |
| ACME (RFC 8555) | https://datatracker.ietf.org/doc/html/rfc8555 | 自動証明書発行プロトコル |
| Route53 開発者ガイド | https://docs.aws.amazon.com/ja_jp/Route53/latest/DeveloperGuide/ | DNS委譲・レコード設定 |
| 別手順書：内部DNS構築 | `nsd-private-redundancy.md` | 内部名前解決の構築 |
| 別手順書：ALB+ACMでのHTTPS化 | `alb-acm-https.md` | 本手順書完了後の作業 |

------------------------------

## 8. ロールバック手順

### 8-1. ロールバック判定基準

以下の場合，直ちにロールバックを実施する：

- `<親ドメイン>` の名前解決が壊れて既存サービスに影響が出ている
- certbot認証が複数回失敗してLet's Encryptのレート制限に達した
- NSDが起動できなくなった

> **注意：** 既存サービスへの影響が最優先．証明書取得失敗は再試行可能なので慌てなくてよい．

------------------------------

### 8-2. NSD設定のバックアップからの復元【実施対象：対外DNSサーバー】

```bash
# バックアップ確認
ls <NSDバックアップディレクトリ>/

# 復元
cp -f <NSDバックアップディレクトリ>/*.conf /etc/nsd/
cp -f <NSDバックアップディレクトリ>/*.zone /etc/nsd/ 2>/dev/null || true

# 構文チェック
nsd-checkconf /etc/nsd/nsd.conf

# 再起動
systemctl restart nsd
systemctl status nsd --no-pager
```

> **補足：** バックアップが無い場合は，追加した`zone:`セクションと`<親ドメイン>.zone`／`<取得するサブドメイン>.zone`を手動で削除．

### 8-3. 取得済み証明書の削除【実施対象：対外DNSサーバー】

```bash
# Let's Encrypt登録の取り消し
certbot delete --cert-name <取得するサブドメイン>

# 残存ファイルの確認
ls /etc/letsencrypt/live/<取得するサブドメイン>/ 2>/dev/null
ls /etc/letsencrypt/archive/<取得するサブドメイン>/ 2>/dev/null
```

> **注意：** Let's Encryptには「失効（revoke）」の手続きもあるが，証明書が外部に流出していない限り削除のみで十分．

### 8-4. Route53委譲レコードの削除【実施対象：Route53管理者】

Route53コンソールから `<取得するサブドメイン>` のNSレコードとAレコードを削除する．

### 8-5. certbotのアンインストール（任意）【実施対象：対外DNSサーバー】

```bash
pip3 uninstall -y certbot
rm -rf /etc/letsencrypt
```

### 8-6. 完了確認【実施対象：対外DNSサーバー】

```bash
# NSDのゾーン状態
nsd-control zonestatus <親ドメイン> 2>&1 | head -3
nsd-control zonestatus <取得するサブドメイン> 2>&1 | head -3

# DNS応答
dig @127.0.0.1 ns.<親ドメイン> A +short
```

> **期待する結果：** 復元後の元の状態に戻っていること．

------------------------------

## 付録

### A. コマンド解説

| コマンド | 説明 |
|---------|------|
| `dnf install -y python3-pip` | pip3をインストール． |
| `pip3 install certbot` | Pythonパッケージ管理ツールでcertbotをインストール． |
| `certbot certonly --manual --preferred-challenges dns -d <ドメイン>` | DNS-01認証で証明書のみ取得（ウェブサーバー設定はしない）． |
| `certbot --version` | certbotのバージョン確認． |
| `certbot certificates` | 取得済み証明書の一覧表示． |
| `certbot renew` | 有効期限が近い証明書を更新． |
| `certbot delete --cert-name <ドメイン>` | 取得済み証明書をローカルから削除． |
| `nsd-checkconf <設定ファイル>` | NSD設定ファイルの構文チェック． |
| `nsd-checkzone <ゾーン名> <ゾーンファイル>` | ゾーンファイルの構文チェック． |
| `nsd-control zonestatus <ゾーン名>` | 指定ゾーンの状態確認． |
| `nsd-control reload [<ゾーン名>]` | 設定／ゾーンの再読み込み． |
| `dig NS <ドメイン> +short` | 指定ドメインのNSレコードを取得． |
| `dig TXT _acme-challenge.<ドメイン> @<DNS> +short` | 指定DNSにTXTレコードを直接問い合わせ． |
| `dig <名前> A @<DNS> +short` | Aレコードを問い合わせ． |
| `openssl x509 -in <cert.pem> -noout -dates` | 証明書の有効期限を表示． |
| `openssl x509 -in <cert.pem> -noout -text` | 証明書の全情報を表示． |

------------------------------

### B. 設定ファイル解説

**`/etc/nsd/nsd.conf`（対外DNSサーバー）**

本手順書では`zone:`セクションを追加するのみ．`server:`セクションの詳細は内部DNS手順書（`nsd-private-redundancy.md` 付録B）を参照．

```
zone:
    name: "<親ドメイン>"
    zonefile: "<親ドメイン>.zone"

zone:
    name: "<取得するサブドメイン>"
    zonefile: "<取得するサブドメイン>.zone"
```

- `name`：ゾーン名（ドメイン名）．
- `zonefile`：`zonesdir`からの相対パスでゾーンファイル名．

**ゾーンファイル**

| レコード | 意味 |
|---------|------|
| `$TTL 3600` | レコードのデフォルトTTL（秒） |
| `SOA` | ゾーンの管理情報（プライマリNS／管理者メール／シリアル等） |
| `NS` | ゾーンを管轄するネームサーバー |
| `A` | ホスト名→IPv4アドレスのマッピング |
| `TXT` | テキストレコード（DNS-01認証で使用） |

**証明書ファイル（`/etc/letsencrypt/live/<取得するサブドメイン>/`）**

| ファイル | 内容 | 用途 |
|---------|------|------|
| `cert.pem` | サーバー証明書のみ | ACMの「証明書本文」欄に貼る |
| `privkey.pem` | 秘密鍵 | ACMの「プライベートキー」欄に貼る |
| `chain.pem` | 中間CA証明書 | ACMの「証明書チェーン」欄に貼る |
| `fullchain.pem` | `cert.pem` + `chain.pem` | Nginx等のサーバー設定で利用 |

> **注意：** これらは実際にはシンボリックリンクで，実体は `/etc/letsencrypt/archive/<取得するサブドメイン>/` にある．バックアップ時はリンクと実体の両方を含めること．

------------------------------

### C. 用語解説

| 用語 | 説明 |
|------|------|
| 権威DNS | 自分が管理するゾーンの情報に対して権威ある回答を返すDNSサーバー． |
| 対外DNS（外部DNS／パブリックDNS） | インターネットからの問い合わせに応答するDNS．本手順書の対象． |
| 内部DNS（プライベートDNS） | VPC内部からの問い合わせのみに応答するDNS．`nsd-private-redundancy.md`の対象． |
| Route53 | AWSのマネージドDNSサービス．本手順書では委譲元として使用． |
| DNS委譲 | あるドメインの管理権限を別のネームサーバーに渡す仕組み．NSレコードで指定． |
| Let's Encrypt | 無料のSSL/TLS証明書を発行する認証局（CA）． |
| certbot | Let's Encrypt公式の証明書取得ツール． |
| ACME | Automatic Certificate Management Environment．証明書の自動発行プロトコル（RFC 8555）． |
| HTTP-01認証 | Webサーバーの`/.well-known/acme-challenge/`にトークンを配置して証明書取得する方式． |
| DNS-01認証 | DNSのTXTレコードにトークンを設定して証明書取得する方式．ワイルドカード証明書はこれが必須． |
| `_acme-challenge` | DNS-01認証で使うTXTレコードの名前（規約） |
| ワイルドカード証明書 | `*.<ドメイン>` の形で複数サブドメインをカバーする証明書．DNS-01認証必須． |
| EIP | Elastic IP．AWSで固定的に保持できるパブリックIPアドレス． |
| シリアル番号 | ゾーンのバージョン番号．SecondaryやキャッシュはこれでPrimaryの更新を検知する． |
| TTL | Time To Live．DNSキャッシュの保持時間（秒）． |
| 有効期限90日 | Let's Encrypt証明書の特徴．短期化により自動更新運用が前提となる． |

------------------------------

### D. 補足解説

#### D-1. HTTP-01認証 vs DNS-01認証

| 観点 | HTTP-01 | DNS-01 |
|------|---------|--------|
| 認証方式 | Webサーバーにファイルを配置 | DNSにTXTを設定 |
| 必要なもの | 公開Webサーバー（80番） | 自分でDNS変更できる権限 |
| ワイルドカード対応 | × | ◎ |
| 自動化のしやすさ | ◎（webroot指定） | △（DNS API連携が必要） |
| 本手順書での選択 | ─ | ◎ |

本手順書では **DNS-01を採用** ：
- ALB配下のWebサーバー(`/.well-known/`を提供できない構成)でも証明書取得可能
- 同じ手順でワイルドカード証明書取得にも拡張可能

#### D-2. 証明書チェーンの構造

```
[ルートCA証明書] (ブラウザに事前インストール)
       ▲
       │ 署名
       │
[中間CA証明書] (Let's Encrypt R3 等) ← chain.pem
       ▲
       │ 署名
       │
[サーバー証明書] (<取得するサブドメイン>用) ← cert.pem
```

- ブラウザは「ルートCA → 中間CA → サーバー証明書」の連鎖を辿って信頼性を検証する．
- `chain.pem`（中間CA）を **省略するとブラウザによって検証エラー** になる場合がある．
- ACMインポート時には3つを正確に分けて入力すること（次の手順書`alb-acm-https.md`参照）．

#### D-3. Let's Encryptのレート制限

- 同一ドメインあたり週20件まで（証明書発行）．
- 同じ`_acme-challenge`に対する認証失敗が連続すると一時的にブロックされる．
- **本番環境での試行前にステージング環境** (`--server https://acme-staging-v02.api.letsencrypt.org/directory`)で動作確認を推奨．

#### D-4. 90日有効期限と自動更新運用

Let's Encrypt証明書は90日で失効するため，定期的に更新が必要：

```bash
# 更新テスト（実際には更新しない dry-run）
certbot renew --dry-run

# 更新（30日以内に期限切れの場合のみ更新される）
certbot renew
```

**ACMにインポートしているため，certbot renew だけでは ACM側の証明書は更新されない**．更新後はACMへの再インポートも必要．運用設計の詳細：

1. cron／systemd timerで`certbot renew`を週1回実行
2. 更新成功時に`/etc/letsencrypt/renewal-hooks/deploy/`内のフックスクリプトでACMの`import-certificate`をCLI実行
3. 更新失敗をログ監視

#### D-5. EIP変更時の影響と再申請

- EIPを変更すると，`<親ドメイン>.zone` と `<取得するサブドメイン>.zone` のAレコード（`ns IN A`）が変わる．
- Route53で登録した「`ns.<取得するサブドメイン>` → `<NSDサーバーのEIP>`」のAレコードも更新申請が必要．
- 証明書自体はEIP変更の影響を受けない（ドメイン名にバインドされているため）．
- DNSキャッシュTTL（本手順書では3600秒＝1時間）の間は古いIPが返り続けるので，変更前にTTLを短く（300秒等）に設定しておくと切替が早い．

#### D-6. 内部DNS（`wp.local`）と対外DNS（`<親ドメイン>`）の併存

同一NSDサーバーで両方を提供する場合，`nsd.conf` には複数の `zone:` セクションを書くだけでよい：

```
zone:
    name: "wp.local"               ← 内部DNS（nsd-private-redundancy.md由来）
    zonefile: "wp.local.zone"
    include-pattern: "master-wplocal"

zone:
    name: "<親ドメイン>"             ← 本手順書で追加
    zonefile: "<親ドメイン>.zone"

zone:
    name: "<取得するサブドメイン>"    ← 本手順書で追加
    zonefile: "<取得するサブドメイン>.zone"
```

- SGの内部DNS問い合わせ（VPC CIDR）と対外DNS問い合わせ（0.0.0.0/0）は別々に許可する．
- 対外DNSをVPC外から見えるようにするには，NSDサーバーをPublic subnetに置きEIPを付与する必要がある．

#### D-7. `dnf update` と `dnf upgrade` の違い

- DNFベースのAmazon Linux 2023では両者は同義．本手順書では `dnf install -y` のみ使用（システム全体の更新は別作業として実施）．
