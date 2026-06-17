# 【BIND + Nginx を用いた DNS/Web サーバ構築】環境構築手順書

---

## 1. ドキュメント情報

| 項目 | 内容 |
|------|------|
| 手順書名 | BIND + Nginx を用いた DNS/Web サーバ構築 |
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

> 本手順書では、WebページをホスティングするWebサーバ(Nginx)と、名前解決を行うDNSサーバ(BIND)の構築手順について説明する。
> 構築後はブラウザで「`http://<ドメイン名>`」でアクセスした際に、Nginxのデフォルトページを閲覧可能な状態を目指す。

> **本手順書のスコープについて(重要)**
>
> 本来、独自のサブドメインをインターネット上で名前解決できるようにするためには、Route 53(または上位のDNS)側で**サブドメインの権限委譲(NSレコード設定)** を行う必要がある。
> **本手順書ではRoute 53でのサブドメイン権限委譲の手順は省略している。** 権限委譲を行わない場合、外部のDNSからは名前解決できないが、自分で構築したDNSサーバ(BIND)に対して直接問い合わせを行えば、ドメイン名で名前解決し、Webページの表示確認が可能である。

### 2-2. 構成概要(アーキテクチャ)

```
[ローカルPC]
    |
    | ① DNS問い合わせ (UDP/53)
    v
[EC2: BIND(DNSサーバ) + Nginx(Webサーバ)]
    |
    | ② HTTPアクセス (TCP/80)
    v
[ローカルPC] ← Nginxのデフォルトページが表示される
```

1台のEC2インスタンス上に、BIND(DNSサーバ)とNginx(Webサーバ)を同居させる構成。

### 2-3. 完成イメージ(ゴール定義)

- [ ] EC2インスタンスにSSHログインできる
- [ ] ローカルPCからBINDに対してDNS問い合わせができる
- [ ] ブラウザで「`http://<ドメイン名>`」にアクセスし、Nginxのデフォルトページが表示される

---

## 3. 前提条件・準備

### 3-1. 環境要件

| 項目 | 要件 |
|------|------|
| OS | Amazon Linux 2023 |
| インスタンスタイプ | t3.micro |
| DNSサーバ | BIND |
| Webサーバ | Nginx |

### 3-2. 本手順書のスコープ外(重要)

以下は本手順書では実施しない。

| 項目 | 説明 |
|------|------|
| Route 53でのサブドメイン権限委譲 | 本来、構築したBINDをインターネット上で機能させるには、Route 53上で対象サブドメインのNSレコードを本EC2に向ける必要があるが、本手順書では省略する |
| インターネット経由での名前解決確認 | 上記の権限委譲を行っていないため、外部DNSからは名前解決できない。動作確認はローカルPCからBINDへ直接問い合わせる形で行う |

### 3-3. 必要なアカウント・権限

- AWSアカウント
- SSHクライアントがローカルPCにインストール済みであること

### 3-4. 事前準備物

- キーペア(`.pem` ファイル)を作成・保存済み
- セキュリティグループを作成済み

### 3-5. セキュリティグループ設定

| タイプ | プロトコル | ポート範囲 | ソース | 説明 |
|-------|------------|----------|--------|------|
| SSH | TCP | 22 | マイIP | ローカルPCからSSHで接続 |
| HTTP | TCP | 80 | マイIP | ローカルPCのブラウザからアクセスするため |
| DNS (UDP) | UDP | 53 | マイIP | ローカルPCからBINDへの名前解決問い合わせ |

> **補足:** Route 53権限委譲を省略し、ローカルPCからの問い合わせのみを想定するため、DNSのソースは「マイIP」に絞っている。本番運用で外部から問い合わせを受け付ける場合は `0.0.0.0/0` とする。

---

## 4. 構築手順(詳細)

> **注意事項**
> - コマンド中の `<山カッコ>` は自分の環境の値に置き換えること
> - `<任意の名前>` は、自分や他のメンバーと区別できるように決めること(例: `example.local`、`mydomain.test` など)

---

### Step 1: システム設定

**目的:** EC2インスタンスにログインし、パッケージの更新とタイムゾーンの設定を行う。

#### 操作手順

```bash
# ローカルPCからSSHログイン
ssh -i <秘密鍵のファイルパス> ec2-user@<EC2のパブリックIP>

# rootユーザーにスイッチ
sudo su -

# 最新パッケージへの更新
dnf update -y

# システムの時間を日本時間に設定
timedatectl set-timezone Asia/Tokyo
```

---

### Step 2: DNSサーバ(BIND)の設定

**目的:** BINDをインストールし、DNSサーバとして動作するように設定する。

#### 操作手順

```bash
# BINDのインストール
dnf install -y bind

# BIND設定ファイル(named.conf)のバックアップ取得
cp /etc/named.conf{,.org}

# BIND設定ファイルの編集
vi /etc/named.conf
```

