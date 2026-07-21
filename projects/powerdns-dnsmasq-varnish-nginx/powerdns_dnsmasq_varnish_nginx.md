# 【DNS再構築 + 配信高速化(PowerDNS + dnsmasq + Varnish + Nginx)】環境構築手順書

---

## 1. ドキュメント情報

| 項目 | 内容 |
|------|------|
| 手順書名 | DNS再構築 + 配信高速化(PowerDNS + dnsmasq + Varnish + Nginx) |
| 作成日 | 2026-06-26 |
| バージョン | v2.0 |
| 対象環境 | AWS EC2(Amazon Linux 2023) |

> **改訂履歴**
>
> | バージョン | 日付 | 変更内容 |
> |-----------|------|---------|
> | v1.0 | 2026-06-26 | 初版作成 |
> | v2.0 | 2026-07-14 | 構築実施で判明した課題を反映。推奨インスタンスタイプ追加(3-2)、EPEL/Varnish公式リポジトリ導入方法の修正(AL2023のrpm依存・OS判定問題対応)、pdnsutilのFQDN必須化対応、dnsmasqのlisten-address自己衝突・reload方式の修正、Varnishのsystemd起動設定(PIDFile)修正とStep4/5構成の入れ替え、動作確認手順(確認①〜④)を実機検証に合わせて修正 |

---

## 2. 目的・概要

### 2-1. 目的

本手順書では、**DNS層**と**HTTPキャッシュ層**の2系統を組み合わせた4台構成を構築する。以下の体験を狙う。

- **PowerDNS(権威DNS)** と **dnsmasq(キャッシュ/フォワーダDNS)** を分離し、「権威」と「キャッシュ」の責務の違いを体感する
- **Varnish** を Nginx の前段に置き、HTTPキャッシュによる応答高速化と、VCLによるキャッシュ制御を体験する
- DNS層・Web層が独立して動きつつ、「Varnish が dnsmasq 経由で PowerDNS の応答を使って Nginx に到達する」という形でつながる構成を観察する

> **解説:既習のBIND/NSDとの違い**
>
> 既習の BIND は「権威もキャッシュもこなせる万能型」、NSD は「権威専用の軽量型」。本案では PowerDNS と dnsmasq という別系統の組み合わせを学ぶ。
>
> - **PowerDNS**: 権威DNS。SQLite/MySQL などのバックエンドDBにゾーンを格納し、`pdnsutil` コマンドでレコードを管理する点が BIND と大きく異なる
> - **dnsmasq**: 軽量なキャッシュ/フォワーダDNS。DHCP機能も持つが本手順では DNS のみ使用
>
> 「ゾーンファイルではなく DB でゾーンを管理する」点が PowerDNS の最大の特徴。

### 2-2. 構成概要(アーキテクチャ)

```
   【検証クライアント(自PC または Varnishサーバ)】
                  |
                  | (1) http://web.ex.local/ にアクセス
                  v
   ┌─────────────────────────────────────┐
   │ [Varnish]  varnish.local             │
   │  ・port 80 で受付                    │
   │  ・VCL でキャッシュ判定             │
   │  ・X-Cache: HIT/MISS を付与         │
   └─────────────────────────────────────┘
                  |
                  | (2) origin.ex.local を名前解決
                  v
   ┌─────────────────────────────────────┐
   │ [dnsmasq]  cache-dns.local          │
   │  ・port 53 (UDP/TCP)                │
   │  ・*.ex.local は PowerDNS にフォワード │
   │  ・それ以外は外部DNS(AWS)へ      │
   │  ・応答をキャッシュ                 │
   └─────────────────────────────────────┘
                  |
                  | (3) ex.local の権威に問い合わせ
                  v
   ┌─────────────────────────────────────┐
   │ [PowerDNS]  pdns.local              │
   │  ・port 53 (UDP/TCP)                │
   │  ・SQLite3 バックエンド             │
   │  ・ex.local ゾーンを保持            │
   │  ・pdnsutil でレコード管理         │
   └─────────────────────────────────────┘

   (1)の続き:Varnish がオリジンへ転送
                  |
                  v
   ┌─────────────────────────────────────┐
   │ [Nginx]  origin.local                │
   │  ・port 80                          │
   │  ・/ → 通常応答(キャッシュ対象)   │
   │  ・/slow → 2秒sleep する応答       │
   │  ・/admin → キャッシュ対象外       │
   └─────────────────────────────────────┘
```

### 2-3. 完成イメージ(ゴール定義)

- [ ] `dig @<CACHEDNS_PRI> web.ex.local` で `<VARNISH_PRI>` が返り、2回目以降は Query time が大幅短縮される
- [ ] `curl -I http://<VARNISH_PRI>/` で初回は `X-Cache: MISS`、2回目以降は `X-Cache: HIT` になる
- [ ] `curl http://<VARNISH_PRI>/slow` の2回目応答時間が、初回より大幅に短縮される(キャッシュ効果)
- [ ] `curl -I http://<VARNISH_PRI>/admin` は何度叩いても `X-Cache: MISS`(キャッシュ対象外)
- [ ] `pdnsutil` でレコードを変更し、dnsmasq のキャッシュをクリアすると新しい値が反映される
- [ ] `varnishlog`/`varnishstat` でキャッシュヒット率を観察できる

---

## 3. 前提条件・準備

### 3-1. AWS環境(起動済み前提)

- AWSアカウントを保有していること
- VPCが作成されており、CIDR は `172.31.0.0/16` であること(異なる場合は手順中の該当箇所を読み替え)
- EC2インスタンスが **4台起動済み** であること(全台 Amazon Linux 2023、パブリックサブネット配置、パブリックIP付与)
- 全EC2にSSHログインできること

### 3-2. 環境要件

| サーバ | 主なソフトウェア | 推奨インスタンスタイプ |
| --------- | ---------------- | ---------------------- |
| pdns | PowerDNS (Authoritative), SQLite3, pdns-tools | t3.micro |
| cache-dns | dnsmasq | t3.micro |
| varnish | Varnish, curl | **t3.small** |
| origin | Nginx | t3.micro |

