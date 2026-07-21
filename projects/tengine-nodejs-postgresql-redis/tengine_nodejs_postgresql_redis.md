# 【案2: Node.jsアプリの本番風配信基盤(Tengine + Node.js/pm2 + PostgreSQL + Redis)】環境構築手順書

---

## 1. ドキュメント情報

| 項目 | 内容 |
|------|------|
| 手順書名 | Node.jsアプリの本番風配信基盤(Tengine + Node.js/pm2 + PostgreSQL + Redis) |
| 作成日 | 2026-06-25 |
| バージョン | v1.0 |
| 対象環境 | AWS |
| 想定工数 | 1.5日 |

> **改訂履歴**
>
> | バージョン | 日付 | 変更内容 |
> |-----------|------|---------|
> | v1.0 | 2026-06-25 | 初版作成 |

---

## 2. 目的・概要

### 2-1. 目的

本手順書では、Node.js で書かれた Web アプリケーションを「本番風」の構成で配信する基盤を、4台のEC2を用いて構築する。具体的には以下のミドルウェアの組み合わせを学ぶ。

- **Tengine**: Nginx 互換のフロントサーバ。upstream のヘルスチェックを標準モジュール(`ngx_http_upstream_check_module`)だけで実現できるのが特徴
- **Node.js + pm2**: アプリケーションサーバ。pm2 のクラスタモードで CPU コア数ぶんプロセスを起動し、プロセス監視・自動再起動を行う
- **PostgreSQL**: 永続データ(items テーブル)の格納先
- **Redis**: セッションストアおよび API レスポンスのキャッシュ

「Redis を落とすとセッションは消えるがデータは生きている」「PostgreSQL を落とすとデータ API は止まるが、キャッシュ済みレスポンスは返せる」といった**役割分担の違いを実機で体感する**ことが学習上のゴールである。

### 2-2. 構成概要(アーキテクチャ)

```
                  【外部クライアント(ブラウザ/curl)】
                              ↓ HTTPS (443)
            ┌────────────────────────────────────┐
            │ Tengine (front.local)              │
            │ ・TLS終端(自己署名証明書)         │
            │ ・upstream ヘルスチェック(check)   │
            │ ・静的ファイル配信(/)             │
            │ ・/api/* → app.local:3000 へプロキシ│
            └────────────────────┬───────────────┘
                                 ↓ HTTP (3000)
            ┌────────────────────────────────────┐
            │ Node.js + pm2 (app.local)          │
            │ ・Express                          │
            │ ・pm2 cluster mode(CPUコア数)    │
            │ ・connect-redis でセッション保存   │
            │ ・pg で PostgreSQL 接続            │
            └──────────┬──────────────┬──────────┘
                       ↓              ↓
            ┌──────────────┐  ┌──────────────────┐
            │ PostgreSQL    │  │ Redis             │
            │ (db.local)    │  │ (cache.local)     │
            │ 永続データ    │  │ セッション+キャッシュ│
            └──────────────┘  └──────────────────┘
```

### 2-3. 完成イメージ(ゴール定義)

- [ ] ブラウザまたは curl で `https://<FRONT_PUB>/` にアクセスすると、Tengine が配信する静的トップページが表示される
- [ ] `POST /api/login` でセッション Cookie が発行され、Redis にセッション情報が保存されている
- [ ] `POST /api/items` で送信したデータが PostgreSQL に保存される
- [ ] `GET /api/items` が1回目はDBから、2回目以降30秒間はRedisキャッシュから応答される(レスポンスヘッダで判別)
- [ ] `pm2 list` で Node.js プロセスが CPU コア数ぶん起動している
- [ ] Node.js プロセスを `kill` しても pm2 が自動再起動する
- [ ] Redis を停止するとセッションが失われるが、items API はDB直アクセスで動作継続する
- [ ] PostgreSQL を停止すると items の書込・新規読込は失敗するが、キャッシュヒット中のレスポンスは返る
- [ ] Tengine の upstream ヘルスチェック画面(`/status`)で app の状態が確認できる

---

## 3. 前提条件・準備

### 3-1. AWS環境(起動済み前提)

以下が完了している前提とする:

- AWSアカウントを保有していること
- VPCが作成されており、CIDRは `172.31.0.0/16` であること(異なる場合は手順中の該当箇所を読み替え)
- EC2インスタンスが **4台起動済み** であること(全台 Amazon Linux 2023、全台パブリックサブネット配置)
- 各EC2にはパブリックIPが付与されており、SSHログインできること
- インスタンスタイプは t3.small 以上を推奨(特に app サーバは pm2 でマルチプロセス起動するため)

> **注意:本構成のパブリックIPについて**
>
> 学習用途のため全EC2をパブリックサブネットに配置し、通常のパブリックIPを使用する。EC2を停止/起動するとパブリックIPが変動する点に注意。実務では、外部公開するサーバには EIP を付与し、内部サーバはプライベートサブネットに配置するのが一般的。

### 3-2. 環境要件

#### 3-2-1. front サーバ

| 項目 | 要件 |
|------|------|
| OS | Amazon Linux 2023 |
| ミドルウェア | Tengine(ソースからビルド) |
| 必要ツール | gcc, make, pcre-devel, openssl-devel, zlib-devel(ビルド用) |
| TLS証明書 | 自己署名証明書(OpenSSL で生成) |

#### 3-2-2. app サーバ

