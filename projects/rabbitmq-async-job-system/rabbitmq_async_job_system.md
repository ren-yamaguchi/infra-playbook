# 【RabbitMQ + Gunicorn + PostgreSQL + Prometheus による非同期ジョブ基盤】環境構築手順書

---

## 1. ドキュメント情報

| 項目 | 内容 |
|------|------|
| 手順書名 | RabbitMQ + Gunicorn + PostgreSQL + Prometheus による非同期ジョブ基盤 |
| 作成日 | 2026-06-25 |
| バージョン | v1.3 |
| 対象環境 | AWS(EC2 / Amazon Linux 2023) |

> **改訂履歴**
>
> | バージョン | 日付 | 変更内容 |
> |-----------|------|---------|
> | v1.0 | 2026-06-25 | 初版作成 |
> | v1.1 | 2026-07-04 | 構築実施で判明した課題を反映(PostgreSQLコマンド名修正、rabbitmqadmin手順追加、EPEL注記追加、参照番号修正) |
> | v1.2 | 2026-07-04 | 2-4節(各MW役割解説)を新設 |
| v1.3 | 2026-07-06 | 構築実施で判明した修正を一括反映(PostgreSQLパッケージ・initコマンド・サービス名修正、バックアップコマンド追加、認証情報をプレースホルダー化) |

---

## 2. 目的・概要

### 2-1. 目的

> 本手順書では、**API + メッセージキュー(MQ) + Worker + DB** の4層構成で、非同期ジョブ処理基盤をAWS上に手動構築する。
>
> 学習の主眼は次の3点:
>
> - **メッセージキューによる疎結合**:APIはジョブを受け取ったら即座に応答を返し、重い処理は非同期にWorkerが行う、という典型パターンを体感する
> - **キューに溜まる性質を利用した耐障害性**:Workerが落ちていてもメッセージはMQに残り、Worker復旧後に自動で処理される
> - **ack/nack によるメッセージ配送制御**:処理失敗時の再配送、Dead Letter Exchange(DLX)による失敗メッセージ隔離

### 2-2. 構成概要(アーキテクチャ)

```
              [クライアント / curl]
                      |
                      | HTTP (POST /jobs, GET /jobs/<id>)
                      v
        +-----------------------------+
        | api.local                   |
        |  Nginx(80) → Gunicorn(8000) |
        |  Flask app                  |
        |   - publish to RabbitMQ     |
        |   - read result from DB     |
        +-----------------------------+
                      |
                      | AMQP (5672) publish
                      v
        +-----------------------------+
        | mq.local                    |
        |  RabbitMQ                   |
        |   - queue: jobs             |
        |   - queue: jobs.dlq (DLX)   |
        |   - 管理UI(15672)           |
        |   - Prometheusプラグイン     |
        |     (15692)                 |
        +-----------------------------+
                      |
                      | AMQP (5672) consume
                      v
        +-----------------------------+
        | worker.local                |
        |  Python consumer (systemd)  |
        |   - pika でジョブ取得        |
        |   - 結果をDBへ書き込み       |
        +-----------------------------+
                      |
                      | PostgreSQL (5432)
                      v
        +-----------------------------+
        | db.local                    |
        |  PostgreSQL                 |
        |   - jobs テーブル           |
        |  Prometheus(9090)           |
        |   - mq:15692 を scrape      |
        |   - 各サーバ:9100 を scrape  |
        +-----------------------------+

  node_exporter(9100) は全4台に導入
```

### 2-3. 完成イメージ(ゴール定義)

- [ ] `curl -X POST http://api.local/jobs -d '{"text":"hello"}'` で `job_id` が即座に返る
- [ ] 数秒後に `curl http://api.local/jobs/<job_id>` で `{"status":"done","result":"HELLO"}` が取れる
- [ ] Workerを停止した状態でジョブを投入すると、RabbitMQ管理UIでキュー長が増加するのが見える
- [ ] Worker復旧後、滞留したメッセージが自動で処理されDBに反映される
- [ ] Workerを2プロセス起動すると、ジョブが2つのWorkerにラウンドロビンで分配される
- [ ] 例外を投げるジョブは複数回再配送された後、DLQ(`jobs.dlq`)に隔離される
- [ ] PrometheusのWebUI(`http://db.local:9090`)で `rabbitmq_queue_messages` などのメトリクスが取得できる


### 2-4. 各ミドルウェアの役割と特徴

本構成で扱うミドルウェアについて、構築前に役割と特徴を整理しておく。手順を進める途中で「何をやっているのか」見失わないよう、まず全体像を頭に入れる。

#### 2-4-1. RabbitMQ(メッセージブローカー)

**役割:** アプリケーション間でメッセージを非同期に受け渡す「仲介役」。送り手(Publisher)はRabbitMQにメッセージを投入するだけで、受け手(Consumer)の存在や処理タイミングを気にする必要がない。

**既知のMWでいうと:** 「処理キュー」の概念に相当する。タスクスケジューラや非同期ジョブシステム(CronやSystemdのTimer)がジョブを順番に実行するのと似ているが、RabbitMQは「複数のWorkerに分散」「Workerが落ちていても失わない」「失敗したメッセージを別キューに隔離」といった仕組みを持つ。

**仕組みのイメージ:** Publisher → Exchange(振り分けルータ) → Queue(メッセージの待機場所) → Consumer という流れ。ExchangeとQueueを結ぶルールを Binding と呼び、この構成では routing_key で Jobs キューに届ける直接型(direct)のシンプルな構成を使う。

**この構成での役回り:** mq 上で常駐し、APIサーバ(api)がPOSTしたジョブを `jobs` キューで保持する。Workerが起動していない間もメッセージを保持し、Worker復旧後に自動で配送する。処理失敗したメッセージは DLX 経由で `jobs.dlq` に隔離する。

**学習ポイント:** pull型の配送モデル(WorkerがRabbitMQに繋ぎに行く)と、ack/nackによるメッセージ配送制御、DLX/DLQによる障害隔離パターンを体感する。

#### 2-4-2. pika(Python AMQPクライアントライブラリ)

**役割:** PythonアプリケーションからRabbitMQに接続し、メッセージの送信(publish)・受信(consume)を行うためのライブラリ。AMQPプロトコルの複雑な実装を隠蔽し、Pythonコードから数行でRabbitMQを操作できる。

**既知のMWでいうと:** psycopg2 が「PythonからPostgreSQLを操作するためのドライバ」であるように、pika は「PythonからRabbitMQを操作するためのクライアントライブラリ」。通信プロトコルはHTTPではなくAMQP(Advanced Message Queuing Protocol)を使う。