設定ファイルの編集内容:

```
// ---[options]セクション内を以下のように変更---
options {
    listen-on port 53 { any; };           // 元: { 127.0.0.1; }
    listen-on-v6 port 53 { none; };       // 元: { ::1; } (IPv6を使わない場合)
    directory       "/var/named";
    dump-file       "/var/named/data/cache_dump.db";
    statistics-file "/var/named/data/named_stats.txt";
    memstatistics-file "/var/named/data/named_mem_stats.txt";
    recursing-file  "/var/named/data/named.recursing";
    secroots-file   "/var/named/data/named.secroots";

    allow-query     { any; };             // 元: { localhost; }
    recursion no;                         // 権威DNSとして動作させるためnoに変更

    dnssec-validation no;

    managed-keys-directory "/var/named/dynamic";
    geoip-directory "/usr/share/GeoIP";

    pid-file "/run/named/named.pid";
    session-keyfile "/run/named/session.key";

    include "/etc/crypto-policies/back-ends/bind.config";
};

// ---ファイル末尾に以下を追記---
zone "<任意の名前>" IN {
    type master;
    file "<任意の名前>.zone";
    allow-update { none; };
};
```

```bash
# 設定ファイルの構文チェック
named-checkconf /etc/named.conf

# ゾーンファイルの作成と編集
vi /var/named/<任意の名前>.zone
```

ゾーンファイルの編集内容:

```
$TTL 3600
@ IN SOA ns.<任意の名前>. test.gmail.com. (
    20260616 ; serial
    3600 ; refresh
    3600 ; retry
    3600 ; expire
    3600 ) ; minimum

    IN NS ns.<任意の名前>.

ns  IN A <自サーバーのパブリックIP>
www IN A <自サーバーのパブリックIP>
```

```bash
# ゾーンファイルの所有者をnamedに変更(BINDのプロセスが読み込めるように)
chown root:named /var/named/<任意の名前>.zone

# ゾーンファイルの権限を設定
chmod 640 /var/named/<任意の名前>.zone

# ゾーンファイルの構文チェック
named-checkzone <任意の名前> /var/named/<任意の名前>.zone

# BINDの起動と自動起動設定
systemctl enable --now named

# BINDの起動確認
systemctl status named | less

# BINDの自動起動設定確認
systemctl is-enabled named
```

---

### Step 3: Webサーバ(Nginx)の設定

**目的:** Nginxをインストールし、Webサーバとして起動する。

#### 操作手順

```bash
# Nginxのインストール
dnf install -y nginx

# Nginxの起動と自動起動設定
systemctl enable --now nginx

# Nginxの起動確認
systemctl status nginx | less

# Nginxの自動起動設定確認
systemctl is-enabled nginx
```

---

## 5. 動作確認・検証

> 構築完了後、以下の確認をすべてパスしたら構築成功とみなす。

### 5-1. 確認チェックリスト

- [ ] **確認①**: ブラウザで「`http://<EC2のパブリックIP>`」にアクセスし、Nginxのデフォルトページが表示される
- [ ] **確認②**: ローカルPCからBINDに直接問い合わせて名前解決ができる
- [ ] **確認③**: ブラウザで「`http://<ドメイン名>`」にアクセスし、Nginxのデフォルトページが表示される

---

### 確認①: NginxのIP直接アクセス確認

ブラウザで「`http://<EC2のパブリックIP>`」にアクセスする。

**期待する結果:** 「*Welcome to nginx!*」が表示される

---

### 確認②: BINDへの直接問い合わせによる名前解決確認

ローカルPC側で、構築したBINDに対して直接DNS問い合わせを行う。

```bash
# Linux/Mac/WSLの場合
dig @<EC2のパブリックIP> www.<任意の名前>

# Windowsの場合
nslookup www.<任意の名前> <EC2のパブリックIP>
```

**期待する結果:** `www.<任意の名前>` のAレコードとして、EC2のパブリックIPが返ってくる

---

### 確認③: ドメイン名でのWebアクセス確認

> **補足:** Route 53の権限委譲を省略しているため、デフォルトの設定ではドメイン名でアクセスできない。確認のためには、ローカルPCの **hosts ファイル** にドメインとIPの対応を一時的に登録するか、ローカルPCのDNS問い合わせ先を構築したBINDに変更する必要がある。

##### hostsファイルを利用する場合(簡易確認)

| OS | hostsファイルの場所 |
|----|-------------------|
| Linux/Mac/WSL | `/etc/hosts` |
| Windows | `C:\Windows\System32\drivers\etc\hosts` |

hostsファイルに以下を追記する。

```
<EC2のパブリックIP>  www.<任意の名前>
```

ブラウザで「`http://www.<任意の名前>`」にアクセスする。

