# Nginxを用いたリバースプロキシ構築

------------------------------

## 1. ドキュメント情報

| 項目 | 内容 |
|------|------|
| 手順書名 | Nginxを用いたリバースプロキシ構築 |
| 作成日 | 2026-06-18 |
| 最終更新日 | 2026-06-18 |
| バージョン | v1.0 |
| 対象環境 | AWS（Amazon Linux 2023） |

> **改訂履歴**
>
> | バージョン | 日付 | 変更内容 |
> |-----------|------|---------|
> | v1.0 | 2026-06-18 | 初版作成（テンプレートに沿って再構成．Amazon Corretto導入手順を削除．ModSecurity関連を別手順書`modsecurity-migration.md`に分離．ハードコード値をプレースホルダー化．構成図・チェックリスト・付録を追加．句読点を「，．」に統一．サーバー表記を「サーバー」に統一．【実施対象】明示．`dnf install`引数順統一．） |
> | v1.1 | 2026-06-19 | 整合性チェックにより8章ロールバック手順を追加（他手順書と章構成を統一）． |

------------------------------

## 2. 目的・概要

### 2-1. 目的

> 本手順書では，AWSのEC2インスタンス上に「Nginx」をインストールし，バックエンドのAPサーバー（Tomcat等）へリクエストを転送するリバースプロキシ環境の構築手順について説明する．
> 構築後はブラウザで「`http://<WebサーバーのパブリックIP>/`」にアクセスし，APサーバー上のアプリケーションが表示される状態を目指す．

### 2-2. 構成概要（アーキテクチャ）

```
[ローカルPC（ブラウザ）]
       |
       | HTTP（80）
       v
┌────────────────────────── VPC ──────────────────────────┐
│                                                          │
│  [EC2: Webサーバー]                                       │
│    └─ Nginx（80番ポート）                                 │
│         ├─ /healthcheck → 200 OK（ヘルスチェック用）       │
│         └─ /  → upstream knowledge_cluster へプロキシ転送  │
│                                |                         │
│                                | HTTP（8080）             │
│                                v                         │
│  [EC2: APサーバー]                                        │
│    └─ Tomcat / アプリケーション（8080番ポート）            │
│                                                          │
└──────────────────────────────────────────────────────────┘
```

### 2-3. 完成イメージ（ゴール定義）

- [ ] WebサーバーにNginxがインストールされ，自動起動が有効である
- [ ] `nginx -t` が成功する
- [ ] ブラウザで「`http://<WebサーバーのパブリックIP>/healthcheck`」にアクセスし「`healthcheck`」が表示される
- [ ] ブラウザで「`http://<WebサーバーのパブリックIP>/`」にアクセスし，APサーバー上のアプリケーションが表示される
- [ ] Webサーバーで `ss -tlnp | grep :80` を実行し，Nginxが80番ポートをLISTENしている

------------------------------

## 3. 前提条件・準備

### 3-1. 環境要件

| 項目 | 要件 |
|------|------|
| OS | Amazon Linux 2023 |
| Webサーバー | Nginx 1.30.0 以降 |
| APサーバー | Tomcat（8080番ポート稼働）※別手順書で構築済みであること |
| CPU | 1コア以上 |
| メモリ | 1GB以上 |
| ストレージ | 8GB以上 |

### 3-2. セキュリティグループ設定

#### 3-2-1. Webサーバーのインバウンドルール

| タイプ | プロトコル | ポート範囲 | ソース | 説明 |
|-------|------------|----------|--------|------|
| SSH | TCP | 22 | マイIP | ローカルPCからSSHで接続 |
| HTTP | TCP | 80 | マイIP | ローカルPCのブラウザから接続 |

#### 3-2-2. APサーバーのインバウンドルール（参考）

| タイプ | プロトコル | ポート範囲 | ソース | 説明 |
|-------|------------|----------|--------|------|
| カスタムTCP | TCP | 8080 | WebサーバーのプライベートIP | Webサーバーからのプロキシ転送許可 |

### 3-3. パラメータ定義表

> **注意：** 以下の値は作業前に環境に合わせて記入してから作業を開始すること．