**この構成での役回り:** APIサーバの `publish_job()` とWorkerの `main()` の双方で使用する。APIは pika でジョブをキューに送信し、Workerは pika で `basic_consume` によりキューを購読して処理する。

**学習ポイント:** `basic_qos(prefetch_count=1)` によるバックプレッシャー制御と、`basic_ack` / `basic_nack` によるメッセージ配送制御を理解する。

#### 2-4-3. psycopg2(Python PostgreSQLアダプタ)

**役割:** PythonアプリケーションからPostgreSQLに接続し、SQLを実行するためのドライバライブラリ。APIサーバ(app.py)とWorker(worker.py)の双方で使用する。

**既知のMWでいうと:** pika が「RabbitMQへのクライアント」であるのと同様に、psycopg2 は「PostgreSQLへのクライアント」。DB-API 2.0 という Python の標準インターフェース仕様を実装しているため、`connection.cursor()` → `cursor.execute(SQL)` → `connection.commit()` という統一されたパターンで使える。

**この構成での役回り:** DBへのINSERT(api)とUPDATE(worker)の両方に使用する。`with conn, conn.cursor() as cur:` でコンテキストマネージャを使い、トランザクション管理と例外時のロールバックを簡潔に記述する。

**学習ポイント:** ソースビルド版(`psycopg2`)は `postgresql-devel` の開発ヘッダが必要。学習環境では `psycopg2-binary`(ビルド済みバイナリ版)を使う選択肢もあるが、本手順では仕組みを理解するためにソースビルドで進める。

---

## 3. 前提条件・準備

### 3-1. AWS環境(起動済み前提)

- AWSアカウントを保有していること
- VPCが作成されており、CIDRは `172.31.0.0/16` であること(異なる場合は手順中の該当箇所を読み替え)
- EC2インスタンスが **4台起動済み** であること(全台 Amazon Linux 2023、t2.micro または t3.micro 想定)
- 全EC2にSSHログインできること
- 各EC2には **パブリックIPが付与されている** こと

> **注意:EC2停止/起動でパブリックIPは変動する**
>
> 本手順では学習用にEIPを使わない。停止→起動するとパブリックIPが変わるので、手順書中の `<API_PUB>` 等は都度確認のこと。プライベートIPはインスタンスの存続中は変わらない。

### 3-2. 環境要件

#### 3-2-1. APIサーバ(api)

| 項目 | 要件 |
|------|------|
| インスタンスタイプ | t3.micro |
| OS | Amazon Linux 2023 |
| Webサーバ | Nginx(リバースプロキシ) |
| アプリサーバ | Gunicorn(Python WSGI) |
| アプリ | Flask + pika(AMQPクライアント) |
| 監視 | node_exporter |

#### 3-2-2. MQサーバ(mq)

| 項目 | 要件 |
|------|------|
| インスタンスタイプ | t3.small |
| OS | Amazon Linux 2023 |
| MQ | RabbitMQ(管理プラグイン + Prometheusプラグイン) |
| 監視 | node_exporter |

#### 3-2-3. Workerサーバ(worker)

| 項目 | 要件 |
|------|------|
| インスタンスタイプ | t3.micro |
| OS | Amazon Linux 2023 |
| アプリ | Python consumer + pika + psycopg2 |
| 起動方式 | systemd 常駐 |
| 監視 | node_exporter |

#### 3-2-4. DBサーバ(db)

| 項目 | 要件 |
|------|------|
| インスタンスタイプ | t3.micro |
| OS | Amazon Linux 2023 |
| RDBMS | PostgreSQL 15 |
| 監視 | Prometheus(サーバ本体)+ node_exporter |

### 3-3. セキュリティグループ設定

#### 3-3-1. api のSG

| タイプ | プロトコル | ポート | ソース | 目的 |
|---|---|---|---|---|
| SSH | TCP | 22 | マイIP | SSHログイン |
| HTTP | TCP | 80 | マイIP | 動作確認用Nginx |
| Custom TCP | TCP | 9100 | 172.31.0.0/16 | node_exporter を Prometheus から scrape |

#### 3-3-2. mq のSG

| タイプ | プロトコル | ポート | ソース | 目的 |
|---|---|---|---|---|
| SSH | TCP | 22 | マイIP | SSHログイン |
| Custom TCP | TCP | 5672 | 172.31.0.0/16 | AMQP(api/workerからの接続) |
| Custom TCP | TCP | 15672 | マイIP | RabbitMQ管理UI(ブラウザから) |
| Custom TCP | TCP | 15692 | 172.31.0.0/16 | Prometheusプラグイン scrape |
| Custom TCP | TCP | 9100 | 172.31.0.0/16 | node_exporter scrape |

#### 3-3-3. worker のSG

| タイプ | プロトコル | ポート | ソース | 目的 |
|---|---|---|---|---|
| SSH | TCP | 22 | マイIP | SSHログイン |
| Custom TCP | TCP | 9100 | 172.31.0.0/16 | node_exporter scrape |

> **解説:Workerはインバウンドに業務ポートを持たない**
>
> Workerは「自分からRabbitMQへ繋ぎに行く(pull型)」モデルなので、外部からの接続を受ける必要がない。これがMQ採用の運用上のメリットの一つで、Workerをスケールアウトしてもロードバランサが要らない。

#### 3-3-4. db のSG

| タイプ | プロトコル | ポート | ソース | 目的 |
|---|---|---|---|---|
| SSH | TCP | 22 | マイIP | SSHログイン |
| Custom TCP | TCP | 5432 | 172.31.0.0/16 | PostgreSQL(api/workerからの接続) |
| Custom TCP | TCP | 9090 | マイIP | Prometheus WebUI(ブラウザから) |
| Custom TCP | TCP | 9100 | 172.31.0.0/16 | node_exporter scrape |

### 3-4. パラメータ整理表

| パラメータ | 意味 | 自環境の値 |
|---|---|---|
| `<API_PUB>` | api のグローバルIP | |
| `<API_PRI>` | api のプライベートIP | |
| `<MQ_PUB>` | mq のグローバルIP | |
| `<MQ_PRI>` | mq のプライベートIP | |
| `<WORKER_PUB>` | worker のグローバルIP | |
| `<WORKER_PRI>` | worker のプライベートIP | |
| `<DB_PUB>` | db のグローバルIP | |
| `<DB_PRI>` | db のプライベートIP | |

### 3-5. ホスト名設計