| 項目 | 要件 |
|------|------|
| OS | Amazon Linux 2023 |
| ミドルウェア | Node.js 20.x, pm2 |
| 必要ツール | npm |
| アプリ依存 | express, pg, redis, connect-redis, express-session |

#### 3-2-3. db サーバ

| 項目 | 要件 |
|------|------|
| OS | Amazon Linux 2023 |
| ミドルウェア | PostgreSQL 15 |

#### 3-2-4. cache サーバ

| 項目 | 要件 |
|------|------|
| OS | Amazon Linux 2023 |
| ミドルウェア | Redis |

### 3-3. セキュリティグループ設定

#### 3-3-1. front サーバ

| タイプ | プロトコル | ポート | ソース | 目的 |
|---|---|---|---|---|
| SSH | TCP | 22 | マイIP | SSHログイン |
| HTTP | TCP | 80 | 0.0.0.0/0 | HTTPS リダイレクト用 |
| HTTPS | TCP | 443 | 0.0.0.0/0 | 外部からのHTTPS受付 |

#### 3-3-2. app サーバ

| タイプ | プロトコル | ポート | ソース | 目的 |
|---|---|---|---|---|
| SSH | TCP | 22 | マイIP | SSHログイン |
| カスタムTCP | TCP | 3000 | 172.31.0.0/16 | front からのプロキシ受付 |

> **解説:app サーバの 3000 番を VPC 内に限定する理由**
>
> Node.js アプリは Tengine 経由でのみアクセスされるべきで、外部から直接 3000 番にアクセスされると、TLS終端を経由しない平文通信になってしまう。SG レベルで「外部からは届かない」と明示することで、設計の意図がセキュリティ層にも反映される。

#### 3-3-3. db サーバ

| タイプ | プロトコル | ポート | ソース | 目的 |
|---|---|---|---|---|
| SSH | TCP | 22 | マイIP | SSHログイン |
| PostgreSQL | TCP | 5432 | 172.31.0.0/16 | app からの接続受付 |

#### 3-3-4. cache サーバ

| タイプ | プロトコル | ポート | ソース | 目的 |
|---|---|---|---|---|
| SSH | TCP | 22 | マイIP | SSHログイン |
| Redis | TCP | 6379 | 172.31.0.0/16 | app からの接続受付 |

> **注意:Redis を VPC 内に公開する場合の本番考慮事項**
>
> 本手順書では学習目的でVPC内全許可・パスワードのみの認証としている。本番ではTLS化(stunnel または Redis 6.x の TLS対応)、ACL(Redis 6.x の細粒度ユーザ機能)、そして可能ならプライベートサブネット配置が望ましい。

### 3-4. パラメータ整理表

| パラメータ | 意味 | 自環境の値 |
|---|---|---|
| `<FRONT_PUB>` | front サーバのグローバルIP | |
| `<FRONT_PRI>` | front サーバのプライベートIP | |
| `<APP_PRI>` | app サーバのプライベートIP | |
| `<DB_PRI>` | db サーバのプライベートIP | |
| `<CACHE_PRI>` | cache サーバのプライベートIP | |
| `<DB_PASSWORD>` | PostgreSQL ユーザ `appuser` のパスワード | |
| `<REDIS_PASSWORD>` | Redis 接続パスワード | |
| `<SESSION_SECRET>` | express-session の署名キー(ランダム文字列) | |

### 3-5. ホスト名設計

| サーバ | ホスト名 |
|---|---|
| front | `front.local` |
| app | `app.local` |
| db | `db.local` |
| cache | `cache.local` |

> **解説:名前解決は /etc/hosts で行う**
>
> 本構成では DNS サーバを別途立てず、各サーバの `/etc/hosts` に4台分のエントリを書く方針とする。サーバ台数が少なく、構成変更も少ない学習用途では十分。実務でサーバ数が増えるなら、内部DNSやサービスディスカバリの仕組みを導入する。

---

## 4. 構築手順(詳細)

### 4-1. 環境構築の流れ

1. 全サーバ共通の初期設定 (Step 0)
2. db サーバ(PostgreSQL)の構築 (Step 1)
3. cache サーバ(Redis)の構築 (Step 2)
4. app サーバ(Node.js + pm2)の構築 (Step 3)
5. front サーバ(Tengine ソースビルド + TLS)の構築 (Step 4)
6. アプリ動作確認 (Step 5)
7. 障害シミュレーション (Step 6)

---

### Step 0: 全サーバ共通の初期設定

**目的:** 全4台で共通の初期化作業を行う。**4台すべてで実施**する。

#### 0-1. 【全サーバで実施】基本初期化

```bash
sudo su -
dnf update -y
timedatectl set-timezone Asia/Tokyo
```

ホスト名は各サーバごとに以下のように設定:

```bash
# front サーバ
hostnamectl set-hostname front.local

# app サーバ
hostnamectl set-hostname app.local

# db サーバ
hostnamectl set-hostname db.local

# cache サーバ
hostnamectl set-hostname cache.local
```

#### 0-2. 【全サーバで実施】/etc/hosts の設定

```bash
vi /etc/hosts
```

末尾に以下を追記(全サーバ共通):

```
<FRONT_PRI>  front.local
<APP_PRI>    app.local
<DB_PRI>     db.local
<CACHE_PRI>  cache.local
```

