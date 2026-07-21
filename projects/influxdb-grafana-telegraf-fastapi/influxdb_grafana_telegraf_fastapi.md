# 【案9: 時系列データ基盤(InfluxDB + Grafana + Telegraf + FastAPI/Gunicorn)】環境構築手順書

---

## 1. ドキュメント情報

| 項目 | 内容 |
|------|------|
| 手順書名 | 時系列データ基盤(InfluxDB + Grafana + Telegraf + FastAPI/Gunicorn) |
| 作成日 | 2026-06-26 |
| バージョン | v1.0 |
| 対象環境 | AWS |

> **改訂履歴**
>
> | バージョン | 日付 | 変更内容 |
> |-----------|------|---------|
> | v1.0 | 2026-06-26 | 初版作成 |

---

## 2. 目的・概要

### 2-1. 目的

> 本手順書では、**Telegraf(収集) + InfluxDB(蓄積) + Grafana(可視化) + FastAPI/Gunicorn/Nginx(API提供)** の3台構成で、時系列データ基盤を構築する。
>
> - **Telegraf** によるシステムメトリクスの定期収集
> - **InfluxDB v2.x** によるトークン認証付きの時系列データストア
> - **Grafana** によるダッシュボード可視化
> - **FastAPI + Gunicorn + Nginx** による読み取り専用APIゲートウェイ
> - 障害シミュレーションで Telegraf のバッファリング機能を体感する

### 2-2. 構成概要(アーキテクチャ)

```
              [運用者/利用者]
                    │
        ┌───────────┼────────────────┐
        │ ブラウザ                    │ curl
        ↓ :3000                       ↓ :80
   ┌───────────────────┐       ┌──────────────────────┐
   │  tsdb.local        │       │  api.local            │
   │                    │       │                       │
   │  Grafana :3000     │       │  Nginx :80            │
   │   ↓ datasource     │       │   ↓ reverse_proxy     │
   │  InfluxDB :8086 ←──┼───────┤  Gunicorn :8000       │
   │   ↑                │ Flux  │   ↓                    │
   │   │ /api/v2/write  │ query │  FastAPI (読み取りAPI) │
   └───┼────────────────┘       └──────────────────────┘
       │ メトリクス書き込み
       │
   ┌───┴────────────────┐
   │  col.local          │
   │                    │
   │  Telegraf          │
   │   ・cpu            │
   │   ・mem            │
   │   ・disk           │
   │   ・net            │
   └────────────────────┘
```

### 2-3. 完成イメージ(ゴール定義)

- [ ] Telegraf が10秒間隔で自サーバのメトリクスを InfluxDB に書き込んでいる
- [ ] Grafana から InfluxDB をデータソースとして参照し、CPU使用率のグラフを表示できる
- [ ] `curl http://<api_pub>/health` で `{"status":"ok"}` が返る
- [ ] `curl http://<api_pub>/metrics/cpu?host=col.local&minutes=5` で直近5分のCPU使用率がJSONで返る
- [ ] InfluxDB を停止すると Telegraf がローカルバッファに溜め、復旧後に再送される様子をログから確認できる

---

## 3. 前提条件・準備

### 3-1. AWS環境(起動済み前提)

以下が完了している前提とする。

- AWSアカウントを保有していること
- VPCが作成されており、CIDRは `172.31.0.0/16` であること(異なる場合は手順中の該当箇所を読み替え)
- EC2インスタンスが **3台起動済み** であること(全台 Amazon Linux 2023)
- 全EC2にSSHログインできること
- 各EC2には **パブリックIPが付与されている** こと

> **注意:EIP・NAT は使わない**
>
> 本手順書では通常のパブリックIPを利用する。EC2を停止/起動するとパブリックIPが変動する点に注意。停止時は手順中の `<xxx_pub>` を読み替える必要がある。

### 3-2. 環境要件

#### 3-2-1. col.local(Telegraf 収集サーバ)

| 項目 | 要件 |
|------|------|
| OS | Amazon Linux 2023 |
| インスタンスタイプ | t3.micro |
| ミドルウェア | Telegraf |
| ツール | curl |

#### 3-2-2. tsdb.local(InfluxDB + Grafana サーバ)

| 項目 | 要件 |
|------|------|
| OS | Amazon Linux 2023 |
| インスタンスタイプ | m7i-flex.large（2 vCPU / 8 GiB、無料利用枠対象） |
| データストア | InfluxDB v2.x |
| 可視化 | Grafana |
| ツール | curl |

#### 3-2-3. api.local(API サーバ)

| 項目 | 要件 |
|------|------|
| OS | Amazon Linux 2023 |
| インスタンスタイプ | t3.small |
| Webサーバ | Nginx |
| APサーバ | Gunicorn |
| アプリ | FastAPI(Python) |
| Python | python3.11 |
| ツール | curl |

### 3-3. セキュリティグループ設定

#### 3-3-1. col.local

| タイプ | プロトコル | ポート範囲 | ソース | 目的 |
|-------|-----------|-----------|--------|------|
| SSH | TCP | 22 | マイIP | ローカルからSSHログイン |

