# 外部公開DNS（NSD 2台冗長構成）+ Let's Encrypt 証明書取得 構築手順書

------------------------------

## 1. ドキュメント情報

| 項目 | 内容 |
|------|------|
| 手順書名 | 外部公開DNS（NSD 2台冗長構成）+ Let's Encrypt 証明書取得 構築手順書 |
| 作成日 | 2026-06-18 |
| 最終更新日 | 2026-06-20 |
| バージョン | v2.2 |
| 対象環境 | AWS（Amazon Linux 2023 / NSD / certbot） |

> **改訂履歴**v
>
> | バージョン | 日付 | 変更内容 |
> |-----------|------|---------|
> | v1.0 | 2026-06-18 | 初版作成（旧 `nsd-public-letsencrypt.md` として作成．元`ACM-ALB構築手順書.md`を機能分割して再構成．本手順書はNSDによる外部DNS構築とLet's Encrypt証明書取得までを範囲とする．） |
> | v1.1 | 2026-06-20 | 用語「対外」→「外部」に統一．certbotインストール方法を `pip3 install` から `dnf install -y certbot`（AL2023標準リポジトリ）に変更．親ドメインゾーン管理は上長（Route53）担当の方針に基づき，親ドメインゾーンファイル作成を削除．サブドメインのみを管理する構成に改訂．SOA値を構築・検証用の暫定値に変更（本番値併記）． |
> | v2.0 | 2026-06-20 | 外部DNSを **2台冗長構成**（Primary/Secondary）に大規模再構成．ファイル名を `nsd-public-letsencrypt.md` → `nsd-public-redundancy.md` に変更（`nsd-private-redundancy.md` と命名統一）．構成図・SG・パラメータ表・Step群を Primary 側／Secondary 側に分割．Primaryに `provide-xfr`／`notify` 設定，Secondaryに `request-xfr`／`allow-notify` 設定を追加．ゾーンファイルのNSレコード／Aレコードを ns1（Primary）／ns2（Secondary）に対応．Route53委譲申請内容を NS 2件＋A 2件に変更．Let's Encrypt証明書取得は Primary 側のみで実施（ゾーン同期により `_acme-challenge` TXTがSecondaryに自動伝播）．動作確認・ロールバック・付録もすべて2台構成に追従． |
> | v2.1 | 2026-06-21 | ゾーン転送（AXFR）・NOTIFY のIP指定を **EIP → プライベートIP** に変更．VPC内通信で完結させ，EIP NAT loopback の不確実性・データ転送料・経路長を回避．対象：Step 2-A の `provide-xfr` / `notify`，Step 2-B の `request-xfr` / `allow-notify`，SG 3-2-3 / 3-2-4 の Primary IP参照，Step 4-B-4 ／エラー① のトラブルシュート `dig AXFR` コマンド，付録B Primary／Secondary 設定例，付録D-6 同居例．インターネット公開向け（NSレコード `ns1 A` / `ns2 A`，Route53委譲申請，外部疎通確認 `dig`，SSH接続）は **EIPのまま維持**．構成図のAXFR/NOTIFYフローに「プライベートIP経由（VPC内）」のラベルを追加．付録D-8「なぜゾーン転送はプライベートIP，インターネット公開はEIPか」を新規追加し，使い分けの根拠を解説． |
> | v2.2 | 2026-06-21 | プレースホルダー命名の手順書内揺れを解消．§2-3 / §3-2-3 / §3-2-4 / §6 トラブルシュート / 付録D-6 で使われていた略記 `<Primary EIP>` `<Secondary EIP>` `<Primary プライベートIP>` `<Secondary プライベートIP>` `<外部DNS Secondary プライベートIP>` を，§3-3 パラメータ表の正式名 `<Primary NSDサーバーのEIP>` `<Secondary NSDサーバーのEIP>` `<Primary NSDサーバーのプライベートIP>` `<Secondary NSDサーバーのプライベートIP>` に統一．付録Aの汎用例示 `<NSDサーバー>`（digコマンドのメタプレースホルダー）は文脈が異なるためそのまま維持． |

------------------------------

## 2. 目的・概要

### 2-1. 目的

> 本手順書では，AWS上に **2台冗長構成（Primary / Secondary）** のNSD（Name Server Daemon）外部公開DNSサーバーを構築し，Let's EncryptのDNS-01認証を用いて `<取得するサブドメイン>` のSSL/TLS証明書を取得するまでの手順について説明する．
>
> 親ドメイン（`<親ドメイン>`）のゾーン管理は上長（Route53）で実施されているため，本手順書では親ドメインのゾーンファイル作成は行わない．サブドメインの **委譲申請** は上長への申請として実施する（Step 3）．
>
> 2台構成にする目的：
> - Primary が単一AZ障害で停止しても，Secondary が DNS応答を継続する
> - 高い名前解決可用性により，世界中のリゾルバへのサービス継続性を確保する
> - Let's Encrypt の `_acme-challenge` 検証時にも片系障害に強い

### 2-2. 構成概要（アーキテクチャ）

```
[インターネット] (Let's Encrypt の ACME サーバー / 世界中のリゾルバ)
       │
       │ ACME / DNS-01 認証
       │ 「_acme-challenge.<取得するサブドメイン>」のTXT問い合わせ
       │
┌──────┼─────── インターネット ─────────────────────────────┐
│      │                                                   │
│      ▼                                                   │
│  [Route53] ← 上長が管理                                   │
│   <親ドメイン> ホストゾーン                                │
│   └─ <取得するサブドメイン> NS ─→ ns1.<取得するサブドメイン> │
│   └─ <取得するサブドメイン> NS ─→ ns2.<取得するサブドメイン> │
│   └─ ns1.<取得するサブドメイン> A ─→ Primary EIP           │
│   └─ ns2.<取得するサブドメイン> A ─→ Secondary EIP         │
│      │                                                   │
└──────┼───────────────────────────────────────────────────┘
       │
       │ DNS委譲（サブドメイン NS×2 / A×2）
       │
┌──────┼─────── VPC ─────────────────────────────────────────────┐
│      ▼                                                         │
│  ┌──────────────────────────┐    ┌──────────────────────────┐  │
│  │ [Public-AZ1]             │    │ [Public-AZ3]             │  │
│  │ EC2: Primary NSD         │    │ EC2: Secondary NSD       │  │
│  │  ├─ EIP (Primary)        │    │  ├─ EIP (Secondary)      │  │
│  │  ├─ UDP/TCP 53           │    │  ├─ UDP/TCP 53           │  │
│  │  ├─ provide-xfr          │◀───┼──┤ request-xfr           │  │
│  │  ├─ notify               │────┼─▶│ allow-notify          │  │
│  │  └─ ゾーンファイル(マスター)│   │  └─ ゾーンファイル(複製)   │  │
│  │    └─ <取得するサブドメイン>│   │     └─ AXFR同期          │  │
│  │         ├─ NS ns1       │     │                          │  │
│  │         ├─ NS ns2       │     │                          │  │
│  │         ├─ ns1 A (Primary EIP)│                          │  │
│  │         ├─ ns2 A (Secondary EIP)│                        │  │
│  │         └─ _acme-challenge TXT (certbot追記)             │  │
│  │                          │    │                          │  │
│  │※ certbot は Primary のみ │    │                          │  │
│  └──────────────────────────┘    └──────────────────────────┘  │
│ ※ AXFR / NOTIFY はプライベートIP経由（VPC内）                   │
│  /etc/letsencrypt/live/<取得するサブドメイン>/ (Primaryに保存)   │
│       ├─ cert.pem                                              │
│       ├─ privkey.pem                                           │
│       ├─ chain.pem                                             │
│       └─ fullchain.pem                                         │
│       │                                                        │
│       ▼                                                        │
│   別手順書 `alb-acm-https.md` へ                                │
└────────────────────────────────────────────────────────────────┘
```