| パラメータ名 | 値 | 説明 |
|------------|---|------|
| `<APサーバーのFQDN>` | `<記入する>` | プロキシ転送先のAPサーバーのFQDN（例：`<任意の名前>-ap.wp.local`） |
| `<APサーバーのプライベートIP>` | `<記入する>` | APサーバーのプライベートIP（FQDNが使えない場合の代替） |
| `<WebサーバーのパブリックIP>` | `<記入する>` | ローカルPCからのアクセス先 |

### 3-4. 事前準備物

- WebサーバーにSSH接続できるキーペア（`.pem` ファイル）
- APサーバーが起動済みで，8080番ポートでアプリケーションが稼働していること
- WebサーバーからAPサーバーへの名前解決が可能であること（または `/etc/hosts` 設定済み）

------------------------------

## 4. 構築手順（詳細）

> **注意事項**
> - コマンド中の `<山カッコ>` は自分の環境の値に置き換えること
> - 各Stepの見出し末尾に **【実施対象：●●サーバー】** を明示しているので，対象のサーバーで実施すること
> - 本手順書の作業対象はすべて **Webサーバー** である

------------------------------

### Step 1：事前確認【実施対象：Webサーバー】

**目的：** APサーバーへの疎通およびrootユーザー権限を確認する

#### 操作手順

WebサーバーにSSH接続後，以下を実行する．

```bash
# rootユーザーにスイッチ
sudo su -

# パッケージを最新化
dnf update -y

# APサーバーの名前解決確認
getent hosts <APサーバーのFQDN>
# → IPアドレスが表示されれば成功

# APサーバーの8080番ポートへの疎通確認
curl -I http://<APサーバーのFQDN>:8080
# → HTTP/1.1 200 など，APサーバーアプリケーションのレスポンスが返れば成功
```

> **注意：** `Connection refused` や `timeout` が出る場合は，APサーバー側のサービス状態，セキュリティグループ，NACL，DNS設定を確認すること．

------------------------------

### Step 2：Nginxインストール【実施対象：Webサーバー】

**目的：** dnfからNginxをインストールし，起動・自動起動を有効にする

#### 操作手順

```bash
# Nginxをインストール
dnf install -y nginx

# バージョン確認（出力例：nginx version: nginx/1.x.x）
nginx -v

# Nginxを起動し，自動起動を有効化
systemctl enable --now nginx.service

# 起動確認（active (running) であること）
systemctl status nginx.service --no-pager

# 自動起動確認（enabled であること）
systemctl is-enabled nginx.service
```

> **テスト：** ブラウザで「`http://<WebサーバーのパブリックIP>/`」にアクセスし，Nginxの「Welcome to nginx!」ページが表示されれば成功．

------------------------------

### Step 3：プロキシ設定ファイルの作成【実施対象：Webサーバー】

**目的：** APサーバーへリクエストを転送するため，Nginxのプロキシ設定ファイルを新規作成する

#### 操作手順

```bash
# プロキシ設定ファイルを新規作成
vi /etc/nginx/conf.d/proxy.conf
```

設定ファイルの記述内容：

```nginx
upstream knowledge_cluster {
    ip_hash;
    server <APサーバーのFQDN>:8080;
}

server {
    listen       80;
    server_name  _;

    location = /healthcheck {
        access_log off;
        return 200 "healthcheck\n";
    }

    location / {
        proxy_pass http://knowledge_cluster;

        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }
}
```

> **補足：** 各設定の意味は付録Bを参照．`/healthcheck` はALBや監視ツールからの正常性確認用エンドポイント．

------------------------------

### Step 4：Nginxメイン設定ファイルの編集【実施対象：Webサーバー】

**目的：** デフォルトのserverブロックをコメントアウトし，`conf.d/proxy.conf`側のserverブロックと重複しないようにする

#### 操作手順

```bash
# バックアップ作成
cp -p /etc/nginx/nginx.conf /etc/nginx/nginx.conf.org

# メイン設定ファイルを編集
vi /etc/nginx/nginx.conf
```

