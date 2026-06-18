# 【Postfix + Dovecot + BIND を用いたメールサーバ構築(2台同居構成)】環境構築手順書

---

## 1. ドキュメント情報

| 項目 | 内容 |
|------|------|
| 手順書名 | Postfix + Dovecot + BIND を用いたメールサーバ構築(2台同居構成) |
| 作成日 | 2026-06-16 |
| 最終更新日 | 2026-06-16 |
| バージョン | v1.1 |
| 対象環境 | AWS |

> **改訂履歴**
>
> | バージョン | 日付 | 変更内容 |
> |-----------|------|---------|
> | v1.0 | 2026-05-18 | 初版作成 |
> | v1.1 | 2026-06-16 | テンプレート構成に再構成、誤記訂正、Step番号の整合 |

---

## 2. 目的・概要

### 2-1. 目的

> 本手順書では、2台のEC2インスタンス間でメールのやり取りができるメールサーバの構築手順について説明する。
> 各EC2にSMTPサーバ(Postfix)・POPサーバ(Dovecot)・DNSサーバ(BIND)を同居させ、2台間で送受信できる状態を目指す。

### 2-2. 構成概要(アーキテクチャ)

```
[サーバA]                          [サーバB]
  ├─ Postfix (SMTP/25)              ├─ Postfix (SMTP/25)
  ├─ Dovecot (POP3/110)             ├─ Dovecot (POP3/110)
  └─ BIND    (DNS/53)               └─ BIND    (DNS/53)
                ↑ メール送受信 ↓
                ↑ 名前解決   ↓
```

2台のEC2インスタンス上に、Postfix・Dovecot・BINDをそれぞれ同居させる構成。

### 2-3. 完成イメージ(ゴール定義)

- [ ] 自サーバから自サーバへメールを送ることができる
- [ ] 自サーバから他サーバへメールを送ることができる
- [ ] 自サーバから他サーバへユーザー名を指定してメールを送ることができる
- [ ] telnetを用いて他サーバへ届いたメールを確認することができる

---

## 3. 前提条件・準備

### 3-1. 環境要件

| 項目 | 要件 |
|------|------|
| OS | Amazon Linux 2023 |
| インスタンスタイプ | t3.micro |
| インスタンス台数 | 2台 |
| SMTPサーバ | Postfix |
| POP3サーバ | Dovecot |
| DNSサーバ | BIND |
| メール管理ツール | Mailx |
| ログ管理サービス | Rsyslog |
| リモート操作コマンド | Telnet |

### 3-2. 必要なアカウント・権限

- AWSアカウント
- SSHクライアントがローカルPCにインストール済みであること

### 3-3. 事前準備物

- キーペア(`.pem` ファイル)を作成・保存済み
- セキュリティグループを作成済み

### 3-4. セキュリティグループ設定

| タイプ | プロトコル | ポート範囲 | ソース | 説明 |
|-------|------------|----------|--------|------|
| SSH | TCP | 22 | マイIP | ローカルPCからSSHで接続 |
| SMTP | TCP | 25 | 0.0.0.0/0 | メールがどこから転送されるか不明なため |
| POP3 | TCP | 110 | <VPCのCIDR> | メールを受信する相手を許可するため |
| DNS (UDP) | UDP | 53 | 0.0.0.0/0 | どこから名前解決依頼がくるか不明なため |

---

## 4. 構築手順(詳細)

> **注意事項**
> - コマンド中の `<山カッコ>` は自分の環境の値に置き換えること
> - `<任意の名前>` は、自分や他のメンバーと区別できるように決めること
> - 本手順書は2台のEC2(サーバA・サーバB)それぞれで同じ手順を実施する(ただしIPアドレス・ドメイン名は各サーバごとに置き換える)

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
# (これによりログを確認した時の時間が日本時間で表示されるようになる)
timedatectl set-timezone Asia/Tokyo
```

---

### Step 2: SMTPサーバ(Postfix)の設定

**目的:** Postfixをインストールし、SMTPサーバの設定を行う。

#### 操作手順

```bash
# PostfixとMailxをインストール
dnf install -y postfix mailx

# Postfixの設定ファイルのバックアップ取得(原本保存)
cp /etc/postfix/main.cf{,.org}