> **解説:Telegrafサーバは外部から接続される必要がない**
>
> Telegraf は「自分から InfluxDB に書き込みに行く」エージェント型の動作なので、外部からの受信ポートは不要。SSHのみで足りる。

#### 3-3-2. tsdb.local

| タイプ | プロトコル | ポート範囲 | ソース | 目的 |
|-------|-----------|-----------|--------|------|
| SSH | TCP | 22 | マイIP | ローカルからSSHログイン |
| HTTP | TCP | 8086 | 172.31.0.0/16 | col.local と api.local からの InfluxDB API アクセス |
| HTTP | TCP | 3000 | マイIP | Grafana 画面アクセス |

> **解説:InfluxDB の 8086 番をVPC内に限定する理由**
>
> InfluxDB の HTTP API はトークン認証で守られているが、それでも外部に晒す必要はない。Telegraf(col.local)と FastAPI(api.local)からの内部通信のみで完結するので、`172.31.0.0/16` に限定する。

#### 3-3-3. api.local

| タイプ | プロトコル | ポート範囲 | ソース | 目的 |
|-------|-----------|-----------|--------|------|
| SSH | TCP | 22 | マイIP | ローカルからSSHログイン |
| HTTP | TCP | 80 | マイIP | 自分の環境から FastAPI へのアクセス |

### 3-4. パラメータ整理表

> 以下のプレースホルダを自分の環境の値に置き換えながら手順を進めること。

| パラメータ | 意味 | 自環境の値 |
|---|---|---|
| `<collector_pri>` | col.local のプライベートIP | |
| `<collector_pub>` | col.local のグローバルIP | |
| `<tsdb_pri>` | tsdb.local のプライベートIP | |
| `<tsdb_pub>` | tsdb.local のグローバルIP | |
| `<api_pri>` | api.local のプライベートIP | |
| `<api_pub>` | api.local のグローバルIP | |
| `<influx_token>` | InfluxDB の API トークン(Step 2 で発行) | |
| `<influx_org>` | InfluxDB の組織名 | `tslab` |
| `<influx_bucket>` | InfluxDB のバケット名 | `metrics` |

### 3-5. ホスト名設計

| ホスト名 | 役割 |
|---|---|
| `col.local` | Telegraf 収集エージェント |
| `tsdb.local` | InfluxDB + Grafana |
| `api.local` | FastAPI + Gunicorn + Nginx |

> **解説:`.local` の意味**
>
> 内部専用ドメインとして `.local` を採用し、役割を表す短いホスト名(`col`, `tsdb`, `api`)と組み合わせて `col.local` のように使う。`/etc/hosts` ベースの名前解決で運用し、DNS は構築しない(別案でDNS構築を扱うため、ここでは扱わない)。

---

## 4. 構築手順(詳細)

### 4-1. 環境構築の流れ

1. 全サーバ共通の初期設定(Step 0)
2. tsdb.local: InfluxDB のインストールと初期化(Step 1)
3. tsdb.local: Grafana のインストールとデータソース設定(Step 2)
4. col.local: Telegraf のインストールと InfluxDB への書き込み設定(Step 3)
5. api.local: FastAPI アプリの作成(Step 4)
6. api.local: Gunicorn の systemd 常駐化(Step 5)
7. api.local: Nginx のリバースプロキシ設定(Step 6)
8. 障害シミュレーション(Step 7)

---

### Step 0: 【全サーバで実施】システム初期設定

各サーバそれぞれにSSHログインし、以下を実施する。

#### 0-1. 共通初期化

```bash
sudo su -
dnf update -y
timedatectl set-timezone Asia/Tokyo
```

#### 0-2. ホスト名の設定

```bash
# col.local で
hostnamectl set-hostname col.local

# tsdb.local で
hostnamectl set-hostname tsdb.local

# api.local で
hostnamectl set-hostname api.local
```

#### 0-3. /etc/hosts に全サーバを登録

各サーバ共通で以下を追記する。

```bash
vi /etc/hosts
```

```
<collector_pri> col.local
<tsdb_pri>      tsdb.local
<api_pri>       api.local
```

> **解説:なぜ全サーバに同じ /etc/hosts を入れるか**
>
> - col.local(Telegraf)は tsdb.local に書き込むため `tsdb.local` を解決する必要がある
> - api.local(FastAPI)は tsdb.local にクエリを投げるため `tsdb.local` を解決する必要がある
> - tsdb.local は他から接続される側だが、自分自身の名前を解決できないと内部ツールが混乱することがある
>
> よって全台に同じエントリを入れておくのが安全。

#### 0-4. 反映確認

```bash
hostname
# 設定したホスト名が表示されればOK
```

---

### Step 1: 【tsdb.localで実施】InfluxDB のインストールと初期化

**目的:** 時系列データストアとなる InfluxDB v2.x をインストールし、初期セットアップでトークンを発行する。

#### 1-1. InfluxDB のリポジトリ登録

```bash
cat <<'EOF' > /etc/yum.repos.d/influxdata.repo
[influxdata]
name = InfluxData Repository
baseurl = https://repos.influxdata.com/stable/$basearch/main
enabled = 1
gpgcheck = 1
gpgkey = https://repos.influxdata.com/influxdata-archive.key
EOF
```