> **解説:プライベートIPを使う理由**
>
> サーバ間通信は VPC 内ルーティングで完結するため、プライベートIPを使うのが基本。グローバルIPで指定するとパケットが一度 VPC 外に出る経路扱いになり、無駄な料金や遅延が発生する可能性がある。

#### 0-3. 【全サーバで実施】疎通確認

```bash
ping -c 2 front.local
ping -c 2 app.local
ping -c 2 db.local
ping -c 2 cache.local
```

---

### Step 1: db サーバ(PostgreSQL)の構築

**目的:** アプリケーションが使う永続データ用の PostgreSQL を構築する。**db.local で実施**する。

#### 1-1. 【db.localで実施】PostgreSQL のインストール

```bash
dnf install -y postgresql15-server postgresql15
```

#### 1-2. 【db.localで実施】データベースの初期化

```bash
/usr/bin/postgresql-setup --initdb
```

#### 1-3. 【db.localで実施】外部接続を許可する設定

```bash
vi /var/lib/pgsql/data/postgresql.conf
```

以下を変更:

```
listen_addresses = '*'
```

```bash
vi /var/lib/pgsql/data/pg_hba.conf
```

末尾に以下を追記:

```
host    appdb    appuser    172.31.0.0/16    md5
```

> **解説:pg_hba.conf の意味**
>
> PostgreSQL のクライアント認証ルールは `pg_hba.conf` で定義される。書式は「種類 DB ユーザ 送信元 認証方式」。上記は「VPC 内から、appdb データベースに対して、appuser ユーザがパスワード(MD5)認証で接続することを許可する」という意味。
>
> 本番では `scram-sha-256` を推奨。`md5` は古い方式だが、学習用途で広く解説されているため本書では `md5` を使用する。

#### 1-4. 【db.localで実施】PostgreSQL の起動

```bash
systemctl start postgresql
systemctl enable postgresql
systemctl status postgresql
```

#### 1-5. 【db.localで実施】DBとユーザの作成

```bash
sudo -iu postgres psql
```

psql プロンプトで:

```sql
CREATE USER appuser WITH PASSWORD '<DB_PASSWORD>';
CREATE DATABASE appdb OWNER appuser;
\c appdb
CREATE TABLE items (
    id SERIAL PRIMARY KEY,
    name VARCHAR(100) NOT NULL,
    description TEXT,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);
GRANT ALL PRIVILEGES ON TABLE items TO appuser;
GRANT USAGE, SELECT ON SEQUENCE items_id_seq TO appuser;
INSERT INTO items (name, description) VALUES ('first item', 'sample row');
\q
```

> **解説:SEQUENCE への権限も必要**
>
> `SERIAL` 型はバックグラウンドでシーケンスオブジェクトを作る。`INSERT` で自動採番する場合、テーブルへの権限とは別にシーケンスへの `USAGE, SELECT` 権限が必要になる。これを忘れると `INSERT` 時に "permission denied for sequence" エラーが出る。よくハマるポイント。

#### 1-6. 【db.localで実施】動作確認

```bash
psql -h 127.0.0.1 -U appuser -d appdb -c "SELECT * FROM items;"
# パスワードを聞かれるので <DB_PASSWORD> を入力
# first item の行が表示されればOK
```

---

### Step 2: cache サーバ(Redis)の構築

**目的:** セッションストアおよびAPIキャッシュ用の Redis を構築する。**cache.local で実施**する。

#### 2-1. 【cache.localで実施】Redis のインストール

```bash
dnf install -y redis6
```

#### 2-2. 【cache.localで実施】Redis の設定

```bash
vi /etc/redis6/redis6.conf
```

以下を変更:

```
# 外部からの接続を受け付ける
bind 0.0.0.0

# 保護モードを無効化(SGで制限するため)
protected-mode no

# パスワード認証を有効化
requirepass <REDIS_PASSWORD>
```

> **解説:protected-mode の意味**
>
> Redis 3.2 以降に追加された機能で、「bind が 0.0.0.0 かつ requirepass 未設定」のときに外部接続を自動拒否する安全装置。本構成では requirepass を設定するので無効化してよい(設定しないと SG で許可しても Redis 自身が接続を弾く)。
>
> 本番ではTLS化や bind を特定IPに絞るなど、もう一段の防御を入れること。

#### 2-3. 【cache.localで実施】Redis の起動

```bash
systemctl start redis6
systemctl enable redis6
systemctl status redis6
```

#### 2-4. 【cache.localで実施】動作確認

```bash
redis6-cli -a '<REDIS_PASSWORD>' ping
# PONG が返ればOK

redis6-cli -a '<REDIS_PASSWORD>' SET hello world
redis6-cli -a '<REDIS_PASSWORD>' GET hello
# "world" が返ればOK
```

---

### Step 3: app サーバ(Node.js + pm2)の構築

**目的:** Express で書かれた Web API を pm2 のクラスタモードで常駐させる。**app.local で実施**する。

#### 3-1. 【app.localで実施】Node.js のインストール

```bash
# NodeSource リポジトリから Node.js 20.x を導入
curl -fsSL https://rpm.nodesource.com/setup_20.x | bash -
dnf install -y nodejs
node --version
npm --version
```

#### 3-2. 【app.localで実施】アプリ用ユーザの作成

```bash
useradd -m -s /bin/bash appuser
```

> **解説:アプリ専用ユーザを作る理由**
>
> Web アプリは root 権限で動かさない。万一アプリに脆弱性があっても被害範囲を限定するため。pm2 もこのユーザで実行する。