### 2-3. 完成イメージ（ゴール定義）

#### Primary側

- [ ] Primary NSDサーバーで `nsd.service` が `active (running)` かつ自動起動有効
- [ ] `/etc/nsd/<取得するサブドメイン>.zone` が作成され `nsd-checkzone` が成功する
- [ ] `nsd.conf` に `provide-xfr`（Secondaryへの転送許可）と `notify`（Secondaryへの通知）が設定されている
- [ ] certbot が DNS-01 認証に成功し，`/etc/letsencrypt/live/<取得するサブドメイン>/` に証明書ファイルが配置される

#### Secondary側

- [ ] Secondary NSDサーバーで `nsd.service` が `active (running)` かつ自動起動有効
- [ ] `nsd.conf` に `request-xfr`（Primaryからの転送要求）と `allow-notify`（Primaryからの通知受信）が設定されている
- [ ] Primaryから AXFR 経由で `<取得するサブドメイン>` ゾーンが同期されている

#### Route53委譲

- [ ] Route53 `<親ドメイン>` ホストゾーンに `<取得するサブドメイン>` の NS 2件（ns1/ns2）と A 2件（Primary EIP / Secondary EIP）が登録されている（上長対応済み）
- [ ] インターネットから `dig NS <取得するサブドメイン>` が `ns1.<取得するサブドメイン>` と `ns2.<取得するサブドメイン>` を返す
- [ ] インターネットから `dig @<Primary NSDサーバーのEIP> NS <取得するサブドメイン>` と `dig @<Secondary NSDサーバーのEIP> NS <取得するサブドメイン>` がそれぞれ同じレコードを返す（ゾーン同期確認）

------------------------------

## 3. 前提条件・準備

### 3-1. 環境要件

| 項目 | 要件 |
|------|------|
| OS | Amazon Linux 2023 |
| EC2 | 2台（Primary：Public-AZ1 / Secondary：Public-AZ3） |
| インスタンスタイプ | t3.micro 以上推奨 |
| ストレージ | 8GB以上 |
| EIP | 2個（Primary用・Secondary用） |
| サブネット | Public subnet × 2（AZ1 と AZ3） |
| ドメイン | `<親ドメイン>` がRoute53で上長により管理されていること |
| certbot | Primary側のみインストール（AL2023標準リポジトリ） |
| インターネット接続 | dnf／certbotのACME通信に必須 |

### 3-2. セキュリティグループ設定

#### 3-2-1. Primary NSDサーバーのインバウンドルール

| タイプ | プロトコル | ポート範囲 | ソース | 説明 |
|-------|------------|----------|--------|------|
| SSH | TCP | 22 | マイIP（踏み台経由） | 構築作業用 |
| DNS (UDP) | UDP | 53 | 0.0.0.0/0 | インターネットからのDNS問い合わせ受信 |
| DNS (TCP) | TCP | 53 | 0.0.0.0/0 | EDNS非対応や大型応答用．**AXFR にも必要** |

> **重要：** `provide-xfr` で許可するSecondaryのIPは `nsd.conf` 側で制御するため，SGでは `TCP/53` を広く許可しても問題ない（NSD自身がIP制限する）．

#### 3-2-2. Primary NSDサーバーのアウトバウンドルール

| タイプ | プロトコル | ポート範囲 | 送信先 | 説明 |
|-------|------------|----------|--------|------|
| HTTPS | TCP | 443 | 0.0.0.0/0 | dnf／Let's Encrypt ACME通信 |
| HTTP | TCP | 80 | 0.0.0.0/0 | dnfミラー |
| DNS (UDP) | UDP | 53 | 0.0.0.0/0 | NOTIFY送信（SecondaryへのVPC内IP宛て） |
| DNS (TCP) | TCP | 53 | 0.0.0.0/0 | AXFR応答 |

#### 3-2-3. Secondary NSDサーバーのインバウンドルール

| タイプ | プロトコル | ポート範囲 | ソース | 説明 |
|-------|------------|----------|--------|------|
| SSH | TCP | 22 | マイIP（踏み台経由） | 構築作業用 |
| DNS (UDP) | UDP | 53 | 0.0.0.0/0 | インターネットからのDNS問い合わせ受信 |
| DNS (TCP) | TCP | 53 | 0.0.0.0/0 | EDNS非対応や大型応答用 |
| DNS (UDP) | UDP | 53 | `<Primary NSDサーバーのプライベートIP>/32` | PrimaryからのNOTIFY受信（再掲；全許可で吸収される） |

#### 3-2-4. Secondary NSDサーバーのアウトバウンドルール

| タイプ | プロトコル | ポート範囲 | 送信先 | 説明 |
|-------|------------|----------|--------|------|
| HTTPS | TCP | 443 | 0.0.0.0/0 | dnf |
| HTTP | TCP | 80 | 0.0.0.0/0 | dnfミラー |
| DNS (TCP) | TCP | 53 | `<Primary NSDサーバーのプライベートIP>/32` | Primaryへの AXFR 要求 |

### 3-3. パラメータ定義表

> **注意：** 以下の値は作業前に環境に合わせて記入してから作業を開始すること．

#### 共通

| パラメータ名 | 値 | 説明 |
|------------|---|------|
| `<親ドメイン>` | `<記入する>` | 既にRoute53で管理されているルートドメイン（例：`example.net`） |
| `<取得するサブドメイン>` | `<記入する>` | 本手順書で取得する証明書のFQDN（例：`app.example.net`） |
| `<SOA管理者メール>` | `<記入する>` | SOAレコードのRNAME．`@`を`.`に置換した形式（例：`admin.example.net.`） |
| `<ゾーンシリアル>` | `<記入する>` | ゾーンシリアル．`YYYYMMDDNN`形式（例：`2026062001`） |

#### Primary側

| パラメータ名 | 値 | 説明 |
|------------|---|------|
| `<Primary NSDサーバーのホスト名>` | `<記入する>` | 例：`ns1-pub` |
| `<Primary NSDサーバーのEIP>` | `<記入する>` | Public-AZ1配置NSDのEIP |
| `<Primary NSDサーバーのプライベートIP>` | `<記入する>` | Public-AZ1配置NSDのVPC内IP |

#### Secondary側

