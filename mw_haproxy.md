# HAProxy 基本・発展課題集

> 前提：AWS 無料利用枠の範囲内で実施可能な課題を基本とする  
> ALB・Nginx との比較視点を随所に盛り込み、使い分けの判断力を養う構成にしています  
> 作成日：2026年5月

---

## 目次

1. [基本課題 A：インストールと基本設定](#基本課題-aインストールと基本設定)
2. [基本課題 B：負荷分散の設定](#基本課題-b負荷分散の設定)
3. [基本課題 C：ヘルスチェックの設定](#基本課題-cヘルスチェックの設定)
4. [発展課題 D：ACL による高度なルーティング](#発展課題-dacl-による高度なルーティング)
5. [発展課題 E：SSL/TLS ターミネーション](#発展課題-essltls-ターミネーション)
6. [発展課題 F：スティッキーセッション](#発展課題-fスティッキーセッション)
7. [発展課題 G：統計ページと監視](#発展課題-g統計ページと監視)
8. [発展課題 H：高可用性構成](#発展課題-h高可用性構成)
9. [発展課題 I：ALB / Nginx との比較と使い分け](#発展課題-ialb--nginx-との比較と使い分け)

---

## 基本課題 A：インストールと基本設定

**A-1. EC2 への HAProxy インストール**
- AL2023 の EC2 に HAProxy をインストールし、`systemd` でサービスとして登録・自動起動を設定する
- `haproxy -v` でバージョンを確認し、`haproxy -f /etc/haproxy/haproxy.cfg -c` で設定ファイルの文法チェックを行う
- `haproxy.cfg` の基本構成（`global`・`defaults`・`frontend`・`backend`）の役割をそれぞれ説明できるようにまとめる

**A-2. 設定ファイルの基本構造の理解**
- `global` セクションで `log`・`maxconn`・`user`・`group` を設定する
- `defaults` セクションで `mode`・`timeout connect`・`timeout client`・`timeout server` を設定し、各タイムアウトの意味を理解する
- `mode http`（レイヤー 7）と `mode tcp`（レイヤー 4）の違いを理解し、用途別の選択基準をまとめる

```haproxy
global
    log         /dev/log local0
    maxconn     50000
    user        haproxy
    group       haproxy

defaults
    mode        http
    log         global
    timeout connect 5s
    timeout client  30s
    timeout server  30s
    option      httplog
    option      dontlognull
```

---

## 基本課題 B：負荷分散の設定

**B-1. ラウンドロビン負荷分散**
- 2 台のバックエンド EC2（Apache または Nginx）に対してラウンドロビンで振り分ける基本構成を設定する
- `curl http://<HAProxy IP>/` を繰り返し実行し、レスポンスが 2 台に交互に振り分けられることを確認する

```haproxy
frontend http_front
    bind *:80
    default_backend http_back

backend http_back
    balance roundrobin
    server web1 10.0.1.10:80 check
    server web2 10.0.1.11:80 check
```

**B-2. 負荷分散アルゴリズムの比較**
- 以下のアルゴリズムをそれぞれ設定し、`ab` で負荷をかけて振り分けの挙動を確認する

| アルゴリズム | 設定値 | 特性 |
|------------|--------|------|
| ラウンドロビン | `roundrobin` | 均等に順番に振り分け |
| 最小コネクション | `leastconn` | 接続数が最も少ないサーバーに振り分け |
| 送信元 IP ハッシュ | `source` | 同じ IP は常に同じサーバーへ |
| URI ハッシュ | `uri` | 同じ URI は常に同じサーバーへ |
| ランダム | `random` | ランダムに振り分け |

**B-3. weight によるサーバーの重み付け**
- `weight` パラメーターでサーバーごとの振り分け比率を設定し（例：web1 weight 3、web2 weight 1）、4 回に 3 回は web1 に振り分けられることを確認する
- スペックの異なるサーバーへの対応として `weight` を使う判断基準をまとめる

---

## 基本課題 C：ヘルスチェックの設定

**C-1. TCP ヘルスチェック**
- `check` オプションでバックエンドサーバーのポート疎通確認を行うヘルスチェックを設定する
- チェック間隔（`inter`）・失敗閾値（`fall`）・復旧閾値（`rise`）を設定し、バックエンドを停止してから振り分けが外れるまでの時間を計測する

**C-2. HTTP ヘルスチェック**
- `option httpchk GET /health` でヘルスチェック用エンドポイントへの HTTP リクエストを使ったチェックを設定する
- バックエンドに `/health` エンドポイント（200 OK を返す）を実装し、HAProxy がステータスコードに基づいて振り分けを制御することを確認する
- `http-check expect status 200` でヘルスチェックの成功条件を明示的に設定する

**C-3. ダウン時の動作確認**
- バックエンドを 1 台停止し、HAProxy が自動で振り分けを外して残りのサーバーのみに振り分けることを確認する
- バックエンドを全台停止した場合のユーザーへのレスポンス（503）を確認し、カスタムエラーページを設定する

---

## 発展課題 D：ACL による高度なルーティング

**D-1. パスベースルーティング**
- ACL（Access Control List）を使い、URL パスに基づいて異なるバックエンドに振り分ける設定を行う

```haproxy
frontend http_front
    bind *:80
    acl is_api  path_beg /api/
    acl is_static path_beg /static/
    use_backend api_back    if is_api
    use_backend static_back if is_static
    default_backend web_back

backend api_back
    server api1 10.0.1.20:8080 check

backend static_back
    server static1 10.0.1.30:80 check

backend web_back
    balance roundrobin
    server web1 10.0.1.10:80 check
    server web2 10.0.1.11:80 check
```

**D-2. ホストベースルーティング**
- `hdr(host)` ACL でリクエストの `Host` ヘッダーに基づいて振り分けを制御する設定を行う
- `api.example.com` は API サーバー群へ、`www.example.com` は Web サーバー群へ振り分ける設定を実装する

**D-3. ヘッダーと Cookie による振り分け**
- 特定の HTTP ヘッダー（`X-Request-Type: mobile`）があるリクエストをモバイル用バックエンドに振り分けるACL を設定する
- `hdr_beg(user-agent) -i Mobile` でモバイルブラウザからのリクエストを自動判別して振り分ける設定を行う

**D-4. レートリミットとブロック**
- `stick-table` を使い、同一 IP から 1 分間に 100 件以上のリクエストがある場合に接続を拒否するレートリミットを実装する
- 特定の IP アドレスや User-Agent からのアクセスを ACL でブロックする設定を行う

---

## 発展課題 E：SSL/TLS ターミネーション

**E-1. HTTPS リスナーの設定**
- Let's Encrypt で取得した証明書（または自己署名証明書）を HAProxy に設定し、443 番ポートで HTTPS リクエストを受け付ける
- バックエンドへの通信は HTTP のまま（SSL オフロード）とし、HAProxy が SSL ターミネーションを担う構成を実装する

```haproxy
frontend https_front
    bind *:443 ssl crt /etc/haproxy/certs/example.pem
    http-request set-header X-Forwarded-Proto https
    default_backend http_back
```

**E-2. HTTP から HTTPS へのリダイレクト**
- 80 番ポートへのリクエストを 443 番にリダイレクトする設定を行う
- `redirect scheme https code 301` でリダイレクトを実装し、ブラウザとの動作を確認する

**E-3. TLS バージョンと暗号スイートの制限**
- `ssl-default-bind-options` で TLS 1.2 以下を無効化し、TLS 1.3 のみ許可する設定を行う
- `ssl-default-bind-ciphers` で弱い暗号スイートを排除し、セキュアな構成を実現する

---

## 発展課題 F：スティッキーセッション

**F-1. Cookie ベースのスティッキーセッション**
- `cookie SERVERID insert indirect nocache` で HAProxy が Cookie を付与し、同一クライアントが常に同じバックエンドに振り分けられる設定を行う
- `curl -v` でレスポンスヘッダーに `Set-Cookie: SERVERID=web1` が含まれることを確認し、以降のリクエストで同じサーバーに振り分けられることを確認する

**F-2. Cookie とヘルスチェックの組み合わせ**
- スティッキーセッションが有効な状態でバックエンドを停止し、対象サーバーへの Cookie を持つリクエストが自動的に別のバックエンドに振り分けられることを確認する
- ALB のスティッキーセッション（Duration-Based Stickiness）と HAProxy の Cookie ベーススティッキーの実装の違いをまとめる

---

## 発展課題 G：統計ページと監視

**G-1. 統計ページの有効化**
- `stats uri /haproxy?stats` で統計ページを有効化し、ブラウザからアクセスする
- 統計ページで確認できる情報（各サーバーの接続数・レスポンスタイム・エラー率・ステータス）をリアルタイムで確認する

```haproxy
listen stats
    bind *:8404
    stats enable
    stats uri /stats
    stats refresh 10s
    stats auth admin:password
    stats show-legends
    stats show-node
```

**G-2. ソケット経由の管理コマンド**
- `stats socket /var/run/haproxy.sock mode 660 level admin` でソケットを有効化する
- `echo "show info" | socat stdio /var/run/haproxy.sock` でソケット経由の管理コマンドを実行する
- ソケットコマンドで特定のサーバーをメンテナンスモード（`MAINT`）に設定し、振り分けから外す手順を確立する

**G-3. Zabbix / Prometheus による監視**
- Zabbix のユーザーパラメーターでソケットから HAProxy のメトリクスを取得し、以下を監視する
  - アクティブセッション数
  - バックエンドサーバーのステータス（UP/DOWN）
  - リクエストエラー率
- `haproxy-exporter`（Prometheus 用）を導入し、Grafana で HAProxy のダッシュボードを構築する

**G-4. ログの分析**
- `option httplog` で HTTP ログを有効化し、syslog に転送する
- HAProxy のログフォーマットを解析し、リクエスト処理時間・バックエンドへの接続時間・ステータスコードを抽出するスクリプトを作成する
- CloudWatch Logs に HAProxy のログを転送し、5xx エラーの急増を検知するアラームを設定する

---

## 発展課題 H：高可用性構成

**H-1. Keepalived による HA 構成**
- 2 台の EC2 に HAProxy + Keepalived を導入し、仮想 IP（VIP）を用いた Active/Standby 構成を構築する
- Active の HAProxy を停止し、VIP が Standby に自動で引き継がれることを確認する
- Keepalived の `vrrp_script` で HAProxy プロセスを監視し、プロセス停止時に自動でフェイルオーバーする設定を行う

**H-2. HAProxy の設定変更とゼロダウンタイムリロード**
- `systemctl reload haproxy` でゼロダウンタイムで設定をリロードし、既存の接続を切断せずに設定変更を反映する
- リロード前後で `ab` のリクエストが途切れないことを確認する

**H-3. ALB との役割分担**
- AWS 環境での推奨構成として、ALB（外部公開・ヘルスチェック）+ HAProxy（内部の細かなルーティング制御）の 2 段構成を設計し、それぞれの役割と責任範囲をまとめる

---

## 発展課題 I：ALB / Nginx との比較と使い分け

**I-1. 比較表の作成**
- 以下の観点で ALB・Nginx・HAProxy の比較表を作成する

| 観点 | ALB | Nginx | HAProxy |
|------|-----|-------|---------|
| 動作レイヤー | L7 | L7（L4 も可） | L4 / L7 |
| 管理コスト | 低（マネージド） | 中 | 中 |
| 細かなルーティング制御 | 中 | 高 | 最高 |
| SSL ターミネーション | ◎（ACM 連携） | ○ | ○ |
| スティッキーセッション | ○ | △（ip_hash） | ◎（Cookie） |
| ヘルスチェックの柔軟性 | 中 | 低 | 高 |
| 統計・監視機能 | CloudWatch | stub_status | 統計ページ |
| コスト | 従量課金 | 無料（自己管理） | 無料（自己管理） |

**I-2. 用途別の選択基準をまとめる**
- 以下のシナリオでどのロードバランサーを選択すべきか、理由とともに整理する
  - AWS マネージドサービスを優先したい場合
  - 複雑な URL ルーティングと細かなアクセス制御が必要な場合
  - レイヤー 4（TCP）の負荷分散が必要な場合（メールサーバー・データベース前段など）
  - オンプレミスと AWS のハイブリッド環境で統一したい場合

---

*以上（HAProxy 基本・発展課題）*