| サーバ | ホスト名 |
|---|---|
| APIサーバ | `api.local` |
| MQサーバ | `mq.local` |
| Workerサーバ | `worker.local` |
| DBサーバ | `db.local` |

### 3-6. 認証情報・固定値

| 項目 | プレースホルダー | 説明 |
|---|---|---|
| RabbitMQ 業務ユーザー | `<MQ_USER>` | 任意の文字列 |
| RabbitMQ 業務ユーザーのパスワード | `<MQ_PASS>` | 任意の文字列 |
| RabbitMQ vhost | `/`(デフォルト) | 変更不要 |
| ジョブ用キュー名 | `<QUEUE_NAME>` | 任意の文字列(例: `jobs`) |
| DLQ(失敗ジョブ隔離キュー) | `<DLQ_NAME>` | 任意の文字列(例: `jobs.dlq`) |
| DLX(失敗時の転送先Exchange) | `<DLX_NAME>` | 任意の文字列(例: `jobs.dlx`) |
| PostgreSQL DB名 | `<DB_NAME>` | 任意の文字列 |
| PostgreSQL 業務ユーザー | `<DB_USER>` | 任意の文字列 |
| PostgreSQL 業務ユーザーのパスワード | `<DB_PASS>` | 任意の文字列 |

> **注意:学習用のシンプルなパスワード**
>
> 本手順では検証容易性のため簡易な値を使用している。実運用では強固なパスワードと、最小権限のロール分離が必要。

---

## 4. 構築手順

> **注意事項**
> - コマンド中の `<山カッコ>` は自分の環境の値に置き換えること
> - 各Stepの見出しに **実行サーバ** を明示している
> - エラーが出た場合は「6. トラブルシューティング」を参照

### 4-0. 環境構築の流れ

1. 全サーバ共通の初期設定(Step 0)
2. 全サーバのhosts設定(Step 1)
3. db: PostgreSQL構築(Step 2)
4. mq: RabbitMQ構築(Step 3)
5. worker: Worker構築(Step 4)
6. api: API構築(Step 5)
7. 全サーバ: node_exporter導入(Step 6)
8. db: Prometheus構築(Step 7)
9. 障害シミュレーション(Step 8)

---

### Step 0: 【全サーバで実施】システム初期設定

各サーバにSSHログインし、以下を実施する。`<HOSTNAME>` は各サーバの役割に応じて読み替える(`api.local` / `mq.local` / `worker.local` / `db.local`)。

```bash
sudo su -
dnf update -y
timedatectl set-timezone Asia/Tokyo
hostnamectl set-hostname <HOSTNAME>
```

設定反映のため一度ログアウトして再ログインしておくとプロンプトに新ホスト名が反映される。

---

### Step 1: 【全サーバで実施】hosts設定

各サーバ間をホスト名で参照できるよう、`/etc/hosts` に4台分のプライベートIPを書く。**全4台で同じ内容を設定する**。

```bash
vi /etc/hosts
```

末尾に追記:

```
<API_PRI>    api.local
<MQ_PRI>     mq.local
<WORKER_PRI> worker.local
<DB_PRI>     db.local
```

> **解説:なぜDNSではなく/etc/hostsか**
>
> 本案ではDNSの構築を主題に置いていないため、シンプルな `/etc/hosts` 方式を採用。BIND等のDNSは案10で扱う。

動作確認:

```bash
ping -c 1 db.local
ping -c 1 mq.local
```

---

### Step 2: 【db.localで実施】PostgreSQL構築

#### 2-1. PostgreSQLのインストール

Amazon Linux 2023標準リポジトリのPostgreSQL 15を使う。

```bash
dnf install -y postgresql15-server
```

> **注意:`postgresql15` は不要**
>
> `postgresql15`（クライアントライブラリ）は `postgresql15-server` の依存関係として自動でインストールされる。明示的に書く必要はない。

#### 2-2. データベース初期化

```bash
postgresql-setup --initdb
```

> **注意:Amazon Linux 2023 では `postgresql-setup` が正しいコマンド**
>
> ネット上の記事に `postgresql15-setup --initdb` と書いてあるものがあるが、Amazon Linux 2023 環境では `postgresql-setup --initdb` が正解。

#### 2-3. リモート接続の許可

編集前にバックアップを取る。

```bash
cp /var/lib/pgsql/data/postgresql.conf{,.org}
vi /var/lib/pgsql/data/postgresql.conf
```

以下の行を編集(コメントアウトを外し、値を変更):

```
listen_addresses = '*'
```

```bash
cp /var/lib/pgsql/data/pg_hba.conf{,.org}
vi /var/lib/pgsql/data/pg_hba.conf
```

末尾に追記:

```
# 業務サーバ(api, worker)からの接続を許可
host    <DB_NAME>    <DB_USER>    172.31.0.0/16    md5
```

> **解説:`md5` 認証を選んだ理由**
>
> Amazon Linux 2023 標準の PostgreSQL 15 では `scram-sha-256` がより推奨だが、本手順では学習目的で挙動が単純な `md5` を採用する。実運用では `scram-sha-256` が望ましい。

#### 2-4. PostgreSQL起動

```bash
systemctl start postgresql
systemctl enable postgresql
```

#### 2-5. DB・ユーザー・テーブル作成

```bash
sudo -u postgres psql
```

psqlプロンプト内で以下を実行:

```sql
CREATE DATABASE <DB_NAME>;
CREATE USER <DB_USER> WITH PASSWORD '<DB_PASS>';
GRANT ALL PRIVILEGES ON DATABASE <DB_NAME> TO <DB_USER>;
\c <DB_NAME>
GRANT ALL ON SCHEMA public TO <DB_USER>;

CREATE TABLE jobs (
    id          UUID PRIMARY KEY,
    text_input  TEXT NOT NULL,
    status      TEXT NOT NULL DEFAULT 'queued',
    result      TEXT,
    created_at  TIMESTAMP NOT NULL DEFAULT NOW(),
    updated_at  TIMESTAMP NOT NULL DEFAULT NOW()
);
GRANT ALL ON TABLE jobs TO <DB_USER>;
\q
```

> **考えるポイント:なぜAPI投入時点でDBにレコードを作るのか**
>
> 今回のフローでは「APIがジョブを受けた瞬間に status='queued' でDBにINSERTし、その後MQに publish する」設計にする。Worker は処理後に同じ id の行を `UPDATE jobs SET status='done', result=...` する。
>
> こうすることで、`GET /jobs/<id>` 時に「キューにあるのか、処理済みなのか」を **DBだけ見れば判断できる**。MQに直接問い合わせる必要がなく、状態管理がシンプルになる。