| パラメータ名 | 値 | 説明 |
|------------|---|------|
| `<Secondary NSDサーバーのホスト名>` | `<記入する>` | 例：`ns2-pub` |
| `<Secondary NSDサーバーのEIP>` | `<記入する>` | Public-AZ3配置NSDのEIP |
| `<Secondary NSDサーバーのプライベートIP>` | `<記入する>` | Public-AZ3配置NSDのVPC内IP |

#### ロールバック用（任意）

| パラメータ名 | 値 | 説明 |
|------------|---|------|
| `<NSDバックアップディレクトリ>` | `<記入する>` | 例：`/root/nsd-backup-<日付>` |
| `<作業前AMI名>` | `<記入する>` | 作業前スナップショット名（戻す場合のみ記入） |

### 3-4. リンク一覧

| 項目名 | 目的 |
|-------|------|
| https://nlnetlabs.nl/projects/nsd/about/ | NSD公式 |
| https://nlnetlabs.nl/documentation/nsd/nsd.conf/ | nsd.conf リファレンス（provide-xfr / request-xfr / notify / allow-notify） |
| https://letsencrypt.org/docs/ | Let's Encrypt 公式 |
| https://eff-certbot.readthedocs.io/ | certbot 公式 |
| 前提手順書：AWS基盤 | `aws-infrastructure-setup.md` |
| 関連手順書：内部DNS（2台冗長） | `nsd-private-redundancy.md` |
| 後続手順書：ALB + ACM | `alb-acm-https.md` |

### 3-5. 事前確認

#### 3-5-1. NSDインストール状況確認【実施対象：Primary／Secondary 両方】

```bash
sudo su -
dnf list installed | grep nsd
```

> **期待する結果：** 既に `nsd-private-redundancy.md` で内部DNSを構築済みの場合は `nsd` パッケージがインストールされている．新規構築の場合は未インストール．

NSDがインストールされていない場合：

```bash
dnf install -y nsd
```

#### 3-5-2. 親ドメインNSレコード確認【実施対象：Primary】

```bash
dig NS <親ドメイン> +short
```

> **期待する結果：** Route53のネームサーバー（`ns-XXX.awsdns-XX.net.` 等）が返る．

#### 3-5-3. EIP割当確認【実施対象：AWSコンソール】

Primary／Secondary 両方にEIPが割り当てられていることを確認．

```bash
# Primary側EC2で
curl -s ifconfig.me
# → <Primary NSDサーバーのEIP> が返る

# Secondary側EC2で
curl -s ifconfig.me
# → <Secondary NSDサーバーのEIP> が返る
```

#### 3-5-4. NSD設定のバックアップ取得【実施対象：Primary／Secondary 両方】

```bash
mkdir -p <NSDバックアップディレクトリ>
cp -a /etc/nsd <NSDバックアップディレクトリ>/
ls <NSDバックアップディレクトリ>/nsd/
```

#### 3-5-5. AMIスナップショット取得（任意）【実施対象：AWSコンソール】

```
AWS コンソール → EC2 → 各NSDインスタンス → アクション
→ イメージとテンプレート → イメージを作成
→ イメージ名： nsd-public-before-redundancy-<日付>-primary
→ 同様に Secondary 用も作成
```

------------------------------

## 4. 構築手順（詳細）

> **注意事項**
> - コマンド中の `<山カッコ>` は自分の環境の値に置き換えること
> - 各Stepの見出し末尾に **【実施対象：●●】** を明示．**Primary／Secondary を取り違えないように注意**

------------------------------

### Step 1：certbotのインストール【実施対象：Primary NSDサーバー】

**目的：** Let's Encrypt証明書取得ツール（certbot）をPrimaryにのみインストールする

> **重要：** certbotはPrimary側にのみインストールする．Secondaryではゾーン同期で `_acme-challenge` TXTを受け取るので個別のcertbot実行は不要．

#### 操作手順

```bash
# AL2023標準リポジトリからインストール
dnf install -y certbot

# 動作確認
certbot --version
```

> **期待する結果：** `certbot 2.x.x` が表示される．

------------------------------

### Step 2-A：Primary NSD設定ファイル編集【実施対象：Primary NSDサーバー】

**目的：** Primaryで `<取得するサブドメイン>` をマスターゾーンとして提供し，Secondaryへの転送許可と通知を設定する

#### 操作手順

```bash
vi /etc/nsd/nsd.conf
```

既に内部DNS構築済みの場合は，**既存の`server:`セクション・他のzoneセクションを維持** しつつ，以下のzoneセクションを追記する：

```
zone:
    name: "<取得するサブドメイン>"
    zonefile: "<取得するサブドメイン>.zone"

    # Secondary への AXFR 転送を許可（NOTIFY が届く前提）
    provide-xfr: <Secondary NSDサーバーのプライベートIP> NOKEY

    # ゾーン更新時に Secondary へ NOTIFY を送る
    notify: <Secondary NSDサーバーのプライベートIP> NOKEY
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
```

> **補足：**
> - `provide-xfr` で指定するIPは Secondary の **プライベートIP**．VPC内通信で完結させる（理由は付録D-8参照）．
> - `NOKEY` はTSIG認証を使わない設定．本手順書では簡素化のためTSIGなしで構成する．本番強化時はTSIGの導入を検討．

------------------------------

### Step 2-B：Secondary NSD設定ファイル編集【実施対象：Secondary NSDサーバー】

**目的：** Secondaryで `<取得するサブドメイン>` をスレーブゾーンとして登録し，Primaryからのゾーン転送要求と通知受信を設定する

#### 操作手順

```bash
vi /etc/nsd/nsd.conf
```

既に内部DNS構築済みの場合は，**既存の`server:`セクション・他のzoneセクションを維持** しつつ，以下のzoneセクションを追記する：

```
zone:
    name: "<取得するサブドメイン>"
    zonefile: "<取得するサブドメイン>.zone"

    # Primary に AXFR 要求を出す
    request-xfr: AXFR <Primary NSDサーバーのプライベートIP> NOKEY

    # Primary からの NOTIFY 受信を許可
    allow-notify: <Primary NSDサーバーのプライベートIP> NOKEY
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
```

> **重要：** Secondary側では **ゾーンファイル本体を手動作成しない**．Primaryから AXFR で受信して自動生成される．`zonefile:` で指定したパスにNSDが自動的にファイルを作成する．

------------------------------

### Step 3：DNS委譲申請（Route53）【実施対象：Route53管理者（上長）／AWSコンソール】

**目的：** Route53の `<親ドメイン>` ゾーンに，Primary／Secondary をネームサーバーとする `<取得するサブドメイン>` の委譲を設定する

> **前提：** 親ドメインゾーンの管理は上長（Route53）で実施されている．本ステップは上長への委譲申請依頼となる．

#### 申請内容

Route53管理者（上長）に以下のレコード登録を依頼する：