> **インスタンスタイプ選定理由**
>
> - **pdns**: SQLite バックエンドで少数レコードのみを保持し、問い合わせ量も検証程度のため t3.micro(メモリ1GB)で十分。
> - **cache-dns**: dnsmasq 自体が極めて軽量なプロセスで、`cache-size=1000` 程度のキャッシュなら t3.micro で十分。
> - **varnish**: Step 4 の VCL で `-s malloc,256m` としてキャッシュ領域を256MB確保する。varnishd 本体(manager + cacher プロセス)のオーバーヘッドと合わせると、t3.micro(1GB)では検証中の同時アクセスや `varnishlog` 監視時に窮屈になり得るため、余裕を持って t3.small(2GB)を推奨。
> - **origin**: 静的HTMLを返すのみで負荷は最小のため t3.micro で十分。
>
> **注意:無料利用枠の対象インスタンスタイプはアカウント作成日で異なる**
>
> [AWS公式ドキュメント](https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/ec2-free-tier-usage.html)によると、無料利用枠の対象インスタンスタイプはAWSアカウントの作成日で異なる。
>
> - **2025年7月15日より前に作成したアカウント**: `t2.micro` / `t3.micro` のみが対象(12か月間、月750時間まで無料)
> - **2025年7月15日以降に作成したアカウント**: `t3.micro` / `t3.small` / `t4g.micro` / `t4g.small` / `c7i-flex.large` / `m7i-flex.large` が対象(時間制ではなく、サインアップ時に付与されるクレジットを6か月以内に使い切る方式)
>
> 2025年7月15日より前に作成したアカウントの場合、varnish サーバの t3.small は無料利用枠の対象外(課金対象)になる。その場合は t3.micro で代用し、VCL の `-s malloc,256m` を `-s malloc,128m` 程度に減らすなどしてメモリ圧迫を避けること。

### 3-3. セキュリティグループ設定

#### 3-3-1. pdns(PowerDNS)

| タイプ | プロトコル | ポート | ソース | 目的 |
|-------|----------|------|------|------|
| SSH | TCP | 22 | マイIP | SSH接続 |
| DNS (UDP) | UDP | 53 | 172.31.0.0/16 | dnsmasqからのフォワード受信 |
| DNS (TCP) | TCP | 53 | 172.31.0.0/16 | TCPフォールバック・AXFR用 |

#### 3-3-2. cache-dns(dnsmasq)

| タイプ | プロトコル | ポート | ソース | 目的 |
|-------|----------|------|------|------|
| SSH | TCP | 22 | マイIP | SSH接続 |
| DNS (UDP) | UDP | 53 | 172.31.0.0/16 | クライアントからの名前解決受付 |
| DNS (TCP) | TCP | 53 | 172.31.0.0/16 | TCPフォールバック |

#### 3-3-3. varnish

| タイプ | プロトコル | ポート | ソース | 目的 |
|-------|----------|------|------|------|
| SSH | TCP | 22 | マイIP | SSH接続 |
| HTTP | TCP | 80 | マイIP | 検証用アクセス(自PCから) |

> **注意:学習用途のためマイIPに限定**
>
> 実務ではALB等を経由するが、本手順では検証用に自PCからの直接アクセスを許可する。検証完了後は閉じることを推奨。

#### 3-3-4. origin(Nginx)

| タイプ | プロトコル | ポート | ソース | 目的 |
|-------|----------|------|------|------|
| SSH | TCP | 22 | マイIP | SSH接続 |
| HTTP | TCP | 80 | 172.31.0.0/16 | Varnishからのオリジン取得 |

> **解説:オリジンの80番は内部のみ**
>
> Varnish を前段に置く意味は「外部からは必ず Varnish を通る」こと。オリジンを外部公開してしまうと、Varnish を迂回してアクセスできてしまい、キャッシュ層の存在意義が薄れる。SG レベルで「外部 → オリジン」を遮断するのが基本。

### 3-4. パラメータ整理表

| パラメータ | 意味 | 自環境の値 |
|---|---|---|
| `<PDNS_PRI>` | PowerDNS サーバのプライベートIP | |
| `<CACHEDNS_PRI>` | dnsmasq サーバのプライベートIP | |
| `<VARNISH_PRI>` | Varnish サーバのプライベートIP | |
| `<VARNISH_PUB>` | Varnish サーバのグローバルIP(検証用) | |
| `<ORIGIN_PRI>` | Nginx (origin) サーバのプライベートIP | |

### 3-5. ホスト名・ドメイン設計

| サーバ | ホスト名 | 用途 |
|--------|---------|------|
| pdns | `pdns.local` | PowerDNS 権威 |
| cache-dns | `cache-dns.local` | dnsmasq キャッシュ |
| varnish | `varnish.local` | HTTPキャッシュ |
| origin | `origin.local` | オリジンWeb |

PowerDNS で管理する権威ゾーンは **`ex.local`** とする。このゾーン内に以下のレコードを持たせる。

| FQDN | タイプ | 値 |
|------|------|----|
| `ex.local` | SOA | (PowerDNS自動) |
| `ex.local` | NS | `ns1.ex.local` |
| `ns1.ex.local` | A | `<PDNS_PRI>` |
| `web.ex.local` | A | `<VARNISH_PRI>` |
| `origin.ex.local` | A | `<ORIGIN_PRI>` |

> **解説:なぜホスト名のドメインと権威ゾーンを分けるか**
>
> 各サーバのホスト名は `.local`(例: `pdns.local`)、PowerDNS で管理する権威ゾーンは `ex.local` という別ドメインに分けている。
>
> こうすることで、「サーバ自身のホスト名」と「DNSに登録するレコード(`web.ex.local` など)」が混ざらず、PowerDNS が解決する対象を明確化できる。実務でも「内部ホスト名は別管理、公開ドメインは権威DNS」という分離はよく行われる。

---

## 4. 構築手順

### 4-1. 環境構築の流れ

1. 全サーバ共通の Step 0(初期設定)
2. PowerDNS の構築(Step 1)
3. dnsmasq の構築(Step 2)
4. Nginx(オリジン)の構築(Step 3)
5. Varnish の構築・DNS設定(Step 4)
6. 接続確認(Step 5)