#### 3-3. 【app.localで実施】アプリディレクトリと依存パッケージ

```bash
mkdir -p /opt/app
chown appuser:appuser /opt/app

sudo -iu appuser
cd /opt/app

npm init -y
npm install express pg redis connect-redis express-session
```

#### 3-4. 【app.localで実施】アプリ本体の作成

引き続き appuser で:

```bash
vi /opt/app/app.js
```

以下の内容を貼り付け:

```javascript
const express = require('express');
const session = require('express-session');
const { RedisStore } = require('connect-redis');
const { createClient } = require('redis');
const { Pool } = require('pg');

const app = express();
app.use(express.json());

// --- Redis クライアント ---
const redisClient = createClient({
    socket: {
        host: process.env.REDIS_HOST,
        port: 6379
    },
    password: process.env.REDIS_PASSWORD
});
redisClient.on('error', (err) => console.error('Redis error:', err.message));
redisClient.connect().catch((err) => console.error('Redis connect error:', err.message));

// --- セッション(Redis保存) ---
app.use(session({
    store: new RedisStore({ client: redisClient, prefix: 'sess:' }),
    secret: process.env.SESSION_SECRET,
    resave: false,
    saveUninitialized: false,
    cookie: { maxAge: 1000 * 60 * 30 }  // 30分
}));

// --- PostgreSQL プール ---
const pgPool = new Pool({
    host: process.env.PG_HOST,
    port: 5432,
    user: process.env.PG_USER,
    password: process.env.PG_PASSWORD,
    database: process.env.PG_DATABASE
});

// --- ルーティング ---

// ログイン(セッション作成)
app.post('/api/login', (req, res) => {
    const { username } = req.body;
    if (!username) return res.status(400).json({ error: 'username required' });
    req.session.username = username;
    res.json({ message: 'logged in', username });
});

// 自分の情報
app.get('/api/me', (req, res) => {
    if (!req.session.username) return res.status(401).json({ error: 'not logged in' });
    res.json({ username: req.session.username, pid: process.pid });
});

// items 一覧(Redisで30秒キャッシュ)
app.get('/api/items', async (req, res) => {
    const cacheKey = 'items:all';
    try {
        const cached = await redisClient.get(cacheKey);
        if (cached) {
            res.set('X-Cache', 'HIT');
            return res.json(JSON.parse(cached));
        }
    } catch (err) {
        console.error('Redis GET error:', err.message);
    }

    try {
        const result = await pgPool.query('SELECT * FROM items ORDER BY id');
        const data = result.rows;
        try {
            await redisClient.set(cacheKey, JSON.stringify(data), { EX: 30 });
        } catch (err) {
            console.error('Redis SET error:', err.message);
        }
        res.set('X-Cache', 'MISS');
        res.json(data);
    } catch (err) {
        res.status(500).json({ error: 'db error: ' + err.message });
    }
});

// item 追加(要ログイン)
app.post('/api/items', async (req, res) => {
    if (!req.session.username) return res.status(401).json({ error: 'not logged in' });
    const { name, description } = req.body;
    if (!name) return res.status(400).json({ error: 'name required' });
    try {
        const result = await pgPool.query(
            'INSERT INTO items (name, description) VALUES ($1, $2) RETURNING *',
            [name, description || '']
        );
        // キャッシュ無効化
        try { await redisClient.del('items:all'); } catch (e) {}
        res.json(result.rows[0]);
    } catch (err) {
        res.status(500).json({ error: 'db error: ' + err.message });
    }
});

// item 個別取得
app.get('/api/items/:id', async (req, res) => {
    try {
        const result = await pgPool.query('SELECT * FROM items WHERE id = $1', [req.params.id]);
        if (result.rows.length === 0) return res.status(404).json({ error: 'not found' });
        res.json(result.rows[0]);
    } catch (err) {
        res.status(500).json({ error: 'db error: ' + err.message });
    }
});

// ヘルスチェック(Tengineの check モジュール用)
app.get('/healthz', (req, res) => res.send('ok'));

const PORT = process.env.PORT || 3000;
app.listen(PORT, () => {
    console.log(`app listening on ${PORT}, pid=${process.pid}`);
});
```

> **解説:`X-Cache` レスポンスヘッダ**
>
> キャッシュヒットだったかDB直アクセスだったかをクライアントが判別できるようにする慣習的なヘッダ。本手順書の動作確認・障害シミュレーションで「キャッシュが効いているか」を可視化するために使う。CloudFront など本物の CDN でも同種のヘッダ(`X-Cache: Hit from cloudfront`)が返る。

> **解説:`/healthz` エンドポイント**
>
> Tengine の check モジュールから定期的に叩かれる軽量なヘルスチェック用エンドポイント。DB接続などは見ずに「プロセスが生きていれば 200」を返す。これにより「アプリは生きているが、DBが死んでいる」状態と「アプリ自体が死んでいる」状態を別レイヤで検知できる。

#### 3-5. 【app.localで実施】pm2 のインストール(rootで)

```bash
exit  # appuser から root に戻る
npm install -g pm2
pm2 --version
```

#### 3-6. 【app.localで実施】ecosystem.config.js の作成

```bash
sudo -iu appuser
vi /opt/app/ecosystem.config.js
```