#### 1-2. InfluxDB のインストール

```bash
dnf install -y influxdb2 influxdb2-cli
```

> **解説:`influxdb2` と `influxdb2-cli` は別パッケージ**
>
> `influxdb2` はサーバー本体(`influxd`)のみを含み、管理用CLIの `influx` コマンドは別パッケージ `influxdb2-cli` に含まれる。片方だけインストールすると、1-4 の `influx setup` 実行時に `influx: command not found` となるため、両方をまとめてインストールする。

#### 1-3. InfluxDB の起動

```bash
systemctl start influxdb
systemctl enable influxdb
systemctl status influxdb
```

#### 1-4. 初期セットアップ(CLIによる)

InfluxDB v2.x は初回起動後、組織・バケット・初期ユーザー・初期トークンを作成する必要がある。CLI で実施する。

```bash
influx setup \
  --username admin \
  --password 'Admin12345!' \
  --org tslab \
  --bucket metrics \
  --retention 7d \
  --force
```

実行後、以下のような出力が出る。

```
User    Organization    Bucket
admin   tslab           metrics
```

#### 1-5. 発行されたトークンの確認

```bash
influx config list --json | grep '"token"'
```

出力される `token` フィールドの長い文字列が **オールアクセストークン**。
これを **パラメータ整理表の `<influx_token>` に控える**。

> **注意:`influx auth list` ではトークンを確認できない**
>
> InfluxDB 2.9.0 以降、トークンはサーバー側でハッシュ化されて保存されるようになり、`influx auth list`(や `--json` 出力)では平文のトークン値を二度と取得できない(`token` フィールドが空になる)。
>
> `influx setup` 実行時にCLIが自動生成するローカルの接続設定ファイル(`~/.influxdbv2/configs`、rootで実行時は `/root/.influxdbv2/configs`)には平文のトークンがそのまま保存されているため、`influx config list` で確認する。ただし**デフォルトのテーブル出力にはToken列がなく**、`--json` を付けて初めて `token` フィールドが出力される。このファイルも失った場合、既存トークンの復元手段はなく、`influx auth create` で新規発行することになる。

<!-- -->

> **解説:InfluxDB v2.x のデータモデル**
>
> v1.x の「database」概念は v2.x では以下に分解された。
>
> - **Organization(org)**: マルチテナンシーの単位。本手順書では `tslab`
> - **Bucket**: データの入れ物(v1.xのdatabaseに近い)+保持期間設定。本手順書では `metrics`(7日保持)
> - **Token**: API認証情報。すべての書き込み/読み込みにこれが必要
>
> Telegraf も FastAPI も、このトークンを使って InfluxDB に接続する。

> **注意:保持期間 7d の意味**
>
> `--retention 7d` で「7日経過したデータは自動削除」と設定している。学習用途では十分。本番運用では用途に応じて長期(30d, 90d, infinite等)を選ぶ。

#### 1-6. 書き込み確認(動作テスト)

```bash
influx write \
  --org tslab \
  --bucket metrics \
  --precision s \
  "test,host=manual value=1 $(date +%s)"
```

エラーが出なければ書き込み成功。

```bash
# 読み出し確認
influx query 'from(bucket:"metrics") |> range(start: -1h) |> filter(fn: (r) => r._measurement == "test")'
```

`value` カラムに 1 が表示されればOK。

---

### Step 2: 【tsdb.localで実施】Grafana のインストールとデータソース設定

**目的:** Grafana をインストールし、InfluxDB をデータソースとして登録する。

#### 2-1. Grafana のリポジトリ登録

```bash
cat <<'EOF' > /etc/yum.repos.d/grafana.repo
[grafana]
name=grafana
baseurl=https://rpm.grafana.com
repo_gpgcheck=1
enabled=1
gpgcheck=1
gpgkey=https://rpm.grafana.com/gpg.key
sslverify=1
sslcacert=/etc/pki/tls/certs/ca-bundle.crt
EOF
```

#### 2-2. Grafana のインストール

```bash
dnf install -y grafana
```

#### 2-3. Grafana の起動

```bash
systemctl start grafana-server
systemctl enable grafana-server
systemctl status grafana-server
```

#### 2-4. ブラウザから Grafana にアクセス

ブラウザで `http://<tsdb_pub>:3000` を開く。

- 初期ユーザー: `admin`
- 初期パスワード: `admin`
- ログイン後にパスワード変更を求められるので任意の値に変更する

#### 2-5. データソースの追加

1. 左メニュー → Connections → Data sources → Add data source
2. **InfluxDB** を選択
3. 以下を設定:

| 項目 | 値 |
|---|---|
| Name | `InfluxDB-metrics` |
| Query language | `Flux` |
| URL | `http://localhost:8086` |
| Organization | `tslab` |
| Token | `<influx_token>`(Step 1-5 で控えた値) |
| Default Bucket | `metrics` |

4. 「Save & test」を押下し、`datasource is working` が表示されることを確認

> **解説:Flux と InfluxQL の選択**
>
> InfluxDB v2.x では両方使えるが、Flux のほうがv2の機能をフルに使えて公式推奨。InfluxQLは旧バージョン互換用。学習目的では Flux を選ぶことで「v2.xらしい」体験ができる。