---

### Step 3: 【mq.localで実施】RabbitMQ構築

#### 3-1. リポジトリ追加とインストール

Amazon Linux 2023 標準リポジトリには RabbitMQ がないため、公式のリポジトリを追加する。

```bash
# Erlang と RabbitMQ の依存関係に必要
# EPEL 9 は RHEL 9 向けであり、Amazon Linux 2023 では公式にはサポートされていない。
# Cloudsmith リポジトリから直接 Erlang/RabbitMQ をインストールする場合は不要なことが多い。
# インストールに失敗する場合はこの行をスキップして試すこと。
dnf install -y https://dl.fedoraproject.org/pub/epel/epel-release-latest-9.noarch.rpm

# Cloudsmith 公式リポジトリを追加
cat > /etc/yum.repos.d/rabbitmq.repo <<'EOF'
[modern-erlang]
name=modern-erlang
baseurl=https://yum1.rabbitmq.com/erlang/el/9/$basearch
       https://yum2.rabbitmq.com/erlang/el/9/$basearch
repo_gpgcheck=1
enabled=1
gpgkey=https://github.com/rabbitmq/signing-keys/releases/download/3.0/cloudsmith.rabbitmq-erlang.E495BB49CC4BBE5B.key
gpgcheck=1
sslverify=1
sslcacert=/etc/pki/tls/certs/ca-bundle.crt

[rabbitmq-server]
name=rabbitmq-server
baseurl=https://yum1.rabbitmq.com/rabbitmq/el/9/$basearch
       https://yum2.rabbitmq.com/rabbitmq/el/9/$basearch
repo_gpgcheck=1
enabled=1
gpgkey=https://github.com/rabbitmq/signing-keys/releases/download/3.0/cloudsmith.rabbitmq-server.9F4587F226208342.key
gpgcheck=1
sslverify=1
sslcacert=/etc/pki/tls/certs/ca-bundle.crt
EOF

dnf install -y erlang rabbitmq-server
```

> **注意:RabbitMQ公式リポジトリのURLは変わることがある**
>
> 上記URLは2026年時点の例。インストールに失敗する場合は <https://www.rabbitmq.com/docs/install-rpm> を参照して最新の手順を確認する。

#### 3-2. 起動と自動起動設定

```bash
systemctl start rabbitmq-server
systemctl enable rabbitmq-server
systemctl status rabbitmq-server
```

#### 3-3. プラグイン有効化

管理UIとPrometheus連携プラグインを有効化する。

```bash
rabbitmq-plugins enable rabbitmq_management
rabbitmq-plugins enable rabbitmq_prometheus
```

> **解説:`rabbitmq_prometheus` プラグインの役割**
>
> RabbitMQはバージョン3.8以降、公式でPrometheus形式のメトリクスエンドポイントを内蔵している。プラグインを有効化するだけで `http://mq.local:15692/metrics` が公開される。
>
> 外部の `rabbitmq_exporter`(コミュニティ製)を別途立てる方式もあるが、公式プラグインが提供されている以上、こちらを使うのが今のスタンダード。

#### 3-3-1. rabbitmqadmin のインストール

`rabbitmqadmin` は RabbitMQ パッケージには同梱されておらず、管理プラグインの Web エンドポイントから別途ダウンロードする必要がある。

```bash
curl -O http://localhost:15672/cli/rabbitmqadmin
chmod +x rabbitmqadmin
mv rabbitmqadmin /usr/local/bin/
```

> **解説:`rabbitmqadmin` とは**
>
> `rabbitmqadmin` は RabbitMQ 管理プラグインが提供する Python 製の CLI ツール。キューや Exchange の作成・削除・メッセージの確認などをコマンドラインで行える。Step 3-5 以降のキュー作成で使用する。

#### 3-4. 業務ユーザー作成と権限付与

初期状態では `guest` ユーザーがあるが、localhostからしか接続できない仕様。業務用に別ユーザーを作る。

```bash
rabbitmqctl add_user <MQ_USER> <MQ_PASS>
rabbitmqctl set_user_tags <MQ_USER> management
rabbitmqctl set_permissions -p / <MQ_USER> ".*" ".*" ".*"
```

> **解説:set_user_tags の `management` の意味**
>
> このタグを付けると、管理UI(15672)にもこのユーザーでログインできるようになる。本番では `administrator` タグの濫用は避け、最小権限を意識する。

#### 3-5. DLX/DLQ/jobs キューの作成

RabbitMQでは「キューに送ったメッセージを処理失敗時にどこへ送るか」を **DLX(Dead Letter Exchange)** で指定する。失敗メッセージは DLX 経由で **DLQ(Dead Letter Queue)** に転送される。

```bash
# DLX(Dead Letter Exchange)を作成
rabbitmqadmin declare exchange name=<DLX_NAME> type=direct -u <MQ_USER> -p <MQ_PASS>

# DLQ(失敗メッセージ隔離用キュー)を作成
rabbitmqadmin declare queue name=<DLQ_NAME> durable=true -u <MQ_USER> -p <MQ_PASS>

# DLX と DLQ を bind(<DLX_NAME> に routing_key='<QUEUE_NAME>' で来たら <DLQ_NAME> へ)
rabbitmqadmin declare binding source=<DLX_NAME> destination=<DLQ_NAME> routing_key=<QUEUE_NAME> -u <MQ_USER> -p <MQ_PASS>

# 本体のキュー <QUEUE_NAME> を作成。DLXを設定しておく
rabbitmqadmin declare queue name=<QUEUE_NAME> durable=true \
  arguments='{"x-dead-letter-exchange":"<DLX_NAME>","x-dead-letter-routing-key":"<QUEUE_NAME>"}' \
  -u <MQ_USER> -p <MQ_PASS>
```

> **解説:DLX/DLQの仕組み**
>
> `jobs` キュー上のメッセージが以下のいずれかになると、自動的に `jobs.dlx` に再送される:
>
> - Consumer が `basic.nack(requeue=False)` で拒否した
> - メッセージのTTL(Time To Live)切れ
> - キューの最大長を超えた
>
> 本案では「Workerが例外を捕まえて nack(requeue=False) する」運用にする。`jobs.dlx` は `jobs.dlq` にバインドされているので、失敗メッセージは `jobs.dlq` に積み上がる。これを管理UIで眺めて運用者が再投入したり調査したりする、というのが定番の使い方。

#### 3-6. 確認

```bash
rabbitmqctl list_queues name messages
# <QUEUE_NAME>       0
# <DLQ_NAME>   0
```