```javascript
module.exports = {
    apps: [{
        name: 'app',
        script: '/opt/app/app.js',
        instances: 'max',          // CPUコア数ぶん起動
        exec_mode: 'cluster',      // クラスタモード
        env: {
            NODE_ENV: 'production',
            PORT: 3000,
            PG_HOST: 'db.local',
            PG_USER: 'appuser',
            PG_PASSWORD: '<DB_PASSWORD>',
            PG_DATABASE: 'appdb',
            REDIS_HOST: 'cache.local',
            REDIS_PASSWORD: '<REDIS_PASSWORD>',
            SESSION_SECRET: '<SESSION_SECRET>'
        }
    }]
};
```

> **解説:`instances: 'max'` と `exec_mode: 'cluster'`**
>
> pm2 のクラスタモードは Node.js の cluster モジュールをラップしたもの。プロセスを CPU コア数ぶん起動し、同一ポートで待ち受けるプロセス群にOSがロードバランスする。Node.js はシングルスレッドなので、マルチコアを活かすにはこの仕組みが必須。
>
> `/api/me` のレスポンスで `pid` を返すようにしているので、何度かアクセスしてどのプロセスが応答しているか確認できる。

> **注意:認証情報を ecosystem.config.js に直書きしている件**
>
> 学習目的のため簡略化しているが、本番では環境変数を別ファイル(`.env`)に切り出して `.gitignore` に入れる、または AWS Secrets Manager / Parameter Store から取得するのが定石。

#### 3-7. 【app.localで実施】アプリの起動

appuser のままで:

```bash
cd /opt/app
pm2 start ecosystem.config.js
pm2 list
# app が online で複数プロセス起動していればOK

pm2 logs --lines 20
# "app listening on 3000, pid=..." がコア数ぶん出ていることを確認
```

#### 3-8. 【app.localで実施】pm2 を systemd 登録

`exit` で root に戻ってから:

```bash
exit
# root で実行
pm2 startup systemd -u appuser --hp /home/appuser
# 出力されたコマンドをそのまま実行する(pm2 が生成する systemctl コマンド)

# appuser に戻って現在の状態を保存
sudo -iu appuser pm2 save
```

#### 3-9. 【app.localで実施】app サーバ上での動作確認

```bash
curl http://localhost:3000/healthz
# "ok" が返ればOK

curl http://localhost:3000/api/items
# itemsの内容がJSONで返ればOK
```

---

### Step 4: front サーバ(Tengine + TLS)の構築

**目的:** Tengine をソースからビルドし、TLS終端と upstream ヘルスチェック付きのリバースプロキシを構築する。**front.local で実施**する。

#### 4-1. 【front.localで実施】ビルド用ツールのインストール

```bash
dnf install -y gcc make pcre-devel openssl-devel zlib-devel wget tar
```

#### 4-2. 【front.localで実施】Tengine ソースの取得とビルド

```bash
cd /usr/local/src
wget https://tengine.taobao.org/download/tengine-3.1.0.tar.gz
tar xzf tengine-3.1.0.tar.gz
cd tengine-3.1.0

./configure \
    --prefix=/usr/local/tengine \
    --with-http_ssl_module \
    --with-http_stub_status_module \
    --with-http_upstream_check_module \
    --with-stream

make
make install
```

> **解説:`--with-http_upstream_check_module` がポイント**
>
> このモジュールこそ Tengine の代表的な特徴。標準の Nginx ではこの相当機能を使うには nginx-plus(有償)または別途サードパーティモジュールのコンパイルが必要だが、Tengine では公式モジュールとしてバンドルされている。
>
> 設定ファイル内で `check interval=3000 rise=2 fall=3 timeout=1000 type=http;` のように書くだけでアクティブヘルスチェックができ、`/status` 画面で結果を可視化できる。

> **注意:本番で Tengine をビルドする場合**
>
> 本手順書ではビルド成果物を `/usr/local/tengine` 配下にそのまま置いているが、本番では rpm パッケージ化(`fpm` ツール等)してデプロイ管理しやすくするのが一般的。

#### 4-3. 【front.localで実施】Tengine 実行ユーザの作成

```bash
useradd -r -s /sbin/nologin nginx
```

#### 4-4. 【front.localで実施】自己署名TLS証明書の生成

```bash
mkdir -p /usr/local/tengine/conf/ssl
cd /usr/local/tengine/conf/ssl

openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
    -keyout server.key -out server.crt \
    -subj "/C=JP/ST=Tokyo/L=Tokyo/O=Learning/CN=front.local"

chmod 600 server.key
```

> **注意:自己署名証明書のブラウザ警告**
>
> 自己署名証明書は認証局による署名がないため、ブラウザでアクセスすると「この接続ではプライバシーが保護されません」という警告が出る。学習用途では「詳細設定」→「アクセスする」で先に進めばよい。
>
> 本番では Let's Encrypt(案1で使用した Certbot)や AWS Certificate Manager (ACM) を使うこと。

#### 4-5. 【front.localで実施】静的コンテンツの配置

```bash
mkdir -p /usr/local/tengine/html
cat > /usr/local/tengine/html/index.html <<'EOF'
<!DOCTYPE html>
<html lang="ja">
<head>
<meta charset="utf-8">
<title>Node.js App Front</title>
</head>
<body>
<h1>Welcome to the Node.js App Front (Tengine)</h1>
<p>API endpoints:</p>
<ul>
<li>POST /api/login</li>
<li>GET /api/me</li>
<li>GET /api/items</li>
<li>POST /api/items</li>
</ul>
</body>
</html>
EOF
```