```
対象：<親ドメイン> ホストゾーン（Route53）

追加するレコード（2台冗長構成のため NS×2 + A×2 を登録）：
- NSレコード:  <取得するサブドメイン> → ns1.<取得するサブドメイン>
- NSレコード:  <取得するサブドメイン> → ns2.<取得するサブドメイン>
- Aレコード:   ns1.<取得するサブドメイン> → <Primary NSDサーバーのEIP>
- Aレコード:   ns2.<取得するサブドメイン> → <Secondary NSDサーバーのEIP>

理由：<取得するサブドメイン> の権威DNSを，自分たちが構築する2台冗長NSDサーバー（Primary/Secondary）に委譲するため．
```

#### 委譲反映確認

```bash
# Route53管理者の対応後（数分〜数十分かかる）
dig NS <取得するサブドメイン> +short
```

> **期待する結果：** `ns1.<取得するサブドメイン>.` と `ns2.<取得するサブドメイン>.` の2行が返る．

> **注意：** 反映に時間がかかる場合があるため，返答が得られるまで定期的に確認する．EIP変更時はAレコードの再登録も上長に依頼する．

------------------------------

### Step 4-A：Primary サブドメインゾーンファイル作成【実施対象：Primary NSDサーバー】

**目的：** Primary で `<取得するサブドメイン>` のマスターゾーンファイルを作成する

> **前提：** Step 2-A で `nsd.conf` に `<取得するサブドメイン>` のzoneセクションを既に追記済みであること．本Stepでは参照先のゾーンファイル本体を作成する．

#### 操作手順

##### Step 4-A-1：ゾーンファイルを新規作成

```bash
vi /etc/nsd/<取得するサブドメイン>.zone
```

設定ファイルの記述内容（構築・検証中の暫定値）：

```
$TTL 60
@ IN SOA ns1.<取得するサブドメイン>. <SOA管理者メール> (
    <ゾーンシリアル>     ; serial (YYYYMMDDNN 形式)
    60                  ; refresh
    60                  ; retry
    3600                ; expire
    60 )                ; minimum

    IN NS ns1.<取得するサブドメイン>.
    IN NS ns2.<取得するサブドメイン>.

ns1  IN A  <Primary NSDサーバーのEIP>
ns2  IN A  <Secondary NSDサーバーのEIP>
```

> **注意（TTLについて）：** 本設定の `$TTL` および SOA の `refresh` / `retry` / `minimum` は **構築・検証中の暫定値（60秒）** である．世界中のリゾルバのキャッシュ保持時間と Secondary 同期周期を短くして，レコード変更（Let's Encrypt用 `_acme-challenge` TXT追加など）の反映を早めるため．動作確認完了後は **本番運用向けの推奨値** に変更すること．
>
> | フィールド | 構築・検証中（暫定） | 動作確認完了後（推奨） |
> |---|---|---|
> | `$TTL` | 60 | 300（5分） |
> | `refresh` | 60 | 3600（1時間） |
> | `retry` | 60 | 900（15分） |
> | `expire` | 3600 | 604800（1週間） |
> | `minimum` | 60 | 300（5分） |
>
> `expire` のみ検証中も `3600` にしている理由：`expire ≤ refresh` の状態だと Primary が1分でも応答しないと Secondary がゾーンを破棄してしまうため．RFC 1035の SOA 設計原則に従い `expire > refresh` を維持する．
>
> 本番値で `$TTL` を内部DNS（3600秒）より短い `300秒` に設定する理由：外部公開DNSは世界中のリゾルバにキャッシュされるため，EIP/ALB変更時の伝播を早めたい．AWS Route53のデフォルト値（300秒）に揃える．
>
> 値変更時は `<ゾーンシリアル>` を必ずインクリメントし，`systemctl reload nsd` で反映すること．シリアル更新がないと Secondary が AXFR 同期に来ない．

> **補足：** この時点では `_acme-challenge` のTXTレコードは不要．Step 5でcertbotから得た値を追記する．

##### Step 4-A-2：Primary NSD設定ファイル検証

```bash
# nsd.conf 構文チェック
nsd-checkconf /etc/nsd/nsd.conf

# ゾーンファイル構文チェック
nsd-checkzone <取得するサブドメイン> /etc/nsd/<取得するサブドメイン>.zone
```

> **期待する結果：** `nsd-checkconf` は何も出力されない．`nsd-checkzone` は `zone <取得するサブドメイン> is ok` が返る．

##### Step 4-A-3：Primary NSD起動

```bash
systemctl enable --now nsd
systemctl status nsd --no-pager
```

> **期待する結果：** `active (running)` および `enabled`．

------------------------------

### Step 4-B：Secondary NSD起動とゾーン同期確認【実施対象：Secondary NSDサーバー】

**目的：** Secondary NSDを起動し，PrimaryからAXFRでゾーンが同期されることを確認する

#### 操作手順

##### Step 4-B-1：Secondary NSD設定ファイル検証

```bash
nsd-checkconf /etc/nsd/nsd.conf
```

> **期待する結果：** 何も出力されない．

##### Step 4-B-2：Secondary NSD起動

```bash
systemctl enable --now nsd
systemctl status nsd --no-pager
```

> **期待する結果：** `active (running)` および `enabled`．

##### Step 4-B-3：ゾーン同期確認

NSD起動後，自動的にPrimaryへAXFR要求を送信する．`zonefile:` で指定したパスにファイルが作成される．

```bash
# ゾーンファイルが自動生成されているか確認（数秒〜数十秒かかる場合あり）
ls -la /etc/nsd/<取得するサブドメイン>.zone

# 内容確認
cat /etc/nsd/<取得するサブドメイン>.zone

# NSD のゾーン状態確認
nsd-control zonestatus <取得するサブドメイン>
```

> **期待する結果：**
> - ゾーンファイルが自動生成されている
> - 内容が Primary の `<取得するサブドメイン>.zone` と同じ
> - `nsd-control zonestatus` で `state: ok` かつ `served-serial` が Primary と同値

##### Step 4-B-4：同期失敗時のトラブルシュート

ゾーンファイルが生成されない・空の場合：

```bash
# NSDログ確認
tail -n 50 /var/log/nsd.log
journalctl -u nsd -n 50 --no-pager

# 手動で AXFR 要求送信テスト（本番経路と一致させるためプライベートIPで実行）
dig @<Primary NSDサーバーのプライベートIP> AXFR <取得するサブドメイン>
```

> **チェック項目：**
> - Primary側 `provide-xfr` のIPが Secondary プライベートIP と一致しているか
> - Secondary側 `request-xfr` のIPが Primary プライベートIP と一致しているか
> - PrimaryのSGで TCP/53 が Secondary プライベートIP からのインバウンドを許可しているか
> - PrimaryのプライベートIPがStep 2-Bで設定したIPと一致しているか

------------------------------

### Step 5：Let's Encrypt証明書取得（DNS-01認証）【実施対象：Primary NSDサーバー】

**目的：** Primary側でcertbotでDNS-01認証を実施し，`<取得するサブドメイン>` のSSL/TLS証明書を取得する

> **重要：** 証明書取得は **Primary側のみで実施**．`_acme-challenge` TXTレコードを Primary のゾーンファイルに追記すると，AXFR/NOTIFY により Secondary へ自動同期される．世界中のリゾルバは Primary／Secondary のいずれかから TXTレコードを取得できる．

#### 操作手順