設定ファイルの編集内容（`http { ... }` ブロック内のデフォルト `server { ... }` 全体をコメントアウト）：

```nginx
# デフォルトのserverブロックはproxy.conf側で設定するためコメントアウト
#    server {
#       listen       80;
#       listen       [::]:80;
#       server_name  _;
#       root         /usr/share/nginx/html;
#
#       include /etc/nginx/default.d/*.conf;
#
#       error_page 404 /404.html;
#       location = /404.html {
#       }
#
#       error_page 500 502 503 504 /50x.html;
#       location = /50x.html {
#       }
#    }
```

> **理由：** `server_name _;` のserverブロックがメイン設定と `proxy.conf` の両方にあると，`conflicting server name "_" on 0.0.0.0:80, ignored` の警告が出てどちらかが無視される．`conf.d/*.conf` 側のserverブロックに一本化する．

> **補足：** `include /etc/nginx/conf.d/*.conf;` の行はデフォルトで記述されているため，編集不要．

------------------------------

### Step 5：構文チェックと反映【実施対象：Webサーバー】

**目的：** Nginx設定の文法エラーを確認し，設定を反映する

#### 操作手順

```bash
# 構文チェック
nginx -t
# → nginx: configuration file /etc/nginx/nginx.conf test is successful が出れば成功

# 設定を反映（無停止リロード）
systemctl reload nginx.service

# 状態確認
systemctl status nginx.service --no-pager
```

> **注意：** `nginx -t` が失敗した場合は，**設定を反映しないこと**．エラーメッセージのファイル名と行番号を確認して修正すること．

------------------------------

## 5. 動作確認・検証

> 構築完了後，以下の確認をすべてパスしたら構築成功とみなす．

### 5-1. 確認チェックリスト

- [ ] **確認①**：Nginxサービスが起動し，自動起動が有効になっている
- [ ] **確認②**：80番ポートでLISTENしている
- [ ] **確認③**：`nginx -t` が成功する
- [ ] **確認④**：`/healthcheck` が正常応答する
- [ ] **確認⑤**：`/` でAPサーバーへプロキシ転送される
- [ ] **確認⑥**：エラーログに異常がない

------------------------------

### 確認①：サービス状態確認

```bash
systemctl status nginx.service --no-pager
systemctl is-enabled nginx.service
```

**期待する結果：** `active (running)` および `enabled` が表示される．

------------------------------

### 確認②：リッスンポート確認

```bash
ss -tlnp | grep :80
```

**期待する結果：** `0.0.0.0:80` でnginxプロセスがLISTENしている．

------------------------------

### 確認③：構文チェック

```bash
nginx -t
```

**期待する結果：** `syntax is ok` および `test is successful` が表示される．

------------------------------

### 確認④：ヘルスチェック応答確認

```bash
curl http://localhost/healthcheck
```

**期待する結果：** `healthcheck` の文字列が返ってくる．

------------------------------

### 確認⑤：プロキシ転送確認

```bash
curl -I http://localhost/
```

**期待する結果：** APサーバー側アプリケーションのHTTPレスポンス（`HTTP/1.1 200` 等）が返る．

または，ブラウザで「`http://<WebサーバーのパブリックIP>/`」にアクセスし，APサーバー上のアプリケーション画面が表示されること．

------------------------------

### 確認⑥：ログ確認

```bash
# エラーログ確認（直近100行）
tail -n 100 /var/log/nginx/error.log

# アクセスログ確認
tail -n 100 /var/log/nginx/access.log
```

> **注意：** `emerg`，`crit`，`error` レベルのログが出ていないことを目視確認する．

------------------------------

## 6. トラブルシューティング

### よくあるエラーと対処法

------------------------------

#### エラー①：`nginx: [warn] conflicting server name "_" on 0.0.0.0:80, ignored`

**原因：** `server_name _;` を持つserverブロックが `nginx.conf` と `conf.d/proxy.conf` の両方に存在している．

**対処法：**

1. 該当箇所を検索する．

   ```bash
   grep -Rn "server_name" /etc/nginx
   ```