# Postfixの設定ファイルを変更
vi /etc/postfix/main.cf
```

設定ファイルの編集内容:

```
# ---以下のように変更---
myhostname = mail.<任意の名前>.local
mydomain = <任意の名前>.local
myorigin = $myhostname
inet_interfaces = all
mydestination = $mydomain, $myhostname
mynetworks = <VPCのCIDR>, 127.0.0.1
mail_spool_directory = /var/spool/mail/
# ----------------------
```

```bash
# Postfixの起動と自動起動設定
systemctl enable --now postfix

# Postfixの起動確認
systemctl status postfix | less

# Postfixの自動起動設定確認
systemctl is-enabled postfix
```

---

### Step 3: DNSサーバ(BIND)の設定

**目的:** BINDをインストールし、DNSサーバの設定を行う。

#### 操作手順

```bash
# BINDのインストール
dnf install -y bind

# BINDの設定ファイルのバックアップ取得(原本保存)
cp /etc/named.conf{,.org}

# BINDの設定ファイルの変更と追記
vi /etc/named.conf
```

設定ファイルの編集内容:

```
// ---[options]セクション内の変更---
// 元: listen-on port 53 { 127.0.0.1; };
// 元: listen-on-v6 port 53 { ::1; };
// 上記2行はコメントアウト(または any; に変更)

// 元: allow-query { localhost; };
// ↓に変更
allow-query { any; };

// ---ファイル末尾に以下を追記---
zone "<任意の名前>.local" IN {
    type master;
    file "/var/named/<任意の名前>.local.zone";
};
```

```bash
# 設定ファイルの構文チェック
named-checkconf

# ゾーンデータベースファイルの作成と記入
vi /var/named/<任意の名前>.local.zone
```

ゾーンファイルの編集内容:

```
$TTL 60
@ IN SOA ns.<任意の名前>.local. test.gmail.com. (
    20260616 ; serial
    3600 ; refresh
    3600 ; retry
    3600 ; expire
    3600 ) ; minimum

    IN NS ns.<任意の名前>.local.
    IN MX 10 mail.<任意の名前>.local.

ns   IN A <DNSサーバーのプライベートIP>
mail IN A <SMTPサーバーのプライベートIP>
```
TTL は検証のために 60（60秒）に設定しているが、検証終了後は適した値に設定
例）3600（1時間）、86400（1日）

```bash
# ゾーンファイルの構文チェック
named-checkzone <任意の名前>.local /var/named/<任意の名前>.local.zone

# BINDの起動と自動起動設定
systemctl enable --now named

# BINDの起動確認
systemctl status named | less

# BINDの自動起動設定確認
systemctl is-enabled named

# LinuxのDNS問い合わせ先設定ファイルのバックアップ取得(原本保存)
cp /etc/systemd/resolved.conf{,.org}

# LinuxのDNS問い合わせ先の変更
vi /etc/systemd/resolved.conf
```

設定ファイルの編集内容:

```
# ---以下のように変更---
DNS=<DNSサーバーのプライベートIP>
# ----------------------
```

```bash
# DNSルールの設定を反映させるため再起動
systemctl restart systemd-resolved.service
```

---

### Step 4: メール送受信確認(自サーバ)

**目的:** MailxとRsyslogを用いてメールの自サーバでの送受信の確認を行う。

#### 操作手順

```bash
# Rsyslogのインストール
dnf install -y rsyslog

# Rsyslogの起動と自動起動設定
systemctl enable --now rsyslog

# Rsyslogの起動確認
systemctl status rsyslog | less

# Rsyslogの自動起動設定確認
systemctl is-enabled rsyslog

# 自サーバへメールの送信
mail -s <件名> root@<任意の名前>.local
```

対話形式でメールを送る:

```
<内容>  ← 内容を記入したらEnter
.       ← 「.」を入力してEnterを押してメールを送信
```

```bash
# メールを送信できているか確認
less /var/log/maillog
# → 「status=sent」が表示されていれば成功

