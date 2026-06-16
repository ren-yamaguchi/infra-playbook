# 【Certbot + Let's Encrypt を用いた Nginx の HTTPS 化】環境構築手順書

---

## 1. ドキュメント情報

| 項目 | 内容 |
|------|------|
| 手順書名 | Certbot + Let's Encrypt を用いた Nginx の HTTPS 化 |
| 作成日 | 2026-06-17 |
| 最終更新日 | 2026-06-17 |
| バージョン | v1.1 |
| 対象環境 | AWS |

> **改訂履歴**
>
> | バージョン | 日付 | 変更内容 |
> |-----------|------|---------|
> | v1.0 | 2026-06-17 | 初版作成 |
> | v1.1 | 2026-06-17 | TTL を 60 秒に設定する旨を追記 |

---

## 2. 目的・概要

### 2-1. 目的

> 本手順書では、既に構築済みの BIND + Nginx 環境に対して、Let's Encrypt から証明書を取得し、Nginx を HTTPS 化する手順について説明する。
> 構築後はブラウザで「`https://www.<ドメイン名>`」でアクセスした際に、鍵マーク付きで Nginx のデフォルトページを閲覧可能な状態を目指す。

> **本手順書のスコープについて(重要)**
>
> 本手順書では、Let's Encrypt の **DNS-01 チャレンジ** を用いて証明書を取得する。
> DNS-01 チャレンジは、認証用の TXT レコードを DNS に登録することでドメイン所有者であることを証明する方式である。これにより 80 番ポートを外部公開する必要がなく、セキュリティグループで HTTP/HTTPS ともに自分の IP のみに絞った構成が実現できる。
>
> 一方、本手順書では **証明書の自動更新は対象外** とする。Let's Encrypt の証明書は有効期限が 90 日であるため、期限が近づいたら本手順書の証明書取得作業を再度手動で実施する必要がある。

> **TTL について(重要)**
>
> 本手順書では検証・動作確認のしやすさを優先し、ゾーンファイルの **TTL を 60 秒(1分)** に設定している。これにより DNS 設定変更後の反映確認が短時間で行えるため、Let's Encrypt 認証用の TXT レコード追加やブラウザでの確認がスムーズに進められる。
> 本番運用時は、DNS サーバへの問い合わせ負荷を抑えるため、通常は 3600(1時間)〜 86400(1日)程度に設定することが多い。

### 2-2. 構成概要(アーキテクチャ)

```
[ローカルPC]
    |
    | HTTPSアクセス (TCP/443)
    v
[EC2: BIND(DNSサーバ) + Nginx(Webサーバ + Let's Encrypt証明書)]
    ^
    | DNS問い合わせ (UDP/53)
    |
[Let's Encrypt 認証サーバ] ← _acme-challenge の TXT レコードを問い合わせ
```

1台のEC2インスタンス上に、BIND(DNSサーバ)とNginx(Webサーバ)を同居させた既存構成に対し、Certbotで取得したLet's Encryptの証明書を導入する。

### 2-3. 完成イメージ(ゴール定義)

- [ ] Certbot で Let's Encrypt の証明書が取得できる
- [ ] ブラウザで「`https://www.<ドメイン名>`」にアクセスし、鍵マーク付きで Nginx のデフォルトページが表示される
- [ ] 「`http://www.<ドメイン名>`」でアクセスした場合、自動的に HTTPS にリダイレクトされる
- [ ] セキュリティグループで 80 番を閉じた状態でも HTTPS アクセスができる

---

## 3. 前提条件・準備

### 3-1. 環境要件

| 項目 | 要件 |
|------|------|
| OS | Amazon Linux 2023 |
| インスタンスタイプ | t3.micro |
| DNSサーバ | BIND |
| Webサーバ | Nginx |
| 証明書ツール | Certbot |
| 認証局 | Let's Encrypt |

### 3-2. 事前構築要件

本手順書の実施前に、以下が完了していること。