---

### Step 0: 全サーバ共通の初期設定

**全4台で実施。** 各サーバの `<hostname>` 部分はサーバごとに置き換える。

```bash
sudo su -
dnf update -y
timedatectl set-timezone Asia/Tokyo

# サーバごとに以下のいずれかを設定
hostnamectl set-hostname pdns.local       # PowerDNSサーバ
hostnamectl set-hostname cache-dns.local  # dnsmasqサーバ
hostnamectl set-hostname varnish.local    # Varnishサーバ
hostnamectl set-hostname origin.local     # Nginxサーバ
```

設定後、再ログインまたは `exec bash` でプロンプトに反映する。

---

### Step 1: 【pdns.localで実施】PowerDNS の構築

**目的:** SQLite3 バックエンドで `ex.local` ゾーンを管理する権威DNSを構築する。

#### 1-1. PowerDNS パッケージのインストール

Amazon Linux 2023 では PowerDNS は標準リポジトリにないため、EPEL を有効化する。

```bash
curl -LO https://dl.fedoraproject.org/pub/epel/epel-release-latest-9.noarch.rpm
rpm -ivh --nodeps epel-release-latest-9.noarch.rpm
dnf install -y pdns pdns-backend-sqlite pdns-tools sqlite
```

> **注意:EPELリポジトリの利用**
>
> EPEL は Fedora プロジェクト提供のサードパーティリポジトリ。実務では「業務サーバに EPEL を入れてよいか」を必ず確認する必要がある(検証経路の問題)。学習用途では問題ない。
>
> **注意:`dnf install` ではなく `rpm -ivh --nodeps` を使う理由**
>
> `epel-release-latest-9.noarch.rpm` は RHEL9系(CentOS Stream 9 / Rocky / AlmaLinux 9 等)向けにビルドされており、`Requires: redhat-release >= 9` という依存を持つ。Amazon Linux 2023 は独自ディストリビューションで `redhat-release` パッケージを提供しないため、`dnf install` で直接インストールしようとすると `conflicting requests` エラーで失敗する。
>
> epel-release パッケージの実体は `.repo` ファイルと GPG鍵を配置するだけの軽量パッケージで、機能的な依存関係はない。そのため `rpm -ivh --nodeps` で依存チェックを外してインストールしても実害はない。

#### 1-2. SQLite3 データベースの初期化

PowerDNS のスキーマ SQL は `pdns-backend-sqlite` パッケージに同梱されている。

```bash
mkdir -p /var/lib/pdns
# スキーマファイルの場所を確認
rpm -ql pdns-backend-sqlite | grep schema.sqlite3.sql
# 出力例: /usr/share/doc/pdns/schema.sqlite3.sql

# DB作成
sqlite3 /var/lib/pdns/pdns.sqlite3 < /usr/share/doc/pdns/schema.sqlite3.sql

# 所有者を pdns ユーザーに(パッケージインストール時に自動作成されている)
chown -R pdns:pdns /var/lib/pdns
ls -l /var/lib/pdns/pdns.sqlite3
```

> **解説:PowerDNS の「バックエンド」概念**
>
> BIND は「ゾーンファイル = テキスト」という前提だが、PowerDNS はゾーンデータをどこに置くかを「バックエンド」として選択できる。SQLite/MySQL/PostgreSQL/LDAP/BIND互換(ゾーンファイル)など複数が用意されている。
>
> 本手順では最小構成として SQLite3 を選択。MySQL/PostgreSQL に切り替えても、上位の `pdnsutil` コマンド操作はほぼ同じになる、というのが PowerDNS の設計思想。

#### 1-3. PowerDNS 設定ファイルの編集

```bash
cp /etc/pdns/pdns.conf /etc/pdns/pdns.conf.orig
vi /etc/pdns/pdns.conf
```

以下の内容を有効化または追記する(既存のコメント行を編集または末尾追記)。

```
# === バックエンド設定 ===
launch=gsqlite3
gsqlite3-database=/var/lib/pdns/pdns.sqlite3

# === 待ち受け設定 ===
local-address=0.0.0.0
local-port=53

# === ログ ===
loglevel=4
log-dns-queries=yes
```

> **解説:`launch` ディレクティブ**
>
> PowerDNS は起動時に `launch=` で指定されたバックエンドモジュールをロードする。`gsqlite3` は SQLite3 用の generic バックエンドモジュールを意味する。複数指定(例: `launch=gsqlite3,bind`)も可能で、ゾーンごとに異なるバックエンドを混在させられる。

#### 1-4. PowerDNS の起動と自動起動

```bash
systemctl start pdns
systemctl status pdns
systemctl enable pdns

# 53番ポートで待ち受けているか確認
ss -tlnup | grep :53
```

#### 1-5. ゾーンとレコードの作成(pdnsutil)

PowerDNS では、ゾーン操作を `pdnsutil` コマンドで行う。

```bash
# パラメータを環境変数に入れておくと便利
PDNS_PRI=<PDNS_PRI を実際の値で>
VARNISH_PRI=<VARNISH_PRI を実際の値で>
ORIGIN_PRI=<ORIGIN_PRI を実際の値で>

# ゾーン作成
pdnsutil create-zone ex.local ns1.ex.local

# レコード追加
pdnsutil add-record ex.local ns1.ex.local A 300 ${PDNS_PRI}
pdnsutil add-record ex.local web.ex.local A 60 ${VARNISH_PRI}
pdnsutil add-record ex.local origin.ex.local A 60 ${ORIGIN_PRI}

# 確認
pdnsutil list-zone ex.local
```

> **注意:`add-record` の NAME 引数は FQDN 必須**
>
> 現行バージョンの PowerDNS では、`pdnsutil add-record` の NAME 引数にゾーン名を省略した相対名(例: `ns1`)を渡すと `Name "ns1." to add is not part of zone "ex.local."` というエラーになる。古いバージョンでは相対名を自動的にゾーン名で展開してくれたが、現行バージョンでは完全修飾ドメイン名(例: `ns1.ex.local`)を明示する必要がある。