##### Step 5-1：certbot実行

```bash
certbot certonly \
  --manual \
  --preferred-challenges dns \
  --email <SOA管理者メールアドレス> \
  --agree-tos \
  --no-eff-email \
  -d <取得するサブドメイン>
```

> **補足：** `<SOA管理者メールアドレス>` は SOA の RNAME 形式ではなく，通常のメールアドレス形式（`admin@example.net`）．

##### Step 5-2：certbotが表示するTXTレコード値を控える

certbotが以下のような表示で停止する：

```
Please deploy a DNS TXT record under the name:
_acme-challenge.<取得するサブドメイン>

with the following value:
xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx

Before continuing, verify the TXT record has been deployed.
Press Enter to Continue
```

> **重要：** この時点で **Enterを押さずに別ターミナルを開く**．TXTレコード値（`xxxxxxxx...`）をメモしておく．

##### Step 5-3：Primary側ゾーンファイルにTXTレコードを追記

```bash
# 別ターミナルで Primary に接続
vi /etc/nsd/<取得するサブドメイン>.zone
```

`<ゾーンシリアル>` をインクリメントし，末尾にTXTレコードを追記：

```
$TTL 60
@ IN SOA ns1.<取得するサブドメイン>. <SOA管理者メール> (
    <ゾーンシリアル+1>   ; serial (同日2回目の変更なのでインクリメント)
    60                  ; refresh
    60                  ; retry
    3600                ; expire
    60 )                ; minimum

    IN NS ns1.<取得するサブドメイン>.
    IN NS ns2.<取得するサブドメイン>.

ns1  IN A  <Primary NSDサーバーのEIP>
ns2  IN A  <Secondary NSDサーバーのEIP>

_acme-challenge IN TXT "xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"
```

> **重要：** TXTレコードの値は **必ずダブルクォートで囲む**．シリアル番号のインクリメントを忘れるとSecondaryへの同期も世界のキャッシュ反映も起こらない．

##### Step 5-4：Primary でNSDに設定を反映

```bash
# 構文チェック
nsd-checkzone <取得するサブドメイン> /etc/nsd/<取得するサブドメイン>.zone

# ゾーンリロード（NSDの再読み込み）
nsd-control reload

# 自身からTXT問い合わせ確認
dig @127.0.0.1 TXT _acme-challenge.<取得するサブドメイン> +short
```

> **期待する結果：** 追記したTXT値（ダブルクォート付き）が返る．

##### Step 5-5：Secondary でゾーン同期確認

Primary でゾーンをリロードすると NOTIFY が Secondary に送信され，Secondary は AXFR で同期する．

```bash
# Secondary 側で確認
ssh ec2-user@<Secondary NSDサーバーのEIP>
sudo su -

# シリアル確認（Primary と同値になっているか）
nsd-control zonestatus <取得するサブドメイン>

# TXT 確認
dig @127.0.0.1 TXT _acme-challenge.<取得するサブドメイン> +short
```

> **期待する結果：** Primary と同じシリアル番号と同じTXT値が返る．

> **注意：** 同期に時間がかかる場合 `nsd-control transfer <取得するサブドメイン>` を Secondary で実行すると手動同期できる．

##### Step 5-6：DNS伝播確認（インターネット側）

```bash
# Primary に直接問い合わせ
dig @<Primary NSDサーバーのEIP> TXT _acme-challenge.<取得するサブドメイン> +short

# Secondary に直接問い合わせ
dig @<Secondary NSDサーバーのEIP> TXT _acme-challenge.<取得するサブドメイン> +short

# パブリックリゾルバ経由（伝播確認）
dig @8.8.8.8 TXT _acme-challenge.<取得するサブドメイン> +short
dig @1.1.1.1 TXT _acme-challenge.<取得するサブドメイン> +short
```

> **期待する結果：** どこから問い合わせても同じTXT値が返る．パブリックリゾルバはキャッシュの関係で時間がかかる場合があるので，`$TTL=60` で運用していれば最大1分待つ．

##### Step 5-7：certbotで認証続行

certbotを実行していたターミナルに戻り，Enterキーを押下．

```
Waiting for verification...
Cleaning up challenges

Successfully received certificate.
Certificate is saved at: /etc/letsencrypt/live/<取得するサブドメイン>/fullchain.pem
Key is saved at:         /etc/letsencrypt/live/<取得するサブドメイン>/privkey.pem
```

##### Step 5-8：証明書ファイルの確認

```bash
ls -la /etc/letsencrypt/live/<取得するサブドメイン>/
```

> **期待する結果：**
> - `cert.pem`（サーバー証明書）
> - `chain.pem`（中間証明書）
> - `fullchain.pem`（サーバー証明書 + 中間証明書）
> - `privkey.pem`（秘密鍵）

##### Step 5-9：認証用TXTレコードのクリーンアップ（任意）

`_acme-challenge` TXTレコードは認証完了後は不要．次回更新時まで残しても問題ないが，クリーンに保ちたい場合は削除可：

```bash
vi /etc/nsd/<取得するサブドメイン>.zone
# → _acme-challenge IN TXT "..." の行を削除
# → <ゾーンシリアル+2> にインクリメント

nsd-control reload
```

------------------------------

## 5. 動作確認・検証

### 5-1. 確認チェックリスト

#### Primary側

- [ ] **確認①**：Primary `nsd.service` が `active (running)` かつ自動起動有効
- [ ] **確認②**：Primary で `<取得するサブドメイン>` のゾーン状態が `state: ok`

#### Secondary側

- [ ] **確認③**：Secondary `nsd.service` が `active (running)` かつ自動起動有効
- [ ] **確認④**：Secondary で `<取得するサブドメイン>.zone` ファイルが自動生成されている
- [ ] **確認⑤**：Primary と Secondary のシリアル番号が一致している

#### 外部からの確認

- [ ] **確認⑥**：インターネットから `dig NS <取得するサブドメイン>` が `ns1` と `ns2` の両方を返す
- [ ] **確認⑦**：Primary／Secondary のEIPに直接問い合わせて同じレコードが返る
- [ ] **確認⑧**：Let's Encrypt証明書が `/etc/letsencrypt/live/<取得するサブドメイン>/` に存在

------------------------------

### 確認①：Primary サービス状態【実施対象：Primary NSDサーバー】

```bash
systemctl status nsd --no-pager
systemctl is-enabled nsd
```

> **期待する結果：** `active (running)` および `enabled`．

------------------------------

### 確認②：Primary ゾーン状態【実施対象：Primary NSDサーバー】

```bash
nsd-control zonestatus <取得するサブドメイン>
```

> **期待する結果：** `state: ok` かつ `served-serial` が表示される．

------------------------------

### 確認③：Secondary サービス状態【実施対象：Secondary NSDサーバー】

```bash
systemctl status nsd --no-pager
systemctl is-enabled nsd
```

> **期待する結果：** `active (running)` および `enabled`．

------------------------------

### 確認④：Secondary ゾーンファイル自動生成【実施対象：Secondary NSDサーバー】

