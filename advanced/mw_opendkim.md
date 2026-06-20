# OpenDKIM 基本・発展課題集

> DKIM（DomainKeys Identified Mail）メール署名の実装。メール認証の三本柱（SPF / DKIM / DMARC）の一つ  
> 前提：AWS 無料利用枠の範囲内で実施可能な課題を基本とする  
> 作成日：2026年6月

---

## 目次

1. [基本課題 A：DKIM の概念理解](#基本課題-adkim-の概念理解)
2. [基本課題 B：インストールと鍵生成](#基本課題-bインストールと鍵生成)
3. [基本課題 C：Postfix との連携](#基本課題-cpostfix-との連携)
4. [発展課題 D：DMARC との組み合わせ](#発展課題-ddmarc-との組み合わせ)
5. [発展課題 E：鍵のローテーション](#発展課題-e鍵のローテーション)
6. [発展課題 F：マルチドメイン対応](#発展課題-fマルチドメイン対応)
7. [発展課題 G：監視と運用](#発展課題-g監視と運用)

---

## 基本課題 A：DKIM の概念理解

**A-1. メール認証三本柱の整理**
- SPF・DKIM・DMARC の役割と相互関係を以下の観点で整理する

| 技術 | 検証対象 | DNS レコード | 保護対象 |
|------|---------|------------|---------|
| SPF | 送信サーバーの IP | TXT（`v=spf1 ...`） | MAIL FROM のドメイン |
| DKIM | メール本文・ヘッダーの署名 | TXT（`v=DKIM1 ...`） | From ヘッダーのドメイン |
| DMARC | SPF・DKIM の整合性 | TXT（`v=DMARC1 ...`） | From ヘッダーのドメイン |

**A-2. DKIM の署名と検証の流れ**
- 送信側（署名）：Postfix + OpenDKIM が秘密鍵でメールに署名 → `DKIM-Signature` ヘッダーを付与
- DNS：公開鍵を TXT レコードに公開（例：`default._domainkey.example.com`）
- 受信側（検証）：受信 MTA が DNS から公開鍵を取得し、署名を検証
- 上記の流れを図で整理し、なりすましメールが防げる仕組みを説明できるようにする

---

## 基本課題 B：インストールと鍵生成

**B-1. OpenDKIM のインストール**
- AL2023 の EC2 に `opendkim` と `opendkim-tools` をインストールし、`systemd` でサービス登録・自動起動を設定する

**B-2. 署名鍵の生成**
- `opendkim-genkey` で RSA 2048bit の鍵ペアを生成する

```bash
mkdir -p /etc/opendkim/keys/example.com
cd /etc/opendkim/keys/example.com
opendkim-genkey -s default -d example.com -b 2048
# default.private（秘密鍵）と default.txt（DNS に登録する公開鍵）が生成される
chown opendkim:opendkim default.private
chmod 600 default.private
```

**B-3. DNS への公開鍵登録**
- `default.txt` の内容を BIND のゾーンファイルに TXT レコードとして追加する
- `dig TXT default._domainkey.example.com` で公開鍵が正しく取得できることを確認する

---

## 基本課題 C：Postfix との連携

**C-1. OpenDKIM の設定**
- `/etc/opendkim.conf` を設定する

```
Mode            sv
Canonicalization relaxed/simple
Domain          example.com
Selector        default
KeyFile         /etc/opendkim/keys/example.com/default.private
Socket          inet:8891@localhost
```

**C-2. Postfix の設定**
- `main.cf` に OpenDKIM をミルターとして登録する

```
milter_default_action = accept
milter_protocol = 6
smtpd_milters = inet:localhost:8891
non_smtpd_milters = inet:localhost:8891
```

**C-3. 送信テストと署名確認**
- テストメールを送信し、受信側のメールヘッダーに `DKIM-Signature` が付与されていることを確認する
- `opendkim-testkey -d example.com -s default -vvv` で鍵の整合性を確認する
- Gmail など外部メールサービスで受信し、「署名済み」と表示されることを確認する

---

## 発展課題 D：DMARC との組み合わせ

**D-1. DMARC レコードの追加**
- BIND のゾーンファイルに DMARC TXT レコードを追加する

```
_dmarc.example.com. IN TXT "v=DMARC1; p=quarantine; rua=mailto:dmarc-reports@example.com; pct=100"
```

- `p=none`（監視のみ）→ `p=quarantine`（隔離）→ `p=reject`（拒否）の段階的な移行手順をまとめる

**D-2. DMARC レポートの受信と分析**
- DMARC 集計レポート（XML 形式）を `rua` 宛に受信し、`parsedmarc` または `dmarcts-report-viewer` で可視化する
- SPF・DKIM の認証結果が DMARC レポートにどのように記録されるかを確認する

---

## 発展課題 E：鍵のローテーション

**E-1. ローテーション手順の確立**
- 新しいセレクター名（例：`2026june`）で新しい鍵ペアを生成し、DNS に新しい公開鍵を追加する
- DNS の TTL 分待機後（キャッシュ更新を待つ）、OpenDKIM の署名に使うセレクターを新しいものに切り替える
- 古いセレクターの DNS レコードを削除するまでの待機期間（受信側のメール再配送期間）を設定する

---

## 発展課題 F：マルチドメイン対応

**F-1. 複数ドメインの署名**
- `KeyTable` と `SigningTable` を使い、複数ドメインの送信メールにそれぞれ対応する鍵で署名する設定を行う

```
# /etc/opendkim/KeyTable
default._domainkey.example.com example.com:default:/etc/opendkim/keys/example.com/default.private
default._domainkey.example.net example.net:default:/etc/opendkim/keys/example.net/default.private

# /etc/opendkim/SigningTable
*@example.com default._domainkey.example.com
*@example.net default._domainkey.example.net
```

---

## 発展課題 G：監視と運用

**G-1. 署名失敗のログ監視**
- `/var/log/maillog` の OpenDKIM エラーログ（`signing failed`・`key retrieval failed`）を監視し、署名失敗が発生した場合にアラートを送る設定を行う
- Zabbix のログ監視機能で `opendkim` のエラーキーワードを検知するトリガーを設定する

**G-2. 外部検証ツールによる確認**
- `mail-tester.com` や `mxtoolbox.com` を使い、SPF・DKIM・DMARC の設定が正しく機能しているかを定期的に確認する手順を確立する

---

*以上（OpenDKIM 基本・発展課題）*
