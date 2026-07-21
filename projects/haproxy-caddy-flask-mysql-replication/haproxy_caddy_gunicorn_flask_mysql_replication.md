# 【高可用Webシステム(HAProxy + Caddy + Gunicorn/Flask + MySQL レプリケーション)】環境構築手順書

---

## 1. ドキュメント情報

| 項目 | 内容 |
|------|------|
| 手順書名 | 高可用Webシステム(HAProxy + Caddy + Gunicorn/Flask + MySQL レプリケーション) |
| 作成日 | 2026-06-23 |
| バージョン | v3.0 |
| 対象環境 | AWS |

> **改訂履歴**
>
> | バージョン | 日付 | 変更内容 |
> |-----------|------|---------|
> | v1.0 | 2026-06-23 | 初版作成 |
> | v2.0 | 2026-06-23 | Caddy → Gunicorn/Flask → MySQL の接続経路を追加。マスタ書き/スレーブ読みの振り分けを実装 |
> | v3.0 | 2026-06-26 | 実機構築で判明した不備を全面修正(VPC CIDR パラメータ化、mysql-client インストール手順追加、MySQL skip-name-resolve 追加、pip upgrade 削除、パスワード使用文字制約の注意追加)。各ミドルウェアの役割と特徴を解説する2-4節を新規追加 |

---

## 2. 目的・概要

### 2-1. 目的

本手順書では、**HAProxy 1台 + Caddy/Gunicorn/Flask(Webサーバ + APサーバ) 2台 + MySQL マスタ/スレーブ 2台**の合計5台構成で、以下の特徴を持つ高可用Webシステムを構築する。

- **HAProxy** によるL7ロードバランシング(ラウンドロビン + ヘルスチェック)
- **Caddy** によるWebサーバ構築(リクエストを Gunicorn にリバースプロキシ)
- **Gunicorn + Flask** によるAPサーバ構築(WSGIサーバの基本構成)
- **MySQL** のバイナリログレプリケーション(マスタ→スレーブ非同期レプリケーション)
- **Flask アプリ側で、マスタ(書き込み)とスレーブ(読み込み)の接続を使い分け**、Read/Write 分離パターンを体験
- **Certbot** による Let's Encrypt 証明書の手動取得

> **本手順書のスコープについて(重要)**
>
> - 学習目的のため、全EC2をパブリックサブネットに配置する。実務ではWebサーバ・APサーバ・DBサーバはプライベートサブネットに置き、LBのみパブリックに置くのが定石である。
> - EIPは利用せず、EC2に自動付与されるパブリックIPで進める。**EC2を停止/起動するとパブリックIPが変化する**ため、停止時はDNSのAレコード更新や、各種設定中のIP参照箇所を更新する必要がある(注意点として常に意識すること)。
> - Read/Write 分離は本来「アプリケーションフレームワーク側の機能」(例: Django のデータベースルータ、SQLAlchemy の binds)で行うのが一般的だが、本手順書では仕組みを理解するために素のFlaskで明示的に2接続を持つ実装にしている。

### 2-2. 構成概要(アーキテクチャ)

```
                  【外部(ブラウザ)】
                          |
                  https://<DOMAIN>/
                          |
                  [Route 53 → HAProxyのパブリックIP]
                          |
              +--------------------------+
              | HAProxy (lb.local)       |
              |  ・L7 LB                 |
              |  ・ヘルスチェック         |
              |  ・stats画面             |
              +------+-----------+-------+
                     |           |
                  ラウンドロビン振り分け
                     |           |
              +------+           +------+
              |                          |
              v                          v
        +-------------------+      +-------------------+
        | Caddy (web1.local)|      | Caddy (web2.local)|
        |  :80              |      |  :80              |
        |   / と /health    |      |   / と /health    |
        |   は静的レスポンス |      |   は静的レスポンス  |
        |   /api/* は       |      |   /api/* は       |
        |   reverse_proxy   |      |   reverse_proxy   |
        |        |          |      |        |          |
        |        v          |      |        v          |
        | Gunicorn          |      | Gunicorn          |
        | (127.0.0.1:8000)  |      | (127.0.0.1:8000)  |
        |  + Flask app      |      |  + Flask app      |
        |   2つのDB接続持つ  |      |   2つのDB接続持つ  |
        +---------+---------+      +---------+---------+
                  |                          |
                書き込みはマスタ、読み込みはスレーブ
                  |                          |
                  v                          v
        +-------------------+         +-------------------+
        | MySQLマスタ(db1)  |         | MySQLスレーブ(db2)  |
        |  書き込み受け付け  |         |  読み込み専用       |
        |  bin-log有効      |<--同期-- |  read-only        |
        +-------------------+         +-------------------+
```

- **HAProxyサーバ × 1台**: HAProxy(L7 LB)、Certbot(証明書取得)
- **Webサーバ × 2台**: Caddy(リバースプロキシ)+ Gunicorn(WSGIサーバ)+ Flask(アプリ)
- **MySQLサーバ × 2台**: MySQL 8.0(マスタ × 1、スレーブ × 1)

### 2-3. 完成イメージ(ゴール定義)

- [ ] ブラウザから `https://<DOMAIN>/` にアクセスすると Caddy のページが表示される
- [ ] 連続アクセスすると、web1 と web2 に交互に振り分けられる
- [ ] `POST /api/visits` でデータを投入すると、Flask 経由で MySQLマスタに INSERT される
- [ ] `GET /api/visits` でデータを取得すると、Flask 経由で MySQLスレーブから SELECT される
- [ ] マスタへの書き込みが、即時にスレーブから読み出せる(レプリケーション動作確認)
- [ ] スレーブのMySQLを止めると、`GET /api/visits` だけ失敗し、`POST` は引き続き成功する(障害時切り分け体感)
- [ ] web1 を停止すると、HAProxyのヘルスチェックで自動的にweb2のみへ振り分けられる
- [ ] HAProxy stats画面でバックエンドの状態が見える
- [ ] Let's Encrypt の証明書がブラウザで有効と表示される

### 2-4. 各ミドルウェアの役割と特徴

本構成で扱う未経験ミドルウェアについて、構築前に役割と特徴を整理しておく。手順を進める途中で「何をやっているのか」見失わないよう、まず全体像を頭に入れる。

#### 2-4-1. HAProxy(L4/L7ロードバランサ)

**役割**: 外部からのHTTP/HTTPSリクエストを受け取り、複数のWebサーバ(web1/web2)に振り分ける。

**既知のMWでいうと**: 既習MWに直接対応するものはない。Nginx もリバースプロキシ・LB機能を持つが、HAProxyは「ロードバランシング専業」のミドルウェア。

**Nginx との違い**: Nginx は Webサーバが主機能でリバースプロキシは付加機能、HAProxy は LB 専業で Webサーバ機能を持たない(静的コンテンツを返せない)。代わりにヘルスチェック・stats画面・きめ細かなバックエンド制御に強い。L4(TCPレベル)とL7(HTTPレベル)の両モードを切り替えられる。

**この構成での役回り**: TLS終端(HTTPS→HTTP変換)と、ラウンドロビンでweb1/web2への振り分けを担当する。ヘルスチェックで死んだサーバを自動で振り分け対象から外す。

**学習ポイント**: Webサーバとロードバランサが別レイヤであることを実感する。`option httpchk` によるアプリレベルのヘルスチェック、`balance` アルゴリズム選択(roundrobin/leastconn/source等)、stats画面によるバックエンド状態の可視化を体感する。

#### 2-4-2. Caddy(モダンなWebサーバ)

**役割**: web1/web2 上で動くWebサーバ。リクエストを受けて、`/api/*` は Gunicorn に転送し、それ以外は静的レスポンスを返す。

**既知のMWでいうと**: Apache や Nginx と同じ「Webサーバ」カテゴリ。

**Apache/Nginx との違い**: Go 製のシングルバイナリで配布される。設定ファイル(Caddyfile)が宣言的で短く書ける。最大の特徴は**自動HTTPS機能**で、ドメイン名を設定するだけで自動的に Let's Encrypt から証明書を取得・更新する。本構成ではTLS終端はHAProxy側で行うため、Caddyの自動HTTPSは意図的に使わず(`:80`表記)、純粋なHTTPサーバとして使う。

**この構成での役回り**: HAProxyから受けたリクエストを、パスごとに振り分ける。`/api/*` は localhost の Gunicorn にリバースプロキシし、それ以外は Caddy 自身が静的応答を返す。

**学習ポイント**: Webサーバ設定ファイルの「宣言的」アプローチを体感する。`reverse_proxy` ディレクティブで自動的に付与される `X-Forwarded-*` ヘッダ群の意味、`handle` ブロックによるパスマッチングの仕組みを知る。

#### 2-4-3. Gunicorn(WSGIアプリケーションサーバ)

**役割**: Python製のFlaskアプリケーションを常駐プロセスとして動かす。

**既知のMWでいうと**: Java界でいう Tomcat、PHP界でいう PHP-FPM のような位置づけ。「アプリケーション本体を実行するためのサーバ」というカテゴリ。