2. Step 4で `nginx.conf` のデフォルトserverブロックがコメントアウトされているか確認する．
3. コメントアウトされていなければ修正し，`nginx -t` → `systemctl reload nginx` を実行する．

> **補足：** 警告だけでNginx自体は起動する場合があるが，意図しないserverブロックが無視される可能性があるため修正する．

------------------------------

#### エラー②：`nginx -t` が失敗する

**原因：** Nginx設定ファイルの文法ミス．

**対処法：**

1. `nginx -t` の出力に表示されたファイル名と行番号を確認して修正する．
2. `nginx -t` が成功するまでは，`systemctl reload nginx` を実行しない．

------------------------------

#### エラー③：`502 Bad Gateway`

**原因：** NginxからAPサーバーへ接続できていない．

**対処法：**

1. APサーバーの名前解決を確認する．

   ```bash
   getent hosts <APサーバーのFQDN>
   ```

2. APサーバーの8080番ポートへの疎通を確認する．

   ```bash
   curl -I http://<APサーバーのFQDN>:8080
   ```

3. Nginxのエラーログを確認する．

   ```bash
   tail -n 50 /var/log/nginx/error.log
   ```

> **補足：** APサーバー停止，8080番ポート未起動，セキュリティグループ未許可，DNS設定ミスが主な原因．

------------------------------

#### エラー④：ブラウザで「Welcome to nginx!」が表示されたままになる

**原因：** `nginx.conf` のデフォルトserverブロックがコメントアウトされておらず，`proxy.conf` のserverブロックが無視されている．

**対処法：** Step 4を再実施し，デフォルトserverブロックをコメントアウトする．

------------------------------

#### エラー⑤：SSH接続がタイムアウトする

**原因：** セキュリティグループでSSH（ポート22）が許可されていない．

**対処法：** Webサーバー用SGのインバウンドルールでSSH（TCP/22）を自分のIPから許可する．

------------------------------

### ログの確認場所

| ログの種類 | 場所（パス） |
|-----------|------------|
| Nginx アクセスログ | `/var/log/nginx/access.log` |
| Nginx エラーログ | `/var/log/nginx/error.log` |
| systemd ログ | `journalctl -u nginx.service` |

------------------------------

## 7. 参考リソース・関連資料

| 資料名 | URL / 場所 | 補足 |
|-------|-----------|------|
| Nginx 公式ドキュメント | https://nginx.org/en/docs/ | リバースプロキシ設定の参考 |
| Amazon Linux 2023 ユーザーガイド | https://docs.aws.amazon.com/ja_jp/linux/al2023/ug/ | AL2023全般 |
| 別手順書：ModSecurity移行手順 | `modsecurity-migration.md` | 本手順書完了後にWAFを追加する場合に参照 |
| 別手順書：Tomcat構築手順 | `tomcat-basic.md` | APサーバー側の構築手順 |

------------------------------

## 8. ロールバック手順

### 8-1. Nginxサービスの停止と無効化【実施対象：Webサーバー】

```bash
systemctl disable --now nginx.service
```

### 8-2. リバースプロキシ設定ファイルの削除【実施対象：Webサーバー】

```bash
# 本手順書で作成した設定ファイルの存在確認
ls /etc/nginx/conf.d/reverse-proxy.conf 2>/dev/null

# 存在する場合のみ削除
rm -f /etc/nginx/conf.d/reverse-proxy.conf
```

### 8-3. nginx.confの復元【実施対象：Webサーバー】

```bash
# バックアップ存在確認
ls /etc/nginx/nginx.conf.org 2>/dev/null

# 存在する場合のみ復元
cp -f /etc/nginx/nginx.conf.org /etc/nginx/nginx.conf

# 構文チェック
nginx -t
```

### 8-4. Nginxパッケージのアンインストール【実施対象：Webサーバー】

```bash
# 存在確認
rpm -q nginx

# インストールされている場合
dnf remove -y nginx
```

### 8-5. 残存ディレクトリの確認（任意で削除）【実施対象：Webサーバー】

```bash
ls -ld /etc/nginx /var/log/nginx 2>/dev/null
```

完全に消す場合のみ（他システムへの影響がないことを確認後）：