```bash
ls -la /etc/nsd/<取得するサブドメイン>.zone
cat /etc/nsd/<取得するサブドメイン>.zone | head -20
```

> **期待する結果：** ファイルが存在し，Primary と同じ内容（SOA・NS・Aレコード）が含まれる．

------------------------------

### 確認⑤：シリアル番号一致確認【実施対象：Primary／Secondary 両方】

```bash
# 両方で実行
nsd-control zonestatus <取得するサブドメイン> | grep -E "serial|state"
```

> **期待する結果：** `served-serial: <ゾーンシリアル>` が両方で一致する．

------------------------------

### 確認⑥：インターネットからのDNS委譲確認【実施対象：ローカルPC】

```bash
# 親ゾーンからの委譲確認
dig NS <取得するサブドメイン> +short

# パブリックリゾルバ経由
dig @8.8.8.8 NS <取得するサブドメイン> +short
```

> **期待する結果：** `ns1.<取得するサブドメイン>.` と `ns2.<取得するサブドメイン>.` の2行が返る．

------------------------------

### 確認⑦：両ネームサーバーへの直接問い合わせ【実施対象：ローカルPC】

```bash
# Primary
dig @<Primary NSDサーバーのEIP> NS <取得するサブドメイン> +short
dig @<Primary NSDサーバーのEIP> A ns1.<取得するサブドメイン> +short

# Secondary
dig @<Secondary NSDサーバーのEIP> NS <取得するサブドメイン> +short
dig @<Secondary NSDサーバーのEIP> A ns1.<取得するサブドメイン> +short
```

> **期待する結果：** Primary／Secondary 両方から同じレコードが返る．

------------------------------

### 確認⑧：証明書ファイル【実施対象：Primary NSDサーバー】

```bash
ls -la /etc/letsencrypt/live/<取得するサブドメイン>/
openssl x509 -in /etc/letsencrypt/live/<取得するサブドメイン>/cert.pem -noout -subject -issuer -dates
```

> **期待する結果：**
> - 4ファイル（cert.pem / chain.pem / fullchain.pem / privkey.pem）が存在
> - Subject に `<取得するサブドメイン>` が含まれる
> - Issuer に `Let's Encrypt` が含まれる
> - notBefore／notAfter（有効期限）が表示される

------------------------------

### 5-2. 次のステップ

本手順書での作業が完了したら，以下に進む：

- ALB と ACM の構築 → `alb-acm-https.md`

------------------------------

## 6. トラブルシューティング

------------------------------

#### エラー①：Secondary でゾーンファイルが生成されない

**原因：**
- Primary側 `provide-xfr` のIP指定が誤り
- Secondary側 `request-xfr` のIP指定が誤り
- PrimaryのSGで TCP/53 が許可されていない
- 親ドメインの委譲（Step 3）が完了していない

**対処法：**

```bash
# Secondary 側で手動 AXFR 試行（本番経路と一致させるためプライベートIPで実行）
dig @<Primary NSDサーバーのプライベートIP> AXFR <取得するサブドメイン>

# NSDログ確認
tail -n 50 /var/log/nsd.log

# 手動転送
nsd-control transfer <取得するサブドメイン>
```

> **チェックポイント：** Primary の `nsd.conf` で `provide-xfr: <Secondary NSDサーバーのプライベートIP>` の `<Secondary NSDサーバーのプライベートIP>` が，Secondary EC2 の実際のプライベートIPと一致しているか．

------------------------------

#### エラー②：Primary／Secondary 間でシリアル番号が一致しない

**原因：**
- Primary のゾーンファイル更新時にシリアル番号をインクリメントしていない
- NOTIFY が Secondary に届いていない（SGまたはネットワーク問題）

**対処法：**

```bash
# Primary でシリアル確認
nsd-control zonestatus <取得するサブドメイン>

# Primary のゾーンファイルでシリアルをインクリメント
vi /etc/nsd/<取得するサブドメイン>.zone

# リロード
nsd-control reload

# Secondary で手動同期
ssh <Secondary>
nsd-control transfer <取得するサブドメイン>
nsd-control zonestatus <取得するサブドメイン>
```

------------------------------

#### エラー③：certbotがTXTレコードを検出できない

**原因：**
- ゾーンファイル更新後 `nsd-control reload` を実行していない
- `<ゾーンシリアル>` をインクリメントしていない
- パブリックリゾルバのキャッシュに古い値が残っている

**対処法：**

```bash
# Primary・Secondary 両方で TXT 確認
dig @<Primary NSDサーバーのEIP> TXT _acme-challenge.<取得するサブドメイン> +short
dig @<Secondary NSDサーバーのEIP> TXT _acme-challenge.<取得するサブドメイン> +short

# パブリックリゾルバ経由
dig @8.8.8.8 TXT _acme-challenge.<取得するサブドメイン> +short

# 不一致の場合は Primary でリロード再実行
nsd-control reload
```

------------------------------

#### エラー④：`dnf install -y certbot` が失敗する

**原因：** ネットワーク到達不可，もしくはAL2023のリポジトリ設定に問題がある．

**対処法：**

```bash
dnf repolist enabled
dnf search certbot
```

> **補足：** 過去のAL2023初期バージョンでは `certbot` パッケージが標準リポジトリに含まれず，`pip3 install certbot` が必要なケースがあった．現行のAL2023ではこの問題は解消されている．

------------------------------

#### エラー⑤：NSDが起動失敗（`address already in use`）

**原因：** systemd-resolvedのスタブリスナーがUDP/53を占有している．

**対処法：** `nsd-private-redundancy.md` のトラブルシューティング⑤を参照．

------------------------------

### ログの確認場所

| ログの種類 | 場所 |
|-----------|------|
| NSD（Primary／Secondary） | `/var/log/nsd.log` |
| systemd（NSD） | `journalctl -u nsd` |
| certbot（Primary） | `/var/log/letsencrypt/letsencrypt.log` |

------------------------------

## 7. 参考リソース・関連資料

| 資料名 | URL / 場所 | 補足 |
|-------|-----------|------|
| NSD 公式 | https://nlnetlabs.nl/projects/nsd/about/ | NSD全般 |
| nsd.conf リファレンス | https://nlnetlabs.nl/documentation/nsd/nsd.conf/ | `provide-xfr` / `request-xfr` / `notify` / `allow-notify` |
| Let's Encrypt 公式 | https://letsencrypt.org/docs/ | ACME / DNS-01 |
| 関連手順書：内部DNS（2台冗長） | `nsd-private-redundancy.md` | 内部DNSの2台冗長構成．本手順書と同じ設計思想 |
| 後続手順書：ALB + ACM | `alb-acm-https.md` | 取得した証明書のACMインポート |

------------------------------

## 8. ロールバック手順

### 8-1. ロールバック判定基準

以下の場合，直ちにロールバックを実施する：

- `<取得するサブドメイン>` の名前解決が壊れて既存サービスに影響が出ている
- certbot認証が複数回失敗してLet's Encryptのレート制限に達した
- Primary／Secondary 間のゾーン同期が継続的に失敗する
- NSDが起動できなくなった