#### 4-6. 【front.localで実施】nginx.conf の編集

```bash
vi /usr/local/tengine/conf/nginx.conf
```

ファイル全体を以下で置き換え:

```nginx
user nginx;
worker_processes auto;
error_log logs/error.log;
pid logs/nginx.pid;

events {
    worker_connections 1024;
}

http {
    include       mime.types;
    default_type  application/octet-stream;
    sendfile      on;
    keepalive_timeout 65;

    # === upstream: app サーバ群 ===
    upstream app_backend {
        server app.local:3000;
        # Tengine独自のアクティブヘルスチェック
        check interval=3000 rise=2 fall=3 timeout=1000 type=http;
        check_http_send "GET /healthz HTTP/1.0\r\n\r\n";
        check_http_expect_alive http_2xx http_3xx;
    }

    # === HTTP → HTTPS リダイレクト ===
    server {
        listen 80;
        server_name _;
        return 301 https://$host$request_uri;
    }

    # === HTTPS 本体 ===
    server {
        listen 443 ssl;
        server_name front.local;

        ssl_certificate     ssl/server.crt;
        ssl_certificate_key ssl/server.key;
        ssl_protocols       TLSv1.2 TLSv1.3;

        # 静的トップページ
        location / {
            root   html;
            index  index.html;
        }

        # API はバックエンドへプロキシ
        location /api/ {
            proxy_pass         http://app_backend;
            proxy_set_header   Host              $host;
            proxy_set_header   X-Real-IP         $remote_addr;
            proxy_set_header   X-Forwarded-For   $proxy_add_x_forwarded_for;
            proxy_set_header   X-Forwarded-Proto $scheme;
        }

        # upstream check の状態確認画面
        location /status {
            check_status;
            access_log off;
            allow 172.31.0.0/16;
            allow 127.0.0.1;
            deny all;
        }
    }
}
```

> **解説:`check_http_send` と `check_http_expect_alive`**
>
> `check_http_send` でヘルスチェック時に投げるHTTPリクエストを定義し、`check_http_expect_alive` でどのステータスコードを「生きている」と判定するかを定義する。今回は app の `/healthz` を叩いて 2xx/3xx なら生存と判定する。
>
> もし app プロセスが死んでも Tengine 側で 3秒間隔のヘルスチェックで気付き、upstream から外す。配信側の障害検知ロジックを設定ファイルだけで完結できるのが Tengine の強み。

> **解説:`/status` を VPC 内に限定**
>
> upstream の状態が外部から丸見えだと「どのバックエンドが落ちているか」が攻撃者に伝わるので、`/status` は VPC 内・localhost のみに制限する。

#### 4-7. 【front.localで実施】systemd ユニットの作成

```bash
vi /etc/systemd/system/tengine.service
```

```ini
[Unit]
Description=Tengine HTTP Server
After=network.target

[Service]
Type=forking
PIDFile=/usr/local/tengine/logs/nginx.pid
ExecStartPre=/usr/local/tengine/sbin/nginx -t
ExecStart=/usr/local/tengine/sbin/nginx
ExecReload=/usr/local/tengine/sbin/nginx -s reload
ExecStop=/usr/local/tengine/sbin/nginx -s quit
PrivateTmp=true

[Install]
WantedBy=multi-user.target
```

#### 4-8. 【front.localで実施】Tengine の起動

```bash
systemctl daemon-reload
systemctl start tengine
systemctl status tengine
systemctl enable tengine
```

#### 4-9. 【front.localで実施】front サーバ上での動作確認

```bash
curl -k https://localhost/
# index.html の内容が返ればOK

curl -k https://localhost/api/items
# itemsの内容がJSONで返ればOK

curl http://127.0.0.1/status?format=json
# upstream check の状態がJSONで返ればOK
```

---

### Step 5: アプリ動作確認

**目的:** 外部からの一連の操作が想定通り動くことを確認する。

#### 5-1. 【ローカルPCで実施】外部からのHTTPS接続確認

```bash
# ブラウザでアクセスする場合
# https://<FRONT_PUB>/  ← トップページが表示される(証明書警告は許可)

# curl でアクセスする場合
curl -k https://<FRONT_PUB>/
```

#### 5-2. 【ローカルPCで実施】API動作確認(セッションあり)

```bash
# Cookieを保存しながらログイン
curl -k -c cookie.txt -X POST https://<FRONT_PUB>/api/login \
    -H "Content-Type: application/json" \
    -d '{"username":"alice"}'
# {"message":"logged in","username":"alice"} が返ればOK

# セッション確認
curl -k -b cookie.txt https://<FRONT_PUB>/api/me
# {"username":"alice","pid":<どれかのpid>} が返ればOK

# 何度か叩いて pid が変動することを確認(pm2 クラスタによる分散)
for i in 1 2 3 4 5; do
    curl -k -b cookie.txt -s https://<FRONT_PUB>/api/me
    echo
done
```

#### 5-3. 【ローカルPCで実施】キャッシュ動作確認

```bash
# 1回目: X-Cache: MISS が返る
curl -k -i https://<FRONT_PUB>/api/items | grep -E "X-Cache|HTTP"

# 2回目以降(30秒以内): X-Cache: HIT が返る
curl -k -i https://<FRONT_PUB>/api/items | grep -E "X-Cache|HTTP"
```

#### 5-4. 【ローカルPCで実施】データ書き込み確認