**特徴**: Python 製のプリフォーク方式 WSGI サーバ。WSGI(Web Server Gateway Interface)というPython専用の標準インタフェースに従ったアプリ(Flask、Django、FastAPI等)を起動できる。シンプルな設定が信条で、コマンドラインオプションだけで本番運用できる。

**この構成での役回り**: Flask アプリを localhost:8000 で待ち受け、Caddyからのリクエストを受けて Python コードを実行する。`--workers N` で複数プロセスを起動して並列処理する。

**学習ポイント**: Python の Web アプリは「Webサーバ + WSGIサーバ + アプリFW」の三層構造になることを理解する。Flask 同梱の `app.run()`(開発用シングルスレッド)と Gunicorn(本番用マルチプロセス)の違いを意識する。

#### 2-4-4. Flask(Pythonウェブフレームワーク)

**役割**: HTTPエンドポイント(`/api/visits` 等)を定義する Python のウェブフレームワーク。

**既知のMWでいうと**: 既習のフレームワークでいうと PHP の素の状態に近い軽量さ。「マイクロフレームワーク」と呼ばれ、必要最小限の機能だけを持つ。

**この構成での役回り**: ルーティング(URL → 関数のマッピング)とリクエスト/レスポンス処理を担う「アプリケーション本体」のロジックを書く場所。MySQLマスタ/スレーブへの接続切り替えロジックもFlask アプリ内で実装する。

**学習ポイント**: フレームワーク自体は最小限で、DB接続は専用ライブラリ(mysql-connector-python)で行うという「組み合わせて作る」パターンを体感する。Read/Write分離をアプリ層で明示的に実装する経験を積む。

#### 2-4-5. MySQL(リレーショナルデータベース)

**役割**: アプリケーションデータの永続化と、マスタ→スレーブの非同期レプリケーション。

**既知のMWでいうと**: 既習の MariaDB と同じ系譜(MariaDB は MySQL からフォークされたOSS)。SQL構文や基本機能はほぼ共通だが、レプリケーション機能や認証プラグインなどに差がある。

**MariaDBとの違い**: 本構成では MySQL 8.0 を使い、GTIDベースのレプリケーションや `caching_sha2_password` 認証プラグインなど、MySQL固有の機能に触れる。Amazon Linux 2023 の標準リポジトリには MariaDB しか入っていないため、MySQL公式リポジトリを別途追加する必要がある。

**この構成での役回り**: 書き込みは db1(マスタ)、読み込みは db2(スレーブ)に振り分けることで、参照クエリの負荷分散を実現する。マスタはbinlogを記録し、スレーブはそれを取り込んで自分のデータに反映する。

**学習ポイント**: レプリケーションの基本概念(マスタ/スレーブ、binlog、GTID)を理解する。Read/Write 分離の設計パターンを実装レベルで体感する。MariaDB との運用面の細かい違い(認証プラグイン、レプリ用語の変更など)を知る。

#### 2-4-6. mysql-connector-python(PythonからMySQLに繋ぐためのコネクタ)

**役割**: Python(Flask アプリ)から MySQL に SQL を投げるためのライブラリ。

**特徴**: 内部に「Pure Python実装」と「C拡張実装(`_mysql_connector`)」の2つを持つ。C拡張版は MySQL公式の `libmysqlclient`(C共有ライブラリ)に依存するため、Pythonパッケージを入れるだけでなく、システム側に `mysql-community-libs` 相当が入っている必要がある。

**この構成での役回り**: マスタ用・スレーブ用の2つのコネクションプールを管理し、Flask の `get_conn(role)` から呼ばれる。

**学習ポイント**: PythonライブラリでありながらC共有ライブラリに依存するという「言語境界をまたぐ依存」を体感する。`mysql-community-client` をインストールすると `libmysqlclient` も入るため、コネクタが正しく動作するようになる。

#### 2-4-7. Certbot(Let's Encrypt クライアント)

**役割**: Let's Encrypt から TLS 証明書を自動取得・更新する。

**既知のMWでいうと**: 既習MWに直接対応するものはない。「証明書取得専用ツール」というカテゴリ。

**仕組みのイメージ**: ACME(Automatic Certificate Management Environment)というプロトコルに従い、Let's Encrypt の認証局と通信する。HTTP-01 チャレンジ方式では、「自分が `<DOMAIN>` の管理者であること」を証明するため、Let's Encrypt から指定されたファイルを 80番ポートで応答する必要がある。

**この構成での役回り**: 本手順書では standalone モード(Certbot自身が一時的にWebサーバを立てる)で証明書を取得し、取得した証明書をHAProxyに組み込む。証明書は90日で期限切れになるため、自動更新タイマー(`certbot-renew.timer`)と連動する。

**学習ポイント**: TLS証明書の「取得」「配置」「更新」のライフサイクルを通しで体験する。ACMEプロトコルの基本(ドメイン所有確認の仕組み)を理解する。証明書をどのコンポーネントが持つか(HAProxyかCaddyか)が、システム全体のTLS終端設計に直結することを実感する。

---

## 3. 前提条件・準備

### 3-1. AWS環境(起動済み前提)

以下が完了している前提とする:

- AWSアカウントを保有していること
- VPCが作成されており、CIDRが確定していること(本手順書では `<VPC_CIDR>` として参照する。デフォルトVPCなら `172.31.0.0/16`、カスタムVPCを使う場合は実際のCIDRに置換する)
- EC2インスタンスが **5台起動済み** であること(全台 Amazon Linux 2023、t2.micro または t3.micro)
- 全EC2が **パブリックサブネット** に配置されていること
- 全EC2に **パブリックIPが自動割当**されていること(EIPは使用しない)
- 全EC2にSSHログインできること
- 独自ドメイン `<DOMAIN>` のAレコードが HAProxyサーバのパブリックIPを指していること(Step 8 Let's Encrypt 取得時)

> **注意:パブリックIP変動への対応**
>
> EIPを使わない場合、EC2を停止/起動するとパブリックIPが変化する。学習中はEC2を停止しない運用とし、課金回避のため作業終了時は「停止」ではなく「終了(削除)」を検討する。

### 3-2. 環境要件

#### 3-2-1. HAProxyサーバ

| 項目 | 要件 |
|------|------|
| OS | Amazon Linux 2023 |
| LBソフト | HAProxy |
| 証明書取得 | Certbot(Let's Encrypt) |
| ツール | curl, telnet |

#### 3-2-2. Webサーバ(2台共通)

| 項目 | 要件 |
|------|------|
| OS | Amazon Linux 2023 |
| Webサーバ | Caddy 2.x |
| APサーバ | Gunicorn(Python WSGI サーバ) |
| アプリFW | Flask |
| Python | Python 3.9以上(Amazon Linux 2023 標準) |
| Pythonライブラリ | flask, gunicorn, mysql-connector-python |
| ツール | curl, mysql-client |

#### 3-2-3. MySQLサーバ(マスタ・スレーブ共通)

| 項目 | 要件 |
|------|------|
| OS | Amazon Linux 2023 |
| DBサーバ | MySQL 8.0 |
| ツール | mysql-client |

### 3-3. セキュリティグループ設定

#### 3-3-1. HAProxyサーバ

| タイプ | プロトコル | ポート範囲 | ソース | 目的 |
|-------|-----------|-----------|--------|------|
| SSH | TCP | 22 | マイIP | ローカルからSSHログイン |
| HTTP | TCP | 80 | 0.0.0.0/0 | 外部からのHTTPアクセス + Let's Encrypt HTTP-01チャレンジ |
| HTTPS | TCP | 443 | 0.0.0.0/0 | 外部からのHTTPSアクセス |
| HAProxy stats | TCP | 8404 | マイIP | stats画面閲覧用 |

#### 3-3-2. Webサーバ(2台共通)

| タイプ | プロトコル | ポート範囲 | ソース | 目的 |
|-------|-----------|-----------|--------|------|
| SSH | TCP | 22 | マイIP | ローカルからSSHログイン |
| HTTP | TCP | 80 | `<VPC_CIDR>` | HAProxyからのHTTPバックエンド通信 |

> **解説:Gunicorn の 8000番は外部に開けない**
>
> Caddy → Gunicorn の通信は同一ホスト内(127.0.0.1)で完結させるため、Gunicorn の8000番ポートはSGで外部公開しない。これにより、Caddyを経由しないと Gunicorn にアクセスできない経路を強制できる。
>
> 注意:実務でも「アプリサーバを直接外に晒さない」のは鉄則。Caddyを前段に置くことで、リバースプロキシによる保護層(ヘッダ加工、HTTPSオフロード、レート制限など)を挟める。

#### 3-3-3. MySQLサーバ(マスタ・スレーブ共通)

| タイプ | プロトコル | ポート範囲 | ソース | 目的 |
|-------|-----------|-----------|--------|------|
| SSH | TCP | 22 | マイIP | ローカルからSSHログイン |
| MySQL | TCP | 3306 | `<VPC_CIDR>` | WebサーバのFlaskからの接続、マスタ↔スレーブ間レプリケーション |

### 3-4. パラメータ整理表

| パラメータ | 意味 | 自環境の値 |
|---|---|---|
| `<VPC_CIDR>` | VPCのCIDR(例: `172.31.0.0/16`、`10.0.0.0/16`) | |
| `<VPC_PREFIX>` | VPCのMySQLユーザHost指定用パターン(例: `172.31.%.%`、`10.0.%.%`)。`<VPC_CIDR>` の上位2オクテットを `%.%` に置換した形 | |
| `<HAPROXY_PUB>` | HAProxyサーバのパブリックIP | |
| `<HAPROXY_PRI>` | HAProxyサーバのプライベートIP | |
| `<WEB1_PRI>` | Webサーバ1のプライベートIP | |
| `<WEB2_PRI>` | Webサーバ2のプライベートIP | |
| `<DB1_PRI>` | MySQLマスタのプライベートIP | |
| `<DB2_PRI>` | MySQLスレーブのプライベートIP | |
| `<DOMAIN>` | 利用する独自ドメイン(例: www.example.com) | |
| `<REPL_PASS>` | MySQLレプリケーション用ユーザのパスワード | |
| `<APP_PASS>` | アプリ用MySQLユーザのパスワード | |

> **注意:パスワードに使う文字の制約**
>
> `<APP_PASS>` や `<REPL_PASS>` には、systemd の `Environment=` で安全に扱える文字のみを使うこと。具体的には `$`, `%`, `"`, `\` などは避ける。systemd は `$word` のような文字列を変数展開しようとして空文字に化けさせるため、パスワードに `$` が含まれると認証が通らない原因になる。
>
> MySQL 8 の validate_password ポリシーを満たすため、英大小文字 + 数字 + `!` の組み合わせで `Password!123` や `AppUserPass123` のような形が無難。
>
> 注意:実務ではパスワードは Secrets Manager や Parameter Store から取得し、systemd unit に直接書かないので、この問題は発生しにくい。

### 3-5. ホスト名設計

| サーバ | 設定するホスト名 |
|---|---|
| HAProxyサーバ | `lb.local` |
| Webサーバ1 | `web1.local` |
| Webサーバ2 | `web2.local` |
| MySQLマスタ | `db1.local` |
| MySQLスレーブ | `db2.local` |

---

## 4. 構築手順(詳細)

### 4-1. 環境構築の流れ

1. 全サーバ共通の初期設定 (Step 0)
2. MySQLマスタの構築 (Step 1)
3. MySQLスレーブの構築 (Step 2)
4. レプリケーション設定 (Step 3)
5. Webサーバ1の構築(Caddy + Gunicorn + Flask) (Step 4)
6. Webサーバ2の構築 (Step 5)
7. HAProxyサーバの構築 (Step 6)
8. アプリ連携の動作確認 (Step 7)
9. Let's Encrypt 証明書の取得 + HTTPS有効化 (Step 8)

---

### Step 0: 全サーバ共通の初期設定

**目的:** 全EC2に対して共通の初期設定を行う。**5台すべてのサーバで実施**する。

#### 0-1. 【全サーバで実施】root昇格・パッケージ更新・タイムゾーン・ホスト名設定

サーバごとに `<ホスト名>` を読み替えること。

| サーバ | 設定するホスト名 |
|---|---|
| HAProxyサーバ | `lb.local` |
| Webサーバ1 | `web1.local` |
| Webサーバ2 | `web2.local` |
| MySQLマスタ | `db1.local` |
| MySQLスレーブ | `db2.local` |

```bash
sudo su -
dnf update -y
timedatectl set-timezone Asia/Tokyo
hostnamectl set-hostname <ホスト名>
```

設定確認:

```bash
date
hostnamectl
```

> **解説:なぜ全サーバで同じ初期設定をするか**
>
> タイムゾーンが揃っていないと、各サーバのログのタイムスタンプがズレてトラブル時の時系列追跡が困難になる。特にレプリケーションや LB ヘルスチェックは「複数台のログを突き合わせる」シーンが多いため、初手で揃えておくのが鉄則。

---

### Step 1: MySQLマスタの構築

**目的:** 書き込み系を担当する MySQL マスタを構築する。**MySQLマスタサーバ(db1.local)で実施**する。

#### 1-1. 【db1.localで実施】MySQL公式リポジトリの追加とインストール

Amazon Linux 2023 の標準リポジトリには MySQL ではなく MariaDB が入っているため、MySQL公式リポジトリを追加する。

```bash
dnf install -y https://dev.mysql.com/get/mysql80-community-release-el9-5.noarch.rpm
dnf install -y mysql-community-server
```

> **解説:なぜ el9 のリポジトリを使うのか**
>
> Amazon Linux 2023 は RHEL 9 ベース(glibc 2.34系)なので、`el9` のパッケージが互換性を持つ。

#### 1-2. 【db1.localで実施】MySQL起動と初期パスワード取得

```bash
systemctl start mysqld
systemctl enable mysqld

grep 'temporary password' /var/log/mysqld.log
```

#### 1-3. 【db1.localで実施】mysql_secure_installation で初期化

```bash
mysql_secure_installation
```

| プロンプト | 回答 |
|---|---|
| Enter password for user root: | (1-2で取得した初期パスワード) |
| New password: | (新しい強力なパスワードを設定) |
| Re-enter new password: | (同上) |
| Change the password for root? | n |
| Remove anonymous users? | y |
| Disallow root login remotely? | y |
| Remove test database and access to it? | y |
| Reload privilege tables now? | y |

> **考えるポイント:MySQLのパスワードポリシー**
>
> MySQL 8 のデフォルトの validate_password プラグインは、大文字・小文字・数字・記号を含む8文字以上を要求する。学習用でも、最低でも `Password!123` 程度の複雑さは必要。

#### 1-4. 【db1.localで実施】マスタ用設定

```bash
vi /etc/my.cnf
```

`[mysqld]` セクションに以下を追記:

```
[mysqld]
# === レプリケーション マスタ設定 ===
server-id = 1
log-bin = mysql-bin
binlog-format = ROW
gtid-mode = ON
enforce-gtid-consistency = ON

# === 外部からの接続を受け付ける ===
bind-address = 0.0.0.0

# === 逆引き問い合わせをスキップ ===
skip-name-resolve
```

> **解説:`server-id` の意味**
>
> レプリケーション構成では、各MySQLサーバを一意に識別するため `server-id` を別々に振る必要がある。重複するとレプリケーションが自分のイベントを自分が受信してループ状態になる。

> **解説:GTIDモードの意味**
>
> 従来のレプリケーションでは「バイナリログのファイル名 + ポジション」で同期位置を管理していたが、GTID(Global Transaction ID)モードでは「トランザクションごとに一意なID」で管理するため、レプリ再構成が自動化しやすい。

> **解説:`binlog-format = ROW` の意味**
>
> バイナリログの記録形式の中で、ROW は安全だがログサイズが大きい。STATEMENT は軽量だが非決定的関数(NOW()、UUID()等)で結果がずれる危険がある。GTID を使う場合は ROW が推奨。

> **解説:`skip-name-resolve` の意味**
>
> MySQLは接続元IPを受け取るとデフォルトで逆引きDNSを試みてホスト名に変換し、認証時のホストパターンと照合する。AWS環境では `ip-10-0-2-174.ap-northeast-1.compute.internal` のような内部DNS名が返り、認証パターン(`'appuser'@'10.0.%.%'`)とマッチせず Access denied になるケースがある。
>
> `skip-name-resolve` を入れると逆引きを行わず、常にIPアドレスで認証されるので、`'appuser'@'<VPC_PREFIX>'` のパターンが安定して効く。逆引きDNS遅延による接続レイテンシの悪化も防げるため、実務でもほぼ必須の設定とされる。

#### 1-5. 【db1.localで実施】MySQL再起動

```bash
systemctl restart mysqld
systemctl status mysqld
```

#### 1-6. 【db1.localで実施】レプリケーション用ユーザ + アプリ用ユーザ作成

```bash
mysql -u root -p
```

```sql
-- === レプリケーション専用ユーザ ===
CREATE USER 'repl'@'<VPC_PREFIX>' IDENTIFIED WITH mysql_native_password BY '<REPL_PASS>';
GRANT REPLICATION SLAVE ON *.* TO 'repl'@'<VPC_PREFIX>';

-- === アプリ用ユーザ(Flaskから接続) ===
CREATE DATABASE webapp;
CREATE USER 'appuser'@'<VPC_PREFIX>' IDENTIFIED WITH mysql_native_password BY '<APP_PASS>';
GRANT ALL PRIVILEGES ON webapp.* TO 'appuser'@'<VPC_PREFIX>';

FLUSH PRIVILEGES;

-- 動作確認用テーブル作成
USE webapp;
CREATE TABLE visits (
    id INT AUTO_INCREMENT PRIMARY KEY,
    accessed_at DATETIME DEFAULT CURRENT_TIMESTAMP,
    note VARCHAR(255)
);
INSERT INTO visits (note) VALUES ('initial record on master');

EXIT;
```

> **注意:VPC_PREFIX は自環境のCIDRに合わせる**
>
> `<VPC_PREFIX>` は実際のVPC CIDRに対応するパターンに置換すること。デフォルトVPC(172.31.0.0/16)なら `172.31.%.%`、カスタムVPC(10.0.0.0/16)なら `10.0.%.%`。
>
> MySQL はクライアント接続を「ユーザ名@ホスト」の組で識別するため、`Host` の指定が実際の接続元IPパターンとマッチしないと `Access denied` で弾かれる。

> **解説:`mysql_native_password` を明示的に指定する理由**
>
> MySQL 8 のデフォルト認証プラグインは `caching_sha2_password` だが、`mysql-connector-python` の古いバージョンや一部のフレームワークが対応していないことがある。学習用途では互換性重視で `mysql_native_password` を選んでおくとトラブルが減る。
>
> 注意:実務では `caching_sha2_password` のままにし、クライアント側を新方式に対応させるのが正しい方向性。

---

### Step 2: MySQLスレーブの構築

**目的:** 参照系を担当するスレーブを構築する。**MySQLスレーブサーバ(db2.local)で実施**する。

#### 2-1. 【db2.localで実施】MySQL のインストール

```bash
dnf install -y https://dev.mysql.com/get/mysql80-community-release-el9-5.noarch.rpm
dnf install -y mysql-community-server
systemctl start mysqld
systemctl enable mysqld

grep 'temporary password' /var/log/mysqld.log
mysql_secure_installation
# マスタと同じ要領で実施
```

#### 2-2. 【db2.localで実施】スレーブ用設定

```bash
vi /etc/my.cnf
```

`[mysqld]` セクションに以下を追記:

```
[mysqld]
# === レプリケーション スレーブ設定 ===
server-id = 2
log-bin = mysql-bin
binlog-format = ROW
gtid-mode = ON
enforce-gtid-consistency = ON
read-only = ON
relay-log = relay-bin

bind-address = 0.0.0.0

skip-name-resolve
```

> **解説:`read-only = ON` の意味**
>
> スレーブでは「アプリからの直接書き込み」を防ぐためにこの設定を入れる。`SUPER` 権限を持つユーザ(=root)は read-only 設定を無視できるので、レプリケーションスレッドは内部的に SUPER 相当の権限でマスタからの更新を反映できる。
>
> 普通のユーザは書けないが、レプリは書ける、というのが read-only の本質。

> **解説:なぜスレーブにも `log-bin` を有効化するか**
>
> スレーブ自身も将来「マスタ昇格」する可能性を見越して、binlog を有効化しておく。これがないと、スレーブをマスタに昇格させた瞬間に「新マスタなのに更新ログが取れない」状態になる。

#### 2-3. 【db2.localで実施】MySQL再起動

```bash
systemctl restart mysqld
```

---

### Step 3: レプリケーション設定

**目的:** マスタ→スレーブのレプリケーションを開始する。**MySQLスレーブサーバ(db2.local)で実施**する。

#### 3-1. 【db2.localで実施】スレーブからマスタへの接続テスト

```bash
mysql -h <DB1_PRI> -u repl -p
EXIT;
```

> **考えるポイント:なぜ事前に接続テストするのか**
>
> レプリケーション設定は内部的にスレッドが起動して接続を試みる処理。接続失敗時のエラーは `Last_IO_Error` を見ないといけないので分かりにくい。事前にクライアントで切り分けておくと、トラブル時の原因特定が楽になる。

#### 3-2. 【db2.localで実施】レプリケーション開始

```bash
mysql -u root -p
```

```sql
RESET MASTER;

CHANGE REPLICATION SOURCE TO
    SOURCE_HOST = '<DB1_PRI>',
    SOURCE_USER = 'repl',
    SOURCE_PASSWORD = '<REPL_PASS>',
    SOURCE_AUTO_POSITION = 1;

START REPLICA;

SHOW REPLICA STATUS\G
```

確認ポイント:

| 項目 | 期待値 |
|---|---|
| `Replica_IO_Running` | `Yes` |
| `Replica_SQL_Running` | `Yes` |
| `Last_IO_Error` | (空) |
| `Last_SQL_Error` | (空) |
| `Seconds_Behind_Source` | 0(または小さい値) |

> **解説:MySQL 8.0.22以降の用語変更**
>
> 従来 `MASTER` / `SLAVE` で書かれていたコマンドは、MySQL 8.0.22 以降 `SOURCE` / `REPLICA` に変更された。

> **解説:`SOURCE_AUTO_POSITION = 1` の意味**
>
> GTIDモードを使う場合、どのトランザクションから受信するかをGTIDセットで自動判定する。従来必要だったマスタの binlog ファイル名とポジションの手動指定が不要になる。

#### 3-3. 【db2.localで実施】レプリケーション動作確認(スレーブ側)

```sql
USE webapp;
SELECT * FROM visits;
-- 「initial record on master」が見えればOK
```

#### 3-4. 【db1.localで実施】マスタで追加投入

```bash
mysql -u root -p
```

```sql
USE webapp;
INSERT INTO visits (note) VALUES ('replication test record');
```

#### 3-5. 【db2.localで実施】スレーブで反映確認

```bash
mysql -u root -p -e "USE webapp; SELECT * FROM visits;"
```

---

### Step 4: Webサーバ1の構築(Caddy + Gunicorn + Flask)

**目的:** Caddy がリクエストを受け、`/api/*` を Gunicorn(Flask)に転送し、Flask が MySQL マスタ/スレーブを使い分ける構成を作る。**Webサーバ1(web1.local)で実施**する。

#### 4-1. 【web1.localで実施】Caddyのインストール

```bash
dnf install -y 'dnf-command(copr)'
dnf copr enable -y @caddy/caddy epel-9-x86_64
dnf install -y caddy
```

> **考えるポイント:`copr` とは何か**
>
> COPR(Cool Other Package Repo)は Fedora プロジェクトが提供するコミュニティリポジトリ。RHEL系で公式リポジトリにないパッケージを入れたいときの定番手段。

#### 4-2. 【web1.localで実施】Python関連パッケージのインストール

```bash
# OS側に必要な開発ツールとMySQLクライアントライブラリを先に入れる
dnf install -y python3 python3-pip python3-devel gcc
dnf install -y https://dev.mysql.com/get/mysql80-community-release-el9-5.noarch.rpm
dnf install -y mysql-community-client

# その後でPythonパッケージをインストール
pip3 install flask gunicorn mysql-connector-python
```

> **解説:なぜ MySQL関連の dnf を pip より先に行うか**
>
> `mysql-connector-python` には「Pure Python実装」と「C拡張実装」の2系統があり、デフォルトでは C拡張実装が優先的に使われる。C拡張は MySQL公式の `libmysqlclient`(C共有ライブラリ)に依存するため、これが事前に入っていないと、pip install自体は成功してもアプリ起動時にC拡張のロードに失敗する。
>
> `mysql-community-client` のインストールに伴って `mysql-community-libs`(`libmysqlclient` を含む)が一緒に入るため、これを先に済ませておく。

> **解説:なぜ `gcc` と `python3-devel` も入れるか**
>
> `mysql-connector-python` をはじめ、PythonのC拡張パッケージはインストール時にC言語のコンパイルを伴うことがある。事前に開発ツールを入れておくと install で詰まりにくい。

> **注意:`pip3 install --upgrade pip` は実行しない**
>
> Amazon Linux 2023 の pip は dnf(rpm) でインストールされているため、`pip install --upgrade pip` を実行すると `RECORD file not found` エラーになる。これは「rpm 管理のパッケージを pip で消すな」というpip側の安全装置で、エラーが出ても後続のパッケージインストールに支障はない。本手順書ではこのアップグレードは行わない。

> **注意:`Running pip as the 'root' user` 警告について**
>
> pip install 実行時に「root で pip を実行するのは推奨されない」という警告が出るが、学習用途では無視してよい。実務では venv(仮想環境)を使い、専用ユーザで pip install するのが定石。本手順書では venv を使わずシステムPythonにインストールしている。

#### 4-3. 【web1.localで実施】Flaskアプリ用ディレクトリ作成

```bash
mkdir -p /opt/webapp
cd /opt/webapp
```

#### 4-4. 【web1.localで実施】Flaskアプリ本体の作成

```bash
vi /opt/webapp/app.py
```

```python
import os
import socket
from flask import Flask, jsonify, request
import mysql.connector
from mysql.connector import pooling

app = Flask(__name__)

# === DB接続設定(マスタ・スレーブ別々) ===
DB_MASTER_CONFIG = {
    "host": os.environ.get("DB_MASTER_HOST", "<DB1_PRI>"),
    "port": 3306,
    "user": "appuser",
    "password": os.environ.get("APP_PASS", "<APP_PASS>"),
    "database": "webapp",
}

DB_SLAVE_CONFIG = {
    "host": os.environ.get("DB_SLAVE_HOST", "<DB2_PRI>"),
    "port": 3306,
    "user": "appuser",
    "password": os.environ.get("APP_PASS", "<APP_PASS>"),
    "database": "webapp",
}

# === コネクションプール(マスタ用・スレーブ用 別々) ===
master_pool = pooling.MySQLConnectionPool(
    pool_name="master_pool",
    pool_size=3,
    **DB_MASTER_CONFIG,
)

slave_pool = pooling.MySQLConnectionPool(
    pool_name="slave_pool",
    pool_size=3,
    **DB_SLAVE_CONFIG,
)


def get_conn(role):
    """role='write' ならマスタ、role='read' ならスレーブを返す"""
    if role == "write":
        return master_pool.get_connection()
    elif role == "read":
        return slave_pool.get_connection()
    else:
        raise ValueError("role must be 'write' or 'read'")


# === エンドポイント ===

@app.route("/api/whoami", methods=["GET"])
def whoami():
    """自分がどのWebサーバかを返す(LB振り分け確認用)"""
    return jsonify({
        "hostname": socket.gethostname(),
    })


@app.route("/api/visits", methods=["GET"])
def list_visits():
    """スレーブから読み出し"""
    conn = get_conn("read")
    try:
        cur = conn.cursor(dictionary=True)
        cur.execute(
            "SELECT id, accessed_at, note FROM visits ORDER BY id DESC LIMIT 20"
        )
        rows = cur.fetchall()
        cur.close()
        # datetime をJSON化のため文字列化
        for r in rows:
            r["accessed_at"] = r["accessed_at"].strftime("%Y-%m-%d %H:%M:%S")
        return jsonify({
            "source": "slave",
            "served_by": socket.gethostname(),
            "rows": rows,
        })
    finally:
        conn.close()


@app.route("/api/visits", methods=["POST"])
def add_visit():
    """マスタへ書き込み"""
    data = request.get_json(silent=True) or {}
    note = data.get("note", "no note")

    conn = get_conn("write")
    try:
        cur = conn.cursor()
        cur.execute(
            "INSERT INTO visits (note) VALUES (%s)",
            (note,),
        )
        conn.commit()
        new_id = cur.lastrowid
        cur.close()
        return jsonify({
            "source": "master",
            "served_by": socket.gethostname(),
            "inserted_id": new_id,
            "note": note,
        }), 201
    finally:
        conn.close()


@app.route("/api/health", methods=["GET"])
def health():
    """ヘルスチェック用(DBに触らない)"""
    return jsonify({"status": "ok"}), 200


if __name__ == "__main__":
    app.run(host="127.0.0.1", port=8000)
```

> **解説:なぜマスタ用・スレーブ用で接続プールを分けるか**
>
> 1つのプールから接続を取り出して、その都度ホストを切り替える、という実装もできなくはないが、コネクションプールは「同じ接続先に対するコネクション」をまとめて管理する仕組み。マスタとスレーブは別ホストなので、プールも別々にするのが自然。
>
> アプリ側で `role` を渡すことで「これは書き込みなのか、読み込みなのか」を明示できるので、後でログ調査やメトリクス取得が楽になる。

> **解説:なぜFlaskを直接実行するのではなくGunicornを使うか**
>
> Flask 同梱の `app.run()` は開発用サーバ。シングルスレッドで本番運用には耐えない。Gunicorn は WSGI 仕様に従う本番向けプリフォークサーバで、複数ワーカープロセスを起動して並列処理する。
>
> Gunicorn は WSGI アプリ(Flask、Django、FastAPI等)を起動するためのプロセスマネージャの役割を持つ。

> **考えるポイント:環境変数で接続情報を渡す設計**
>
> パスワードをコード内にハードコードするのではなく、`os.environ.get()` で環境変数から取得する形にしている。systemd unit ファイルで `Environment=` を指定することで注入する(後述)。
>
> 注意:実務ではAWS Secrets Manager や Parameter Store を使うのが定石。学習段階では環境変数で十分。

#### 4-5. 【web1.localで実施】Gunicorn を systemd で起動する設定

```bash
vi /etc/systemd/system/webapp.service
```

```
[Unit]
Description=Webapp Gunicorn Service
After=network.target

[Service]
Type=simple
User=caddy
Group=caddy
WorkingDirectory=/opt/webapp
Environment="DB_MASTER_HOST=<DB1_PRI>"
Environment="DB_SLAVE_HOST=<DB2_PRI>"
Environment="APP_PASS=<APP_PASS>"
ExecStart=/usr/local/bin/gunicorn \
    --workers 2 \
    --bind 127.0.0.1:8000 \
    --access-logfile /var/log/webapp_access.log \
    --error-logfile /var/log/webapp_error.log \
    app:app
Restart=on-failure

[Install]
WantedBy=multi-user.target
```

> **解説:`User=caddy` の意味**
>
> Caddy パッケージインストール時に `caddy` ユーザが自動作成されているので、それを Gunicorn の実行ユーザとして流用する。同じユーザで動かすことで権限関連のトラブルを減らせる。
>
> 注意:実務ではアプリ専用のユーザ(例: `webapp`)を別途作成するのが望ましい。サービスごとに権限境界を作ることで影響範囲を小さくできる。

> **解説:`--workers 2` の意味**
>
> Gunicorn のワーカープロセス数。一般的に「CPUコア数 × 2 + 1」が推奨値だが、t2.micro/t3.micro は1コアなので 2 で十分。多すぎるとメモリ不足で OOM Killer に殺される。

#### 4-6. 【web1.localで実施】ログファイルの初期作成と権限設定

```bash
touch /var/log/webapp_access.log /var/log/webapp_error.log
chown caddy:caddy /var/log/webapp_access.log /var/log/webapp_error.log
chown -R caddy:caddy /opt/webapp
```

#### 4-7. 【web1.localで実施】Gunicornのパス確認

```bash
which gunicorn
# /usr/local/bin/gunicorn と表示されればOK(systemd unit のパスと一致)
# 異なる場合は systemd unit を修正
```

#### 4-8. 【web1.localで実施】Gunicornの起動

```bash
systemctl daemon-reload
systemctl start webapp
systemctl enable webapp
systemctl status webapp
```

#### 4-9. 【web1.localで実施】Gunicorn 単体の動作確認

```bash
curl http://127.0.0.1:8000/api/health
# {"status":"ok"}

curl http://127.0.0.1:8000/api/whoami
# {"hostname":"web1.local"}

curl http://127.0.0.1:8000/api/visits
# {"rows":[...],"served_by":"web1.local","source":"slave"}
```

#### 4-10. 【web1.localで実施】Caddyfile の作成

```bash
vi /etc/caddy/Caddyfile
```

```
:80 {
    header X-Backend-Server "web1"

    # /api/* は Gunicorn(Flask) にリバースプロキシ
    handle /api/* {
        reverse_proxy 127.0.0.1:8000
    }

    # それ以外は Caddy が静的に応答
    handle / {
        respond "Hello from web1.local" 200
    }

    # HAProxyからのヘルスチェック用
    handle /health {
        respond "OK" 200
    }
}
```

> **解説:`handle` の意味**
>
> Caddyfile では `handle` ブロックを使うとパスごとに処理を分岐できる。`/api/*` は Gunicorn にプロキシ、それ以外は静的レスポンス、と切り分けている。
>
> `handle` は「最初にマッチしたものだけ実行」する。`/api/visits` は `/api/*` にマッチするが `/` にはマッチしないので、Gunicorn だけに送られる。

> **解説:`reverse_proxy 127.0.0.1:8000` の意味**
>
> Caddyは受けたHTTPリクエストをそのまま Gunicorn(localhost:8000)に転送し、その応答をクライアントに返す。これがいわゆるリバースプロキシ。
>
> Caddy が前段に立つことで、HTTPS終端、ヘッダ操作、レート制限などをGunicorn より手前で行える。Gunicorn は純粋にアプリの処理に集中できる。

#### 4-11. 【web1.localで実施】Caddyの起動

```bash
systemctl start caddy
systemctl enable caddy
systemctl status caddy
```

#### 4-12. 【web1.localで実施】Caddy 経由の動作確認

```bash
curl -i http://localhost/
# X-Backend-Server: web1
# Hello from web1.local

curl http://localhost/health
# OK

curl http://localhost/api/whoami
# {"hostname":"web1.local"}

curl http://localhost/api/visits
# {"rows":[...],"served_by":"web1.local","source":"slave"}

# 書き込みテスト
curl -X POST -H "Content-Type: application/json" \
    -d '{"note":"posted via web1"}' \
    http://localhost/api/visits
# {"inserted_id":N,"note":"posted via web1","served_by":"web1.local","source":"master"}
```

---

### Step 5: Webサーバ2の構築

**目的:** Webサーバ1と同じ構成の2台目を構築する。**Webサーバ2(web2.local)で実施**する。

Step 4 と同じ手順だが、Caddyfile のヘッダ・レスポンス文字列のみ異なる。

#### 5-1. 【web2.localで実施】Caddyのインストール

```bash
dnf install -y 'dnf-command(copr)'
dnf copr enable -y @caddy/caddy epel-9-x86_64
dnf install -y caddy
```

#### 5-2. 【web2.localで実施】Python関連パッケージのインストール

```bash
# OS側に必要な開発ツールとMySQLクライアントライブラリを先に入れる
dnf install -y python3 python3-pip python3-devel gcc
dnf install -y https://dev.mysql.com/get/mysql80-community-release-el9-5.noarch.rpm
dnf install -y mysql-community-client

# その後でPythonパッケージをインストール
pip3 install flask gunicorn mysql-connector-python
```

> **解説**: 順序の意味と詳細はStep 4-2を参照。

#### 5-3. 【web2.localで実施】Flaskアプリの配置

```bash
mkdir -p /opt/webapp
vi /opt/webapp/app.py
```

→ Step 4-4 と完全に同じ内容(app.py は同一でOK。`socket.gethostname()` で自動的に `web2.local` を返す)

#### 5-4. 【web2.localで実施】Gunicorn systemd unit 作成

```bash
vi /etc/systemd/system/webapp.service
```

→ Step 4-5 と完全に同じ内容

#### 5-5. 【web2.localで実施】ログファイル・権限・起動

```bash
touch /var/log/webapp_access.log /var/log/webapp_error.log
chown caddy:caddy /var/log/webapp_access.log /var/log/webapp_error.log
chown -R caddy:caddy /opt/webapp

systemctl daemon-reload
systemctl start webapp
systemctl enable webapp
```

#### 5-6. 【web2.localで実施】Caddyfile の作成

```bash
vi /etc/caddy/Caddyfile
```

```
:80 {
    header X-Backend-Server "web2"

    handle /api/* {
        reverse_proxy 127.0.0.1:8000
    }

    handle / {
        respond "Hello from web2.local" 200
    }

    handle /health {
        respond "OK" 200
    }
}
```

#### 5-7. 【web2.localで実施】起動・確認

```bash
systemctl start caddy
systemctl enable caddy

curl http://localhost/api/whoami
# {"hostname":"web2.local"}
```

---

### Step 6: HAProxyサーバの構築

**目的:** ロードバランサとして HAProxy を構築する。**HAProxyサーバ(lb.local)で実施**する。

#### 6-1. 【lb.localで実施】HAProxyのインストール

```bash
dnf install -y haproxy
```

#### 6-2. 【lb.localで実施】HAProxy設定ファイルの編集

```bash
cp /etc/haproxy/haproxy.cfg{,.org}
vi /etc/haproxy/haproxy.cfg
```

設定内容を以下に置き換える(まずはHTTPのみ、HTTPSは Step 8 で追加):

```
global
    log         127.0.0.1 local2
    chroot      /var/lib/haproxy
    pidfile     /var/run/haproxy.pid
    maxconn     4000
    user        haproxy
    group       haproxy
    daemon
    stats socket /var/lib/haproxy/stats

defaults
    mode                    http
    log                     global
    option                  httplog
    option                  dontlognull
    option                  http-server-close
    option                  forwardfor       except 127.0.0.0/8
    option                  redispatch
    retries                 3
    timeout http-request    10s
    timeout queue           1m
    timeout connect         10s
    timeout client          1m
    timeout server          1m
    timeout http-keep-alive 10s
    timeout check           10s
    maxconn                 3000

# === stats画面 ===
frontend stats
    bind *:8404
    stats enable
    stats uri /stats
    stats refresh 5s
    stats admin if TRUE
    stats auth admin:StrongPassword123

# === HTTPフロントエンド ===
frontend http_front
    bind *:80
    default_backend web_backend

# === バックエンドサーバ群 ===
backend web_backend
    balance roundrobin
    option httpchk GET /health
    http-check expect status 200
    server web1 <WEB1_PRI>:80 check inter 2000 rise 2 fall 3
    server web2 <WEB2_PRI>:80 check inter 2000 rise 2 fall 3
```

> **解説:`balance roundrobin` の意味**
>
> リクエストを来た順に web1 → web2 → web1 → web2 と交互に振り分ける。他にもアルゴリズムがある(`leastconn`、`source`、`uri`等)。学習段階では roundrobin が動作確認しやすい。

> **解説:`option httpchk` の意味**
>
> HAProxyが定期的に GET /health を投げて、バックエンドが生きているか確認する仕組み。`check inter 2000` は「2秒ごとにチェック」、`rise 2` は「2回連続で成功したら復活」、`fall 3` は「3回連続で失敗したら停止」と判定する。
>
> Step 4-10 で Caddyfile に `/health` エンドポイントを書いたのはこのため。

> **解説:`option forwardfor` の意味**
>
> HAProxyからバックエンドへの転送時に、`X-Forwarded-For` ヘッダにクライアントの本物のIPを入れる。LB配下のサーバから見ると、すべての接続がHAProxyから来ているように見えるので、アクセスログ用に本物のIPを補完する必要がある。

> **解説:`option redispatch` の意味**
>
> あるバックエンドに振り分けた直後にそのサーバが落ちた場合、別の生きているサーバに自動的に振り直す。接続切れの瞬間を救済するフェイルオーバの仕組み。

#### 6-3. 【lb.localで実施】SELinux対策(必要な場合のみ)

```bash
setsebool -P haproxy_connect_any 1
```

#### 6-4. 【lb.localで実施】HAProxyの起動

```bash
systemctl start haproxy
systemctl enable haproxy
systemctl status haproxy
```

#### 6-5. 【lb.localで実施】HAProxy経由の動作確認

```bash
# 静的レスポンスのラウンドロビン
for i in 1 2 3 4 5; do curl -s http://localhost/; done

# APIのラウンドロビン
for i in 1 2 3 4; do curl -s http://localhost/api/whoami; echo; done
# {"hostname":"web1.local"}
# {"hostname":"web2.local"}
# {"hostname":"web1.local"}
# {"hostname":"web2.local"}
```

stats画面の確認:

```
ブラウザで:
http://<HAPROXY_PUB>:8404/stats
ユーザ名: admin
パスワード: StrongPassword123
```

---

### Step 7: アプリ連携の動作確認

**目的:** HAProxy → Caddy → Gunicorn → Flask → MySQL の経路が、マスタ書き/スレーブ読みで正しく動作することを確認する。**HAProxyサーバまたはローカルPCで実施**する。

#### 7-1. 【lb.localで実施】マスタへの書き込みテスト

```bash
curl -X POST -H "Content-Type: application/json" \
    -d '{"note":"end-to-end test 1"}' \
    http://localhost/api/visits
# {"inserted_id":N,"note":"end-to-end test 1","served_by":"web1.local","source":"master"}

curl -X POST -H "Content-Type: application/json" \
    -d '{"note":"end-to-end test 2"}' \
    http://localhost/api/visits
# {"inserted_id":N+1,"note":"end-to-end test 2","served_by":"web2.local","source":"master"}
```

書き込みは `web1` と `web2` で振り分けられているが、どちらも `source: master` になっていることを確認。

#### 7-2. 【lb.localで実施】スレーブからの読み込みテスト

```bash
curl http://localhost/api/visits
# {"rows":[..., {"id":N+1,"note":"end-to-end test 2",...}, {"id":N,"note":"end-to-end test 1",...}, ...],
#  "served_by":"web1.local",
#  "source":"slave"}
```

`source: slave` で取得され、直前に書き込んだ2件が含まれていることを確認(レプリ遅延がほぼゼロであることを実感)。

#### 7-3. 【db2.localで実施】スレーブ障害シミュレーション

```bash
# スレーブのMySQLを停止
systemctl stop mysqld
```

#### 7-4. 【lb.localで実施】読み込みが失敗、書き込みは成功することを確認

```bash
# 書き込みは成功する(マスタは生きている)
curl -X POST -H "Content-Type: application/json" \
    -d '{"note":"during slave outage"}' \
    http://localhost/api/visits
# 201 Created で成功する

# 読み込みは失敗する(スレーブが死んでいる)
curl -i http://localhost/api/visits
# 500 Internal Server Error
```

> **考えるポイント:Read/Write分離は障害ドメインが分かれるという点**
>
> マスタ・スレーブを別ノードにすると、それぞれが独立した障害点になる。スレーブだけ落ちても書き込みは続けられる。逆にマスタが落ちると書き込みが止まる。
>
> 注意:実務では「スレーブ障害時は自動的にマスタから読む」フォールバック処理をアプリ側に入れたり、ProxySQL 等のミドルウェアでDB側のヘルスチェック+ルーティングを担わせる。本手順書では学習目的でシンプルに「スレーブ死んだら読みエラー」のままにしている。

#### 7-5. 【db2.localで実施】スレーブを復旧

```bash
systemctl start mysqld

# レプリも自動再開しているか確認
mysql -u root -p -e "SHOW REPLICA STATUS\G" | grep Running
# Replica_IO_Running: Yes
# Replica_SQL_Running: Yes
```

#### 7-6. 【lb.localで実施】スレーブから読み込み再開を確認

```bash
curl http://localhost/api/visits
# 200 OK で、Step 7-4 でマスタに書き込んだ "during slave outage" レコードも見える(レプリで追いついた)
```

#### 7-7. 【web1.localで実施】Web1停止 → 自動フェイルオーバ確認

```bash
systemctl stop caddy
```

#### 7-8. 【lb.localで実施】Web1停止時の挙動

```bash
# 数秒待ってから
for i in 1 2 3 4; do curl -s http://localhost/api/whoami; echo; done
# すべて {"hostname":"web2.local"}
```

#### 7-9. 【web1.localで実施】復旧

```bash
systemctl start caddy
```

---

### Step 8: Let's Encrypt 証明書の取得 + HTTPS有効化

**目的:** HAProxyに Let's Encrypt の証明書を組み込み、HTTPS化する。**HAProxyサーバ(lb.local)で実施**する。

> **前提:** `<DOMAIN>` のAレコードが HAProxyサーバの現在のパブリックIPを指していること。

> **注意:パブリックIP変動による証明書失効**
>
> EIPを使わないため、EC2再起動でパブリックIPが変わるとAレコード再設定が必要になる。本Step実施中はEC2を停止しないこと。実務ではEIPまたはDNS名(`example.com` がEIP固定)を使うのが必須。

#### 8-1. 【lb.localで実施】Certbotのインストール

```bash
dnf install -y certbot
```

#### 8-2. 【lb.localで実施】HAProxyをいったん停止して80番を空ける

```bash
systemctl stop haproxy
```

> **考えるポイント:なぜいったん HAProxy を止めるのか**
>
> Let's Encrypt のHTTP-01 チャレンジは指定ドメインの80番ポートに `/.well-known/acme-challenge/...` パスでアクセスして特定の値が返ってくれば所有者と認定する仕組み。Certbot standalone モードは自分で軽量Webサーバを立てて応答する方式なので、80番を独占する必要がある。
>
> 注意:実務では HAProxy を止めずに webroot モードを使う(HAProxy内で `.well-known/acme-challenge/` パスだけ別バックエンドのCertbotに転送する)。

#### 8-3. 【lb.localで実施】証明書取得

```bash
certbot certonly --standalone -d <DOMAIN> --agree-tos -m admin@<DOMAIN> --non-interactive
```

#### 8-4. 【lb.localで実施】HAProxy用のPEM結合

```bash
mkdir -p /etc/haproxy/certs
cat /etc/letsencrypt/live/<DOMAIN>/fullchain.pem \
    /etc/letsencrypt/live/<DOMAIN>/privkey.pem \
    > /etc/haproxy/certs/<DOMAIN>.pem
chmod 600 /etc/haproxy/certs/<DOMAIN>.pem
```

> **解説:なぜ結合が必要か**
>
> Nginx は証明書と秘密鍵を別々に指定するスタイル。HAProxyはひとまとめのPEMを指定するスタイル。これは設計思想の違いで、HAProxyは「1サーバ=1ファイル」管理を好む。
>
> 結合ファイルの管理は秘密鍵が含まれるので、`chmod 600` で必ず保護する。

#### 8-5. 【lb.localで実施】HAProxyの設定にHTTPSを追加

```bash
vi /etc/haproxy/haproxy.cfg
```

`frontend http_front` を以下のように書き換え、HTTPS フロントエンドを追加:

```
# === HTTPフロントエンド(HTTPSへリダイレクト) ===
frontend http_front
    bind *:80
    acl is_acme path_beg /.well-known/acme-challenge/
    use_backend acme_backend if is_acme
    redirect scheme https code 301 if !{ ssl_fc }

# === HTTPSフロントエンド ===
frontend https_front
    bind *:443 ssl crt /etc/haproxy/certs/<DOMAIN>.pem
    default_backend web_backend

# === ACME更新用 ===
backend acme_backend
    server certbot 127.0.0.1:8888
```

> **解説:HTTP→HTTPS強制リダイレクトの実装パターン**
>
> `redirect scheme https code 301 if !{ ssl_fc }` の `ssl_fc` はフロントエンド接続がSSLかを判定する HAProxy 組み込み変数。否定(`!`)を付けることで、平文HTTPで来た接続だけリダイレクトする。
>
> ただし `.well-known/acme-challenge/` だけは素通しさせる必要がある(Let's Encrypt の自動更新時にここを叩かれるため)。

#### 8-6. 【lb.localで実施】HAProxy起動

```bash
systemctl start haproxy
```

#### 8-7. 【ローカルPCで実施】ブラウザで動作確認

```
https://<DOMAIN>/                    → "Hello from web1/2.local"
https://<DOMAIN>/api/whoami          → {"hostname":"web1/2.local"}
https://<DOMAIN>/api/visits          → DBレコード一覧
```

#### 8-8. 【lb.localで実施】証明書自動更新の設定

```bash
mkdir -p /etc/letsencrypt/renewal-hooks/post
cat > /etc/letsencrypt/renewal-hooks/post/haproxy.sh << 'EOF'
#!/bin/bash
cat /etc/letsencrypt/live/<DOMAIN>/fullchain.pem \
    /etc/letsencrypt/live/<DOMAIN>/privkey.pem \
    > /etc/haproxy/certs/<DOMAIN>.pem
chmod 600 /etc/haproxy/certs/<DOMAIN>.pem
systemctl reload haproxy
EOF
chmod +x /etc/letsencrypt/renewal-hooks/post/haproxy.sh

systemctl enable --now certbot-renew.timer
systemctl list-timers | grep certbot
```

> **考えるポイント:証明書更新と無停止運用**
>
> Let's Encrypt の証明書は90日で期限切れ。実運用では更新を完全自動化する必要がある。`reload` は `restart` と違い、新しい接続は新しいプロセスで受け、既存接続は古いプロセスで処理しきってから終了する。LBの世界では無停止再読み込みが運用品質を決める。

---

## 5. 動作確認・検証

### 5-1. 確認チェックリスト

- [ ] **確認①**: HTTP→HTTPS リダイレクトが効く
- [ ] **確認②**: 静的レスポンスがラウンドロビンされる
- [ ] **確認③**: `/api/whoami` がラウンドロビンされる
- [ ] **確認④**: `POST /api/visits` でマスタに書き込みでき、`GET /api/visits` でスレーブから即読める
- [ ] **確認⑤**: スレーブ停止時、書き込みは成功するが読み込みは失敗する
- [ ] **確認⑥**: Web1停止時、自動的にWeb2のみに振り分けられる
- [ ] **確認⑦**: HAProxy stats画面でバックエンド状態が見える

---

### 確認①: HTTP→HTTPS リダイレクト

**【ローカルPCで実施】**

```bash
curl -I http://<DOMAIN>/
# HTTP/1.1 301 Moved Permanently
# Location: https://<DOMAIN>/
```

### 確認②③: ラウンドロビン

**【ローカルPCで実施】**

```bash
for i in 1 2 3 4; do curl -s https://<DOMAIN>/; done

for i in 1 2 3 4; do curl -s https://<DOMAIN>/api/whoami; echo; done
```

### 確認④: マスタ書き/スレーブ読み

**【ローカルPCで実施】**

```bash
# 書き込み
curl -X POST -H "Content-Type: application/json" \
    -d '{"note":"check4"}' \
    https://<DOMAIN>/api/visits
# {"source":"master",...}

# 読み込み
curl https://<DOMAIN>/api/visits
# {"source":"slave","rows":[{"note":"check4",...},...]}
```

### 確認⑤: スレーブ障害

**【db2.localで実施】**

```bash
systemctl stop mysqld
```

**【ローカルPCで実施】**

```bash
curl -X POST -H "Content-Type: application/json" \
    -d '{"note":"during outage"}' \
    https://<DOMAIN>/api/visits
# 201 Created で成功

curl -i https://<DOMAIN>/api/visits
# 500 Internal Server Error
```

**【db2.localで実施】復旧**

```bash
systemctl start mysqld
```

### 確認⑥: Web1停止

**【web1.localで実施】**

```bash
systemctl stop caddy
```

**【ローカルPCで実施】**

```bash
for i in 1 2 3; do curl -s https://<DOMAIN>/api/whoami; echo; done
# すべて web2.local
```

**【web1.localで実施】復旧**

```bash
systemctl start caddy
```

### 確認⑦: stats画面

**【ローカルPCで実施】** ブラウザで `http://<HAPROXY_PUB>:8404/stats`

---

## 6. トラブルシューティング

### エラー①: Gunicornが起動しない

**原因:** Python依存パッケージのインストール失敗、systemd unit のパスミス、ユーザ権限。

**対処法:**

```bash
# 【web1.localで実施】
systemctl status webapp
journalctl -u webapp -n 50

# パスを確認
which gunicorn

# 手動起動して詳細エラーを確認
sudo -u caddy /usr/local/bin/gunicorn --bind 127.0.0.1:8000 --chdir /opt/webapp app:app
```

---

### エラー②: FlaskからMySQL接続失敗(`Access denied for user 'appuser'@'...'`)

**原因の切り分け方:** エラーメッセージの `'appuser'@'XXX'` の `XXX` 部分を確認する。

- **XXXがホスト名(`ip-10-0-2-174.ap-northeast-1.compute.internal` 等)** → MySQL の `skip-name-resolve` が効いていない。Step 1-4 / 2-2 の `/etc/my.cnf` を確認し、再起動する
- **XXXがIPアドレス(`10.0.2.174` 等)で、しかしユーザは `'appuser'@'172.31.%.%'` のように作成されている** → VPC CIDR の不一致。Step 1-6 で `<VPC_PREFIX>` を実環境に合わせて作り直す
- **XXXのパターンは合っているのに弾かれる** → パスワード化け。Step 4-5 の systemd unit の `Environment="APP_PASS=..."` で特殊文字(`$` など)が変数展開で消えていないか確認

**切り分けコマンド:**

```bash
# 【web1.localで実施】mysqlクライアントで手動接続テスト
mysql -h <DB1_PRI> -u appuser -p
```

- 手動で繋がる → systemd unit のパスワード化けが原因
- 手動でも繋がらない → MySQLユーザ定義の問題

**Flaskのエラーログ確認:**

```bash
tail -50 /var/log/webapp_error.log
```

**よくある根本原因:**

| 症状 | 原因 | 対処 |
|------|------|------|
| `Access denied for user 'appuser'@'ip-XX...'` | 逆引きDNSが有効 | `/etc/my.cnf` に `skip-name-resolve` 追加 |
| `Access denied for user 'appuser'@'10.0.X.X'`(VPC CIDR違い) | ユーザのHost指定がVPC CIDRと不一致 | `DROP USER` してから`<VPC_PREFIX>` で作り直し |
| 手動mysqlは通るがGunicornで失敗 | パスワードに `$` が含まれている | パスワード変更または `$$` でエスケープ |
| `_mysql_connector.MySQLInterfaceError` が出る | `libmysqlclient` がない | `mysql-community-client` をインストール |

---

### エラー③: Caddyが起動しない、または `/api/*` が502になる

**原因:** Caddyfile の文法エラー、Gunicornが起動していない。

**対処法:**

```bash
caddy validate --config /etc/caddy/Caddyfile

# Gunicornのリッスン状況
ss -tlnp | grep 8000
```

---

### エラー③-2: Caddy COPRリポジトリ有効化で `Repository 'amazonlinux-2023-x86_64' does not exist`

**症状:**

```
Error: It wasn't possible to enable this project.
Repository 'amazonlinux-2023-x86_64' does not exist in project '@caddy/caddy'.
```

**原因:** COPR の `@caddy/caddy` プロジェクトに Amazon Linux 2023 向けのリポジトリが登録されていない。

**対処法:** Amazon Linux 2023 は RHEL 9 ベースなので、EPEL 9 向けのリポジトリを指定する。

```bash
dnf copr enable -y @caddy/caddy epel-9-x86_64
dnf install -y caddy
```

エラー出力にも対応するレポジトリ候補が一覧されるため、その中から最新のEPEL系を選ぶ。

---

### エラー④: stats画面で web1/web2 が赤(DOWN)

**原因:** Caddyが停止している、SGで80番が許可されていない。

**対処法:**

```bash
# 【lb.localで実施】HAProxyサーバから直接バックエンドへ接続できるか
curl http://<WEB1_PRI>/health
```

---

### エラー⑤: レプリケーションが `Replica_IO_Running: No`

**対処法:**

```sql
-- 【db2.localで実施】
SHOW REPLICA STATUS\G
-- Last_IO_Error の内容を確認
```

---

### エラー⑥: Let's Encrypt 証明書取得で `Failed authorization procedure`

**原因:** ドメインのAレコードが指していない、EC2再起動でパブリックIPが変わっている、SGで80番が外部に開いていない。

**対処法:**

```bash
dig +short <DOMAIN>
ss -tlnp | grep :80
```

---

### ログの確認場所

| ログの種類 | 場所(パス) | 確認コマンド |
|-----------|------------|------------|
| HAProxy | `journalctl -u haproxy` | `sudo journalctl -u haproxy -f` |
| Caddy | `journalctl -u caddy` | `sudo journalctl -u caddy -f` |
| Gunicorn | `/var/log/webapp_*.log` | `sudo tail -f /var/log/webapp_error.log` |
| MySQL | `/var/log/mysqld.log` | `sudo tail -f /var/log/mysqld.log` |
| Certbot | `/var/log/letsencrypt/letsencrypt.log` | `sudo tail -f /var/log/letsencrypt/letsencrypt.log` |

---

## 7. 参考リソース・関連資料

| 資料名 | URL | 補足 |
|-------|-----|------|
| HAProxy 公式 | https://docs.haproxy.org/ | 設定リファレンス |
| Caddy 公式 | https://caddyserver.com/docs/ | Caddyfile 構文 |
| Caddy reverse_proxy | https://caddyserver.com/docs/caddyfile/directives/reverse_proxy | プロキシ設定 |
| Flask 公式 | https://flask.palletsprojects.com/ | Webフレームワーク |
| Gunicorn 公式 | https://docs.gunicorn.org/ | WSGIサーバ |
| mysql-connector-python | https://dev.mysql.com/doc/connector-python/en/ | Python公式コネクタ |
| MySQL 8.0 リファレンス | https://dev.mysql.com/doc/refman/8.0/en/ | DB公式 |
| MySQL レプリケーション | https://dev.mysql.com/doc/refman/8.0/en/replication.html | レプリ章 |
| Certbot 公式 | https://eff-certbot.readthedocs.io/ | 各種モード解説 |

---

## 付録

### A. 環境変数・パラメータまとめ

| パラメータ名 | 自分の環境の値 | 説明 |
|------------|-------------|------|
| `<VPC_CIDR>` | `172.31.0.0/16` 等 | VPCのCIDR |
| `<VPC_PREFIX>` | `172.31.%.%` 等 | MySQLユーザのHost指定用パターン |
| `<HAPROXY_PUB>` | `xx.xx.xx.xx` | HAProxyのパブリックIP |
| `<HAPROXY_PRI>` | `xx.xx.xx.xx` | HAProxyのプライベートIP |
| `<WEB1_PRI>` | `xx.xx.xx.xx` | Web1のプライベートIP |
| `<WEB2_PRI>` | `xx.xx.xx.xx` | Web2のプライベートIP |
| `<DB1_PRI>` | `xx.xx.xx.xx` | MySQLマスタのプライベートIP |
| `<DB2_PRI>` | `xx.xx.xx.xx` | MySQLスレーブのプライベートIP |
| `<DOMAIN>` | `www.example.com` | 利用ドメイン |
| `<APP_PASS>` | `AppUserPass123` 等 | アプリ用MySQLユーザのパスワード(`$` 等特殊文字は避ける) |
| `<REPL_PASS>` | `ReplPass123` 等 | レプリケーション用ユーザのパスワード(同上) |

### B. 用語解説

| 用語 | 説明 |
|------|------|
| L7ロードバランサ | HTTPヘッダやURLなどアプリ層情報で振り分けるLB |
| リバースプロキシ | クライアントからの要求を受けて、内部のサーバに転送・応答を返す中継サーバ |
| WSGI | Web Server Gateway Interface。Python製Webアプリと Webサーバ間の標準インタフェース |
| Gunicorn | WSGI仕様に従う本番向けPython HTTPサーバ。プリフォーク方式 |
| Flask | Python製の軽量Webフレームワーク |
| コネクションプール | DB接続を使い回すための仕組み。接続生成のオーバーヘッドを削減 |
| Read/Write分離 | 書き込みをマスタに、読み込みをスレーブに振り分ける設計パターン |
| ラウンドロビン | リクエストを順番に均等振り分けする方式 |
| ヘルスチェック | バックエンドの生存をLBが定期的に確認する仕組み |
| GTID | Global Transaction Identifier。MySQLでトランザクションを一意に識別 |
| バイナリログ | MySQLが行うすべての変更操作を時系列で記録するログ |
| TLS終端 | HTTPS接続を解いて平文HTTPに変換する処理(通常LBで行う) |
| Let's Encrypt | 無料でTLS証明書を発行する認証局 |
| HTTP-01 チャレンジ | 80番のHTTP応答でドメイン所有を証明するACMEの方式 |

### C. 削除・クリーンアップ手順

1. Certbotのtimer停止: 【lb.localで実施】`systemctl disable --now certbot-renew.timer`
2. 各サーバでサービス停止: `systemctl stop haproxy / caddy / webapp / mysqld`
3. EC2インスタンスを5台とも終了する
4. セキュリティグループ・キーペアを削除

> **注意:** EBSボリュームやスナップショットが残ると課金されるため、EC2終了時に「ボリュームも一緒に削除」を選ぶこと。