> **解説:TTLを短めに設定する理由**
>
> `web` と `origin` の A レコードは TTL=60秒 にしている。学習中はレコードを書き換えてキャッシュ挙動を観察することが多いため、長すぎる TTL は不便。実務ではより長い TTL(数時間〜1日)が一般的。

> **考えるポイント:`pdnsutil create-zone` は内部で何をしているか**
>
> 内部的には `domains` テーブルへの INSERT と、SOA レコードの自動生成を行っている。SQLite を直接覗いてみると理解が深まる。
>
> ```
> sqlite3 /var/lib/pdns/pdns.sqlite3 "SELECT * FROM domains;"
> sqlite3 /var/lib/pdns/pdns.sqlite3 "SELECT name,type,content,ttl FROM records;"
> ```
>
> 「DNSの実体はテキストファイルではなく、テーブルの行データである」という見え方になるのが PowerDNS の特徴。

#### 1-6. 自身での動作確認

```bash
dig @127.0.0.1 ex.local SOA +short
# 期待: ns1.ex.local. hostmaster.ex.local. <serial> ...

dig @127.0.0.1 web.ex.local A +short
# 期待: <VARNISH_PRI>

dig @127.0.0.1 origin.ex.local A +short
# 期待: <ORIGIN_PRI>
```

---

### Step 2: 【cache-dns.localで実施】dnsmasq の構築

**目的:** クライアントからの名前解決を受け、`ex.local` は PowerDNS にフォワード、それ以外は外部DNSへ流すキャッシュDNSを構築する。

#### 2-1. dnsmasq のインストール

```bash
dnf install -y dnsmasq bind-utils
```

#### 2-2. systemd-resolved との競合回避

Amazon Linux 2023 では `systemd-resolved` が 127.0.0.53:53 で待ち受けることがある。dnsmasq が 0.0.0.0:53 を掴むため、stub listener を無効化する。

```bash
mkdir -p /etc/systemd/resolved.conf.d
cat > /etc/systemd/resolved.conf.d/disable-stub.conf <<'EOF'
[Resolve]
DNSStubListener=no
EOF

systemctl restart systemd-resolved 2>/dev/null || true

# 念のため自身の /etc/resolv.conf はAWSデフォルトDNSのままにしておく
# (dnsmasq自身が外部解決に使うため)
cat /etc/resolv.conf
```

> **注意:dnsmasq 自身の上流DNS**
>
> dnsmasq が「`ex.local` 以外」を解決するために問い合わせる先は、デフォルトでは `/etc/resolv.conf` の内容を使う。AL2023 では `/etc/resolv.conf` が `systemd-resolved` 管理のシンボリックリンクになっている可能性がある。後述の `server=` 設定で明示すれば確実。

#### 2-3. dnsmasq の設定

```bash
cp /etc/dnsmasq.conf /etc/dnsmasq.conf.orig
vi /etc/dnsmasq.conf
```

AL2023 の dnsmasq パッケージが出荷時点で用意している `/etc/dnsmasq.conf` には、既定で `interface=lo`(ループバックのみで待ち受け)が有効化されている。これは後述の `listen-address=0.0.0.0` + `bind-interfaces`(全アドレスで待ち受け)と矛盾し、`Address already in use` で起動失敗する原因になるため、**まず既存の `interface=lo` 行をコメントアウトする**。

```bash
grep -n '^interface=lo' /etc/dnsmasq.conf
# ヒットしたらコメントアウト
sed -i 's/^interface=lo/#interface=lo/' /etc/dnsmasq.conf
```

続けて、設定内容(既存ファイル末尾に追記、または該当行を有効化):

```
# === 基本設定 ===
# 0.0.0.0 で待ち受け(127.0.0.1 は 0.0.0.0 に包含されるため列挙しない。
# bind-interfaces と併用する場合、0.0.0.0 と 127.0.0.1 を両方列挙すると
# 自己衝突して Address already in use になるので注意)
listen-address=0.0.0.0
bind-interfaces

# /etc/resolv.conf を読まず、下記 server= だけを使う
no-resolv

# ホスト名解決を /etc/hosts に頼らない(明確化のため)
no-hosts

# === ex.local ゾーンは PowerDNS にフォワード ===
server=/ex.local/<PDNS_PRI>

# === それ以外は AWS の VPC リゾルバへフォワード ===
# Amazon Linux のデフォルトリゾルバ(VPC + 2)を使う。
# 簡単のためパブリックDNSを指定してもよい
server=8.8.8.8
server=1.1.1.1

# === キャッシュサイズ ===
cache-size=1000

# === ログ(学習のため有効化)===
log-queries
log-facility=/var/log/dnsmasq.log
```

`<PDNS_PRI>` は実際の値に置換する。

> **解説:`server=/ex.local/...` 構文**
>
> dnsmasq の `server=/<domain>/<ip>` は「このドメイン配下の問い合わせはこのDNSへフォワードせよ」という意味。**条件付きフォワーダ**として機能する。
>
> 本構成では「`ex.local` は権威の PowerDNS、それ以外はインターネット側」という二系統の振り分けが、この1行で実現される。BIND の `forward zone` 設定に相当する機能。

> **解説:`no-resolv` の意味**
>
> これを指定しないと、dnsmasq は `/etc/resolv.conf` も上流DNSとして併用する。AL2023 では `/etc/resolv.conf` が動的に変わる可能性があり、挙動が読みづらくなる。明示的に `no-resolv` を付けて「`server=` で指定したものだけを使う」と固定するのが安全。

#### 2-4. ログファイル作成と起動

```bash
touch /var/log/dnsmasq.log
chown dnsmasq:dnsmasq /var/log/dnsmasq.log

# 構文チェック
dnsmasq --test

systemctl start dnsmasq
systemctl status dnsmasq
systemctl enable dnsmasq

ss -tlnup | grep :53
```

#### 2-5. 動作確認

