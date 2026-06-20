# Lighttpd 基本・発展課題集

> 軽量 Web サーバー。低スペック環境・静的コンテンツ配信・組み込み用途で強みを持つ  
> Apache / Nginx との比較視点を随所に盛り込んでいます  
> 前提：AWS 無料利用枠の範囲内で実施可能な課題を基本とする  
> 作成日：2026年6月

---

## 目次

1. [基本課題 A：インストールと基本設定](#基本課題-aインストールと基本設定)
2. [基本課題 B：バーチャルホストとアクセス制御](#基本課題-bバーチャルホストとアクセス制御)
3. [基本課題 C：モジュールの有効化](#基本課題-cモジュールの有効化)
4. [発展課題 D：PHP-FPM との連携](#発展課題-dphp-fpm-との連携)
5. [発展課題 E：SSL/TLS 設定](#発展課題-essltls-設定)
6. [発展課題 F：リバースプロキシとロードバランシング](#発展課題-fリバースプロキシとロードバランシング)
7. [発展課題 G：パフォーマンスチューニング](#発展課題-gパフォーマンスチューニング)
8. [発展課題 H：監視・ログ管理](#発展課題-h監視ログ管理)
9. [発展課題 I：Apache / Nginx との比較と使い分け](#発展課題-iapache--nginx-との比較と使い分け)

---

## 基本課題 A：インストールと基本設定

**A-1. EC2 への Lighttpd インストール**
- AL2023 の EC2 に Lighttpd をインストールし、`systemd` でサービス登録・自動起動を設定する
- `lighttpd -v` でバージョンを確認し、ブラウザからデフォルトページが表示されることを確認する
- 設定ファイル（`/etc/lighttpd/lighttpd.conf`）の基本構造を Apache の `httpd.conf`・Nginx の `nginx.conf` と比較してまとめる

**A-2. 基本設定の変更**
- `server.port`・`server.document-root`・`server.errorlog`・`server.accesslog` を設定し、カスタムドキュメントルートでページが表示されることを確認する
- `lighttpd -t -f /etc/lighttpd/lighttpd.conf` で設定ファイルの文法チェックを行い、正常終了することを確認する
- `server.max-connections` と `server.max-fds` の意味と適切な設定値をまとめる

**A-3. MIME タイプと静的ファイル配信**
- `mimetype.assign` で拡張子ごとの MIME タイプを設定し、HTML・CSS・JS・画像が正しい Content-Type で返ることを `curl -I` で確認する
- ディレクトリ一覧表示（`dir-listing.activate = "enable"`）を有効化・無効化し、動作の違いを確認する

---

## 基本課題 B：バーチャルホストとアクセス制御

**B-1. 名前ベースのバーチャルホスト**
- `$HTTP["host"]` を使って 2 つのドメインを同一 IP で異なるドキュメントルートに振り分けるバーチャルホストを設定する
- Apache の `VirtualHost`・Nginx の `server` ブロックと設定量・可読性を比較してまとめる

**B-2. アクセス制御**
- `mod_access` を使って特定 IP アドレスへのアクセス許可・拒否を設定する
- `mod_auth` で Basic 認証を設定し、`htpasswd` で認証ファイルを作成する
- 特定のパス（例：`/admin`）に対してのみ Basic 認証を要求する設定を行う

---

## 基本課題 C：モジュールの有効化

**C-1. 主要モジュールの理解と有効化**
- 以下のモジュールをそれぞれ有効化し、動作を確認する

| モジュール | 役割 |
|-----------|------|
| `mod_rewrite` | URL 書き換え |
| `mod_redirect` | リダイレクト |
| `mod_compress` | gzip 圧縮 |
| `mod_expire` | ブラウザキャッシュ制御 |
| `mod_status` | サーバー統計情報 |
| `mod_fastcgi` | FastCGI（PHP-FPM）連携 |
| `mod_proxy` | リバースプロキシ |

**C-2. mod_rewrite によるリダイレクト**
- HTTP → HTTPS への強制リダイレクトを `mod_rewrite` で実装する
- WordPress のパーマリンク設定に相当する URL 書き換えルールを設定する

---

## 発展課題 D：PHP-FPM との連携

**D-1. Lighttpd + PHP-FPM 連携**
- `mod_fastcgi` を使って Lighttpd と PHP-FPM を連携させ、PHP スクリプトが実行されることを確認する
- `fastcgi.server` の設定（`socket`・`host:port`・`check-local`）を理解し、Unix ドメインソケットと TCP 接続それぞれで動作を確認する
- Apache・Nginx との PHP-FPM 連携設定を並べて比較し、設定量と可読性の違いをまとめる

**D-2. WordPress の動作確認**
- Lighttpd + PHP-FPM + MariaDB で WordPress を動作させる
- WordPress のパーマリンクを機能させるための URL 書き換えルールを設定する
- Apache + PHP-FPM 構成と Lighttpd + PHP-FPM 構成のレスポンスタイムを `ab` で比較する

---

## 発展課題 E：SSL/TLS 設定

**E-1. Let's Encrypt による HTTPS 化**
- Certbot で SSL 証明書を取得し、Lighttpd の `ssl.engine`・`ssl.pemfile` を設定して HTTPS を有効化する
- PEM ファイルは証明書・秘密鍵・中間証明書を結合したファイルが必要なことを理解し、正しく生成する
- `ssl.use-sslv2`・`ssl.use-sslv3` を無効化し、TLS 1.2 以上のみ許可する設定を行う

**E-2. HSTS と セキュリティヘッダー**
- `mod_setenv` を使って `Strict-Transport-Security`・`X-Content-Type-Options`・`X-Frame-Options` ヘッダーを設定する
- `curl -I https://<ドメイン>` で全ヘッダーが返ることを確認する

---

## 発展課題 F：リバースプロキシとロードバランシング

**F-1. mod_proxy によるリバースプロキシ**
- `mod_proxy` を使って Lighttpd をリバースプロキシとして設定し、バックエンドの Tomcat / Node.js アプリケーションにリクエストを転送する
- `proxy.server` の設定と Apache の `ProxyPass`・Nginx の `proxy_pass` を比較する

**F-2. 複数バックエンドへの振り分け**
- `proxy.balance` を設定して複数バックエンドへのロードバランシングを実装し、`ab` で振り分け動作を確認する

---

## 発展課題 G：パフォーマンスチューニング

**G-1. 同時接続数とワーカーの最適化**
- `server.max-connections`・`server.event-handler` を調整し、epoll（Linux）によるイベント駆動処理を有効化する
- `ab` で同時接続 100・リクエスト 10000 の負荷テストを実施し、Apache・Nginx と比較する

**G-2. キャッシュと圧縮**
- `mod_compress` で gzip 圧縮を有効化し、レスポンスサイズが削減されることを `curl -I` で確認する
- `mod_expire` でブラウザキャッシュの有効期限をコンテンツ種別ごとに設定する

**G-3. ベンチマーク比較**
- 同一コンテンツ・同一 EC2 スペックで Apache・Nginx・Lighttpd のスループットとレイテンシを `ab` で計測し、静的ファイル配信における三者の性能差を数値でまとめる

---

## 発展課題 H：監視・ログ管理

**H-1. mod_status による統計情報取得**
- `mod_status` を有効化し、`/server-status` でリクエスト数・接続数・稼働時間を確認する
- Zabbix のユーザーパラメーターで `mod_status` の値を定期取得し、監視に組み込む

**H-2. ログ管理**
- アクセスログのフォーマットをカスタマイズし、レスポンスタイム・リファラーを追加する
- `logrotate` でアクセスログ・エラーログを日次でローテーションする設定を行う
- CloudWatch Logs にログを転送し、5xx エラーが増加した場合のアラームを設定する

---

## 発展課題 I：Apache / Nginx との比較と使い分け

**I-1. 三者比較表の作成**

| 観点 | Apache | Nginx | Lighttpd |
|------|--------|-------|---------|
| アーキテクチャ | マルチプロセス／スレッド | イベント駆動 | イベント駆動 |
| 設定の柔軟性 | 最高（.htaccess） | 高 | 中 |
| 静的ファイル性能 | 中 | 高 | 高 |
| メモリ使用量 | 多 | 少 | 最少 |
| モジュール数 | 最多 | 多 | 少 |
| 学習コスト | 中 | 中 | 低 |
| 現場採用率 | 高 | 高 | 低（特定用途向け） |

**I-2. 用途別の選択基準**
- RAM 512MB 以下の低スペック EC2 での静的ファイル配信 → Lighttpd
- 高トラフィック・リバースプロキシ・複雑なルーティング → Nginx
- .htaccess による細かなディレクトリ単位の制御・モジュールの豊富さ → Apache

---

*以上（Lighttpd 基本・発展課題）*