| 項目 | 説明 |
|------|------|
| BIND + Nginx 基本構築 | 前回手順書(下記リンク)の構築が完了し、「`http://www.<ドメイン名>`」で Nginx のデフォルトページが閲覧可能な状態であること |
| Route 53 でのサブドメイン権限委譲 | Route 53 上で対象サブドメインの NS レコードを本 EC2 に向けて設定済みであること。これが完了していないと、Let's Encrypt 側から `_acme-challenge` の TXT レコードが引けず、認証に失敗する |
| 外部 DNS からの名前解決確認 | `dig @8.8.8.8 www.<ドメイン名>` で EC2 のパブリックIPが返ってくること |

> **参考:** 前回手順書(BIND + Nginx 基本構築)
> https://github.com/ren-yamaguchi/infra-playbook/blob/main/05_DNS%E3%82%B5%E3%83%BC%E3%83%90/%E6%89%8B%E9%A0%86%E6%9B%B8_BIND_Nginx_%E5%9F%BA%E6%9C%AC%E6%A7%8B%E7%AF%89.md

### 3-3. 本手順書のスコープ外(重要)

以下は本手順書では実施しない。

| 項目 | 説明 |
|------|------|
| 証明書の自動更新 | Let's Encrypt 証明書は 90 日で失効するが、本手順書では自動更新の仕組み(認証フックスクリプト等)は構築しない。期限が近づいたら本手順を再実施すること |
| HTTPS 設定の強化 | TLS バージョンの明示、暗号スイートの選定、HSTS ヘッダの追加など、SSL/TLS のセキュリティ強化設定は本手順書のスコープ外とする |

### 3-4. 必要なアカウント・権限