```bash
rm -rf /etc/nginx /var/log/nginx
```

### 8-6. systemd-resolvedのDNS設定削除（同居サーバーの場合）【実施対象：Webサーバー】

> **注意：** 本手順書で `system-setup` を実施し，他サーバーと同居していない場合のみ実施．他のサービス（Tomcat等）と同居している場合はスキップ．

```bash
ls /etc/systemd/resolved.conf.d/wp-local.conf 2>/dev/null && rm -f /etc/systemd/resolved.conf.d/wp-local.conf
systemctl restart systemd-resolved
```

### 8-7. ホスト名・タイムゾーンの復元（任意）【実施対象：Webサーバー】

```bash
hostnamectl set-hostname <元のホスト名>
timedatectl set-timezone <元のタイムゾーン>
```

### 8-8. 完了確認【実施対象：Webサーバー】

```bash
systemctl status nginx.service 2>&1 | head -3
```

> **期待する結果：** `Unit nginx.service could not be found.`（パッケージ削除済みの場合）

> **注意：**
> - `dnf update` で適用したパッケージ更新は取り消さない（依存破壊リスク回避）．
> - ホスト名を変更した場合はSSHを一度切断して再ログインすること．

------------------------------

## 付録

### A. コマンド解説

| コマンド | 説明 |
|---------|------|
| `dnf install -y nginx` | Nginxをdnfからインストール．`-y`オプションで対話プロンプトをスキップ． |
| `nginx -v` | インストール済みNginxのバージョンを表示． |
| `nginx -t` | Nginx設定ファイルの構文をチェック．エラー時はファイル名と行番号を表示． |
| `systemctl enable --now <サービス>` | サービスを起動し，同時に自動起動を有効化（OS再起動後も自動で起動）． |
| `systemctl reload <サービス>` | サービスを停止せずに設定だけ再読み込み．無停止での設定反映が可能． |
| `systemctl status <サービス>` | サービスの稼働状態を確認． |
| `systemctl is-enabled <サービス>` | 自動起動の有効/無効を確認． |
| `ss -tlnp` | TCPでLISTEN中のポートとプロセスを一覧表示． |
| `getent hosts <ホスト名>` | システムの名前解決機能を使ってホスト名→IPを解決． |
| `curl -I <URL>` | HTTPヘッダのみを取得（GETしない）．疎通確認やステータスコード確認に使う． |
| `tail -n <数> <ファイル>` | ファイルの末尾N行を表示． |

------------------------------

### B. 設定ファイル解説

**`/etc/nginx/conf.d/proxy.conf`（Webサーバー）**

```nginx
upstream knowledge_cluster {
    ip_hash;
    server <APサーバーのFQDN>:8080;
}
```

- `upstream`：転送先のサーバーグループを定義する．複数台のAPサーバーを束ねる場合に便利．
- `ip_hash`：クライアントIPに基づいて常に同じAPサーバーに転送する（セッション固定，スティッキーセッション）．APサーバーが1台の場合は意味が薄いが，将来の冗長化を見据えて記述しておく．
- `server <APサーバーのFQDN>:8080;`：転送先APサーバーのFQDNとポート．

```nginx
location = /healthcheck {
    access_log off;
    return 200 "healthcheck\n";
}
```

- `location = <パス>`：完全一致で `/healthcheck` のみにマッチ．
- `access_log off`：このパスへのアクセスはアクセスログに記録しない（ヘルスチェックでログが膨大になるのを防ぐ）．
- `return 200 "healthcheck\n";`：200 OK と固定文字列を返す．

```nginx
location / {
    proxy_pass http://knowledge_cluster;
    proxy_set_header Host $host;
    proxy_set_header X-Real-IP $remote_addr;
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto $scheme;
}
```

- `location /`：すべてのパスにマッチ（`/healthcheck`より優先度が低い）．
- `proxy_pass`：転送先を指定．`upstream`で定義したグループを指定できる．
- `proxy_set_header Host $host;`：転送先に元のHostヘッダを引き継ぐ．
- `X-Real-IP` / `X-Forwarded-For`：クライアントの実IPを転送先に伝える．
- `X-Forwarded-Proto`：元のプロトコル（http/https）を転送先に伝える．