```bash
# ex.local 配下(PowerDNS経由)
dig @127.0.0.1 web.ex.local +short
# 期待: <VARNISH_PRI>

# それ以外(外部DNS経由)
dig @127.0.0.1 www.google.com +short
# 期待: IPアドレスが複数返る

# 2回目で Query time が短くなる(キャッシュヒット)
dig @127.0.0.1 web.ex.local | grep "Query time"
dig @127.0.0.1 web.ex.local | grep "Query time"
```

> **考えるポイント:キャッシュは TTL の期間だけ保持される**
>
> `web.ex.local` の TTL を 60 秒にしているため、60秒以上経つと dnsmasq のキャッシュは失効し、再び PowerDNS に問い合わせる。5章の確認④でレコード変更の反映確認をするとき、この TTL を意識すると挙動が読みやすい。

---

### Step 3: 【origin.localで実施】Nginx(オリジン)の構築

**目的:** Varnish の背後で動くオリジン Web サーバを構築する。キャッシュ効果を観察しやすいように、わざと遅い応答エンドポイントと、キャッシュ除外用エンドポイントを用意する。

#### 3-1. Nginx のインストール

```bash
dnf install -y nginx
```

#### 3-2. コンテンツ配置

```bash
mkdir -p /var/www/origin
cat > /var/www/origin/index.html <<'EOF'
<!DOCTYPE html>
<html>
<head><title>Origin Server</title></head>
<body>
<h1>Hello from origin.local</h1>
<p>This is served by Nginx (origin).</p>
<p>Time: <strong>__TIME__</strong></p>
</body>
</html>
EOF

mkdir -p /var/www/origin/admin
cat > /var/www/origin/admin/index.html <<'EOF'
<!DOCTYPE html>
<html><body><h1>Admin (not cached)</h1></body></html>
EOF
```

#### 3-3. Nginx 設定

```bash
vi /etc/nginx/conf.d/origin.conf
```

```
server {
    listen 80;
    server_name origin.ex.local;

    root /var/www/origin;
    index index.html;

    # 通常コンテンツ(キャッシュ対象)
    location / {
        add_header X-Origin-Server "origin.local" always;
    }

    # わざと遅い応答(キャッシュ効果を体感するため)
    location = /slow {
        add_header X-Origin-Server "origin.local" always;
        return 200 "slow response\n";
        # echo モジュールは標準にないため、bashを介さず疑似的に遅延させる代替手段として
        # 後述のとおり origin 側で nginx-mod-http-echo を使わず、
        # アクセスログでミリ秒単位の差を見ることで体感する
    }

    # キャッシュ除外用パス
    location /admin {
        add_header X-Origin-Server "origin.local" always;
        try_files $uri $uri/ =404;
    }
}
```

> **注意:`/slow` の遅延は Varnish 側で表現する**
>
> Nginx 単体で正確な「N秒スリープ応答」を作るには echo-nginx-module や Lua モジュールが必要になり、ビルドが複雑になる。本手順では「キャッシュヒット時とミス時の Varnish 側応答時間差」で効果を観察するため、オリジン側の遅延は割愛する。
>
> もし遅延応答を試したい場合は、`/etc/nginx/conf.d/origin.conf` に追加で `location = /slow { ... }` を作り、`fastcgi_pass` で PHP-FPM 経由の sleep スクリプトを呼び出すなどの構成が考えられるが、本手順スコープ外とする。

#### 3-4. 起動

```bash
nginx -t
systemctl start nginx
systemctl enable nginx

# 自身から確認
curl -I http://127.0.0.1/
curl -I http://127.0.0.1/admin/
```

---

### Step 4: 【varnish.localで実施】Varnish の構築

**目的:** HTTPキャッシュリバースプロキシを構築し、Nginx をオリジンに指定する。

#### 4-1. Varnish のインストール

Amazon Linux 2023 の標準リポジトリには Varnish パッケージが含まれていないため、Varnish公式のRPMリポジトリ(packagecloud)を追加する。このスクリプトはOSを自動判定するが、AL2023は `amzn/2023` として検出され、その組み合わせ向けのパッケージは実際には配布されていない。`os=el dist=9`(EL9系として扱う)で判定を上書きする。

```bash
curl -s https://packagecloud.io/install/repositories/varnishcache/varnish80/script.rpm.sh -o /tmp/varnish_repo.sh
os=el dist=9 bash /tmp/varnish_repo.sh

dnf install -y varnish
varnishd -V
```

> **注意:`curl` パッケージを明示的にインストールしない**
>
> Amazon Linux 2023 では「フル機能版の `curl`」と、ベースイメージに最初から入っている「軽量版の `curl-minimal`」が互いに競合するパッケージになっている。`dnf install -y curl` のように明示的にフル版を指定すると `curl-minimal` と衝突してインストールが失敗する。本手順で使う `curl -I` などの基本的なHTTPテストは `curl-minimal` で十分満たせるため、`curl` パッケージは指定しない。

#### 4-2. listen ポートを 80 に変更

Varnish のデフォルト listen ポートは 6081。今回は 80 で受ける。

```bash
mkdir -p /etc/systemd/system/varnish.service.d
cat > /etc/systemd/system/varnish.service.d/override.conf <<'EOF'
[Service]
ExecStart=
ExecStart=/usr/sbin/varnishd -a :80 -f /etc/varnish/default.vcl -s malloc,256m -P %t/%N/varnishd.pid
EOF

systemctl daemon-reload
```

> **解説:systemd drop-in による上書き**
>
> パッケージ提供の unit ファイル(`/usr/lib/systemd/system/varnish.service`)を直接編集すると、パッケージ更新時に上書きされる。`/etc/systemd/system/<service>.d/override.conf` を作るのが正攻法。`ExecStart=` を空にしてから再定義しているのは、systemd の仕様で複数 ExecStart を扱う際の初期化が必要なため。
>
> **注意:`-P` オプションを忘れずに引き継ぐ**
>
> 元の unit は `Type=forking` で `PIDFile=%t/%N/varnishd.pid`(`/run/varnish/varnishd.pid`)を指定しており、systemd はこのPIDファイルが書き出されるのを待って起動完了と判定する。`ExecStart=` を独自コマンドで上書きする際に `-P %t/%N/varnishd.pid` を引き継がないと、varnishd自体は正常起動していてもPIDファイルが作られず、systemdが `activating` のままタイムアウトして強制終了される。