- AWSアカウント
- 受信可能なメールアドレス(Let's Encrypt からの失効通知用)

### 3-5. セキュリティグループ設定(初期状態)

> **重要:** 構築作業中は、動作確認の都合により HTTP(80)も開放しておく。手順の最後で 80 番を閉じる作業を行う。

| タイプ | プロトコル | ポート範囲 | ソース | 説明 |
|-------|------------|----------|--------|------|
| SSH | TCP | 22 | マイIP | ローカルPCからSSHで接続 |
| HTTP | TCP | 80 | マイIP | 構築途中の IP 直接アクセス確認用(最終的に閉じる) |
| HTTPS | TCP | 443 | マイIP | ローカルPCのブラウザから HTTPS アクセス |
| DNS (UDP) | UDP | 53 | 0.0.0.0/0 | Let's Encrypt 認証サーバを含む外部から `_acme-challenge` の TXT レコードを引けるようにするため |

> **補足:** DNS の 53 番は権威 DNS として動作するため、外部からの問い合わせを受け付ける必要があり `0.0.0.0/0` で開放する。

---

## 4. 構築手順(詳細)

> **注意事項**
> - コマンド中の `<山カッコ>` は自分の環境の値に置き換えること
> - `<任意の名前>` は、前回手順書の BIND 構築時に設定したゾーン名を指す
> - 本手順は前回手順書の構築が完了した状態から開始することを前提とする

---

### Step 1: Certbot のインストール

**目的:** Let's Encrypt の証明書を取得するための Certbot をインストールする。

#### 操作手順

```bash
# ローカルPCからSSHログイン
ssh -i <秘密鍵のファイルパス> ec2-user@<EC2のパブリックIP>

# rootユーザーにスイッチ
sudo su -

# Certbot のインストール
dnf install -y certbot

# インストール確認
certbot --version
```

---

### Step 2: Certbot による証明書取得(DNS-01 チャレンジ)

**目的:** DNS-01 チャレンジ方式で Let's Encrypt の証明書を手動取得する。

> **作業の流れ:**
> 1. Certbot を手動モードで起動する
> 2. Certbot から指示された TXT レコードを BIND のゾーンファイルに登録する
> 3. 外部から TXT レコードが引けることを確認してから Certbot に Enter を返す
> 4. 証明書が発行される

#### 操作手順

##### 2-1. Certbot を手動モードで起動

```bash
# DNS-01 チャレンジで証明書取得を開始
certbot certonly --manual --preferred-challenges dns \
  -d www.<任意の名前> -d <任意の名前>
```

対話形式で以下を聞かれるので回答する。

| 質問 | 回答 |
|------|------|
| `Enter email address` | 受信可能なメールアドレス |
| `Please read the Terms of Service` | `Y`(同意) |
| `Would you be willing ... share your email address with the Electronic Frontier Foundation` | `N`(任意のため不要) |
| `Are you OK with your IP being logged?` | `Y`(DNS-01 では聞かれる場合あり) |

最後に以下のような表示で **一時停止** する。

```
Please deploy a DNS TXT record under the name:
_acme-challenge.<任意の名前>
with the following value:
xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx

Press Enter to Continue
```

**Enter は押さず、別ターミナルで次の作業を行う。**

##### 2-2. BIND のゾーンファイルに TXT レコードを追加(別ターミナル)

```bash
# 別ターミナルでEC2にSSHログインしてrootへスイッチ
ssh -i <秘密鍵のファイルパス> ec2-user@<EC2のパブリックIP>
sudo su -

# ゾーンファイルを編集
vi /var/named/<任意の名前>.zone
```

ゾーンファイルの編集内容:

```
$TTL 60
@ IN SOA ns.<任意の名前>. test.gmail.com. (
    20260617 ; serial ← 既存の値より大きい値にインクリメントする
    3600 ; refresh
    3600 ; retry
    3600 ; expire
    3600 ) ; minimum

    IN NS ns.<任意の名前>.

ns  IN A <自サーバーのパブリックIP>
www IN A <自サーバーのパブリックIP>

; --- 以下を追記 ---
_acme-challenge IN TXT "xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"
```

> **重要:** SOA レコードのシリアル番号を必ずインクリメントすること。インクリメントしないと BIND が新しい内容を読み込まない。
>
> **TTL について:** `$TTL 60` は、本ゾーン内のレコードのデフォルト TTL を 60 秒に設定するもの。これは検証用の短い値であり、DNS 変更の反映確認をスムーズに行うための設定である(詳細は「2-1. 目的」の補足を参照)。前回手順書から流用する場合、TTL は 3600 になっているため 60 に変更すること。

```bash
# ゾーンファイルの構文チェック
named-checkzone <任意の名前> /var/named/<任意の名前>.zone

# BINDに設定を再読み込みさせる
rndc reload
```

##### 2-3. TXT レコードが引けるか確認

```bash
# 自分のBINDに直接問い合わせ
dig @localhost _acme-challenge.<任意の名前> TXT +short

# 外部DNS経由で問い合わせ(Let's Encrypt 側から見えるかの確認)
dig @8.8.8.8 _acme-challenge.<任意の名前> TXT +short
```

**期待する結果:** 両方の問い合わせで、登録した TXT レコードの値が返ってくる。

##### 2-4. Certbot に戻って Enter を押す

最初の Certbot を実行したターミナルに戻り、Enter を押す。Let's Encrypt 側で認証が行われ、成功すると以下のメッセージが表示される。

```
Successfully received certificate.
Certificate is saved at: /etc/letsencrypt/live/www.<任意の名前>/fullchain.pem
Key is saved at:         /etc/letsencrypt/live/www.<任意の名前>/privkey.pem
```

##### 2-5. 証明書ファイルの確認

```bash
ll /etc/letsencrypt/live/www.<任意の名前>/
```

**期待する結果:** `cert.pem`、`chain.pem`、`fullchain.pem`、`privkey.pem` のシンボリックリンクが作成されている。

---

### Step 3: Nginx の HTTPS 設定

**目的:** 取得した証明書を Nginx に設定し、HTTPS でアクセスできるようにする。

#### 操作手順

```bash
# Nginx の設定ファイルを編集(新規作成)
vi /etc/nginx/conf.d/<任意の名前>.conf
```

設定ファイルの編集内容:

```nginx
# HTTP (80) → HTTPS にリダイレクト
server {
    listen 80;
    server_name www.<任意の名前> <任意の名前>;
    return 301 https://$host$request_uri;
}

# HTTPS (443)
server {
    listen 443 ssl;
    server_name www.<任意の名前> <任意の名前>;

    ssl_certificate     /etc/letsencrypt/live/www.<任意の名前>/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/www.<任意の名前>/privkey.pem;

    location / {
        root  /usr/share/nginx/html;
        index index.html index.htm;
    }
}
```

> **注意:** 既存の Nginx 設定(`/etc/nginx/nginx.conf` 内の `server` ブロック等)に同じ `server_name` の 80 番設定が残っている場合、設定の重複でエラーになる。既存の HTTP 用 `server` ブロックはコメントアウトまたは削除すること。

```bash
# Nginx 設定の構文チェック
nginx -t

# Nginx の再読み込み
systemctl reload nginx

# Nginx が 443 で Listen していることを確認
ss -tlnp | grep nginx
```

**期待する結果:** `0.0.0.0:443` と `0.0.0.0:80` の両方で Listen している。

---

### Step 4: 動作確認(HTTP/HTTPS 両方が開いた状態)

> 詳細は「5. 動作確認・検証」のセクションを参照。
> このタイミングで以下を確認する。
>
> - ブラウザで「`https://www.<任意の名前>`」にアクセスし、鍵マーク付きで Nginx のデフォルトページが表示される
> - ブラウザで「`http://www.<任意の名前>`」にアクセスすると、自動的に HTTPS にリダイレクトされる

動作確認が完了したら、次の Step 5 でセキュリティグループの 80 番を閉じる。

---

### Step 5: セキュリティグループの 80 番を閉じる

**目的:** 構築完了後、不要となった HTTP(80)のインバウンドルールを削除し、最小権限の原則に基づいた構成に変更する。

#### 操作手順

AWS マネジメントコンソールでセキュリティグループを編集し、インバウンドルールを以下の状態にする。

| タイプ | プロトコル | ポート範囲 | ソース | 説明 |
|-------|------------|----------|--------|------|
| SSH | TCP | 22 | マイIP | ローカルPCからSSHで接続 |
| HTTPS | TCP | 443 | マイIP | ローカルPCのブラウザから HTTPS アクセス |
| DNS (UDP) | UDP | 53 | 0.0.0.0/0 | 権威DNSとして外部からの問い合わせを受け付ける |

> **削除対象:** タイプ「HTTP / TCP / 80 / マイIP」のインバウンドルール

設定変更後、再度動作確認を行い、HTTPS でアクセス可能なことを確認する。

---

## 5. 動作確認・検証

> 構築完了後、以下の確認をすべてパスしたら構築成功とみなす。

### 5-1. 確認チェックリスト

- [ ] **確認①**: EC2 上で localhost 経由の HTTPS アクセスが成功する
- [ ] **確認②**: ブラウザで「`https://www.<任意の名前>`」にアクセスし、鍵マーク付きで Nginx のデフォルトページが表示される
- [ ] **確認③**: ブラウザで「`http://www.<任意の名前>`」にアクセスし、HTTPS に自動リダイレクトされる
- [ ] **確認④**: SG 変更後(80 番を閉じた後)も HTTPS アクセスが継続できる

---

### 確認①: EC2 上での localhost 経由の HTTPS アクセス確認

EC2 上で以下のコマンドを実行する。

```bash
curl -kI https://localhost -H "Host: www.<任意の名前>"
```

**期待する結果:** `HTTP/1.1 200 OK` が返ってくる。

> **補足:** EC2 自身からパブリックIPに対して `curl` を実行すると、セキュリティグループで「自分のIPのみ」を許可している場合、EC2 のIPからは入れずタイムアウトする。これは正常動作のため、localhost 経由で確認する。

---

### 確認②: ブラウザでの HTTPS アクセス確認

ローカルPCのブラウザで「`https://www.<任意の名前>`」にアクセスする。

**期待する結果:**
- 鍵マーク(🔒)が表示される
- 「*Welcome to nginx!*」が表示される
- 証明書を表示すると、発行者が「Let's Encrypt」になっている

---

### 確認③: HTTP → HTTPS リダイレクト確認

ローカルPCのブラウザで「`http://www.<任意の名前>`」にアクセスする。

**期待する結果:** URL が自動的に「`https://www.<任意の名前>`」に変わり、HTTPS で接続される。

---

### 確認④: SG 変更後の HTTPS アクセス確認

Step 5 でセキュリティグループの 80 番を閉じた後、再度ブラウザで「`https://www.<任意の名前>`」にアクセスする。

**期待する結果:** 鍵マーク付きで Nginx のデフォルトページが表示される。

---

## 6. トラブルシューティング

### よくあるエラーと対処法

---

#### エラー①: `dig @8.8.8.8 _acme-challenge.<任意の名前> TXT` で値が返ってこない

**原因:**
- Route 53 でのサブドメイン権限委譲が完了していない
- BIND の `rndc reload` を実行していない
- SOA レコードのシリアル番号をインクリメントしていない
- セキュリティグループで 53/UDP が外部に開いていない

**対処法:**
```bash
# 自分のBINDには反映されているか
dig @localhost _acme-challenge.<任意の名前> TXT +short

# 権限委譲の確認(Route 53 が本EC2をNSとして返しているか)
dig <任意の名前> NS +short

# シリアル番号確認
grep -i serial /var/named/<任意の名前>.zone

# BINDのログ確認
journalctl -u named -n 50
```

---

#### エラー②: Certbot で `DNS problem: NXDOMAIN looking up TXT` エラー

**原因:** 外部DNSから `_acme-challenge.<任意の名前>` のTXTレコードが引けない

**対処法:** エラー①の対処法を参照。`dig @8.8.8.8` で TXT レコードが返ることを確認してから Certbot に Enter を返す。

---

#### エラー③: `nginx -t` で `duplicate ... server` エラー

**エラーメッセージ例:**
```
nginx: [emerg] duplicate listen options for 0.0.0.0:80
```

**原因:** 既存の Nginx 設定(`/etc/nginx/nginx.conf` 内のデフォルト `server` ブロック等)と、新規作成した HTTPS 設定の `server_name` または `listen` が重複している

**対処法:** 既存の HTTP 用 `server` ブロックをコメントアウトまたは削除する。
```bash
# 既存設定の確認
grep -rn "server_name" /etc/nginx/
```

---

#### エラー④: ブラウザで HTTPS アクセスができない

**原因:**
- セキュリティグループで 443 番が開いていない
- 自分のローカル IP が変わっており、SG の許可IPと現在のIPが異なる
- Nginx が 443 で Listen していない

**対処法:**
```bash
# Nginx の Listen 状況確認
ss -tlnp | grep nginx

# 現在の自分のグローバルIPを確認 → SG の許可IPと一致しているか確認
```

---

### ログの確認場所

| ログの種類 | 場所(パス) | 確認コマンド |
|-----------|------------|------------|
| Certbot ログ | `/var/log/letsencrypt/letsencrypt.log` | `sudo tail -f /var/log/letsencrypt/letsencrypt.log` |
| BINDログ | `/var/log/messages` または `journalctl -u named` | `sudo journalctl -u named -f` |
| Nginxアクセスログ | `/var/log/nginx/access.log` | `sudo tail -f /var/log/nginx/access.log` |
| Nginxエラーログ | `/var/log/nginx/error.log` | `sudo tail -f /var/log/nginx/error.log` |

---

## 7. 参考リソース・関連資料

| 資料名 | URL / 場所 | 補足 |
|-------|-----------|------|
| Let's Encrypt 公式 | https://letsencrypt.org/ja/ | Let's Encrypt の概要・利用規約 |
| Certbot 公式ドキュメント | https://eff-certbot.readthedocs.io/ | Certbot コマンドリファレンス |
| ACME プロトコル仕様 (RFC 8555) | https://datatracker.ietf.org/doc/html/rfc8555 | 認証プロトコルの詳細 |
| 前回手順書(BIND + Nginx 基本構築) | https://github.com/ren-yamaguchi/infra-playbook/blob/main/05_DNS%E3%82%B5%E3%83%BC%E3%83%90/%E6%89%8B%E9%A0%86%E6%9B%B8_BIND_Nginx_%E5%9F%BA%E6%9C%AC%E6%A7%8B%E7%AF%89.md | 本手順書の前提となる構築手順 |

---

## 付録(任意)

### A. 環境変数・パラメータまとめ

| パラメータ名 | 自分の環境の値 | 説明 |
|------------|-------------|------|
| EC2 パブリックIP | `xx.xx.xx.xx` | SSH接続・HTTPSアクセスの宛先 |
| ドメイン名 | `<任意の名前>` | BIND で管理するゾーン名 |
| 証明書配置パス | `/etc/letsencrypt/live/www.<任意の名前>/` | 取得した証明書のシンボリックリンク配置先 |
| 受信メールアドレス | `<メールアドレス>` | Let's Encrypt からの失効通知用 |

### B. 用語解説

| 用語 | 説明 |
|------|------|
| Let's Encrypt | 無料で SSL/TLS 証明書を発行している認証局(CA)。証明書の有効期限は 90 日。 |
| Certbot | Let's Encrypt の証明書発行・更新を自動化するためのクライアントツール。 |
| ACME | Automatic Certificate Management Environment。Let's Encrypt が採用している証明書発行プロトコル。 |
| HTTP-01 チャレンジ | 80 番ポート経由で Web サーバ上に認証ファイルを配置して所有者認証する方式。 |
| DNS-01 チャレンジ | DNS に TXT レコードを登録して所有者認証する方式。ワイルドカード証明書取得や 80 番ポート非公開構成で利用。 |
| `fullchain.pem` | サーバ証明書 + 中間証明書を結合したファイル。Nginx で利用。 |
| `privkey.pem` | 秘密鍵ファイル。Nginx で利用。 |

### C. HTTP-01 との比較(参考)

| 項目 | HTTP-01 | DNS-01 |
|------|---------|--------|
| 認証方式 | Web サーバ上のファイル配置 | DNS の TXT レコード登録 |
| 必要なポート | 80(外部公開必須) | 53(権威DNSとして外部公開) |
| 自動化の容易さ | 容易(Certbot の nginx プラグインで自動) | 困難(DNS サーバへの API or フックスクリプトが必要) |
| ワイルドカード証明書 | 取得不可 | 取得可能 |
| セキュリティ | 80 番を全公開する必要あり | 80 番を閉じられる |

### D. 証明書更新時の作業

Let's Encrypt 証明書は 90 日で失効するため、期限が近づいたら以下のコマンドで再取得する。

```bash
# 既存の証明書を強制的に更新
certbot certonly --manual --preferred-challenges dns \
  -d www.<任意の名前> -d <任意の名前> --force-renewal
```

本手順書の Step 2-2 〜 2-4 と同様に、BIND のゾーンファイルに TXT レコードを追加(シリアル番号をインクリメント)してから Certbot に Enter を返す。

更新後は Nginx を reload する。

```bash
systemctl reload nginx
```

### E. 削除・クリーンアップ手順

1. EC2 インスタンスを終了する
2. Let's Encrypt の証明書失効処理(任意):
   ```bash
   certbot revoke --cert-path /etc/letsencrypt/live/www.<任意の名前>/cert.pem
   ```
3. セキュリティグループを削除する
4. キーペアを削除する(必要に応じて)
