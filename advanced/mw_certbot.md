# Let's Encrypt / Certbot 基本・発展課題集

> 無料 SSL/TLS 証明書の自動取得・更新ツール。現代のインフラで必須のスキル  
> 前提：AWS 無料利用枠の範囲内で実施可能な課題を基本とする  
> 作成日：2026年6月

---

## 目次

1. [基本課題 A：Certbot のインストールと証明書取得](#基本課題-acertbot-のインストールと証明書取得)
2. [基本課題 B：Web サーバーへの適用](#基本課題-bweb-サーバーへの適用)
3. [基本課題 C：自動更新の設定](#基本課題-c自動更新の設定)
4. [発展課題 D：ワイルドカード証明書の取得](#発展課題-dワイルドカード証明書の取得)
5. [発展課題 E：複数ドメインへの対応](#発展課題-e複数ドメインへの対応)
6. [発展課題 F：証明書の管理と運用](#発展課題-f証明書の管理と運用)
7. [発展課題 G：ACM との比較と使い分け](#発展課題-gacm-との比較と使い分け)

---

## 基本課題 A：Certbot のインストールと証明書取得

**A-1. Certbot のインストール**
- AL2023 の EC2 に `certbot` をインストールする（`dnf` または `pip` 経由）
- `certbot --version` でバージョンを確認する

**A-2. HTTP-01 チャレンジによる証明書取得**
- ドメイン（Route 53 で管理しているドメイン）を EC2 の Elastic IP に向け、80 番ポートへのアクセスが通る状態を確認する
- `certbot certonly --standalone -d example.com -d www.example.com` でスタンドアロンモードで証明書を取得する
- 証明書ファイルの配置場所（`/etc/letsencrypt/live/example.com/`）と各ファイルの役割を確認する

```
fullchain.pem  # サーバー証明書 + 中間証明書（Nginx / Apache で使用）
privkey.pem    # 秘密鍵
cert.pem       # サーバー証明書のみ
chain.pem      # 中間証明書のみ
```

**A-3. チャレンジ方式の理解**
- HTTP-01（80 番ポートへのアクセスが必要）・DNS-01（DNS TXT レコードが必要）・TLS-ALPN-01 の三つのチャレンジ方式の違いと使い分けをまとめる

---

## 基本課題 B：Web サーバーへの適用

**B-1. Apache への適用**
- `certbot --apache -d example.com` で Apache プラグインを使い、証明書取得と Apache 設定の自動変更を行う
- または `--standalone` で取得した証明書を Apache の `SSLCertificateFile`・`SSLCertificateKeyFile`・`SSLCertificateChainFile` に手動で設定する

**B-2. Nginx への適用**
- `certbot --nginx -d example.com` で Nginx プラグインを使い、証明書取得と Nginx 設定の自動変更を行う
- `nginx -t` で設定の文法チェックを行い、HTTPS でアクセスできることを確認する

**B-3. HTTPS 設定の強化**
- TLS 1.2 以下を無効化し、TLS 1.3 のみ許可する設定を行う
- HSTS ヘッダー・セキュリティヘッダーを追加し、`ssllabs.com` で A 評価以上を取得する

---

## 基本課題 C：自動更新の設定

**C-1. 自動更新の動作確認**
- `certbot renew --dry-run` でドライランを実行し、自動更新のシミュレーションが成功することを確認する
- AL2023 ではインストール時に `systemd timer` が自動設定されることを確認し、`systemctl status certbot-renew.timer` で動作を確認する

**C-2. cron による自動更新**
- `systemd timer` が使えない環境向けに、cron で自動更新を設定する

```bash
# /etc/cron.d/certbot-renew
0 2,14 * * * root certbot renew --quiet --deploy-hook "systemctl reload httpd"
```

**C-3. 更新後フックの設定**
- `--deploy-hook` で証明書更新後に Web サーバーを自動リロードする設定を行い、更新が無停止で適用されることを確認する

---

## 発展課題 D：ワイルドカード証明書の取得

**D-1. DNS-01 チャレンジによるワイルドカード証明書**
- Route 53 を使った DNS-01 チャレンジで `*.example.com` のワイルドカード証明書を取得する
- `certbot certonly --dns-route53 -d "*.example.com" -d "example.com"` を実行し、証明書が取得できることを確認する
- Route 53 への書き込み権限を持つ IAM ロールを EC2 にアタッチし、アクセスキーなしで認証する設定を行う

**D-2. ワイルドカード証明書の用途**
- `*.example.com` の証明書を複数のサブドメイン（`api.example.com`・`mail.example.com`・`admin.example.com`）に適用し、証明書管理の効率化を確認する

---

## 発展課題 E：複数ドメインへの対応

**E-1. SAN（Subject Alternative Name）証明書**
- 複数ドメインを 1 枚の証明書にまとめる SAN 証明書を取得する
- `certbot certonly -d example.com -d www.example.com -d api.example.com` で取得し、`openssl x509 -in cert.pem -text` で SAN の内容を確認する

---

## 発展課題 F：証明書の管理と運用

**F-1. 証明書の有効期限監視**
- 証明書の有効期限を確認するスクリプトを作成し、残り 30 日以下になった場合に SNS 経由でアラートを送る仕組みを構築する

```bash
#!/bin/bash
DOMAIN="example.com"
EXPIRY=$(echo | openssl s_client -connect ${DOMAIN}:443 2>/dev/null | \
         openssl x509 -noout -enddate | cut -d= -f2)
EXPIRY_EPOCH=$(date -d "${EXPIRY}" +%s)
NOW_EPOCH=$(date +%s)
DAYS_LEFT=$(( (EXPIRY_EPOCH - NOW_EPOCH) / 86400 ))
echo "${DOMAIN} の証明書残日数: ${DAYS_LEFT} 日"
```

**F-2. 証明書のバックアップ**
- `/etc/letsencrypt/` ディレクトリ全体を定期的に S3 にバックアップし、EC2 を再構築した場合でも証明書を復元できる手順を確立する

**F-3. 複数 EC2 での証明書共有**
- 証明書を取得する専用 EC2（または Lambda）を用意し、証明書ファイルを EFS または S3 に配置して複数の Web サーバーで共有する構成を設計する

---

## 発展課題 G：ACM との比較と使い分け

**G-1. 比較表の作成**

| 観点 | Let's Encrypt（Certbot） | AWS ACM |
|------|------------------------|---------|
| 料金 | 無料 | 無料（ALB / CloudFront 経由） |
| 有効期限 | 90 日（自動更新必須） | 13 ヶ月（自動更新） |
| ワイルドカード | 対応（DNS-01 必須） | 対応 |
| EC2 直接適用 | ○ | ✕（ALB 経由のみ） |
| ALB / CloudFront への適用 | ✕（直接設定不可） | ○ |
| 管理の手間 | 中（自動更新設定が必要） | 低（自動更新） |
| 秘密鍵の管理 | 自己管理 | AWS 管理（エクスポート不可） |

**G-2. 使い分けの基準**
- EC2 で直接 HTTPS を終端する場合 → Let's Encrypt（Certbot）
- ALB・CloudFront で HTTPS を終端する場合 → ACM
- 両方を組み合わせる場合（ALB は ACM・EC2 直接は Certbot）の構成を設計する

---

*以上（Let's Encrypt / Certbot 基本・発展課題）*