> **考えるポイント:Grafana から `localhost:8086` でよい理由**
>
> 同じサーバ上で InfluxDB と Grafana が動いているので、ループバックで接続できる。これにより SG で 8086 番を外部に開ける必要がない(VPC内に絞れる)という設計上のメリットがある。

---

### Step 3: 【col.localで実施】Telegraf のインストールと設定

**目的:** Telegraf を入れ、自サーバのシステムメトリクスを InfluxDB に送信する。

#### 3-1. Telegraf のリポジトリ登録

```bash
cat <<'EOF' > /etc/yum.repos.d/influxdata.repo
[influxdata]
name = InfluxData Repository
baseurl = https://repos.influxdata.com/stable/$basearch/main
enabled = 1
gpgcheck = 1
gpgkey = https://repos.influxdata.com/influxdata-archive.key
EOF
```

#### 3-2. Telegraf のインストール

```bash
dnf install -y telegraf
```

#### 3-3. 既存設定ファイルのバックアップ

```bash
cp /etc/telegraf/telegraf.conf /etc/telegraf/telegraf.conf.bak
```

#### 3-4. 設定ファイルを書き換える

デフォルトの設定は非常に長くコメントアウトされているので、本手順書では必要な部分のみを残した最小構成で上書きする。

```bash
cat <<'EOF' > /etc/telegraf/telegraf.conf
# === Agent設定 ===
[agent]
  interval = "10s"
  round_interval = true
  metric_batch_size = 1000
  metric_buffer_limit = 10000
  collection_jitter = "0s"
  flush_interval = "10s"
  flush_jitter = "0s"
  precision = ""
  hostname = ""
  omit_hostname = false

# === Output: InfluxDB v2.x ===
[[outputs.influxdb_v2]]
  urls = ["http://tsdb.local:8086"]
  token = "<influx_token>"
  organization = "tslab"
  bucket = "metrics"

# === Input: CPU ===
[[inputs.cpu]]
  percpu = true
  totalcpu = true
  collect_cpu_time = false
  report_active = false

# === Input: Memory ===
[[inputs.mem]]

# === Input: Disk ===
[[inputs.disk]]
  ignore_fs = ["tmpfs", "devtmpfs", "devfs", "overlay", "aufs", "squashfs"]

# === Input: Network ===
[[inputs.net]]
EOF
```

**上記ファイル内の `<influx_token>` を、Step 1-5 で控えた実際のトークン値に置換する。**

```bash
vi /etc/telegraf/telegraf.conf
# token = "<influx_token>" の部分を実値に書き換える
```

> **解説:`interval = "10s"` と `metric_buffer_limit = 10000`**
>
> - `interval`: 収集間隔。10秒ごとに各 input が実行される
> - `metric_buffer_limit`: 送信に失敗した場合にメモリ上に保持するメトリクスの最大件数
>
> InfluxDB が停止していると、Telegraf は送信できなかったメトリクスをこのバッファに溜める。10000件まで保持できるので、10秒間隔で4種類のinputなら2500回分(約7時間)はバッファできる計算。これが Step 7 の障害シミュレーションのキモになる。

> **解説:`omit_hostname = false` の意味**
>
> Telegraf は各メトリクスに自動的に `host` タグを付ける。値はOSの hostname(`col.local`)が使われる。後で FastAPI から「ホスト名で絞り込んで取得」する際にこのタグを利用する。

#### 3-5. Telegraf の起動

```bash
systemctl start telegraf
systemctl enable telegraf
systemctl status telegraf
```

#### 3-6. ログ確認

```bash
journalctl -u telegraf -f
```

`E!` から始まるエラーが出ていなければ正常。

> **注意:`Connecting to outputs` / `Successfully connected to outputs` は表示されない**
>
> これらの接続ログは Telegraf の **Debugレベル(`D!`)** でのみ出力される。3-4で作成した `telegraf.conf` には `debug = true` を設定していないため、デフォルト(Info以上)のログレベルではこの行は出力されない。
>
> 一時的に見たい場合は `[agent]` セクションに `debug = true` を追加して `systemctl restart telegraf` すれば表示されるが、必須の確認ではない。本当の成功判定は 3-7 で実際にInfluxDB側にデータが書き込まれているかを確認すること。

`Ctrl+C` でログ追跡を抜ける。

#### 3-7. tsdb.local 側で書き込み確認

tsdb.local に移動して以下を実行:

```bash
influx query 'from(bucket:"metrics") |> range(start: -1m) |> filter(fn: (r) => r._measurement == "cpu") |> limit(n:5)'
```

`host=col.local` のCPUデータが表示されればOK。

---

### Step 4: 【api.localで実施】FastAPI アプリの作成

**目的:** InfluxDB に Flux クエリを投げて結果をJSONで返す、読み取り専用APIを実装する。

#### 4-1. Python と必要パッケージのインストール

```bash
dnf install -y python3.11
python3.11 -m ensurepip --upgrade
```

#### 4-2. アプリ用ディレクトリの作成