> **注意：** 既存サービスへの影響が最優先．証明書取得失敗は再試行可能なので慌てなくてよい．

------------------------------

### 8-2. NSD設定のバックアップからの復元【実施対象：Primary／Secondary 両方】

```bash
# バックアップ確認
ls <NSDバックアップディレクトリ>/nsd/

# 復元
cp -f <NSDバックアップディレクトリ>/nsd/*.conf /etc/nsd/
cp -f <NSDバックアップディレクトリ>/nsd/*.zone /etc/nsd/ 2>/dev/null || true

# 構文チェック
nsd-checkconf /etc/nsd/nsd.conf

# 再起動
systemctl restart nsd
systemctl status nsd --no-pager
```

> **補足：** バックアップが無い場合は，本手順書で追加した `zone:` セクションと `<取得するサブドメイン>.zone` を手動で削除．

------------------------------

### 8-3. 取得済み証明書の削除【実施対象：Primary NSDサーバー】

```bash
# 証明書ディレクトリ削除
rm -rf /etc/letsencrypt/live/<取得するサブドメイン>
rm -rf /etc/letsencrypt/archive/<取得するサブドメイン>
rm -f /etc/letsencrypt/renewal/<取得するサブドメイン>.conf
```

> **注意：** Let's Encryptには「失効（revoke）」の手続きもあるが，証明書が外部に流出していない限り削除のみで十分．

------------------------------

### 8-4. Route53委譲レコードの削除依頼【実施対象：Route53管理者（上長）】

Route53管理者（上長）に，以下のレコードの削除を依頼する：

```
対象：<親ドメイン> ホストゾーン（Route53）

削除するレコード：
- NSレコード:  <取得するサブドメイン> → ns1.<取得するサブドメイン>
- NSレコード:  <取得するサブドメイン> → ns2.<取得するサブドメイン>
- Aレコード:   ns1.<取得するサブドメイン> → <Primary NSDサーバーのEIP>
- Aレコード:   ns2.<取得するサブドメイン> → <Secondary NSDサーバーのEIP>

理由：<取得するサブドメイン> の権威DNS構成をロールバックするため．
```

------------------------------

### 8-5. certbotのアンインストール（任意）【実施対象：Primary NSDサーバー】

```bash
dnf remove -y certbot
rm -rf /etc/letsencrypt
```

------------------------------

### 8-6. 完全リカバリ：AMIスナップショットからの復元【実施対象：AWSコンソール】

```
AWS コンソール → EC2 → AMI → <作業前AMI名> を選択
→ 「AMIからインスタンスを起動」
→ 既存サーバーを停止／削除し，新インスタンスに切替
```

------------------------------

### 8-7. 完了確認【実施対象：Primary／Secondary 両方】

```bash
# NSDのゾーン状態（zone セクション削除後は zonestatus でエラーになる想定）
nsd-control zonestatus <取得するサブドメイン> 2>&1 | head -3

# DNS応答
dig @127.0.0.1 ns1.<取得するサブドメイン> A +short
```

> **期待する結果：** 復元後の元の状態に戻っていること．

------------------------------

## 付録

### A. コマンド解説

| コマンド | 説明 |
|---------|------|
| `dnf install -y certbot` | AL2023標準リポジトリからcertbotをインストール． |
| `dnf remove -y certbot` | certbotをアンインストール． |
| `certbot certonly --manual --preferred-challenges dns -d <ドメイン>` | DNS-01認証で証明書のみ取得（ウェブサーバー設定はしない）． |
| `nsd-checkconf <パス>` | NSDの設定ファイル構文チェック． |
| `nsd-checkzone <ゾーン名> <パス>` | NSDのゾーンファイル構文チェック． |
| `nsd-control reload` | NSDが管理するゾーンを再読み込みする． |
| `nsd-control zonestatus <ゾーン名>` | 各ゾーンの状態（serial／state など）を確認する． |
| `nsd-control transfer <ゾーン名>` | Secondaryから Primary に手動でAXFR要求を発行する． |
| `dig @<NSDサーバー> AXFR <ゾーン名>` | 指定したサーバーからゾーン全体を AXFR で取得（権限が必要）． |
| `dig NS <ドメイン> +short` | 指定ドメインのNSレコード問い合わせ． |
| `dig @<リゾルバIP> TXT _acme-challenge.<ドメイン>` | DNS-01認証用のTXTレコード問い合わせ． |

------------------------------

### B. 設定ファイル解説

**`/etc/nsd/nsd.conf`（Primary）**

本手順書で追加する Primary 側 `zone:` セクション：

```
zone:
    name: "<取得するサブドメイン>"
    zonefile: "<取得するサブドメイン>.zone"
    provide-xfr: <Secondary NSDサーバーのプライベートIP> NOKEY
    notify: <Secondary NSDサーバーのプライベートIP> NOKEY
```

| 項目 | 説明 |
|---|---|
| `provide-xfr` | このゾーンの AXFR/IXFR を許可するIPリスト．Secondary のIPを指定．`NOKEY` はTSIG認証なし． |
| `notify` | ゾーン更新時に NOTIFY を送信する宛先．Secondary のIPを指定． |

**`/etc/nsd/nsd.conf`（Secondary）**

本手順書で追加する Secondary 側 `zone:` セクション：

```
zone:
    name: "<取得するサブドメイン>"
    zonefile: "<取得するサブドメイン>.zone"
    request-xfr: AXFR <Primary NSDサーバーのプライベートIP> NOKEY
    allow-notify: <Primary NSDサーバーのプライベートIP> NOKEY
```

| 項目 | 説明 |
|---|---|
| `request-xfr` | Primary に対する AXFR 要求の宛先．`AXFR` はフルゾーン転送を意味する（`IXFR` は差分）． |
| `allow-notify` | NOTIFY を受け入れるソースIP．Primary のIPを指定． |

**`/etc/nsd/<取得するサブドメイン>.zone`（Primary のみ作成）**

```
$TTL 60
@ IN SOA ns1.<取得するサブドメイン>. <SOA管理者メール> (
    <ゾーンシリアル>     ; serial (YYYYMMDDNN 形式)
    60                  ; refresh
    60                  ; retry
    3600                ; expire
    60 )                ; minimum
```

| 項目 | 説明 |
|---|---|
| `$TTL 60` | レコードのデフォルトTTL（秒）．構築・検証中は60，本番運用時は300に変更 |
| `SOA` | Start Of Authority．ゾーンの管理情報 |
| シリアル番号 | ゾーンのバージョン番号．SecondaryやキャッシュはこれでPrimaryの更新を検知する |

------------------------------

### C. 用語解説