# mailコマンドでメールが届いているか確認
mail
```

mailコマンドでの確認結果:

```
Heirloom Mail version 12.5 7/5/10.  Type ? for help.
"/var/spool/mail/root": 1 message 1 new
>N  1 root                  Mon May 18 17:44  17/523   "hi"
&
# → rootの横の数字を入力してメールを閲覧可能
```

```bash
# メールの実ファイルを確認
ll /var/spool/mail/
# → rootディレクトリが作成され、その中にメールが存在すれば成功
```

---

### Step 5: メール送受信確認(他サーバ)

**目的:** 自サーバから相手サーバへメールが届くことを確認する。

#### 操作手順

```bash
# LinuxのDNS問い合わせ先を相手のDNSサーバに変更
vi /etc/systemd/resolved.conf
```

設定ファイルの編集内容:

```
# ---以下のように変更---
DNS=<相手のDNSサーバーのプライベートIP>
# ----------------------
```

```bash
# DNSルールの設定を反映させるため再起動
systemctl restart systemd-resolved.service

# mailコマンドで相手にメールが届くか確認
mail -s <件名> root@<相手の任意の名前>.local

# Step 4と同じ手順でメールが届いているか確認(相手側で実施)
```

---

### Step 6: メールアドレス(ユーザー)の作成

**目的:** メール送受信用のユーザーを作成する。

#### 操作手順

```bash
# メール用のユーザーを作成
useradd <任意のユーザー名> -g mail -M -K MAIL_DIR=/dev/null -s /sbin/nologin

# 作成したユーザーのパスワードを設定
passwd <任意のユーザー名>
```

対話形式でパスワードを設定:

```
New Password:
Retry Password:
passwd: all authentication tokens updated successfully.
```

---

### Step 7: POP3サーバ(Dovecot)の構築

**目的:** Dovecotをインストールし、POP3サーバとして動作させる。

#### 操作手順

```bash
# Dovecotのインストール
dnf install -y dovecot

# Dovecotの設定ファイルのバックアップ取得(原本保存)
cp /etc/dovecot/dovecot.conf{,.org}

# Dovecotの設定ファイルの変更と追記
vi /etc/dovecot/dovecot.conf
```

設定ファイルの編集内容:

```
# ---以下のように変更---
protocols = pop3
# ----------------------

# ---ファイル末尾に追記---
mail_location = maildir:/var/spool/mail/%u/
# ----------------------
```

```bash
# Dovecotの暗号化設定ファイルのバックアップ取得(原本保存)
cp /etc/dovecot/conf.d/10-ssl.conf{,.org}

# Dovecotの暗号化設定ファイルの変更
vi /etc/dovecot/conf.d/10-ssl.conf
```

設定ファイルの編集内容:

```
# ---以下のように変更(SSLを無効化)---
#ssl = required
# ----------------------
```

```bash
# Dovecotのユーザー認証設定ファイルのバックアップ取得(原本保存)
cp /etc/dovecot/conf.d/10-auth.conf{,.org}

# Dovecotのユーザー認証設定ファイルの変更
vi /etc/dovecot/conf.d/10-auth.conf
```

設定ファイルの編集内容:

```
# ---以下のように変更---
disable_plaintext_auth = no
# ----------------------
```

```bash
# Dovecotの起動と自動起動設定
systemctl enable --now dovecot

# Dovecotの起動確認
systemctl status dovecot | less

# Dovecotの自動起動設定確認
systemctl is-enabled dovecot

# telnetのインストール
dnf install -y telnet
```

---

## 5. 動作確認・検証

> 構築完了後、以下の確認をすべてパスしたら構築成功とみなす。

### 5-1. 確認チェックリスト

- [ ] **確認①**: 自サーバ内でメール送受信ができる
- [ ] **確認②**: 自サーバから他サーバへメールが送信できる
- [ ] **確認③**: telnetでPOP3に接続し、相手のメールを確認できる

---

### 確認①: 自サーバ内でのメール送受信

Step 4で記載した `mail -s <件名> root@<任意の名前>.local` を実行し、自サーバ内で送受信できることを確認する。

---

### 確認②: 他サーバへのメール送信

Step 5で記載した手順で、相手サーバへメールを送信し、相手側で `mail` コマンドにて受信を確認する。

---

### 確認③: telnetでPOP3経由のメール確認

```bash
# 相手のSMTPサーバへtelnetで接続
telnet <相手のSMTPサーバのプライベートIP> 110
```

接続後、対話形式でログインしメール確認:

```
user <作成したユーザー名>
+OK
pass <パスワード>
+OK Logged in.
list
+OK 1 messages;
retr 1
# → メール本文が表示される
quit
```

**期待する結果:** 相手サーバのメールスプールから、作成したユーザー宛のメールを閲覧できる。

---

## 6. トラブルシューティング

### よくあるエラーと対処法

---

#### エラー①: `named-checkconf` で構文エラーが出る

**原因:** `zone` セクションの記述ミス、セミコロン抜け

**対処法:**
- `zone "..." IN { ... };` の末尾のセミコロンを確認
- `file "/var/named/...";` のセミコロン・クォートを確認

---

#### エラー②: メールが送信できない(`status=deferred` や接続失敗)

**原因:** DNSの名前解決ができていない、または相手サーバのSMTPに到達できない

**対処法:**
```bash
# DNS問い合わせ先を確認
cat /etc/systemd/resolved.conf