#### 4-3. VCL の作成

```bash
cp /etc/varnish/default.vcl /etc/varnish/default.vcl.orig
vi /etc/varnish/default.vcl
```

ファイル全体を以下で置き換える:

```vcl
vcl 4.1;

# === オリジン(バックエンド)定義 ===
backend default {
    .host = "origin.ex.local";
    .port = "80";
    .connect_timeout = 5s;
    .first_byte_timeout = 30s;
    .between_bytes_timeout = 10s;
}

# === リクエスト受信時の処理 ===
sub vcl_recv {
    # /admin 以下はキャッシュ対象外
    if (req.url ~ "^/admin") {
        return (pass);
    }

    # GET/HEAD 以外はキャッシュしない
    if (req.method != "GET" && req.method != "HEAD") {
        return (pass);
    }
}

# === バックエンド応答受信時の処理 ===
sub vcl_backend_response {
    # 通常コンテンツは 60秒キャッシュ
    set beresp.ttl = 60s;

    # /admin は明示的にキャッシュしない(念のため)
    if (bereq.url ~ "^/admin") {
        set beresp.ttl = 0s;
        set beresp.uncacheable = true;
    }
}

# === クライアント応答送信時の処理 ===
sub vcl_deliver {
    # X-Cache ヘッダで HIT/MISS を可視化
    if (obj.hits > 0) {
        set resp.http.X-Cache = "HIT";
        set resp.http.X-Cache-Hits = obj.hits;
    } else {
        set resp.http.X-Cache = "MISS";
    }
}
```

> **解説:VCL のステートマシン**
>
> Varnish のリクエスト処理は複数のサブルーチン(`vcl_recv`、`vcl_hash`、`vcl_backend_fetch`、`vcl_backend_response`、`vcl_deliver` 等)を順に経由する状態機械として動く。各サブルーチンで `return (...)` を呼ぶと次の状態に遷移する。
>
> - `vcl_recv`: クライアントからのリクエストを受けた直後の判定(キャッシュ参照するか、素通りさせるか)
> - `vcl_backend_response`: オリジンから応答を受け取った直後(キャッシュ可否・TTL決定)
> - `vcl_deliver`: クライアントに返す直前(レスポンスヘッダ加工)
>
> どこで何をするか、を意識すると VCL は読みやすくなる。

> **解説:`pass` と `hash` の違い**
>
> - `return (pass)`: このリクエストはキャッシュを参照せずオリジンへ素通し。応答もキャッシュしない
> - (省略時の) `hash` 遷移: URLとHostでハッシュキーを作り、キャッシュを参照する
>
> `/admin` は `pass` させることで、ログイン状態に依存するページなどを誤ってキャッシュさせない安全策になる。

> **考えるポイント:なぜオリジン指定を IP ではなくホスト名にしているか**
>
> `.host = "origin.ex.local"` のようにホスト名で指定することで、IPが変わってもVCLを書き換えずに済む。この名前解決は **Varnish 起動時の OS の resolver** が行う。よって次の 4-4 で Varnish サーバの DNS 設定を dnsmasq に向けてから VCL をロードする必要がある(先に構文チェック・起動をしてしまうと `origin.ex.local` が解決できずに失敗する)。

#### 4-4. Varnish の名前解決を dnsmasq に向ける

**目的:** Varnish が `origin.ex.local` を解決するときに dnsmasq → PowerDNS の経路を通るようにする。VCLは起動時にバックエンドのホスト名を名前解決するため、次の4-5(構文チェック・起動)より前に必ず行う。

```bash
mkdir -p /etc/systemd/resolved.conf.d
cat > /etc/systemd/resolved.conf.d/dnsmasq.conf <<'EOF'
[Resolve]
DNS=<CACHEDNS_PRI>
Domains=~ex.local
EOF

systemctl restart systemd-resolved
resolvectl status
# Current DNS Server: <CACHEDNS_PRI> または Per-link で表示されればOK

resolvectl query origin.ex.local
# 期待: <ORIGIN_PRI> が返る
```

`<CACHEDNS_PRI>` は実際の値に置換。

> **解説:`Domains=~ex.local` の意味**
>
> 先頭の `~` は「ルーティング専用ドメイン」を意味し、「`ex.local` 配下の名前解決はこのリンクの DNS(=dnsmasq)に向ける」という指示。これがないと、systemd-resolved が他の経路も並行して使ってしまい挙動が読みにくくなる。

#### 4-5. VCL の構文チェックと起動

```bash
varnishd -C -f /etc/varnish/default.vcl > /dev/null 2>&1
echo $?
# 0 なら成功(成功時もCソースの大量出力がstderrに出るため、2>&1でまとめて捨てて終了コードで判定する)

systemctl start varnish
systemctl status varnish
systemctl enable varnish

ss -tlnup | grep :80
```

---

### Step 5: 【varnish.localで実施】接続確認

**目的:** Varnish 越しにオリジンへ到達できること、キャッシュが機能していることを確認する。

#### 5-1. 接続確認

```bash
# Varnish 越しにオリジンへ
curl -I http://127.0.0.1/
# 期待: 200 OK + X-Cache: MISS (初回)

curl -I http://127.0.0.1/
# 期待: 200 OK + X-Cache: HIT (2回目以降)
```

---

## 5. 動作確認・検証

### 5-1. 確認チェックリスト

- [ ] **確認①**: dnsmasq のキャッシュ効果(ログの forwarded/cached 表示)
- [ ] **確認②**: Varnish のキャッシュ効果(`X-Cache: HIT/MISS`、応答時間)
- [ ] **確認③**: `/admin` がキャッシュされないこと
- [ ] **確認④**: PowerDNS レコード変更が dnsmasq 経由で反映されること
- [ ] **確認⑤**: `varnishstat` でヒット率を確認

---

### 確認①: dnsmasq のキャッシュ効果

cache-dns サーバ上で実行:

```bash
dig @127.0.0.1 web.ex.local +short
dig @127.0.0.1 web.ex.local +short
```

**ログで forwarded → cached の切り替わりを確認する(主な確認方法):**

```bash
tail -n 20 /var/log/dnsmasq.log
```

1回目は `forwarded web.ex.local to <PDNS_PRI>`(PowerDNSへ問い合わせ)、2回目は `cached web.ex.local is <VARNISH_PRI>`(キャッシュから即答)と表示されればキャッシュが効いている。

> **注意:`dig` の Query time はVPC内では差が出ないことがある**
>
> `dig ... | grep "Query time"` でミリ秒単位の応答時間を比較する方法も考えられるが、同一VPC内はPowerDNSへの往復も1ミリ秒未満で完了することが多く、1回目・2回目とも `Query time: 0 msec` になり違いが見えないことがある。これはキャッシュが効いていないという意味ではなく、`dig` の表示粒度(ミリ秒単位)が本環境の低レイテンシに対して粗すぎるだけである。実際にキャッシュが機能しているかどうかは上記のログで確認するのが確実。

---

### 確認②: Varnish のキャッシュ効果

検証用クライアント(自PC、または Varnish サーバ自身)から:

```bash
# 自PCから(<VARNISH_PUB> に SG で 80番が開いている前提)
curl -sI http://<VARNISH_PUB>/ | grep -i x-cache
# 1回目: X-Cache: MISS

curl -sI http://<VARNISH_PUB>/ | grep -i x-cache
# 2回目以降: X-Cache: HIT
```

応答時間の比較:

```bash
# Varnishのキャッシュをクリア(mallocストレージなので再起動で全消去される)
systemctl restart varnish

# 1回目(再起動直後なのでキャッシュミス)
curl -o /dev/null -s -w "time_total: %{time_total}s\n" http://<VARNISH_PUB>/

# 2回目(キャッシュヒット)
curl -o /dev/null -s -w "time_total: %{time_total}s\n" http://<VARNISH_PUB>/
```

> **解説:サービスを止めずにキャッシュを無効化する方法**
>
> `systemctl restart varnish` はVarnishプロセスごと再起動するため手軽だが、稼働中のサービスでは使いにくい。実務では `varnishadm` でbanをかけ、無停止でキャッシュを論理的に無効化することが多い。
>
> ```bash
> varnishadm ban req.url ~ .
> ```
>
> banは対象パターンにマッチする既存キャッシュを「次回アクセス時に再取得すべきもの」として扱う仕組みで、即座に物理メモリを解放するわけではないが、動作としては「キャッシュがクリアされた」のと同じ結果になる。
>
> **考えるポイント:差が小さい場合**
>
> Nginx の静的ファイル応答は元々高速なので、`time_total` の差はミリ秒単位。差を実感したい場合は、Varnish サーバ内から `curl http://127.0.0.1/` を多数並列で叩き、`varnishstat` のヒット数推移を見るほうが効果的。

---

### 確認③: `/admin` がキャッシュされないこと

```bash
for i in 1 2 3; do
  curl -sI http://<VARNISH_PUB>/admin/ | grep -i x-cache
done
# 何度叩いても X-Cache: MISS になることを確認
```

> **解説:`MISS` と `pass` の違い**
>
> VCLで `return (pass)` した結果も、`vcl_deliver` では `obj.hits == 0` のため `X-Cache: MISS` と表示される。より厳密には `MISS` と `PASS` を区別したい場合は VCL の `vcl_deliver` で `obj.uncacheable` を見て出し分ける手もあるが、本手順では「キャッシュされていない」ことが分かれば十分とする。

---

### 確認④: レコード変更の反映確認

pdns サーバで TTL の挙動を観察するため、`web.ex.local` を一時的に別のIPに変更してみる。

```bash
# pdns サーバで
pdnsutil replace-rrset ex.local web.ex.local A 60 172.31.99.99
pdnsutil list-zone ex.local | grep web
```

cache-dns サーバ側のキャッシュは TTL(=60秒)が切れるまで古い値を返す。即座に反映を見たい場合はキャッシュをクリアする:

```bash
# cache-dns サーバで
# dnsmasq はキャッシュクリア = プロセスへ SIGHUP
# (AL2023のdnsmasq unitにはExecReload=が定義されておらず systemctl reload は使えないため、
#  systemctl kill で直接SIGHUPを送る)
systemctl kill -s HUP dnsmasq

dig @127.0.0.1 web.ex.local +short
# 期待: 172.31.99.99
```

確認後は元に戻す:

```bash
# pdns サーバで
pdnsutil replace-rrset ex.local web.ex.local A 60 <VARNISH_PRI>

# cache-dns サーバで
systemctl kill -s HUP dnsmasq
```

> **考えるポイント:本来 TTL を待つのが正しい挙動**
>
> 「キャッシュをクリアして即座に反映させる」のは検証時の便宜。実運用では「TTLが切れるまで古い値が見える」のが本来の DNS の挙動。だからこそ「変更前に TTL を短くしておく」というプラクティスが存在する。

---

### 確認⑤: varnishstat / varnishlog

```bash
# Varnish サーバで
varnishstat -1 | grep -E "cache_hit|cache_miss|client_req"
# MAIN.cache_hit と MAIN.cache_miss の比率がヒット率
```

リアルタイムでログを流したい場合:

```bash
varnishlog -g request | head -n 80
```

---

## 6. トラブルシューティング

### エラー①: PowerDNS が起動しない

**症状:** `systemctl status pdns` で fail。

**確認:**

```bash
journalctl -u pdns -n 50
```

- `Unable to launch backend` → `launch=gsqlite3` のスペルや SQLite DB のパス、権限を確認
- `Cannot bind to port 53` → 他のサービス(systemd-resolved 等)が 53 を掴んでいないか `ss -tlnup | grep :53`

---

### エラー②: dnsmasq が「address already in use」で起動しない

原因は2パターンあるため、`ss` の結果で切り分ける。

```bash
ss -tlnup | grep :53
```

**パターンA: `127.0.0.53:53` などが表示される場合**