**期待する結果:** 「*Welcome to nginx!*」が表示される

> **注意:** 確認終了後はhostsファイルの追記行を削除しておくこと。

---

## 6. トラブルシューティング

### よくあるエラーと対処法

---

#### エラー①: `named-checkconf` または `named-checkzone` で構文エラーが出る

**原因:** 設定ファイル・ゾーンファイルの記法ミス

**対処法:**
- `zone "<任意の名前>" IN { ... };` のセミコロンとブレースが正しく対応しているか確認
- ゾーンファイルの `$TTL`、`SOA`、`NS`、`A` レコードの行頭に余分なスペースが入っていないか確認
- SOAレコードのシリアル番号(`20260616` など)が10桁以内の数値か確認

---

#### エラー②: BINDが起動しない

**エラーメッセージ例:**
```
Failed to start named.service
```

**原因:** ポート53が他のプロセスで使われている、設定ファイルの構文エラー、ゾーンファイルの権限不足など

**対処法:**
```bash
# ポート53を使用しているプロセスを確認
ss -ulnp | grep :53

# systemd-resolvedが53を使っている場合は停止
systemctl stop systemd-resolved
systemctl disable systemd-resolved

# BINDのログを確認
journalctl -u named -n 50
tail -f /var/log/messages

# ゾーンファイルの権限を再確認
ls -l /var/named/<任意の名前>.zone
# → 所有者がroot:namedで、namedグループに読み取り権限があること
```

---

#### エラー③: ブラウザでドメイン名アクセスできない

**原因:** Route 53での権限委譲が行われていないため、外部DNSからは名前解決できない

**対処法:** 本手順書の「確認③」のとおり、hostsファイルへの追記、またはローカルPCのDNS問い合わせ先をBINDに変更する。

---

### ログの確認場所

| ログの種類 | 場所(パス) | 確認コマンド |
|-----------|------------|------------|
| BINDログ | `/var/log/messages` または `journalctl -u named` | `sudo journalctl -u named -f` |
| Nginxアクセスログ | `/var/log/nginx/access.log` | `sudo tail -f /var/log/nginx/access.log` |
| Nginxエラーログ | `/var/log/nginx/error.log` | `sudo tail -f /var/log/nginx/error.log` |

---

## 7. 参考リソース・関連資料

| 資料名 | URL / 場所 | 補足 |
|-------|-----------|------|
| BIND 公式ドキュメント (ISC) | https://www.isc.org/bind/ | BINDの設定リファレンス |
| Nginx 公式ドキュメント | https://nginx.org/en/docs/ | Nginxの設定リファレンス |

---

## 付録(任意)

### A. 環境変数・パラメータまとめ

| パラメータ名 | 自分の環境の値 | 説明 |
|------------|-------------|------|
| EC2 パブリックIP | `xx.xx.xx.xx` | SSH接続・DNS問い合わせ・HTTPアクセスの宛先 |
| ドメイン名 | `<任意の名前>` | BINDで管理するゾーン名 |
| キーペア名 | `<秘密鍵の名前>` | SSH認証に使用 |

### B. 用語解説

| 用語 | 説明 |
|------|------|
| BIND | Berkeley Internet Name Domain。世界で最も広く使われているDNSサーバソフトウェア。 |
| named | BINDのデーモンプロセス名。`systemctl` での操作対象。 |
| ゾーンファイル | DNSのレコード(A、NS、SOA等)を記述するファイル。 |
| SOAレコード | ゾーンの管理情報を示すレコード(シリアル番号、リフレッシュ間隔など)。 |
| NSレコード | そのゾーンを管理する権威DNSサーバを示すレコード。 |
| Aレコード | ドメイン名とIPv4アドレスの対応を示すレコード。 |
| 権威DNSサーバ | 特定ゾーンの正規の名前解決情報を返すDNSサーバ。本手順書のBINDがこれに該当。 |
| 権限委譲 | 上位のDNSが、サブドメインの管理を別のDNSサーバに委ねること。NSレコードで実現する。 |

### C. NSDとの比較(参考)

| 項目 | BIND | NSD |
|------|------|-----|
| 設定ファイル | `/etc/named.conf` | `/etc/nsd/nsd.conf` |
| ゾーンファイル配置 | `/var/named/` | `/etc/nsd/` |
| サービス名 | `named` | `nsd` |
| 構文チェック | `named-checkconf`, `named-checkzone` | `nsd-checkconf`, `nsd-checkzone` |
| 役割 | 権威DNS + キャッシュDNS(両用可) | 権威DNS専用 |
| リポジトリ | 標準リポジトリ | SPAL(拡張)リポジトリが必要 |

### D. 削除・クリーンアップ手順

1. EC2インスタンスを終了する
2. セキュリティグループを削除する
3. キーペアを削除する(必要に応じて)