管理UIをローカルPCのブラウザで開いて確認:

```
http://<MQ_PUB>:15672/
```

`<MQ_USER>` / `<MQ_PASS>` でログインし、Queues タブに `<QUEUE_NAME>` と `<DLQ_NAME>` が見えればOK。

---

### Step 4: 【worker.localで実施】Worker構築

#### 4-1. Python環境の準備

```bash
dnf install -y python3 python3-pip python3-devel gcc postgresql15-devel
pip3 install pika psycopg2
```

#### 4-2. Workerアプリの作成

```bash
mkdir -p /opt/worker
vi /opt/worker/worker.py
```

ファイル内容:

```python
#!/usr/bin/env python3
"""
RabbitMQ から jobs キューを consume し、
text を大文字化して PostgreSQL に書き込む Worker。
"""
import json
import os
import time
import traceback
import pika
import psycopg2

RABBIT_HOST = os.environ.get("RABBIT_HOST", "mq.local")
RABBIT_USER = os.environ.get("RABBIT_USER", "<MQ_USER>")
RABBIT_PASS = os.environ.get("RABBIT_PASS", "<MQ_PASS>")
DB_HOST     = os.environ.get("DB_HOST", "db.local")
DB_NAME     = os.environ.get("DB_NAME", "<DB_NAME>")
DB_USER     = os.environ.get("DB_USER", "<DB_USER>")
DB_PASS     = os.environ.get("DB_PASS", "<DB_PASS>")

def process_job(payload):
    """ジョブ本体。text を大文字化。'FAIL' を含むと例外を投げる(動作確認用)"""
    text = payload["text"]
    if "FAIL" in text:
        raise RuntimeError("intentional failure for DLQ test")
    time.sleep(3)  # 重い処理のシミュレーション
    return text.upper()

def update_db(job_id, status, result):
    conn = psycopg2.connect(
        host=DB_HOST, dbname=DB_NAME, user=DB_USER, password=DB_PASS
    )
    try:
        with conn, conn.cursor() as cur:
            cur.execute(
                "UPDATE jobs SET status=%s, result=%s, updated_at=NOW() WHERE id=%s",
                (status, result, job_id),
            )
    finally:
        conn.close()

def on_message(ch, method, properties, body):
    try:
        payload = json.loads(body)
        job_id = payload["job_id"]
        print(f"[worker] received job_id={job_id}", flush=True)
        result = process_job(payload)
        update_db(job_id, "done", result)
        ch.basic_ack(delivery_tag=method.delivery_tag)
        print(f"[worker] done job_id={job_id} result={result}", flush=True)
    except Exception as e:
        print(f"[worker] FAILED: {e}", flush=True)
        traceback.print_exc()
        # requeue=False で DLX に流す
        ch.basic_nack(delivery_tag=method.delivery_tag, requeue=False)

def main():
    creds = pika.PlainCredentials(RABBIT_USER, RABBIT_PASS)
    params = pika.ConnectionParameters(host=RABBIT_HOST, credentials=creds, heartbeat=60)
    conn = pika.BlockingConnection(params)
    ch = conn.channel()
    # prefetch=1: 一度に取りに行くのは1メッセージだけ(複数Worker時の公平分配)
    ch.basic_qos(prefetch_count=1)
    ch.basic_consume(queue="<QUEUE_NAME>", on_message_callback=on_message)
    print("[worker] waiting for messages...", flush=True)
    ch.start_consuming()

if __name__ == "__main__":
    main()
```

> **解説:`basic_qos(prefetch_count=1)` の意味**
>
> RabbitMQはデフォルトでは「接続しているConsumerにメッセージを次々と前送り」する挙動を取る。これを無制限にすると、片方のWorkerが大量に貯め込んだままになり、複数Workerでの公平分配が崩れる。
>
> `prefetch_count=1` にすると「ackするまで次のメッセージは渡さない」となり、複数Workerでの均等なジョブ分配が実現する。これはRabbitMQの「Work Queues」パターンの定番設定。

#### 4-3. systemdサービス化

```bash
vi /etc/systemd/system/worker.service
```

```ini
[Unit]
Description=Async Job Worker
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
Environment="RABBIT_HOST=mq.local"
Environment="RABBIT_USER=<MQ_USER>"
Environment="RABBIT_PASS=<MQ_PASS>"
Environment="DB_HOST=db.local"
Environment="DB_NAME=<DB_NAME>"
Environment="DB_USER=<DB_USER>"
Environment="DB_PASS=<DB_PASS>"
ExecStart=/usr/bin/python3 /opt/worker/worker.py
Restart=on-failure
RestartSec=5
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
```

> **解説:Environment= による接続情報の注入**
>
> アプリのソースコードに認証情報を直接書かず、systemd経由で環境変数として渡す。これは案1でも採用した方式で、本番ではこの上に AWS Secrets Manager や HashiCorp Vault を被せていく。

#### 4-4. 起動

```bash
systemctl daemon-reload
systemctl start worker
systemctl enable worker
systemctl status worker
journalctl -u worker -f
```

ログに `[worker] waiting for messages...` が出ればOK。Ctrl+Cでログ表示を抜ける(サービスは止まらない)。

---

### Step 5: 【api.localで実施】API構築

#### 5-1. Python・Nginxのインストール

```bash
dnf install -y python3 python3-pip python3-devel gcc postgresql15-devel nginx
pip3 install flask gunicorn pika psycopg2
```

#### 5-2. Flaskアプリの作成

```bash
mkdir -p /opt/api
vi /opt/api/app.py
```