```bash
curl -k -b cookie.txt -X POST https://<FRONT_PUB>/api/items \
    -H "Content-Type: application/json" \
    -d '{"name":"second item","description":"added via API"}'

# キャッシュ無効化されているので、再取得は MISS → DBから新データ取得
curl -k -i https://<FRONT_PUB>/api/items | grep -E "X-Cache|HTTP"
```

#### 5-5. 【cache.localで実施】Redisにセッションが保存されていることを確認

```bash
redis6-cli -a '<REDIS_PASSWORD>' KEYS 'sess:*'
# sess:<セッションID> のキーが見えればOK

redis6-cli -a '<REDIS_PASSWORD>' KEYS 'items:*'
# items:all のキーが見えればOK(30秒で消える)
```

---

### Step 6: 障害シミュレーション

**目的:** 各ミドルウェアの役割の違いを「停止したときに何が起きるか」で体感する。

> **考えるポイント:学習のメインイベント**
>
> ここからが本手順書の山場。それぞれのミドルウェアが「何を担っているのか」は、止めてみて初めて実感できる。期待される挙動を予想してから実行すると学びが深い。

#### 6-1. シミュレーション①: Node.jsプロセスを kill する

**期待挙動:** pm2 が即座に新プロセスを立ち上げる(無停止に近い)。

```bash
# app.local で
pm2 list
# 複数の app プロセスとそれぞれの pid を確認

# どれか1つのプロセスを kill(pid は環境による)
kill -9 <どれかのpid>

# 直後に確認
pm2 list
# restart の数字が増え、新しいプロセスが online になっているはず
```

クライアント側から `/api/items` を叩き続けても、ユーザからはほぼ気付かれない。

#### 6-2. シミュレーション②: Redis を停止する

**期待挙動:**
- ログインセッションが切れる(セッションストアが失われる)
- `/api/items` のキャッシュは効かなくなるが、DBから取得して応答は返る

```bash
# cache.local で
systemctl stop redis6
```

クライアント側で:

```bash
# セッション確認 → 401 not logged in になるはず
curl -k -b cookie.txt https://<FRONT_PUB>/api/me

# items 一覧 → MISS で返るが、内容は取得できる
curl -k -i https://<FRONT_PUB>/api/items | grep -E "X-Cache|HTTP"
# X-Cache ヘッダ自体出なくなる場合あり(Redisエラーで set がスキップされるため)
```

app.local の pm2 ログを見るとRedis接続エラーが流れている:

```bash
pm2 logs --lines 30
```

#### 6-3. 復旧

```bash
# cache.local で
systemctl start redis6
```

クライアントで再ログインすれば元通り。

#### 6-4. シミュレーション③: PostgreSQL を停止する

**期待挙動:**
- 書き込みAPI(`POST /api/items`)はDBエラー
- 読み取りAPI(`GET /api/items`)は、キャッシュヒット中なら成功・キャッシュ切れたらDBエラー

事前に1回 `/api/items` を叩いてキャッシュを温めておく:

```bash
curl -k https://<FRONT_PUB>/api/items > /dev/null
```

PostgreSQL を停止:

```bash
# db.local で
systemctl stop postgresql
```

すぐに `/api/items` を叩く:

```bash
# 30秒以内なら X-Cache: HIT で成功
curl -k -i https://<FRONT_PUB>/api/items | grep -E "X-Cache|HTTP"

# 30秒以上待つと X-Cache: MISS の試みで500エラー
sleep 35
curl -k -i https://<FRONT_PUB>/api/items
```

> **考えるポイント:この実験で見えること**
>
> 「Redis が落ちても items は返るが、PostgreSQL が落ちると(キャッシュ切れ後は)返らない」── これがミドルウェアごとの責務の違いを最も雄弁に語る。
>
> 実務では「重要データはDBに、揮発してよいキャッシュやセッションは Redis に」という設計原則が、こうした性質に基づいていることを実感できるはず。

#### 6-5. 復旧

```bash
# db.local で
systemctl start postgresql
```

#### 6-6. シミュレーション④: app サーバを完全停止して check モジュールを観察

**期待挙動:** Tengine のヘルスチェックが3秒間隔で動いており、3回連続失敗で upstream から外れる。`/status` 画面に反映される。

```bash
# app.local で
pm2 stop all
```

front サーバから10秒ほど待って状態確認:

```bash
# front.local で
sleep 10
curl http://127.0.0.1/status?format=json
# server の status が "down" になっているはず
```

復旧:

```bash
# app.local で
pm2 start all
```

10秒後、再度 status を確認 → "up" に戻る。

---

## 5. 動作確認・検証

### 5-1. 確認チェックリスト

- [ ] 4台すべてで `hostnamectl` 結果が想定通り
- [ ] 全サーバから `ping app.local` 等で名前解決と疎通ができる
- [ ] db.local で `psql` ログインし items テーブルが SELECT できる
- [ ] cache.local で `redis6-cli ping` が PONG を返す
- [ ] app.local で `pm2 list` が複数の online プロセスを表示
- [ ] front.local で `curl -k https://localhost/` が成功
- [ ] 外部から `https://<FRONT_PUB>/` でトップページが見える
- [ ] ログイン → /api/me → /api/items の一連のフローが動く
- [ ] `X-Cache: MISS` → `X-Cache: HIT` の切り替わりが観測できる
- [ ] `/status` 画面で upstream の状態が見える
- [ ] Step 6 の障害シミュレーション 4種類がすべて期待通りに動く