```bash
mkdir -p /opt/tsapi
cd /opt/tsapi
```

#### 4-3. 仮想環境作成と依存パッケージインストール

```bash
python3.11 -m venv venv
source venv/bin/activate
pip install --upgrade pip
pip install fastapi gunicorn uvicorn influxdb-client
deactivate
```

> **解説:`influxdb-client` パッケージ**
>
> InfluxDB v2.x 公式の Python クライアント。トークン認証・Flux クエリ・結果のオブジェクト変換まで一通り提供される。FastAPI からはこのクライアント経由で InfluxDB を操作する。

#### 4-4. アプリケーション本体の作成

```bash
vi /opt/tsapi/app.py
```

以下の内容を記述:

```python
from fastapi import FastAPI, HTTPException, Query
from influxdb_client import InfluxDBClient
import os

INFLUX_URL = os.environ.get("INFLUX_URL", "http://tsdb.local:8086")
INFLUX_TOKEN = os.environ.get("INFLUX_TOKEN", "")
INFLUX_ORG = os.environ.get("INFLUX_ORG", "tslab")
INFLUX_BUCKET = os.environ.get("INFLUX_BUCKET", "metrics")

app = FastAPI(title="TS API")

client = InfluxDBClient(url=INFLUX_URL, token=INFLUX_TOKEN, org=INFLUX_ORG)
query_api = client.query_api()


@app.get("/health")
def health():
    return {"status": "ok"}


@app.get("/hosts")
def list_hosts():
    flux = f'''
    import "influxdata/influxdb/schema"
    schema.tagValues(bucket: "{INFLUX_BUCKET}", tag: "host", start: -7d)
    '''
    try:
        tables = query_api.query(flux)
        hosts = [record.get_value() for table in tables for record in table.records]
        return {"hosts": hosts}
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))


@app.get("/metrics/cpu")
def metrics_cpu(host: str = Query(...), minutes: int = Query(5, ge=1, le=1440)):
    flux = f'''
    from(bucket: "{INFLUX_BUCKET}")
      |> range(start: -{minutes}m)
      |> filter(fn: (r) => r._measurement == "cpu")
      |> filter(fn: (r) => r._field == "usage_user")
      |> filter(fn: (r) => r.cpu == "cpu-total")
      |> filter(fn: (r) => r.host == "{host}")
      |> keep(columns: ["_time", "_value"])
    '''
    try:
        tables = query_api.query(flux)
        points = [
            {"time": r.get_time().isoformat(), "value": r.get_value()}
            for t in tables for r in t.records
        ]
        return {"host": host, "minutes": minutes, "metric": "cpu.usage_user", "points": points}
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))


@app.get("/metrics/memory")
def metrics_memory(host: str = Query(...), minutes: int = Query(5, ge=1, le=1440)):
    flux = f'''
    from(bucket: "{INFLUX_BUCKET}")
      |> range(start: -{minutes}m)
      |> filter(fn: (r) => r._measurement == "mem")
      |> filter(fn: (r) => r._field == "used_percent")
      |> filter(fn: (r) => r.host == "{host}")
      |> keep(columns: ["_time", "_value"])
    '''
    try:
        tables = query_api.query(flux)
        points = [
            {"time": r.get_time().isoformat(), "value": r.get_value()}
            for t in tables for r in t.records
        ]
        return {"host": host, "minutes": minutes, "metric": "mem.used_percent", "points": points}
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))
```

> **解説:接続情報を環境変数から読む設計**
>
> `INFLUX_TOKEN` などをコード内にハードコードせず、`os.environ.get()` で取得する。Step 5 で systemd の `Environment=` から注入する。これにより、アプリコードを変更せずに本番/検証で設定を切り替えられる。
>
> 案1で Gunicorn の DB 接続情報を `Environment=` で渡したのと同じパターン。

> **解説:Flux クエリで何をしているか**
>
> 例として `/metrics/cpu` のクエリ:
> - `from(bucket: "metrics")` — どのバケットから取るか
> - `|> range(start: -5m)` — 直近5分の範囲
> - `|> filter(...)` — measurement(cpu), field(usage_user), tag(cpu-total, host) で絞り込み
> - `|> keep(...)` — 結果に含めるカラムを限定
>
> Flux はパイプ `|>` でつないでいくのが特徴。SQLとは大きく違う書き味だが、データの流れが読みやすい。

#### 4-5. アプリの動作確認(手動起動)

```bash
cd /opt/tsapi
source venv/bin/activate
export INFLUX_URL="http://tsdb.local:8086"
export INFLUX_TOKEN="<influx_token>"
export INFLUX_ORG="tslab"
export INFLUX_BUCKET="metrics"
gunicorn -w 2 -k uvicorn.workers.UvicornWorker -b 127.0.0.1:8000 app:app
```

別ターミナルで:

```bash
curl http://127.0.0.1:8000/health
# {"status":"ok"}

curl "http://127.0.0.1:8000/hosts"
# {"hosts":["col.local"]}

curl "http://127.0.0.1:8000/metrics/cpu?host=col.local&minutes=5"
# {"host":"col.local","minutes":5,"metric":"cpu.usage_user","points":[...]}
```