```python
#!/usr/bin/env python3
"""
ジョブ投入API。
- POST /jobs : ジョブをDBに登録(status=queued)し、RabbitMQに publish
- GET  /jobs/<id> : DBから状態を返す
"""
import json
import os
import uuid
import pika
import psycopg2
from flask import Flask, request, jsonify, abort

RABBIT_HOST = os.environ.get("RABBIT_HOST", "mq.local")
RABBIT_USER = os.environ.get("RABBIT_USER", "<MQ_USER>")
RABBIT_PASS = os.environ.get("RABBIT_PASS", "<MQ_PASS>")
DB_HOST     = os.environ.get("DB_HOST", "db.local")
DB_NAME     = os.environ.get("DB_NAME", "<DB_NAME>")
DB_USER     = os.environ.get("DB_USER", "<DB_USER>")
DB_PASS     = os.environ.get("DB_PASS", "<DB_PASS>")

app = Flask(__name__)

def db_conn():
    return psycopg2.connect(
        host=DB_HOST, dbname=DB_NAME, user=DB_USER, password=DB_PASS
    )

def publish_job(job_id, text):
    creds = pika.PlainCredentials(RABBIT_USER, RABBIT_PASS)
    params = pika.ConnectionParameters(host=RABBIT_HOST, credentials=creds)
    conn = pika.BlockingConnection(params)
    try:
        ch = conn.channel()
        body = json.dumps({"job_id": job_id, "text": text})
        ch.basic_publish(
            exchange="",
            routing_key="jobs",
            body=body,
            properties=pika.BasicProperties(delivery_mode=2),  # 永続化
        )
    finally:
        conn.close()

@app.post("/jobs")
def create_job():
    payload = request.get_json(force=True)
    text = payload.get("text")
    if not text:
        abort(400, "text is required")
    job_id = str(uuid.uuid4())
    # DBに先にINSERT
    conn = db_conn()
    try:
        with conn, conn.cursor() as cur:
            cur.execute(
                "INSERT INTO jobs(id, text_input, status) VALUES (%s, %s, 'queued')",
                (job_id, text),
            )
    finally:
        conn.close()
    # 次にMQへpublish
    publish_job(job_id, text)
    return jsonify({"job_id": job_id, "status": "queued"}), 202

@app.get("/jobs/<job_id>")
def get_job(job_id):
    conn = db_conn()
    try:
        with conn, conn.cursor() as cur:
            cur.execute(
                "SELECT id, text_input, status, result FROM jobs WHERE id=%s",
                (job_id,),
            )
            row = cur.fetchone()
    finally:
        conn.close()
    if not row:
        abort(404)
    return jsonify({
        "job_id": row[0],
        "text_input": row[1],
        "status": row[2],
        "result": row[3],
    })

if __name__ == "__main__":
    app.run(host="127.0.0.1", port=8000)
```

> **考えるポイント:DB INSERT → MQ publish の順序**
>
> 本アプリは「先にDBにINSERT(status=queued)してから、MQに publish」する。逆順(MQ publish → DB INSERT)にすると、publish直後にAPIが落ちた場合、Workerが取り出した時点でDBに対応行がなく `UPDATE` が0行hitになる。
>
> 厳密には「DB INSERT 後、MQ publish 直前に落ちた」場合に「DBには queued があるがMQには存在しない迷子」が生まれる。これを完全に防ぐには Outbox パターン等を組むが、本手順のスコープ外とする。

#### 5-3. Gunicorn の systemd サービス化

```bash
vi /etc/systemd/system/gunicorn.service
```

```ini
[Unit]
Description=Gunicorn for API
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
WorkingDirectory=/opt/api
Environment="RABBIT_HOST=mq.local"
Environment="RABBIT_USER=<MQ_USER>"
Environment="RABBIT_PASS=<MQ_PASS>"
Environment="DB_HOST=db.local"
Environment="DB_NAME=<DB_NAME>"
Environment="DB_USER=<DB_USER>"
Environment="DB_PASS=<DB_PASS>"
ExecStart=/usr/local/bin/gunicorn -w 2 -b 127.0.0.1:8000 app:app
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
```

```bash
systemctl daemon-reload
systemctl start gunicorn
systemctl enable gunicorn
systemctl status gunicorn
```

#### 5-4. Nginx のリバースプロキシ設定

```bash
vi /etc/nginx/conf.d/api.conf
```

```nginx
server {
    listen 80 default_server;
    server_name api.local;

    location / {
        proxy_pass http://127.0.0.1:8000;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_read_timeout 30s;
    }
}
```

デフォルトの `/etc/nginx/nginx.conf` 内の `server { ... }` ブロックは無効化(コメントアウト)するか、`/etc/nginx/conf.d/api.conf` の方を優先させる(同じ80番portでlistenしてエラーになる)。

```bash
vi /etc/nginx/nginx.conf
# 「server {」から対応する「}」までをコメントアウト
```

```bash
nginx -t
systemctl start nginx
systemctl enable nginx
```

#### 5-5. 動作確認

api 上で:

```bash
curl -X POST -H "Content-Type: application/json" \
     -d '{"text":"hello"}' http://localhost/jobs
# {"job_id":"xxxxxxxx-xxxx-...","status":"queued"}
```

数秒後:

```bash
curl http://localhost/jobs/<job_id>
# {"job_id":"...","result":"HELLO","status":"done","text_input":"hello"}
```

---

### Step 6: 【全サーバで実施】node_exporter導入

各サーバ(api / mq / worker / db)で同じ手順を実施する。

#### 6-1. ダウンロードと配置

```bash
cd /tmp
curl -LO https://github.com/prometheus/node_exporter/releases/download/v1.8.2/node_exporter-1.8.2.linux-amd64.tar.gz
tar zxf node_exporter-1.8.2.linux-amd64.tar.gz
cp node_exporter-1.8.2.linux-amd64/node_exporter /usr/local/bin/
useradd -r -s /sbin/nologin nodeexp
```

#### 6-2. systemd サービス化

```bash
vi /etc/systemd/system/node_exporter.service
```

```ini
[Unit]
Description=Node Exporter
After=network-online.target

[Service]
User=nodeexp
ExecStart=/usr/local/bin/node_exporter
Restart=on-failure

[Install]
WantedBy=multi-user.target
```

```bash
systemctl daemon-reload
systemctl start node_exporter
systemctl enable node_exporter
curl -s http://localhost:9100/metrics | head -5
```

---

### Step 7: 【db.localで実施】Prometheus構築

#### 7-1. ダウンロードと配置

```bash
cd /tmp
curl -LO https://github.com/prometheus/prometheus/releases/download/v2.54.1/prometheus-2.54.1.linux-amd64.tar.gz
tar zxf prometheus-2.54.1.linux-amd64.tar.gz
mkdir -p /opt/prometheus /var/lib/prometheus
cp prometheus-2.54.1.linux-amd64/prometheus /usr/local/bin/
cp prometheus-2.54.1.linux-amd64/promtool /usr/local/bin/
cp -r prometheus-2.54.1.linux-amd64/consoles /opt/prometheus/
cp -r prometheus-2.54.1.linux-amd64/console_libraries /opt/prometheus/
useradd -r -s /sbin/nologin prom
chown -R prom:prom /var/lib/prometheus /opt/prometheus
```

#### 7-2. 設定ファイル

```bash
vi /opt/prometheus/prometheus.yml
```