---

## 6. トラブルシューティング

#### エラー①: app.local で Redis に接続できない

**症状:** pm2 logs に `Redis error: getaddrinfo ENOTFOUND cache.local` 等。

**対処法:**

```bash
# app.local で
ping cache.local
# 失敗するなら /etc/hosts の cache.local 行を確認

# 到達するが接続失敗する場合
nc -zv cache.local 6379
# 失敗するなら cache 側のSGや bind 設定を確認
```

#### エラー②: app.local で PostgreSQL に接続できない

**症状:** `/api/items` で `db error: password authentication failed` 等。

**対処法:**

```bash
# db.local で
sudo -iu postgres psql -c "\du"
# appuser が存在するか確認

# pg_hba.conf の内容を確認
cat /var/lib/pgsql/data/pg_hba.conf | grep appuser

# 設定変更したのに反映されていない場合は再読込
systemctl reload postgresql
```

#### エラー③: Tengine の `make` で OpenSSL 関連エラー

**症状:** `error: openssl/ssl.h: No such file or directory`

**対処法:**

```bash
# 必要な開発パッケージ不足の可能性
dnf install -y openssl-devel pcre-devel zlib-devel
# 再度 make を実行
```

#### エラー④: ブラウザで「証明書が無効」と表示される

**症状:** 自己署名証明書のため。

**対処法:** 学習用途では「詳細設定」から進む。本番では Let's Encrypt や ACM を使用すること。

#### エラー⑤: `/status` が 403 で見られない

**症状:** Tengine の status 画面が "403 Forbidden"。

**対処法:** `nginx.conf` の `allow` ディレクティブに自分のアクセス元IPが含まれているか確認。外部から見たい場合は一時的に `allow all;` にして検証(検証後は戻す)。

#### エラー⑥: pm2 startup で生成されたコマンドが分からない

**症状:** `pm2 startup systemd ...` 実行後、出力が流れて見落とした。

**対処法:**

```bash
# もう一度実行すれば再度出力される
pm2 startup systemd -u appuser --hp /home/appuser
# 表示された "sudo env PATH=..." の行をコピーして実行
```

### ログの確認場所

| ログの種類 | 場所 |
|---|---|
| Tengine アクセスログ | `/usr/local/tengine/logs/access.log` |
| Tengine エラーログ | `/usr/local/tengine/logs/error.log` |
| Node.js (pm2) ログ | `pm2 logs` または `/home/appuser/.pm2/logs/` |
| PostgreSQL ログ | `/var/lib/pgsql/data/log/` |
| Redis ログ | `journalctl -u redis6` |
| systemd 全般 | `journalctl -u <unit名>` |

---

## 7. 参考リソース・関連資料

| 資料名 | URL |
|---|---|
| Tengine 公式 | https://tengine.taobao.org/ |
| Tengine upstream check module | https://tengine.taobao.org/document/http_upstream_check.html |
| Node.js 公式 | https://nodejs.org/ |
| pm2 公式 | https://pm2.keymetrics.io/ |
| Express 公式 | https://expressjs.com/ |
| connect-redis | https://github.com/tj/connect-redis |
| PostgreSQL 公式 | https://www.postgresql.org/docs/ |
| Redis 公式 | https://redis.io/docs/ |

---

## 付録

### A. 環境変数・パラメータまとめ

| パラメータ | 説明 |
|---|---|
| `<FRONT_PUB>` | front サーバのグローバルIP(外部アクセス) |
| `<FRONT_PRI>` | front サーバのプライベートIP |
| `<APP_PRI>` | app サーバのプライベートIP |
| `<DB_PRI>` | db サーバのプライベートIP |
| `<CACHE_PRI>` | cache サーバのプライベートIP |
| `<DB_PASSWORD>` | PostgreSQL の appuser パスワード |
| `<REDIS_PASSWORD>` | Redis の認証パスワード |
| `<SESSION_SECRET>` | express-session の署名キー |

### B. 用語解説

| 用語 | 説明 |
|---|---|
| Tengine | Taobao が Nginx をフォークして開発した HTTP サーバ。Nginx 互換に加え、upstream のアクティブヘルスチェックなど独自モジュールを公式提供 |
| pm2 | Node.js プロセスマネージャ。常駐化・自動再起動・ログ管理・クラスタモードを提供 |
| cluster mode (pm2) | Node.js の cluster モジュールを使い、CPUコア数ぶんのワーカープロセスを起動する pm2 の動作モード |
| connect-redis | express-session のセッション保存先を Redis にするためのストアアダプタ |
| upstream check (Tengine) | Tengine 独自のアクティブヘルスチェック機構。指定間隔でバックエンドにHTTPリクエストを送り、応答ステータスで生死判定 |
| `X-Cache` ヘッダ | レスポンスがキャッシュから返されたか(HIT)、オリジンから返されたか(MISS)を示す慣習的なHTTPヘッダ |
| 自己署名証明書 | 認証局を介さず自分で発行したSSL/TLS証明書。学習用途や閉域では使えるが、ブラウザは信頼しない |

### C. 削除・クリーンアップ手順

1. app.local で `pm2 delete all` および `pm2 unstartup systemd -u appuser` を実行
2. front.local で `systemctl stop tengine && systemctl disable tengine` を実行
3. EC2インスタンスを4台とも終了
4. セキュリティグループを削除
5. キーペアを削除(必要に応じて)