systemd-resolved のスタブリスナーがポート53を握っている。

```bash
# 2-2 の DNSStubListener=no が適用されているか確認
cat /etc/systemd/resolved.conf.d/disable-stub.conf
systemctl restart systemd-resolved
systemctl restart dnsmasq
```

**パターンB: `ss` の結果が空(何も表示されない)の場合**

他プロセスとの競合ではなく、dnsmasq 自身の設定が自己衝突している可能性が高い。`/etc/dnsmasq.conf` の有効行を確認する。

```bash
grep -vE '^#|^$' /etc/dnsmasq.conf
```

- `listen-address=0.0.0.0,127.0.0.1` のように **ワイルドカード(`0.0.0.0`)とそれに包含される具体アドレス(`127.0.0.1`)を`bind-interfaces`と併用**していないか確認する。`0.0.0.0` は `127.0.0.1` を含むため、`127.0.0.1` を削除して1つのアドレスだけにする。
- **`interface=lo` が残っていないか確認する。** AL2023 の dnsmasq パッケージは出荷時点で `interface=lo`(ループバックのみで待ち受け)を有効化しており、2-3節で追加する `listen-address=0.0.0.0` + `bind-interfaces`(全アドレスで待ち受け)と矛盾して自己衝突する。コメントアウトする。

```bash
vi /etc/dnsmasq.conf
# listen-address=0.0.0.0,127.0.0.1 → listen-address=0.0.0.0 に修正
# interface=lo → #interface=lo にコメントアウト

dnsmasq --test
systemctl restart dnsmasq
```

---

### エラー③: Varnish 起動時に「Backend host 'origin.ex.local': resolves to no addresses」

**原因:** Varnish が起動した時点で OS の resolver が `origin.ex.local` を解決できない。

**対処:**

```bash
# Step 4-4 の dnsmasq 向け設定が反映されているか確認
resolvectl status
resolvectl query origin.ex.local

# 通れば再度
systemctl restart varnish
```

それでも解決できない場合、`origin.ex.local` を PowerDNS に登録し忘れていないか確認:

```bash
# pdns で
pdnsutil list-zone ex.local | grep origin
```

---

### エラー④: `X-Cache` ヘッダが付かない

**原因:** VCL が読み込まれていない、または別の VCL が走っている。

**対処:**

```bash
varnishadm vcl.list
varnishadm vcl.show boot
# 想定した内容になっているか確認
systemctl restart varnish
```

---

### エラー⑤: 自PCから http://<VARNISH_PUB>/ にアクセスできない

- SG で 80/tcp が自PCのIPに対して開いているか
- Varnish の listen ポートが 80 か(`ss -tlnup | grep :80`)
- EC2 がパブリックIPを持っているか

---

### ログの場所

| 種別 | コマンド/パス |
|------|--------------|
| PowerDNS | `journalctl -u pdns -f` |
| dnsmasq | `tail -f /var/log/dnsmasq.log` または `journalctl -u dnsmasq -f` |
| Varnish(リクエスト) | `varnishlog -g request` |
| Varnish(統計) | `varnishstat` |
| Nginx | `/var/log/nginx/access.log`, `/var/log/nginx/error.log` |

---

## 7. 参考リソース

| 資料名 | URL |
|--------|-----|
| PowerDNS Authoritative Documentation | https://doc.powerdns.com/authoritative/ |
| pdnsutil リファレンス | https://doc.powerdns.com/authoritative/manpages/pdnsutil.1.html |
| dnsmasq man page | https://thekelleys.org.uk/dnsmasq/docs/dnsmasq-man.html |
| Varnish Cache Documentation | https://varnish-cache.org/docs/ |
| VCL 4.1 Reference | https://varnish-cache.org/docs/trunk/reference/vcl.html |
| Nginx Documentation | https://nginx.org/en/docs/ |

---

## 付録

### A. パラメータまとめ

| パラメータ | 自分の環境の値 | 説明 |
|-----------|--------------|------|
| `<PDNS_PRI>` | | PowerDNS サーバの IP |
| `<CACHEDNS_PRI>` | | dnsmasq サーバの IP |
| `<VARNISH_PRI>` | | Varnish サーバの IP |
| `<VARNISH_PUB>` | | Varnish サーバのグローバルIP(検証用) |
| `<ORIGIN_PRI>` | | Nginx サーバの IP |
| 権威ゾーン | `ex.local` | PowerDNS で管理 |
| TTL(レコード) | 60秒 | 学習用に短め |

### B. 用語解説

| 用語 | 説明 |
|------|------|
| 権威DNS(Authoritative) | あるゾーンの「正解」を持つDNS。PowerDNS が該当 |
| キャッシュ/フォワーダDNS | 自分は権威を持たず、他のDNSへ問い合わせて結果をキャッシュするDNS。dnsmasq が該当 |
| 条件付きフォワーダ | ドメインごとに転送先DNSを変える機能。dnsmasq の `server=/domain/ip` |
| VCL (Varnish Configuration Language) | Varnish の挙動を制御するDSL |
| `vcl_recv` | クライアントリクエスト受信時に呼ばれる VCL サブルーチン |
| `vcl_backend_response` | バックエンド応答受信時に呼ばれる VCL サブルーチン |
| `vcl_deliver` | クライアント応答送信前に呼ばれる VCL サブルーチン |
| HIT / MISS / PASS | キャッシュ参照結果。HIT=ヒット、MISS=ミス、PASS=キャッシュ対象外 |
| TTL | DNS や HTTPキャッシュの有効期間 |

### C. クリーンアップ手順

1. 各サーバでサービス停止: `systemctl stop varnish dnsmasq pdns nginx`(該当のみ)
2. EC2インスタンスを4台とも終了する
3. セキュリティグループ・キーペアを必要に応じて削除する

> **注意:VCL や PowerDNS の DB ファイルはローカル**
>
> 検証用構築なので、EC2を終了すれば全データが消失する。SQLite DB(`/var/lib/pdns/pdns.sqlite3`)に学習で作ったゾーン定義が残したい場合は、事前にローカルにダウンロードしておくこと。