| 用語 | 説明 |
|------|------|
| NSD | Name Server Daemon．軽量・高速な権威DNSサーバー |
| 権威DNS | 自分が管理するゾーンの情報を返すDNS．キャッシュDNSとは別物 |
| AXFR | Authoritative XFR．ゾーン全体の転送． |
| IXFR | Incremental XFR．差分転送．本手順書ではAXFRを使用 |
| NOTIFY | Primary がゾーン更新を Secondary に通知するDNSメッセージ |
| `provide-xfr` | NSDで AXFR/IXFR を許可するソースIPリストを定義 |
| `request-xfr` | NSDで AXFR/IXFR の要求先を定義（Secondary側で使用） |
| `allow-notify` | NSDで NOTIFY を受け入れるソースIPリストを定義（Secondary側で使用） |
| TSIG | Transaction SIGnature．DNSメッセージ認証．本手順書では `NOKEY` で省略 |
| EIP | Elastic IP．AWSの静的グローバルIP |
| DNS-01 認証 | Let's EncryptがDNS TXTレコードでドメイン所有を確認する方式 |
| ACME | Automatic Certificate Management Environment．証明書発行プロトコル |

------------------------------

### D. 補足解説

#### D-1. なぜ NSDで2台冗長構成にするか

DNSはサービス継続の根幹．単一AZ障害や単一EC2障害でDNSが停止すると：
- Webサイトへのアクセスが世界中から不能になる
- Let's Encrypt の更新検証（DNS-01）が失敗する
- メール（MXレコード）配送が止まる

RFC 2182 推奨：**権威DNSは2台以上，異なる物理ロケーションに配置**．本手順書では Public-AZ1 と Public-AZ3 に分散．

#### D-2. なぜ Primary/Secondary 方式か（マルチマスターでなく）

NSDはマスター・スレーブ方式しかサポートしない．BINDの「マルチマスター」相当はサポート対象外．代わりに：
- ゾーン更新は **Primary でのみ実施**
- Secondary は AXFR で複製
- 世界からは両方が同じNSとして見える

#### D-3. SOA値の `expire` を `refresh` より大きく保つ理由

SOA設計原則 `expire > refresh + retry * N`：
- `refresh=60` `retry=60` `expire=60` にすると，Primary が1分応答しないだけで Secondary がゾーン破棄
- 検証中でも `expire ≥ 3600` を維持することで，Primary 一時障害時の Secondary 継続性を確保

#### D-4. Let's Encrypt 証明書の自動更新

Let's Encrypt 証明書は **90日有効**．自動更新を組むなら：

- **DNS-01 自動化**：API経由でTXTレコード追加・削除を自動化（NSDネイティブにはAPIなし．スクリプトで `vi` の代わりに `sed` + `nsd-control reload`）
- **HTTP-01 への切替**：別途WebサーバーでACMEチャレンジを応答
- **手動更新**：90日ごとに本手順書のStep 5を再実行

#### D-5. EIP変更時の影響と再申請

- EIPを変更すると，`<取得するサブドメイン>.zone` の `ns1` / `ns2` Aレコードが変わる
- Route53に登録した `ns1.<取得するサブドメイン>` / `ns2.<取得するサブドメイン>` のAレコードも上長への更新申請が必要
- 証明書自体はEIP変更の影響を受けない
- DNSキャッシュTTL（本番運用時300秒＝5分）の間は古いIPが返り続けるので，変更前にTTLをさらに短く（60秒等）に設定しておくと切替が早い

#### D-6. 内部DNS（`ex.local`）と外部DNS（`<取得するサブドメイン>`）の併存

同一NSDサーバーで両方を提供する場合，`nsd.conf` には複数の `zone:` セクションを書くだけでよい．**Primary 側の例：**

```
zone:
    name: "ex.local"                  ← 内部DNS（nsd-private-redundancy.md由来）
    zonefile: "ex.local.zone"
    # ... 内部DNS用の provide-xfr / notify

zone:
    name: "<取得するサブドメイン>"     ← 本手順書で追加
    zonefile: "<取得するサブドメイン>.zone"
    provide-xfr: <Secondary NSDサーバーのプライベートIP> NOKEY
    notify: <Secondary NSDサーバーのプライベートIP> NOKEY
```

- SGの内部DNS問い合わせ（VPC CIDR）と外部DNS問い合わせ（0.0.0.0/0）は別々に許可する
- 外部DNSをVPC外から見えるようにするには，NSDサーバーをPublic subnetに置きEIPを付与する必要がある
- 親ドメイン（`<親ドメイン>`）のゾーンファイルは本NSDサーバーには配置しない（上長のRoute53で管理）

#### D-7. `nsd-private-redundancy.md` との関係

| 観点 | 内部DNS（`nsd-private-redundancy.md`） | 外部DNS（本手順書） |
|---|---|---|
| 利用者 | 自社内のEC2のみ | インターネット全体のリゾルバ |
| 配置サブネット | Private | Public |
| EIP | 不要 | 必要（2個） |
| 委譲申請 | 不要 | 必要（Route53） |
| Let's Encrypt 連携 | なし | あり |
| ファイル名の対比 | `private` | `public` |
| 命名規則 | `redundancy` で揃える | `redundancy` で揃える |

#### D-8. なぜゾーン転送はプライベートIP，インターネット公開はEIPか

外部DNSは Public subnet に配置されEIPを持つが，それでも **ゾーン転送（AXFR）と NOTIFY はプライベートIPで実装** する設計を採用している．使い分けの理由を以下に整理する．

##### 用途別の使い分け

| 用途 | 使うIP | 理由 |
|---|---|---|
| インターネット向けの NSレコード（`ns1 A` `ns2 A`） | **EIP** | 世界中のリゾルバが到達できる固定IPが必要 |
| Route53へのNS委譲申請 | **EIP** | 同上．Route53も親ゾーンも外部から見える |
| 動作確認の `dig` コマンド（外部疎通） | **EIP** | 外部から本当に名前解決できるかの確認 |
| Primary ⇄ Secondary のAXFR/NOTIFY | **プライベートIP** | VPC内で完結．後述の3つの利点 |

##### プライベートIPで実装する3つの利点

**利点1：通信経路が VPC 内で完結する**

EIPを宛先にした場合，Public subnet 内のEC2 同士の通信でも：
- VPC内ルーティングテーブルでEIPは「VPC CIDR外」と判定される
- Internet Gateway 経由で外に出る → 折り返して入る（**EIP NAT loopback**）
- AWSではサポートされているが，経路が長く障害ポイントも増える

プライベートIPなら **VPC内で完結** し，経路は明確かつ短い．

**利点2：データ転送料の最適化**

| 経路 | 課金 |
|---|---|
| プライベートIP同士（同一AZ） | 無料 |
| プライベートIP同士（クロスAZ） | $0.01/GB |
| **EIP経由（IGW往復）** | **$0.01〜0.02/GB ＋ EIP関連料金** |

ゾーン転送のトラフィックは少量だが，検証フェーズで頻繁にリロードする場合は無視できなくなる．

**利点3：AWSのベストプラクティスに整合**

AWS公式ドキュメントでも「**同一VPC内のEC2間通信はプライベートIPで行うべき**」と明記されている．EIP経由通信は「外部からの接続を受け付ける」目的に限定するのが推奨設計．

##### TL;DR

> **インターネット公開（NSレコード・dig確認）には EIP，VPC内通信（AXFR・NOTIFY）にはプライベートIP** を使う．EIPはあくまで「世界中から到達するための公開アドレス」であり，VPC内の隣接EC2との通信に使うべきではない．