**`/etc/nginx/nginx.conf`（Webサーバー）**

- `worker_processes auto;`：CPUコア数に応じてワーカープロセス数を自動決定．
- `include /etc/nginx/conf.d/*.conf;`：`conf.d`配下の `.conf` ファイルを自動読み込み．`proxy.conf`はここで読み込まれる．
- デフォルトの `server { ... }` ブロック：今回は `proxy.conf` 側で `server_name _;` のserverブロックを定義するため，重複を避けてコメントアウトする．

------------------------------

### C. 用語解説

| 用語 | 説明 |
|------|------|
| リバースプロキシ | クライアントとバックエンドサーバーの間に立って，リクエストを受け取りバックエンドに転送するサーバー．負荷分散・SSL終端・キャッシュ等の機能を担う． |
| upstream | Nginxにおける転送先サーバーのグループ定義．複数台のバックエンドサーバーをまとめて指定できる． |
| ip_hash | クライアントIPに基づき転送先を固定する負荷分散方式（スティッキーセッション）． |
| location | Nginxでリクエストパスごとの処理を定義するディレクティブ． |
| server_name | Nginxでバーチャルホストを識別する名前．`_`はワイルドカードとして使われる（マッチする`server_name`が他に無い場合のデフォルト）． |
| proxy_pass | リクエストを別のサーバーに転送するNginxディレクティブ． |
| X-Forwarded-For | プロキシ経由のリクエストで，元のクライアントIPをバックエンドに伝えるためのHTTPヘッダ． |
| ヘルスチェック | ALBや監視ツールがサーバーの正常性を確認するために定期的にアクセスするエンドポイント． |
| ワーカープロセス | Nginxがリクエストを処理するために起動するプロセス．`worker_processes auto;`でコア数に応じて自動決定される． |

------------------------------

### D. 補足解説

- **なぜリバースプロキシを使うか？**
  - クライアントから見るとWebサーバー1台にアクセスしているように見えるが，実際は背後の複数のAPサーバーにリクエストを分散できる．
  - SSL終端（HTTPS処理）を一箇所で行えるためAPサーバー側の負荷を減らせる．
  - APサーバーの内部構造をクライアントから隠蔽できる（セキュリティ向上）．

- **`server_name _;` の意味**
  - `_` は無効なドメイン名であり，Nginxでは「どのHostヘッダにもマッチしないリクエスト用のデフォルトサーバー」として扱われる．
  - VPC内部の検証環境のように，ドメイン名を厳密に指定しない場合に便利．

- **`location` の優先順位**
  - `=` で始まる完全一致が最優先（例：`location = /healthcheck`）．
  - 次に `^~` で始まる前方一致．
  - 最後に `/` のような前方一致（`/healthcheck` より優先度が低い）．
  - そのため `/healthcheck` のリクエストは `location = /healthcheck` にマッチし，`location /` には流れない．

- **`systemctl restart` と `systemctl reload` の違い**
  - `restart`：サービスを停止してから起動する．一時的な通信断が発生する可能性あり．
  - `reload`：サービスを停止せずに設定だけ再読み込み．Nginxの設定変更は基本的に `reload` で反映する．

- **GeoIP設定について**
  - 元の手順書ではGeoIPによるアクセス制御の設定例があったが，Amazon Linux 2023の標準リポジトリに `nginx-module-geoip` パッケージが存在しないため，本手順書では削除している．
  - GeoIPを利用する場合は，別途GeoIP2モジュールの導入やNginx公式リポジトリの利用を検討する．

- **`dnf update` と `dnf upgrade` の違い**
  - DNFベースのAmazon Linux 2023では両者は同義．本手順書では `dnf update -y` に統一している．

- **ModSecurityによるWAFを併用する場合**
  - 本手順書はリバースプロキシ単体の構築までを範囲とする．
  - ModSecurityによるWAF機能を追加する場合は，別手順書 `modsecurity-migration.md` を本手順書完了後に実施すること．