確認後、`Ctrl+C` で停止し、`deactivate` で仮想環境を抜ける。

---

### Step 5: 【api.localで実施】Gunicorn の systemd 常駐化

**目的:** FastAPI アプリを Gunicorn 経由で systemd の管理下に置き、常駐させる。

#### 5-1. systemd ユニットファイル作成

```bash
vi /etc/systemd/system/tsapi.service
```

```ini
[Unit]
Description=Time Series API (FastAPI on Gunicorn)
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=/opt/tsapi
Environment="INFLUX_URL=http://tsdb.local:8086"
Environment="INFLUX_TOKEN=<influx_token>"
Environment="INFLUX_ORG=tslab"
Environment="INFLUX_BUCKET=metrics"
ExecStart=/opt/tsapi/venv/bin/gunicorn -w 2 -k uvicorn.workers.UvicornWorker -b 127.0.0.1:8000 app:app
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
```

**`<influx_token>` を実際のトークン値に書き換える。**

> **解説:`-k uvicorn.workers.UvicornWorker` の意味**
>
> Gunicorn は同期型のワーカーがデフォルトだが、FastAPI は ASGI(非同期)アプリなので、Uvicorn を「Gunicornのワーカークラス」として使う必要がある。`-k uvicorn.workers.UvicornWorker` でその指定をする。
>
> これにより、「プロセス管理は Gunicorn、リクエスト処理は Uvicorn」というハイブリッド構成になる。

> **解説:`Restart=on-failure` の意味**
>
> プロセスが異常終了した場合、5秒後に自動再起動する。本番運用に近づける設計。

#### 5-2. systemd への登録と起動

```bash
systemctl daemon-reload
systemctl start tsapi
systemctl enable tsapi
systemctl status tsapi
```

#### 5-3. 動作確認

```bash
curl http://127.0.0.1:8000/health
# {"status":"ok"}
```

---

### Step 6: 【api.localで実施】Nginx のリバースプロキシ設定

**目的:** 外部からのHTTPリクエストを Nginx で受け、Gunicorn(127.0.0.1:8000)に転送する。

#### 6-1. Nginx のインストール

```bash
dnf install -y nginx
```

#### 6-2. リバースプロキシ設定ファイル作成

```bash
vi /etc/nginx/conf.d/tsapi.conf
```

```nginx
server {
    listen 80;
    server_name _;

    access_log /var/log/nginx/tsapi_access.log;
    error_log  /var/log/nginx/tsapi_error.log;

    location / {
        proxy_pass http://127.0.0.1:8000;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }
}
```

> **解説:`server_name _;` の意味**
>
> どんなホスト名(Hostヘッダ)で来てもこの server ブロックで受ける、というワイルドカード設定。学習用途で1サーバ1サービスならこれで十分。本番でドメインを使い分けるなら明示的に書く。

#### 6-3. デフォルト設定の調整

Amazon Linux 2023 のデフォルト `/etc/nginx/nginx.conf` には、あらかじめ `listen 80 default_server; server_name _;` のサーバブロックが存在する。6-2で追加した `tsapi.conf` も `server_name _;` を使っており、同じ待受(`0.0.0.0:80`)で名前が重複するため、**先にコメントアウトしておく**。

```bash
vi /etc/nginx/nginx.conf
```

`http { ... }` 内の `server { listen 80 default_server; ... }` ブロックを丸ごとコメントアウトする。

```bash
nginx -t
# syntax is ok / test is successful が出ればOK
```

> **注意:この対応は警告(warning)が出ていなくても必須**
>
> `nginx.conf` 側のブロックには `default_server` が付いているため、コメントアウトしないまま起動すると、Hostヘッダが一致しないリクエスト(`_` は実際のホスト名とは一致しないので実質すべてのリクエスト)は常に `nginx.conf` 側のデフォルトブロックが処理してしまう。この場合 `nginx -t` は `conflicting server name "_" on 0.0.0.0:80, ignored` という**警告のみ**を出し、`test is successful` 自体は表示されてしまうため、警告を見逃すと `tsapi.conf` 側のリバースプロキシが実質使われないまま気づかずに進んでしまう。そのため、警告の有無によらず必ずコメントアウトする。

#### 6-4. Nginx の起動

```bash
systemctl start nginx
systemctl enable nginx
systemctl status nginx
```

#### 6-5. 外部からの動作確認

自分のPC等から:

```bash
curl http://<api_pub>/health
# {"status":"ok"}

curl "http://<api_pub>/hosts"
# {"hosts":["col.local"]}

curl "http://<api_pub>/metrics/cpu?host=col.local&minutes=5"
# CPU使用率の時系列データが返る
```

---

### Step 7: 【全サーバで実施】障害シミュレーション(Telegrafバッファリング)

**目的:** InfluxDB を意図的に停止し、Telegraf がメモリ上にデータをバッファして復旧後に再送する挙動を観察する。

#### 7-1. 事前状態の確認

col.local で Telegraf のログを追跡開始:

```bash
journalctl -u telegraf -f
```

別ターミナルで、tsdb.local に接続。

#### 7-2. InfluxDB を停止

tsdb.local で:

```bash
systemctl stop influxdb
```

#### 7-3. Telegraf のログを観察

col.local のログタブに戻ると、しばらくして以下のようなエラーが出始める:

```
E! [outputs.influxdb_v2] When writing to [http://tsdb.local:8086]:
    Post "http://tsdb.local:8086/api/v2/write?...": dial tcp ...: connect: connection refused
```

> **解説:この時点で何が起きているか**
>
> - Telegraf は10秒ごとに収集・送信を試みている
> - 送信先(InfluxDB)が落ちているので、送信に失敗
> - 失敗したメトリクスは **メモリ上のバッファに蓄積される**(`metric_buffer_limit = 10000`)
> - バッファが上限を超えると、古いものから捨てられる

#### 7-4. しばらく待ってから InfluxDB を再起動

3〜5分ほど待ったあと、tsdb.local で:

```bash
systemctl start influxdb
```

#### 7-5. Telegraf のログを再観察

col.local のログに以下のような出力が出る:

```
D! [outputs.influxdb_v2] Wrote batch of 1000 metrics in ...
D! [outputs.influxdb_v2] Buffer fullness: 0 / 10000 metrics
```

バッファに溜まったメトリクスがまとめて送信される様子が確認できる。

#### 7-6. データが欠損していないか確認

tsdb.local で:

```bash
influx query 'from(bucket:"metrics") |> range(start: -10m) |> filter(fn: (r) => r._measurement == "cpu") |> filter(fn: (r) => r._field == "usage_user") |> filter(fn: (r) => r.cpu == "cpu-total") |> keep(columns: ["_time", "_value"]) |> count()'
```

10分間で約60件(10秒間隔 × 6件/分 × 10分)のレコードが保持されていればバッファリングが効いている。

> **考えるポイント:バッファ限界を超えるとどうなるか**
>
> `metric_buffer_limit = 10000` を超えると、Telegraf は古いメトリクスから捨てて新しいものを優先する。データロスが発生する。
>
> 長時間の障害に備える場合、Telegraf のバッファをメモリではなくディスクに保持する「`outputs.influxdb_v2.bucket_tag` + ファイルベースキュー」のような構成も可能だが、本手順書の範囲外。

> **注意:本番運用では監視を組む**
>
> Telegraf のログを目視で確認するのは学習用。本番では「Telegraf自身のメトリクス(`internal` プラグイン)」を別の監視系で収集し、`buffer_size` が増え続けていないかをアラート化するのが定石。

---

## 5. 動作確認・検証

### 5-1. 確認チェックリスト

- [ ] **確認①**: Telegraf が継続的にデータを書き込んでいる
- [ ] **確認②**: Grafana から CPU使用率グラフが表示できる
- [ ] **確認③**: FastAPI 経由で時系列データを取得できる
- [ ] **確認④**: InfluxDB 停止 → 復旧でバッファリングが機能する(Step 7で実施済み)

---

### 確認①: Telegraf 書き込みの継続性

tsdb.local で:

```bash
# 直近1分の cpu レコード件数を確認
influx query 'from(bucket:"metrics") |> range(start: -1m) |> filter(fn: (r) => r._measurement == "cpu") |> count()'
```

複数件が返ればOK(10秒間隔で書き込まれている)。

---

### 確認②: Grafana ダッシュボード

1. ブラウザで `http://<tsdb_pub>:3000` にログイン
2. 左メニュー → Dashboards → New → New dashboard
3. Add visualization → `InfluxDB-metrics` を選択
4. クエリ欄に以下を入力:

```flux
from(bucket: "metrics")
  |> range(start: -15m)
  |> filter(fn: (r) => r._measurement == "cpu")
  |> filter(fn: (r) => r._field == "usage_user")
  |> filter(fn: (r) => r.cpu == "cpu-total")
```

5. CPU使用率の折れ線グラフが表示されればOK

---

### 確認③: FastAPI 経由のデータ取得

自分のPC等から:

```bash
curl http://<api_pub>/health
curl "http://<api_pub>/hosts"
curl "http://<api_pub>/metrics/cpu?host=col.local&minutes=10"
curl "http://<api_pub>/metrics/memory?host=col.local&minutes=10"
```

すべて200応答でJSONが返ればOK。

---

## 6. トラブルシューティング

### よくあるエラーと対処法

---

#### エラー①: `influx setup` で `already been set up` と出る

**原因:** すでに初期セットアップ済み。

**対処法:** トークンを再確認:

```bash
influx auth list
```

それでも紛失した場合、`influx user password --name admin` でパスワード再設定後、Web UI(`http://<tsdb_pub>:8086`)からトークンを再発行する。

---

#### エラー②: Telegraf のログに `unauthorized access` が出る

**原因:** `telegraf.conf` の `token` が間違っている。

**対処法:**

```bash
grep token /etc/telegraf/telegraf.conf
# 値を確認

influx auth list
# 正しいトークンと比較
```

修正後:

```bash
systemctl restart telegraf
```

---

#### エラー③: FastAPI から InfluxDB に接続できない

**原因:** api.local から tsdb.local への 8086 接続が SG で塞がれている、または `/etc/hosts` で `tsdb.local` が解決できない。