# 相手サーバのMXレコードが解決できるか確認
dig mail.<相手の任意の名前>.local

# postfixのログを確認
tail -f /var/log/maillog
```

---

#### エラー③: telnetでPOP3に接続できない

**原因:** Dovecotが起動していない、またはセキュリティグループでPOP3(TCP/110)が許可されていない

**対処法:**
```bash
# Dovecotの状態確認
systemctl status dovecot

# ポート110がLISTENしているか確認
ss -tlnp | grep :110
```

セキュリティグループでPOP3が `172.31.0.0/16` から許可されていることをAWSコンソールで確認する。

---

### ログの確認場所

| ログの種類 | 場所(パス) | 確認コマンド |
|-----------|------------|------------|
| メールログ | `/var/log/maillog` | `sudo tail -f /var/log/maillog` |
| BINDログ | `journalctl -u named` | `sudo journalctl -u named -f` |
| Dovecotログ | `journalctl -u dovecot` | `sudo journalctl -u dovecot -f` |
| OSシステムログ | `/var/log/messages` | `sudo tail -f /var/log/messages` |

---

## 7. 参考リソース・関連資料

| 資料名 | URL / 場所 | 補足 |
|-------|-----------|------|
| Postfix 公式ドキュメント | https://www.postfix.org/documentation.html | Postfixの設定リファレンス |
| Dovecot 公式ドキュメント | https://doc.dovecot.org/ | Dovecotの設定リファレンス |
| BIND 公式ドキュメント (ISC) | https://www.isc.org/bind/ | BINDの設定リファレンス |

---

## 付録(任意)

### A. 環境変数・パラメータまとめ

| パラメータ名 | 自分の環境の値 | 説明 |
|------------|-------------|------|
| 自サーバ パブリックIP | `xx.xx.xx.xx` | SSH接続先 |
| 自サーバ プライベートIP | `xx.xx.xx.xx` | DNS・MXレコードに記載するIP |
| 相手サーバ プライベートIP | `xx.xx.xx.xx` | DNS問い合わせ先・メール送信先 |
| ドメイン名 | `<任意の名前>.local` | BINDで管理するゾーン名 |
| メールユーザー名 | `<任意のユーザー名>` | メール送受信用ユーザー |
| キーペア名 | `<秘密鍵の名前>` | SSH認証に使用 |

### B. 用語解説

| 用語 | 説明 |
|------|------|
| SMTP | Simple Mail Transfer Protocol。メールを送信・転送するためのプロトコル(ポート25)。 |
| POP3 | Post Office Protocol version 3。メールサーバから受信メールを取得するプロトコル(ポート110)。 |
| MXレコード | Mail eXchanger Record。あるドメイン宛のメールを受け取るメールサーバを示すDNSレコード。 |
| Mailx | コマンドラインからメールを送受信するためのユーティリティ。 |
| Rsyslog | Linuxでログを集約・管理するサービス。`/var/log/maillog` などのログを生成する。 |
| Maildir | メールを1メール1ファイル形式で保存する形式。Dovecotで `mail_location=maildir:...` を指定して使用。 |

### C. 削除・クリーンアップ手順

1. EC2インスタンスを2台とも終了する
2. セキュリティグループを削除する
3. キーペアを削除する(必要に応じて)