```yaml
global:
  scrape_interval: 15s

scrape_configs:
  - job_name: 'prometheus'
    static_configs:
      - targets: ['localhost:9090']

  - job_name: 'node'
    static_configs:
      - targets:
          - 'api.local:9100'
          - 'mq.local:9100'
          - 'worker.local:9100'
          - 'db.local:9100'

  - job_name: 'rabbitmq'
    static_configs:
      - targets: ['mq.local:15692']
```

```bash
chown prom:prom /opt/prometheus/prometheus.yml
```

#### 7-3. systemd サービス化

```bash
vi /etc/systemd/system/prometheus.service
```

```ini
[Unit]
Description=Prometheus
After=network-online.target

[Service]
User=prom
ExecStart=/usr/local/bin/prometheus \
  --config.file=/opt/prometheus/prometheus.yml \
  --storage.tsdb.path=/var/lib/prometheus \
  --web.console.templates=/opt/prometheus/consoles \
  --web.console.libraries=/opt/prometheus/console_libraries
Restart=on-failure

[Install]
WantedBy=multi-user.target
```

```bash
systemctl daemon-reload
systemctl start prometheus
systemctl enable prometheus
systemctl status prometheus
```

#### 7-4. 動作確認

ローカルPCのブラウザで:

```
http://<DB_PUB>:9090/targets
```

`node`(4台分)と `rabbitmq`(1台)が全て `UP` になっていればOK。

Graphタブで以下のクエリを試す:

- `rabbitmq_queue_messages` … キュー内の現在メッセージ数
- `rabbitmq_queue_messages_published_total` … publish 累計
- `rabbitmq_queue_messages_delivered_total` … consume 累計
- `node_load1` … 各サーバのロードアベレージ

---

### Step 8: 障害シミュレーション

ここからは「動かしながら学ぶ」フェーズ。RabbitMQ管理UI(`http://<MQ_PUB>:15672/`)と Prometheus(`http://<DB_PUB>:9090/`)を別タブで開きながら進める。

#### 8-1. シナリオA: Worker停止中のメッセージ滞留

workerで:

```bash
systemctl stop worker
```

apiで連続投入:

```bash
for i in 1 2 3 4 5; do
  curl -s -X POST -H "Content-Type: application/json" \
       -d "{\"text\":\"msg-$i\"}" http://localhost/jobs
  echo
done
```

mqで確認:

```bash
rabbitmqctl list_queues name messages
# jobs    5
```

PrometheusのGraphで `rabbitmq_queue_messages{queue="<QUEUE_NAME>"}` を見ると、値が0から5にジャンプしているのが確認できる。

workerでWorkerを再起動:

```bash
systemctl start worker
journalctl -u worker -f
```

ログに5件分の処理が流れる。`rabbitmqctl list_queues name messages` でjobsは0に戻る。

> **解説:これがメッセージキューの本質**
>
> 「処理する側が落ちていても、メッセージは失われずに溜まっておく」。これがMQ採用の最大のメリット。同期API同士の直接連携では成立しない、疎結合・耐障害性の典型例。

#### 8-2. シナリオB: Workerを2プロセス並列化

worker上で、systemdのWorkerを起動したまま、もう1つWorkerを手動起動する。

```bash
# 別ターミナルで worker にログインし、環境変数を手動で設定して直接起動
RABBIT_HOST=mq.local RABBIT_USER=<MQ_USER> RABBIT_PASS=<MQ_PASS> \
DB_HOST=db.local DB_NAME=<DB_NAME> DB_USER=<DB_USER> DB_PASS=<DB_PASS> \
python3 /opt/worker/worker.py
```

apiで10件連続投入:

```bash
for i in $(seq 1 10); do
  curl -s -X POST -H "Content-Type: application/json" \
       -d "{\"text\":\"para-$i\"}" http://localhost/jobs > /dev/null &
done
wait
```

`journalctl -u worker -f`(1個目)と、手動起動のWorkerのstdout(2個目)を見比べると、ジョブが**だいたい半分ずつ**分配されているのが見える。

> **解説:`prefetch_count=1` の効果**
>
> Step 4 で設定した `basic_qos(prefetch_count=1)` のおかげで、2プロセスが交互にジョブを取りに行く挙動になる。これが Work Queues パターン。
>
> もし `prefetch_count` を10にしてしまうと、片方のWorkerが10件まとめて確保し、もう片方は待機、ということになりがち。

確認後、手動起動のWorkerは Ctrl+C で停止する。

#### 8-3. シナリオC: DLQ(失敗ジョブ隔離)

apiで `FAIL` という文字列を含むジョブを投入:

```bash
curl -X POST -H "Content-Type: application/json" \
     -d '{"text":"this will FAIL"}' http://localhost/jobs
```

workerの `journalctl -u worker -f` を見ると `FAILED: intentional failure...` と `basic_nack` が走る。

mqで確認:

```bash
rabbitmqctl list_queues name messages
# <QUEUE_NAME>        0
# <DLQ_NAME>    1
```

管理UI(`http://<MQ_PUB>:15672/`)の Queues タブで `<DLQ_NAME>` が 1 件持っているのが見える。
クリックして "Get Messages" で本体を覗くと、元のJSONがそのまま入っている。

> **解説:DLQに溜まったメッセージの扱い**
>
> 本手順では「DLQに溜める」までで、自動再投入は組まない。運用では:
>
> - 監視で `rabbitmq_queue_messages{queue="<DLQ_NAME>"} > 0` をアラート化
> - 運用者が原因調査して、修正後に手動で `jobs` キューに戻す
>
> ような流れにする。「失敗を隠さず、明示的に別キューに分離する」のがDLXパターンのコア思想。

#### 8-4. シナリオD: Prometheusでメトリクス推移を観察

`http://<DB_PUB>:9090/graph` で以下を試す:

```promql
# 直近5分間の publish レート(件/秒)
rate(rabbitmq_queue_messages_published_total{queue="<QUEUE_NAME>"}[5m])

# 直近5分間の deliver レート
rate(rabbitmq_queue_messages_delivered_total{queue="<QUEUE_NAME>"}[5m])

# 現在のキュー長
rabbitmq_queue_messages{queue="<QUEUE_NAME>"}

# DLQに溜まっている件数
rabbitmq_queue_messages{queue="<DLQ_NAME>"}
```

シナリオA(Worker停止)中の時間帯を見ると、publish レートは上がっているが、deliver レートはほぼ0になっており、キュー長が増加していることがグラフで確認できる。

