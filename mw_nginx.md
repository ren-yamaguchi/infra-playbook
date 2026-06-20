# Nginx 発展課題集

> Nginx はこれから初めて触れるミドルウェアのため、発展課題のみを掲載しています  
> Apache との比較視点を随所に盛り込み、既習知識を活かして学習できる構成にしています  
> 前提：AWS 無料利用枠の範囲内で実施可能な課題を基本とする  
> 作成日：2026年5月

---

## 目次

1. [発展課題 A：リバースプロキシと負荷分散](#発展課題-aリバースプロキシと負荷分散)
2. [発展課題 B：SSL/TLS と HTTPS 化](#発展課題-bssltls-と-https-化)
3. [発展課題 C：PHP-FPM との連携と WordPress 構築](#発展課題-cphp-fpm-との連携と-wordpress-構築)
4. [発展課題 D：Tomcat との連携](#発展課題-dtomcat-との連携)
5. [発展課題 E：パフォーマンスチューニング](#発展課題-eパフォーマンスチューニング)
6. [発展課題 F：セキュリティ強化](#発展課題-fセキュリティ強化)
7. [発展課題 G：ログ管理と監視](#発展課題-gログ管理と監視)
8. [発展課題 H：高可用性構成への発展](#発展課題-h高可用性構成への発展)

---

## 発展課題 A：リバースプロキシと負荷分散

**A-1. 基本的なリバースプロキシ設定**
- EC2 上に Nginx をインストールし、バックエンドの Tomcat（8080番ポート）へリクエストを転送するリバースプロキシを設定する
- `proxy_pass`・`proxy_set_header`（`Host`・`X-Real-IP`・`X-Forwarded-For`）の意味と役割を Apache の `mod_proxy` と比較してまとめる
- `proxy_read_timeout`・`proxy_connect_timeout` を設定し、バックエンドが応答しない場合のタイムアウト動作を確認する

**A-2. upstream による負荷分散**
- `upstream` ブロックで Tomcat 2 台（または Apache 2 台）へのラウンドロビン負荷分散を設定し、`ab` でリクエストを送って両サーバーに均等に振り分けられることを確認する
- 負荷分散アルゴリズムを `round_robin`・`least_conn`（最小コネクション数）・`ip_hash`（クライアント IP による固定）に切り替えて動作の違いを検証する
- `weight` パラメーターを設定してサーバーごとに振り分け比率を変え、スペックの異なるサーバーへの対応を体験する
- `max_fails` と `fail_timeout` を設定し、バックエンドが応答しない場合に自動で振り分けから外れることを確認する

**A-3. バーチャルホスト（server ブロック）**
- 複数の `server` ブロックで異なるドメインへのリクエストを別々のバックエンドに振り分ける設定を行う
- `default_server` の役割を確認し、いずれのバーチャルホストにも一致しないリクエストの扱いを設定する
- Apache の `VirtualHost` との設定ファイル構造の違いを比較し、`sites-available` / `sites-enabled` パターンを Nginx で再現する

**A-4. location ブロックの深掘り**
- `location` ブロックの一致優先順位（完全一致 `=`・前方一致 `^~`・正規表現 `~`・通常前方一致）を理解し、意図した順序でマッチングされることを確認する
- `/static/` 以下は Nginx が直接ファイルを返し、それ以外はバックエンドへプロキシする構成（静的ファイルの直接配信とプロキシの併用）を実装する
- `try_files` を使い、ファイルが存在する場合は直接返し、存在しない場合はバックエンドへ転送する設定を行う

---

## 発展課題 B：SSL/TLS と HTTPS 化

**B-1. Let's Encrypt による証明書取得と HTTPS 化**
- Certbot を使って Let's Encrypt の証明書を取得し、Nginx に HTTPS（443番）リスナーを追加する
- HTTP（80番）へのアクセスを HTTPS（443番）に 301 リダイレクトする設定を行う
- `ssl_protocols` で TLS 1.2 以下を無効化し、TLS 1.3 のみ許可する設定を行う

**B-2. SSL 設定の強化**
- `ssl_ciphers` で弱い暗号スイートを排除し、`ssllabs.com` で A 評価以上を取得する
- `ssl_session_cache` と `ssl_session_timeout` を設定し、SSL セッションの再利用によるハンドシェイクコストを削減する
- HSTS（`Strict-Transport-Security`）ヘッダーを追加し、`includeSubDomains` と `preload` の違いを理解した上で設定する

**B-3. Apache との SSL 設定比較**
- Apache（`mod_ssl`）と Nginx の SSL 設定ファイルを並べて比較し、設定項目の対応関係と記述量の違いをまとめる
- どちらが SSL ターミネーションとして採用されやすいか、現場での選定基準を調べてまとめる

---

## 発展課題 C：PHP-FPM との連携と WordPress 構築

**C-1. Nginx + PHP-FPM による WordPress 構築**
- Apache + PHP-FPM で構築した WordPress 環境を Nginx + PHP-FPM に移行し、設定の違いを比較する
- `fastcgi_pass`・`fastcgi_param`・`include fastcgi_params` の役割を Apache の `mod_proxy_fcgi` と比較してまとめる
- WordPress の `.htaccess` によるパーマリンク設定を Nginx の `try_files` に書き換える（Nginx は `.htaccess` を解釈しないため）

**C-2. PHP-FPM ソケット接続**
- PHP-FPM との接続を TCP（`127.0.0.1:9000`）から Unix ドメインソケット（`/run/php-fpm/www.sock`）に変更し、パフォーマンスの違いを `ab` で計測する
- ソケットファイルのパーミッション設定（`listen.owner`・`listen.group`・`listen.mode`）を正しく設定し、Nginx からのアクセスが通ることを確認する

**C-3. 3 台構成への発展**
- EC2 を Web（Nginx）・AP（PHP-FPM）・DB（MariaDB）の 3 台に分離し、Nginx がリバースプロキシとして PHP-FPM に転送する構成を構築する
- Apache + PHP-FPM の 3 台構成と比較し、設定の違い・処理の流れ・Security Group 設計の差異をまとめる

---

## 発展課題 D：Tomcat との連携

**D-1. Nginx + Tomcat によるリバースプロキシ構成**
- Nginx を Tomcat（8080番）のリバースプロキシとして設定し、80番ポートへのアクセスで Tomcat アプリケーションが表示されることを確認する
- Apache の `mod_proxy_ajp` を使った連携と、Nginx の `proxy_pass` を使った HTTP 連携の違いをまとめる（Nginx は AJP プロトコル非対応のため HTTP のみ）

**D-2. 負荷分散と冗長化**
- Nginx の `upstream` で Tomcat 2 台への負荷分散を設定し、Apache の `mod_proxy_balancer` と設定量・機能を比較する
- Tomcat の一方を停止し、Nginx が自動で振り分けから外してもう一方のみにルーティングすることを確認する

---

## 発展課題 E：パフォーマンスチューニング

**E-1. worker プロセスの最適化**
- `worker_processes auto` を設定し、CPU コア数に応じてワーカープロセス数が自動設定されることを確認する
- `worker_connections` を調整し、最大同時接続数を計算する（最大同時接続数 = worker_processes × worker_connections）
- `use epoll` を明示的に設定し、I/O イベントの処理方式を確認する

**E-2. キャッシュの設定**
- `proxy_cache` を設定し、バックエンドへの同一リクエストをキャッシュから返す構成を実装する
- キャッシュの TTL・キャッシュキー（`proxy_cache_key`）・バイパス条件（`proxy_cache_bypass`）を設定する
- `gzip` 圧縮を有効化し、テキスト系コンテンツ（HTML・CSS・JavaScript・JSON）の転送量が削減されることを `curl -I` で確認する

**E-3. keepalive の最適化**
- `keepalive_timeout` と `keepalive_requests` を設定し、HTTP Keep-Alive の動作を確認する
- `upstream` ブロックで `keepalive` を設定し、Nginx とバックエンド間の接続を再利用することでレイテンシを削減する
- `ab` で `keepalive` 有効・無効のスループット差を計測し、効果を数値で確認する

**E-4. 静的ファイルの配信最適化**
- `sendfile on`・`tcp_nopush on`・`tcp_nodelay on` を設定し、それぞれの効果と適切な組み合わせを理解する
- `open_file_cache` を設定し、ファイルディスクリプタのキャッシュで静的ファイルのアクセスを高速化する
- Apache の `mod_expires` に相当する `expires` ディレクティブでブラウザキャッシュを設定し、静的ファイルへの再リクエストを削減する

---

## 発展課題 F：セキュリティ強化

**F-1. セキュリティヘッダーの実装**
- `add_header` で以下のセキュリティヘッダーをすべて設定し、`curl -I` で全項目が返ることを確認する
  - `X-Content-Type-Options: nosniff`
  - `X-Frame-Options: DENY`
  - `X-XSS-Protection: 1; mode=block`
  - `Content-Security-Policy`
  - `Referrer-Policy: strict-origin-when-cross-origin`

**F-2. レートリミットの設定**
- `limit_req_zone` と `limit_req` を使い、同一 IP からの過剰なリクエストを制限する設定を行う
- `limit_conn_zone` と `limit_conn` で同一 IP の同時接続数を制限する
- WordPress のログインページ（`/wp-login.php`）に対して特に厳しいレートリミットを設定し、ブルートフォース攻撃を抑制する

**F-3. 不審なリクエストのブロック**
- `User-Agent` が空のリクエストや、一般的なスキャンツール（`nikto`・`sqlmap`）の User-Agent を `map` ブロックでブロックする設定を行う
- `$http_user_agent` の値に基づいて、不審なクライアントへの応答を 403 にする設定を実装する
- Nginx の `deny` ディレクティブで特定の IP レンジからのアクセスを拒否する設定と、`allow`・`deny` の評価順序を確認する

**F-4. Nginx のバージョン情報隠蔽**
- `server_tokens off` でレスポンスヘッダーとエラーページから Nginx のバージョン情報を除去する
- カスタムエラーページ（403・404・500・502・503）を設定し、デフォルトの Nginx エラーページを非表示にする

---

## 発展課題 G：ログ管理と監視

**G-1. カスタムログフォーマット**
- `log_format` でカスタムログフォーマットを定義し、以下の情報をアクセスログに追加する
  - リクエスト処理時間（`$request_time`）
  - バックエンドへの接続時間（`$upstream_response_time`）
  - キャッシュヒット状況（`$upstream_cache_status`）
- JSON 形式のログフォーマットを定義し、CloudWatch Logs Insights でパースしやすいログを出力する

**G-2. ログローテーションと転送**
- `logrotate` で Nginx のアクセスログ・エラーログを日次でローテーションし、7 日分を保持する設定を行う
- CloudWatch エージェントで Nginx のアクセスログを CloudWatch Logs に転送し、5xx エラーが一定数を超えた場合のアラームを設定する

**G-3. stub_status による監視**
- `stub_status` モジュールを有効化し、`/nginx_status` エンドポイントでアクティブコネクション数・リクエスト数・処理待ちコネクション数を取得する
- Zabbix のユーザーパラメーターで `stub_status` の値を定期取得し、Zabbix ダッシュボードで Nginx の稼働状況を可視化する
- Prometheus の `nginx-prometheus-exporter` を導入し、Grafana ダッシュボードで Nginx メトリクスを可視化する

---

## 発展課題 H：高可用性構成への発展

**H-1. ALB + Nginx の組み合わせ**
- ALB の後段に Nginx を配置し、Nginx がさらにバックエンドアプリケーションへのリバースプロキシを担う 2 段構成を構築する
- ALB と Nginx それぞれのヘルスチェック設定の役割分担を整理し、どちらがどの障害を検知するかをまとめる

**H-2. Auto Scaling との統合**
- Nginx の設定・コンテンツ一式を User Data または Ansible Playbook で自動セットアップし、Auto Scaling Group からの EC2 起動だけで Nginx が稼働する状態を実現する
- スケールアウトした Nginx インスタンスが ALB のターゲットグループに自動登録されることを確認する

**H-3. Nginx をコードで管理する**
- Nginx の全設定（`nginx.conf`・バーチャルホスト・upstream 定義）を Ansible Playbook でコード化し、EC2 を再構築してもワンコマンドで同じ構成が再現できるようにする
- Terraform で EC2・SG・EIP を定義し、Ansible と組み合わせることで「インフラ構築から Nginx 設定まで」を完全自動化するパイプラインを構築する

---

*以上（Nginx 発展課題）*