**対処法:**

```bash
# api.local で
ping -c 1 tsdb.local
nc -zv tsdb.local 8086
```

接続できなければ:
- 名前解決失敗 → `/etc/hosts` を確認
- ポート閉塞 → tsdb.local の SG を確認

---

#### エラー④: Nginx が 502 Bad Gateway を返す

**原因:** Gunicorn(tsapi.service)が起動していない。

**対処法:**

```bash
systemctl status tsapi
journalctl -u tsapi -n 50
```

ログにスタックトレースが出ているはずなので確認する。

---

#### エラー⑤: Grafana のデータソースで `Bad Gateway` または `unauthorized`

**原因:** Token が誤っている、または Organization 名が一致していない。

**対処法:** Grafana の Data sources → InfluxDB-metrics を開き、Token と Organization を再入力して Save & test。

---

### ログの確認場所

| ログの種類 | 確認コマンド |
|-----------|------------|
| OSシステムログ | `journalctl -f` |
| InfluxDB | `journalctl -u influxdb -f` |
| Grafana | `journalctl -u grafana-server -f` |
| Telegraf | `journalctl -u telegraf -f` |
| FastAPI(Gunicorn) | `journalctl -u tsapi -f` |
| Nginx アクセス | `tail -f /var/log/nginx/tsapi_access.log` |
| Nginx エラー | `tail -f /var/log/nginx/tsapi_error.log` |

---

## 7. 参考リソース・関連資料

| 資料名 | URL | 補足 |
|-------|-----|------|
| InfluxDB v2 公式ドキュメント | https://docs.influxdata.com/influxdb/v2/ | InfluxDB v2 リファレンス |
| Telegraf 公式ドキュメント | https://docs.influxdata.com/telegraf/ | Telegraf 入力・出力プラグイン一覧 |
| Flux 言語ガイド | https://docs.influxdata.com/flux/ | Flux クエリ言語リファレンス |
| Grafana 公式ドキュメント | https://grafana.com/docs/grafana/latest/ | Grafana 全般 |
| FastAPI 公式ドキュメント | https://fastapi.tiangolo.com/ | FastAPI 全般 |
| Gunicorn 公式ドキュメント | https://docs.gunicorn.org/ | Gunicorn 設定リファレンス |
| influxdb-client (Python) | https://github.com/influxdata/influxdb-client-python | Python クライアントライブラリ |

---

## 付録

### A. 環境変数・パラメータまとめ

| パラメータ名 | 自分の環境の値 | 説明 |
|------------|-------------|------|
| `<collector_pri>` | `xx.xx.xx.xx` | col.local のプライベートIP |
| `<collector_pub>` | `xx.xx.xx.xx` | col.local のグローバルIP |
| `<tsdb_pri>` | `xx.xx.xx.xx` | tsdb.local のプライベートIP |
| `<tsdb_pub>` | `xx.xx.xx.xx` | tsdb.local のグローバルIP(Grafana画面) |
| `<api_pri>` | `xx.xx.xx.xx` | api.local のプライベートIP |
| `<api_pub>` | `xx.xx.xx.xx` | api.local のグローバルIP(API公開) |
| `<influx_token>` | (Step 1-5で発行) | InfluxDB API トークン |
| `<influx_org>` | `tslab` | InfluxDB 組織名 |
| `<influx_bucket>` | `metrics` | InfluxDB バケット名 |

### B. 用語解説

| 用語 | 説明 |
|------|------|
| 時系列データベース | 時刻をキーとしてデータを格納・問い合わせするDB。InfluxDB が代表格 |
| Organization(InfluxDB) | v2.x で導入されたマルチテナンシーの単位 |
| Bucket(InfluxDB) | データの入れ物。保持期間を設定できる |
| Measurement | InfluxDB における「テーブル」相当の概念(例: cpu, mem) |
| Field | 数値データを格納するフィールド(例: usage_user) |
| Tag | インデックスされる文字列ラベル(例: host=col.local) |
| Flux | InfluxDB v2.x の主要クエリ言語。パイプ演算子で処理を連結 |
| Telegraf | 各種データソースから収集して各種出力先に送る、プラグイン型エージェント |
| metric_buffer_limit | Telegraf のメモリバッファ上限。送信失敗時の一時保管領域 |
| ASGI | Asynchronous Server Gateway Interface。FastAPI 等の非同期Webアプリ規格 |
| UvicornWorker | Gunicorn が Uvicorn を内包して ASGI アプリを動かすためのワーカークラス |

### C. 削除・クリーンアップ手順

1. 各サーバで関連サービスを停止
   ```bash
   # col.local
   systemctl stop telegraf

   # tsdb.local
   systemctl stop grafana-server
   systemctl stop influxdb

   # api.local
   systemctl stop nginx
   systemctl stop tsapi
   ```
2. EC2インスタンスを3台とも終了する
3. セキュリティグループを削除する
4. キーペアを削除する(必要に応じて)

> **注意:** InfluxDB のデータは `/var/lib/influxdb/` 配下に保存されている。EC2終了でEBSも削除される設定なら一緒に消える。残したい場合はEBSスナップショットを取ること。