> **考えるポイント:この見え方が「監視のあるべき姿」**
>
> 「APIは正常に200を返している」「Workerプロセスも生きている(stopしていないつもり)」のような表面的な指標だけでは、ジョブの処理遅延を捉えられない。
>
> queue depth(キュー長)の継続増加は、まさに「裏側で何かが詰まっている」ことを示す**第一級の異常シグナル**。MQベースの非同期処理では、この指標を必ず監視に組み込む。

---

## 5. 動作確認・検証

### 5-1. 確認チェックリスト

- [ ] **確認①**: API経由でジョブ投入 → DBに `done` 状態で結果が書かれる
- [ ] **確認②**: Worker停止 → ジョブ投入 → キューに滞留 → Worker復旧で自動処理
- [ ] **確認③**: Worker 2プロセス起動 → ジョブが分配される
- [ ] **確認④**: `FAIL` を含むジョブ → DLQ に隔離される
- [ ] **確認⑤**: Prometheus で `rabbitmq_queue_messages` が取得できる
- [ ] **確認⑥**: Prometheus で 4台分の `node_load1` が取得できる

### 5-2. 主要検証コマンド集

```bash
# (api) ジョブ投入
curl -X POST -H "Content-Type: application/json" \
     -d '{"text":"hello"}' http://localhost/jobs

# (api) ジョブ状態確認
curl http://localhost/jobs/<job_id>

# (mq) キュー状態
rabbitmqctl list_queues name messages consumers
rabbitmqctl list_consumers

# (db) DB状態
sudo -u postgres psql -d <DB_NAME> -c "SELECT id, status, result FROM jobs ORDER BY created_at DESC LIMIT 10;"

# (db) Prometheus targets
curl -s http://localhost:9090/api/v1/targets | python3 -m json.tool | grep health
```

---

## 6. トラブルシューティング

### エラー①: apiからRabbitMQに繋がらない

**症状:** `curl /jobs` が500エラー、Gunicornログに `pika.exceptions.AMQPConnectionError`。

**対処:**

```bash
# apiで疎通確認
nc -zv mq.local 5672
# Connection refused → SG確認 or rabbitmq-server status
nc -zv mq.local 5672
# timed out → SGで 5672 が 172.31.0.0/16 に許可されているか確認

# mqで
systemctl status rabbitmq-server
rabbitmqctl list_users
# <MQ_USER> がいない → 3-4 のユーザー作成を再実行
```

---

### エラー②: Workerが起動直後に終了する

**症状:** `systemctl status worker` で `Active: failed`、`journalctl -u worker` に `psycopg2.OperationalError` や `pika.exceptions.ProbableAuthenticationError`。

**対処:**

- `Environment=` の値が正しいか確認(Workerの `/etc/systemd/system/worker.service`)
- dbの `pg_hba.conf` に `172.31.0.0/16` の `md5` 行があるか
- mqで `rabbitmqctl list_user_permissions <MQ_USER>` で `.* .* .*` が出るか

---

### エラー③: 管理UIにログインできない

**症状:** `http://<MQ_PUB>:15672/` を開いても「Login failed」。

**対処:**

```bash
# mqで
rabbitmq-plugins list | grep management
# management が "[E*]" なら有効
rabbitmqctl set_user_tags <MQ_USER> management
```

---

### エラー④: Prometheus の targets が DOWN

**症状:** `http://<DB_PUB>:9090/targets` で `rabbitmq` や `node` の一部が DOWN。

**対処:**

```bash
# dbで実際に叩いてみる
curl -s http://mq.local:15692/metrics | head -3
curl -s http://api.local:9100/metrics | head -3
# 繋がらない → SGで 15692 / 9100 が 172.31.0.0/16 に許可されているか
# 繋がる → node_exporter / rabbitmq_prometheus プラグインのプロセス確認
```

---

### エラー⑤: ジョブがDBに反映されない

**症状:** `GET /jobs/<id>` で `status` がいつまでも `queued` のまま。

**対処:**

```bash
# (mq) キューに溜まっていないか
rabbitmqctl list_queues name messages consumers
# messages > 0 で consumers = 0 → Workerが繋がっていない
# messages = 0 で consumers >= 1 → DB側で詰まっている可能性

# (worker) Workerログ
journalctl -u worker -n 50
```

---

### 6-2. ログ確認場所

| ログ | 場所 |
|---|---|
| Worker | `journalctl -u worker` |
| Gunicorn(api) | `journalctl -u gunicorn` |
| Nginx | `/var/log/nginx/access.log`, `error.log` |
| RabbitMQ | `journalctl -u rabbitmq-server`, `/var/log/rabbitmq/` |
| PostgreSQL | `/var/lib/pgsql/data/log/` |
| Prometheus | `journalctl -u prometheus` |

---

## 7. 参考リソース

| 資料名 | URL |
|---|---|
| RabbitMQ 公式チュートリアル(Work Queues) | https://www.rabbitmq.com/tutorials/tutorial-two-python |
| RabbitMQ Dead Letter Exchange | https://www.rabbitmq.com/docs/dlx |
| RabbitMQ Prometheus | https://www.rabbitmq.com/docs/prometheus |
| pika ドキュメント | https://pika.readthedocs.io/ |
| Prometheus 公式 | https://prometheus.io/docs/ |
| node_exporter | https://github.com/prometheus/node_exporter |
| Flask 公式 | https://flask.palletsprojects.com/ |
| Gunicorn 公式 | https://docs.gunicorn.org/ |

---

## 付録

### A. 環境変数・パラメータまとめ

| パラメータ | 自環境の値 | 説明 |
|---|---|---|
| `<API_PRI>` | | apiのプライベートIP |
| `<API_PUB>` | | apiのグローバルIP |
| `<MQ_PRI>` | | mqのプライベートIP |
| `<MQ_PUB>` | | mqのグローバルIP |
| `<WORKER_PRI>` | | workerのプライベートIP |
| `<DB_PRI>` | | dbのプライベートIP |
| `<DB_PUB>` | | dbのグローバルIP(Prometheus UI) |

### B. 用語解説

| 用語 | 説明 |
|---|---|
| AMQP | RabbitMQが実装するメッセージプロトコル(Advanced Message Queuing Protocol) |
| Exchange | RabbitMQでメッセージを受け取り、ルーティングルールに従いキューに振り分ける部品 |
| Queue | メッセージが実際に溜まる場所 |
| Binding | ExchangeとQueueの紐付けルール |
| Routing Key | publish時に指定する文字列。Exchangeのルーティング判断に使われる |
| ack | Consumerが「正常処理完了」をRabbitMQに伝える応答 |
| nack | Consumerが「処理失敗」をRabbitMQに伝える応答(requeueの可否を指定可能) |
| prefetch_count | 1つのConsumer