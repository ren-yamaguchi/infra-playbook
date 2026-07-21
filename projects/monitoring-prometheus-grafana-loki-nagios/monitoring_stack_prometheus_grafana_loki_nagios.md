# 【案4: 監視スタック総合演習(Prometheus + Grafana + Loki + Fluent Bit + Nagios)】環境構築手順書

---

## 1. ドキュメント情報

| 項目 | 内容 |
|------|------|
| 手順書名 | 監視スタック総合演習(Prometheus + Grafana + Loki + Fluent Bit + Nagios) |
| 作成日 | 2026-06-25 |
| バージョン | v1.0 |
| 対象環境 | AWS |
| 想定作業時間 | 1〜1.5日 |

> **改訂履歴**
>
> | バージョン | 日付 | 変更内容 |
> |-----------|------|---------|
> | v1.0 | 2026-06-25 | 初版作成 |

---

## 2. 目的・概要

### 2-1. 目的

本手順書では、**監視基盤2台 + 監視対象2台**の合計4台構成で、現代的な監視スタック(Prometheus + Grafana + Loki + Fluent Bit)と、伝統的な死活監視ツール(Nagios)を同居させた監視環境を構築する。

学習の主眼は以下の3点である。

- **pull型メトリクス監視**(Prometheus)と **アクティブチェック型監視**(Nagios)を対比して理解する
- **メトリクス**(Prometheus)と **ログ**(Loki)を、それぞれ別の経路で収集し、Grafana で統合的に可視化する流れを体感する
- 障害シミュレーションを通じて、各監視ツールが「何を捉え、何を捉えないか」を観察する

### 2-2. 構成概要(アーキテクチャ)

```
              [外部からのHTTPアクセス]
                        ↓
            ┌───────────┴───────────┐
            ↓                       ↓
       [app1.local]            [app2.local]
        Nginx(:80)              Nginx(:80)
        node_exporter(:9100)    node_exporter(:9100)
        nginx-exporter(:9113)   nginx-exporter(:9113)
        Fluent Bit              Fluent Bit
            │   │                   │   │
            │   └──ログ(Loki push)──┼───┘
            │   ┌──メトリクス(pull)─┘
            ↓   ↓
       [mon1.local]                    [mon2.local]
        Prometheus(:9090)──┐            Nagios(Web UI:80)
        Alertmanager(:9093)┼─アラート→ Postfix(:25)→メール
        Loki(:3100)        │            └─アクティブチェック(SSH/HTTP)
        Grafana(:3000)─────┘                ↓ app1/app2 へ
```

- **監視基盤(mon1)**: メトリクス収集(Prometheus)、ログ収集(Loki)、可視化(Grafana)、アラート通知振り分け(Alertmanager)
- **死活監視(mon2)**: Nagios によるアクティブチェック、Postfix によるメール通知(ローカル配送)
- **監視対象(app1, app2)**: 各種 Exporter による メトリクス公開、Fluent Bit によるログ転送

### 2-3. 完成イメージ(ゴール定義)

- [ ] Prometheus の `/targets` で app1/app2 の各 Exporter が `UP` になっている
- [ ] Grafana で node_exporter ダッシュボード(ID 1860)が表示され、CPU/メモリ等のメトリクスが見える
- [ ] Grafana で Loki データソースを使い、Nginx アクセスログが時系列で参照できる
- [ ] Nagios Web UI で app1/app2 の SSH/HTTP サービスが OK 状態になっている
- [ ] app1 の Nginx を停止すると、Nagios が CRITICAL を検知し、mon2 ローカルにメール通知される
- [ ] app2 の node_exporter を停止すると、Prometheus 側で `up == 0` になるが、Nagios は何も検知しない(対比の体感)
- [ ] app1 に大量の 404 を発生させると、Grafana の Loki パネルでログ件数の急増が確認できる

---

## 3. 前提条件・準備

### 3-1. AWS環境(起動済み前提)

以下が完了している前提とする。

- AWS アカウントを保有していること
- VPC が作成されており、CIDR は `172.31.0.0/16` であること(異なる場合は手順中の該当箇所を読み替え)
- パブリックサブネットが利用可能であること
- EC2 インスタンスが **4台起動済み** であること(全台 Amazon Linux 2023、t2.micro 以上推奨。mon1 のみ t3.small 推奨)
- 全 EC2 にパブリック IP が付与されていること
- 全 EC2 に SSH ログインできること

> **注意: mon1 のスペックについて**
>
> mon1 は Prometheus + Grafana + Loki + Alertmanager の4プロセスが常駐するため、t2.micro(1GBメモリ)では起動時に OOM になる可能性がある。可能なら t3.small(2GBメモリ)以上を推奨する。t2.micro しか使えない場合は、swap を 1GB 確保しておくと安全。

> **注意: パブリックIPの変動について**
>
> EC2 を停止/起動するとパブリック IP が変動する。本手順書では EIP を使わない方針のため、停止後に再開する場合は SG の「マイIP」許可と、後述のパラメータ整理表の `<XXX_PUB>` の更新が必要になる点に留意すること。

### 3-2. 環境要件

#### 3-2-1. 監視基盤サーバ(mon1)

| 項目 | 要件 |
|------|------|
| OS | Amazon Linux 2023 |
| メトリクス収集 | Prometheus(公式バイナリ) |
| ログ収集 | Loki(公式バイナリ) |
| 可視化 | Grafana(公式 yum リポジトリ) |
| アラート振り分け | Alertmanager(公式バイナリ) |
| ツール | curl, telnet, tar |

#### 3-2-2. 死活監視サーバ(mon2)

| 項目 | 要件 |
|------|------|
| OS | Amazon Linux 2023 |
| 死活監視 | Nagios Core(ソースビルド)+ Nagios Plugins |
| Web UI 提供 | Apache(httpd) |
| 通知用メール送信 | Postfix(ローカル配送) |
| ツール | curl, telnet, tar, gcc, make 等 |

#### 3-2-3. 監視対象サーバ(app1, app2)共通

| 項目 | 要件 |
|------|------|
| OS | Amazon Linux 2023 |
| Web サーバ | Nginx |
| ホスト系メトリクス | node_exporter(公式バイナリ) |
| Nginx メトリクス | nginx-prometheus-exporter(公式バイナリ) |
| ログ転送 | Fluent Bit(公式 yum リポジトリ) |
| ツール | curl, telnet, tar |

### 3-3. セキュリティグループ設定

#### 3-3-1. 監視基盤サーバ(mon1)

| タイプ | プロトコル | ポート | ソース | 目的 |
|---|---|---|---|---|
| SSH | TCP | 22 | マイIP | SSH 接続 |
| カスタム TCP | TCP | 9090 | マイIP | Prometheus Web UI |
| カスタム TCP | TCP | 9093 | マイIP | Alertmanager Web UI |
| カスタム TCP | TCP | 3000 | マイIP | Grafana Web UI |
| カスタム TCP | TCP | 3100 | 172.31.0.0/16 | Loki への push(app1/app2 から) |

> **解説: Loki だけ VPC 内開放にしている理由**
>
> Prometheus/Grafana/Alertmanager は「人間がブラウザで見る」用途なので自分のIPだけ。Loki(3100) は「app1/app2 の Fluent Bit が push してくる」用途なので VPC 内開放にする。Prometheus は逆に「自分が app1/app2 に pull しに行く」側なので、mon1 側でポート開放する必要はない(後述の app1/app2 側で Exporter ポートを開ける)。

#### 3-3-2. 死活監視サーバ(mon2)

| タイプ | プロトコル | ポート | ソース | 目的 |
|---|---|---|---|---|
| SSH | TCP | 22 | マイIP | SSH 接続(およびNagios のSSHチェック確認用) |
| HTTP | TCP | 80 | マイIP | Nagios Web UI |
| SMTP | TCP | 25 | 127.0.0.1 のみ(暗黙) | Postfix ローカル配送(SG設定は不要) |

> **解説: Postfix は SG に書かない**
>
> Postfix はローカル(127.0.0.1)宛の配送だけ行うので、外部公開ポートは不要。Postfix プロセスは起動するが、SG で 25 番を開ける必要はない。

#### 3-3-3. 監視対象サーバ(app1, app2)

| タイプ | プロトコル | ポート | ソース | 目的 |
|---|---|---|---|---|
| SSH | TCP | 22 | マイIP, 172.31.0.0/16 | SSH 接続 + Nagios の SSH チェック |
| HTTP | TCP | 80 | マイIP, 172.31.0.0/16 | Nginx 動作確認 + Nagios の HTTP チェック |
| カスタム TCP | TCP | 9100 | 172.31.0.0/16 | node_exporter(mon1 から pull) |
| カスタム TCP | TCP | 9113 | 172.31.0.0/16 | nginx-exporter(mon1 から pull) |

> **注意: SSH の「マイIP + 172.31.0.0/16」併記**
>
> SSH(22)は通常マイIPだけだが、Nagios の `check_ssh` を mon2 から実行する都合上、`172.31.0.0/16` も追加する。同じポートに対する複数ソースは、AWS SG では「ルールを2行に分けて」追加する。

### 3-4. パラメータ整理表

| パラメータ | 意味 | 自環境の値 |
|---|---|---|
| `<MON1_PUB>` | mon1 のグローバルIP | |
| `<MON1_PRI>` | mon1 のプライベートIP | |
| `<MON2_PUB>` | mon2 のグローバルIP | |
| `<MON2_PRI>` | mon2 のプライベートIP | |
| `<APP1_PUB>` | app1 のグローバルIP | |
| `<APP1_PRI>` | app1 のプライベートIP | |
| `<APP2_PUB>` | app2 のグローバルIP | |
| `<APP2_PRI>` | app2 のプライベートIP | |

### 3-5. ホスト名設計

| サーバ | ホスト名 | 役割 |
|---|---|---|
| mon1 | `mon1.local` | 監視基盤(Prom/Graf/Loki/Alertmanager) |
| mon2 | `mon2.local` | 死活監視(Nagios + Postfix) |
| app1 | `app1.local` | 監視対象 Web1 |
| app2 | `app2.local` | 監視対象 Web2 |

> **解説: `.local` ドメインの利用について**
>
> 本手順書では内部用ホスト名として `.local` を使用する。BIND/DNS は構築しないので、Prometheus の scrape ターゲット指定や Nagios の監視対象指定は **プライベートIP直書き** で行う。ホスト名はあくまでサーバ識別用のラベル。

---

## 4. 構築手順(詳細)

### 4-1. 構築の流れ

```
Step 0: 全サーバ共通の初期設定(4台)
Step 1: app1/app2 に Nginx + 各種 Exporter + Fluent Bit を導入
Step 2: mon1 に Prometheus + Alertmanager を導入
Step 3: mon1 に Loki を導入
Step 4: mon1 に Grafana を導入(データソース + ダッシュボード)
Step 5: mon2 に Postfix(通知用ローカル配送)を導入
Step 6: mon2 に Nagios を導入
Step 7: 障害シミュレーション(3シナリオ)
```

---

### Step 0: 全サーバ共通の初期設定

**目的:** 全 4 台に対して、共通の初期設定(タイムゾーン、ホスト名、パッケージ更新)を行う。

#### 0-1. 【全4台で実施】システム初期化

各サーバで以下を実行する。ホスト名はサーバごとに変える。

```bash
sudo su -
dnf update -y
timedatectl set-timezone Asia/Tokyo

# mon1 の場合
hostnamectl set-hostname mon1.local
# mon2 の場合 → mon2.local
# app1 の場合 → app1.local
# app2 の場合 → app2.local

# 反映確認
hostname
date
```

> **解説: なぜ全サーバで同じ初期設定を毎回やるのか**
>
> Amazon Linux 2023 のデフォルトタイムゾーンは UTC。Prometheus、Nagios、Loki などのログ・タイムスタンプを後で照合する際に、全サーバの時刻表示が揃っていないと「障害がいつ起きたか」の対応付けが難しくなる。最初に全台で `Asia/Tokyo` に揃えるのが鉄則。

---

### Step 1: app1/app2 に Nginx + Exporter + Fluent Bit を導入

**目的:** 監視対象サーバ 2 台に、Web サーバとメトリクス公開エンドポイントを構築する。**app1, app2 両方で同じ手順を実施**する。

#### 1-1. 【app1, app2 で実施】Nginx 導入と動作確認

```bash
dnf install -y nginx

systemctl start nginx
systemctl enable nginx

# 動作確認
curl -I http://localhost/
# HTTP/1.1 200 OK が返ればOK
```

#### 1-2. 【app1, app2 で実施】Nginx の stub_status 有効化

nginx-exporter がメトリクスを取得するために、Nginx の状態モジュールエンドポイントを有効化する。

```bash
vi /etc/nginx/conf.d/stub_status.conf
```

```
server {
    listen 127.0.0.1:8080;
    server_name localhost;

    location /stub_status {
        stub_status;
        allow 127.0.0.1;
        deny all;
    }
}
```

```bash
nginx -t
systemctl reload nginx

# 動作確認
curl http://127.0.0.1:8080/stub_status
# Active connections: 1
# server accepts handled requests
#  1 1 1
# Reading: 0 Writing: 1 Waiting: 0
# のような出力が返ればOK
```

> **解説: stub_status を 127.0.0.1 だけに絞る理由**
>
> stub_status のメトリクスは外部公開する性質のものではない。同じサーバ上で動く nginx-exporter からだけアクセスできれば十分なので、`listen 127.0.0.1:8080` でローカル限定にする。nginx-exporter が変換後の Prometheus 形式メトリクスを 9113 番ポートで公開する役割を担う。

#### 1-3. 【app1, app2 で実施】node_exporter の導入

ホスト系メトリクス(CPU、メモリ、ディスクなど)を公開する exporter を導入する。Amazon Linux 2023 の yum リポジトリには無いので、公式バイナリを直接配置する。

```bash
cd /usr/local/src
NODE_EXPORTER_VERSION=1.8.2
curl -LO https://github.com/prometheus/node_exporter/releases/download/v${NODE_EXPORTER_VERSION}/node_exporter-${NODE_EXPORTER_VERSION}.linux-amd64.tar.gz
tar xvf node_exporter-${NODE_EXPORTER_VERSION}.linux-amd64.tar.gz
cp node_exporter-${NODE_EXPORTER_VERSION}.linux-amd64/node_exporter /usr/local/bin/

# 専用ユーザー作成
useradd -rs /sbin/nologin node_exporter
chown node_exporter:node_exporter /usr/local/bin/node_exporter
```

systemd ユニット作成:

```bash
vi /etc/systemd/system/node_exporter.service
```

```
[Unit]
Description=Node Exporter
After=network.target

[Service]
User=node_exporter
Group=node_exporter
Type=simple
ExecStart=/usr/local/bin/node_exporter

[Install]
WantedBy=multi-user.target
```

起動と動作確認:

```bash
systemctl daemon-reload
systemctl start node_exporter
systemctl enable node_exporter

# 動作確認
curl http://localhost:9100/metrics | head -20
# # HELP go_gc_duration_seconds ... のような Prometheus 形式メトリクスが返ればOK
```

> **解説: なぜ専用ユーザーで動かすのか**
>
> Exporter 系は「メトリクスを公開するだけ」のシンプルなプロセスなので、root 権限が不要。専用ユーザーで動かすことで、万が一 Exporter に脆弱性があっても影響範囲を限定できる。`/sbin/nologin` でログインも禁止。「最小権限の原則」をシンプルな例で体感する場面。

#### 1-4. 【app1, app2 で実施】nginx-prometheus-exporter の導入

Nginx の stub_status を Prometheus 形式メトリクスに変換する exporter を導入する。

```bash
cd /usr/local/src
NGINX_EXPORTER_VERSION=1.3.0
curl -LO https://github.com/nginx/nginx-prometheus-exporter/releases/download/v${NGINX_EXPORTER_VERSION}/nginx-prometheus-exporter_${NGINX_EXPORTER_VERSION}_linux_amd64.tar.gz
tar xvf nginx-prometheus-exporter_${NGINX_EXPORTER_VERSION}_linux_amd64.tar.gz
cp nginx-prometheus-exporter /usr/local/bin/

useradd -rs /sbin/nologin nginx_exporter
chown nginx_exporter:nginx_exporter /usr/local/bin/nginx-prometheus-exporter
```

systemd ユニット作成:

```bash
vi /etc/systemd/system/nginx_exporter.service
```

```
[Unit]
Description=Nginx Prometheus Exporter
After=network.target nginx.service

[Service]
User=nginx_exporter
Group=nginx_exporter
Type=simple
ExecStart=/usr/local/bin/nginx-prometheus-exporter \
  --nginx.scrape-uri=http://127.0.0.1:8080/stub_status \
  --web.listen-address=:9113

[Install]
WantedBy=multi-user.target
```

起動と動作確認:

```bash
systemctl daemon-reload
systemctl start nginx_exporter
systemctl enable nginx_exporter

# 動作確認
curl http://localhost:9113/metrics | grep nginx
# nginx_connections_active 1
# nginx_http_requests_total ... 等が返ればOK
```

> **解説: Exporter は「翻訳係」である**
>
> nginx-exporter は、Nginx 固有の stub_status 形式(独自テキスト)を、Prometheus が読める形式(`metric_name value` の繰り返し)に変換するだけのプロセス。Prometheus は数百種類の対象を扱えるが、それは「対象側がそれぞれ自分用の Exporter を用意してくれる」前提に立っているから。Exporter は「対象 → Prometheus」の翻訳係と考えると、エコシステム全体が理解しやすい。

#### 1-5. 【app1, app2 で実施】Fluent Bit の導入

ログ転送ツール Fluent Bit を公式 yum リポジトリから導入する。

```bash
# 公式リポジトリ追加
cat > /etc/yum.repos.d/fluent-bit.repo <<'EOF'
[fluent-bit]
name = Fluent Bit
baseurl = https://packages.fluentbit.io/amazonlinux/2023/
gpgcheck=1
gpgkey=https://packages.fluentbit.io/fluentbit.key
enabled=1
EOF

dnf install -y fluent-bit

# fluent-bit ユーザーが Nginx ログを読めるようにする
usermod -a -G nginx fluent-bit
chmod g+rx /var/log/nginx
```

> **解説: グループ参加によるログ読み取り権限**
>
> Nginx ログは通常 `/var/log/nginx/access.log` 等に nginx ユーザー所有で保存される。Fluent Bit はパッケージで `fluent-bit` ユーザーで動くため、デフォルトでは読めない。`fluent-bit` を `nginx` グループに参加させ、ディレクトリにグループ読み取り権限を付けることで、Fluent Bit がログを読めるようになる。

Fluent Bit 設定:

```bash
vi /etc/fluent-bit/fluent-bit.conf
```

ファイルの中身を以下で完全に置き換える(既存内容を消して書き換える):

```
[SERVICE]
    Flush        5
    Daemon       Off
    Log_Level    info
    Parsers_File parsers.conf

[INPUT]
    Name              tail
    Path              /var/log/nginx/access.log
    Tag               nginx.access
    Refresh_Interval  5

[INPUT]
    Name              tail
    Path              /var/log/nginx/error.log
    Tag               nginx.error
    Refresh_Interval  5

[INPUT]
    Name              systemd
    Tag               host.syslog
    Systemd_Filter    _SYSTEMD_UNIT=sshd.service
    Read_From_Tail    On

[OUTPUT]
    Name        loki
    Match       *
    Host        <MON1_PRI>
    Port        3100
    Labels      job=fluent-bit, host=${HOSTNAME}
    Label_Keys  $tag
```

`<MON1_PRI>` を実際の mon1 プライベートIPに書き換えること。

起動:

```bash
systemctl restart fluent-bit
systemctl enable fluent-bit

# ステータス確認
systemctl status fluent-bit
# active (running) になっていればOK
# (Loki 未起動時は接続エラーが出るが、後で Loki 起動後に自動で繋がる)
```

> **解説: Loki への送信は「OUTPUT loki」プラグインで完結**
>
> Fluent Bit 1.7 以降、Loki 向けの専用 OUTPUT プラグインが標準同梱されている。HTTP で Loki の `/loki/api/v1/push` エンドポイントに JSON を投げる仕様。`Labels` 設定が Loki 上での絞り込みキーになる(後で Grafana から `{job="fluent-bit"}` のように検索する)。

> **考えるポイント: なぜ「ログ」と「メトリクス」を別系統で扱うのか**
>
> ログとメトリクスは性質が違う。メトリクスは「数値の時系列」(CPU 使用率 50%、リクエスト数 100/秒など)で、Prometheus のような時系列DBが向く。ログは「個別の出来事のテキスト記録」で、検索・絞り込みに強い Loki のような仕組みが向く。
>
> 「全部 1 つの DB に投げ込めばいいのでは」と思うかもしれないが、用途が違うと最適化したい性質が違う(集約 vs 全文検索、保持期間、容量効率など)。本手順書ではこの「役割分担」を体感する。

---

### Step 2: mon1 に Prometheus + Alertmanager を導入

**目的:** メトリクス収集サーバとアラート振り分けサーバを構築する。**mon1 で実施**する。

#### 2-1. 【mon1 で実施】Prometheus の導入

```bash
cd /usr/local/src
PROMETHEUS_VERSION=2.54.1
curl -LO https://github.com/prometheus/prometheus/releases/download/v${PROMETHEUS_VERSION}/prometheus-${PROMETHEUS_VERSION}.linux-amd64.tar.gz
tar xvf prometheus-${PROMETHEUS_VERSION}.linux-amd64.tar.gz

cd prometheus-${PROMETHEUS_VERSION}.linux-amd64
cp prometheus promtool /usr/local/bin/
mkdir -p /etc/prometheus /var/lib/prometheus
cp -r consoles console_libraries /etc/prometheus/

useradd -rs /sbin/nologin prometheus
chown -R prometheus:prometheus /etc/prometheus /var/lib/prometheus /usr/local/bin/prometheus /usr/local/bin/promtool
```

設定ファイル作成:

```bash
vi /etc/prometheus/prometheus.yml
```

```yaml
global:
  scrape_interval: 15s
  evaluation_interval: 15s

alerting:
  alertmanagers:
    - static_configs:
        - targets:
            - 127.0.0.1:9093

rule_files:
  - /etc/prometheus/alert_rules.yml

scrape_configs:
  - job_name: 'prometheus'
    static_configs:
      - targets: ['127.0.0.1:9090']

  - job_name: 'node_exporter'
    static_configs:
      - targets:
          - '<APP1_PRI>:9100'
          - '<APP2_PRI>:9100'

  - job_name: 'nginx_exporter'
    static_configs:
      - targets:
          - '<APP1_PRI>:9113'
          - '<APP2_PRI>:9113'
```

`<APP1_PRI>`, `<APP2_PRI>` を実際のIPに書き換えること。

アラートルール作成:

```bash
vi /etc/prometheus/alert_rules.yml
```

```yaml
groups:
  - name: basic_alerts
    rules:
      - alert: TargetDown
        expr: up == 0
        for: 1m
        labels:
          severity: critical
        annotations:
          summary: "Target {{ $labels.instance }} is DOWN"
          description: "Job {{ $labels.job }} on {{ $labels.instance }} has been down for more than 1 minute."

      - alert: HighCpuUsage
        expr: 100 - (avg by(instance)(rate(node_cpu_seconds_total{mode="idle"}[2m])) * 100) > 80
        for: 2m
        labels:
          severity: warning
        annotations:
          summary: "High CPU on {{ $labels.instance }}"
          description: "CPU usage above 80% for 2 minutes."
```

```bash
chown -R prometheus:prometheus /etc/prometheus

# 構文チェック
promtool check config /etc/prometheus/prometheus.yml
# Checking /etc/prometheus/prometheus.yml SUCCESS が出ればOK
```

systemd ユニット作成:

```bash
vi /etc/systemd/system/prometheus.service
```

```
[Unit]
Description=Prometheus
After=network.target

[Service]
User=prometheus
Group=prometheus
Type=simple
ExecStart=/usr/local/bin/prometheus \
  --config.file=/etc/prometheus/prometheus.yml \
  --storage.tsdb.path=/var/lib/prometheus/ \
  --web.console.templates=/etc/prometheus/consoles \
  --web.console.libraries=/etc/prometheus/console_libraries \
  --web.listen-address=0.0.0.0:9090

[Install]
WantedBy=multi-user.target
```

起動:

```bash
systemctl daemon-reload
systemctl start prometheus
systemctl enable prometheus

# 確認
curl http://localhost:9090/-/healthy
# Prometheus Server is Healthy. が返ればOK
```

ブラウザで `http://<MON1_PUB>:9090/targets` を開き、`node_exporter` と `nginx_exporter` の app1/app2 が **UP** 状態になっていることを確認する(まだ UP にならない場合は Step 1 の Exporter 起動状況や SG を確認)。

#### 2-2. 【mon1 で実施】Alertmanager の導入

```bash
cd /usr/local/src
ALERTMANAGER_VERSION=0.27.0
curl -LO https://github.com/prometheus/alertmanager/releases/download/v${ALERTMANAGER_VERSION}/alertmanager-${ALERTMANAGER_VERSION}.linux-amd64.tar.gz
tar xvf alertmanager-${ALERTMANAGER_VERSION}.linux-amd64.tar.gz
cd alertmanager-${ALERTMANAGER_VERSION}.linux-amd64
cp alertmanager amtool /usr/local/bin/
mkdir -p /etc/alertmanager /var/lib/alertmanager

useradd -rs /sbin/nologin alertmanager
chown -R alertmanager:alertmanager /etc/alertmanager /var/lib/alertmanager /usr/local/bin/alertmanager /usr/local/bin/amtool
```

設定ファイル(本手順書ではメール通知は省略し、Alertmanager に「届いたアラート一覧」が見える状態までを学習目標とする):

```bash
vi /etc/alertmanager/alertmanager.yml
```

```yaml
global:
  resolve_timeout: 5m

route:
  receiver: 'log-only'
  group_wait: 10s
  group_interval: 1m
  repeat_interval: 1h

receivers:
  - name: 'log-only'
    webhook_configs:
      - url: 'http://127.0.0.1:9999/dummy'
        send_resolved: true
```

```bash
chown -R alertmanager:alertmanager /etc/alertmanager
```

> **解説: メール通知ではなく Webhook(ダミー)にしている理由**
>
> Alertmanager のメール送信機能を使うと、本格的な SMTP リレー設定が必要になる(送信元アドレス、SMTP サーバ指定、TLS、認証など)。学習スコープでは「Alertmanager にアラートが届く」「Alertmanager の Web UI でアラート一覧が見える」までで本質的な学びは得られるため、Webhook の宛先はダミーにしている(127.0.0.1:9999 は何も listen していないので送信は失敗するが、Alertmanager の動作観察には支障なし)。
>
> Nagios 側のメール通知は実体のある Postfix で行うので、「メール通知の体験」は Nagios 側で実施する。

systemd ユニット作成:

```bash
vi /etc/systemd/system/alertmanager.service
```

```
[Unit]
Description=Alertmanager
After=network.target

[Service]
User=alertmanager
Group=alertmanager
Type=simple
ExecStart=/usr/local/bin/alertmanager \
  --config.file=/etc/alertmanager/alertmanager.yml \
  --storage.path=/var/lib/alertmanager/ \
  --web.listen-address=0.0.0.0:9093

[Install]
WantedBy=multi-user.target
```

起動:

```bash
systemctl daemon-reload
systemctl start alertmanager
systemctl enable alertmanager

curl http://localhost:9093/-/healthy
# OK が返ればOK
```

ブラウザで `http://<MON1_PUB>:9093/` を開き、Alertmanager の Web UI が表示されることを確認する。

---

### Step 3: mon1 に Loki を導入

**目的:** ログ収集サーバを構築する。**mon1 で実施**する。

#### 3-1. 【mon1 で実施】Loki の導入

```bash
cd /usr/local/src
LOKI_VERSION=3.1.1
curl -LO https://github.com/grafana/loki/releases/download/v${LOKI_VERSION}/loki-linux-amd64.zip
dnf install -y unzip
unzip loki-linux-amd64.zip
mv loki-linux-amd64 /usr/local/bin/loki
chmod +x /usr/local/bin/loki

mkdir -p /etc/loki /var/lib/loki
useradd -rs /sbin/nologin loki
chown -R loki:loki /var/lib/loki /usr/local/bin/loki
```

設定ファイル作成:

```bash
vi /etc/loki/loki-config.yml
```

```yaml
auth_enabled: false

server:
  http_listen_port: 3100
  grpc_listen_port: 9096

common:
  path_prefix: /var/lib/loki
  storage:
    filesystem:
      chunks_directory: /var/lib/loki/chunks
      rules_directory: /var/lib/loki/rules
  replication_factor: 1
  ring:
    kvstore:
      store: inmemory

schema_config:
  configs:
    - from: 2024-01-01
      store: tsdb
      object_store: filesystem
      schema: v13
      index:
        prefix: index_
        period: 24h

limits_config:
  allow_structured_metadata: true
  volume_enabled: true
```

```bash
chown -R loki:loki /etc/loki
```

systemd ユニット作成:

```bash
vi /etc/systemd/system/loki.service
```

```
[Unit]
Description=Loki
After=network.target

[Service]
User=loki
Group=loki
Type=simple
ExecStart=/usr/local/bin/loki -config.file=/etc/loki/loki-config.yml

[Install]
WantedBy=multi-user.target
```

起動:

```bash
systemctl daemon-reload
systemctl start loki
systemctl enable loki

# 起動には少し時間がかかる
sleep 10
curl http://localhost:3100/ready
# ready が返ればOK
```

#### 3-2. 【mon1 で実施】Loki への push 動作確認

app1/app2 の Fluent Bit が既に push しているはず。Loki 側でラベルを問い合わせて確認する。

```bash
curl -s 'http://localhost:3100/loki/api/v1/labels' | python3 -m json.tool
# {
#   "status": "success",
#   "data": ["host", "job", "service_name", ...]
# }
# のような出力で "job" が含まれていればOK

curl -s 'http://localhost:3100/loki/api/v1/label/job/values' | python3 -m json.tool
# "fluent-bit" が含まれていればOK
```

> **解説: Loki にラベルが届いていない場合**
>
> - app1/app2 で `systemctl status fluent-bit` を確認し、active(running) か
> - app1/app2 から `curl -v http://<MON1_PRI>:3100/ready` で疎通確認(つながらなければ SG を確認)
> - Fluent Bit のログ `journalctl -u fluent-bit -n 50` でエラーを確認

---

### Step 4: mon1 に Grafana を導入

**目的:** Prometheus(メトリクス)と Loki(ログ)を統合的に可視化する Web UI を構築する。**mon1 で実施**する。

#### 4-1. 【mon1 で実施】Grafana の導入

公式 yum リポジトリから導入する。

```bash
cat > /etc/yum.repos.d/grafana.repo <<'EOF'
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

dnf install -y grafana

systemctl daemon-reload
systemctl start grafana-server
systemctl enable grafana-server
```

ブラウザで `http://<MON1_PUB>:3000/` を開き、初回ログイン(admin / admin、初回ログイン後にパスワード変更を求められる)を行う。

#### 4-2. 【mon1 で実施】データソース追加(Prometheus)

Grafana 左メニューから Connections → Data sources → Add data source。

- Type: **Prometheus**
- URL: `http://127.0.0.1:9090`
- 一番下の **Save & test** をクリック → "Successfully queried the Prometheus API." が出ればOK

#### 4-3. 【mon1 で実施】データソース追加(Loki)

同様に Add data source。

- Type: **Loki**
- URL: `http://127.0.0.1:3100`
- **Save & test** をクリック → "Data source successfully connected." が出ればOK

#### 4-4. 【mon1 で実施】ダッシュボードインポート(node_exporter full)

左メニューから Dashboards → New → Import。

- Import via grafana.com に **1860** を入力 → Load
- Data source(下部)で先ほど追加した Prometheus を選択
- Import

CPU、メモリ、ディスク、ネットワーク等のグラフが app1/app2 ごとに表示される。右上のドロップダウンで instance を切り替えられる。

#### 4-5. 【mon1 で実施】Loki 用パネル作成(Explore で動作確認)

左メニューから Explore を選択し、データソースを Loki に切り替える。

クエリ入力欄に以下を入力して Run query:

```
{job="fluent-bit"}
```

app1/app2 の Nginx アクセスログ・エラーログ・syslog が一覧表示されればOK。

```
{job="fluent-bit", host="app1.local"} |= "404"
```

のようにフィルタすると、特定ホストの特定文字列だけ抽出できる。

> **解説: LogQL の構文**
>
> Loki のクエリ言語は LogQL と呼ばれ、PromQL に似た発想。`{ラベル=値}` で対象ストリームを絞り込み、`|= "文字列"` で含む行のみ抽出。`|~ "正規表現"` も使える。「ログを SQL 的に絞り込む」感覚で、grep のチェーンに近い。

---

### Step 5: mon2 に Postfix を導入(通知用ローカル配送)

**目的:** Nagios からの通知メールをローカルに配送して、メールが届いていることを確認できる状態にする。**mon2 で実施**する。

#### 5-1. 【mon2 で実施】Postfix と mailx の導入

```bash
dnf install -y postfix s-nail

# Amazon Linux 2023 は MTA がデフォルト無しなので Postfix を「デフォルト MTA」に設定
alternatives --set mta /usr/sbin/sendmail.postfix
```

#### 5-2. 【mon2 で実施】Postfix の最小設定

ローカル配送のみ。外部に出さない設定にする。

```bash
postconf -e "inet_interfaces = loopback-only"
postconf -e "mydestination = \$myhostname, localhost.\$mydomain, localhost"

systemctl start postfix
systemctl enable postfix
```

#### 5-3. 【mon2 で実施】メール受信用ユーザー作成(Nagios 通知の宛先)

```bash
useradd -m nagiosadmin
echo "nagiosadmin:Passw0rd!" | chpasswd
```

#### 5-4. 【mon2 で実施】配送確認

```bash
echo "test body" | mail -s "test subject" nagiosadmin@localhost

# 受信箱確認
ls -l /var/spool/mail/nagiosadmin
cat /var/spool/mail/nagiosadmin
# Subject: test subject が含まれていればOK
```

> **解説: なぜここで Postfix を仕込むのか**
>
> Nagios はアラート発生時に「通知コマンド」を実行する設計。デフォルトの通知コマンドが `/bin/mail` を呼び出すため、MTA(Postfix)が動いていないと通知が成立しない。Nagios の動作を完全に体感するには、メールが実際に届いて読める状態が必要。ローカル配送だけなら設定は最小で済む。

---

### Step 6: mon2 に Nagios を導入

**目的:** 死活監視サーバ Nagios を構築し、app1/app2 をアクティブチェック対象として登録する。**mon2 で実施**する。

Amazon Linux 2023 の標準リポジトリには Nagios が無いため、公式ソースからビルドする。

#### 6-1. 【mon2 で実施】ビルド依存パッケージの導入

```bash
dnf install -y gcc glibc glibc-common make wget tar unzip httpd php gd gd-devel perl openssl-devel
dnf install -y net-snmp net-snmp-utils

systemctl start httpd
systemctl enable httpd
```

#### 6-2. 【mon2 で実施】Nagios Core のビルド

```bash
useradd nagios
groupadd nagcmd
usermod -a -G nagcmd nagios
usermod -a -G nagios,nagcmd apache

cd /usr/local/src
NAGIOS_VERSION=4.5.5
wget https://github.com/NagiosEnterprises/nagioscore/releases/download/nagios-${NAGIOS_VERSION}/nagios-${NAGIOS_VERSION}.tar.gz
tar xvf nagios-${NAGIOS_VERSION}.tar.gz
cd nagios-${NAGIOS_VERSION}

./configure --with-command-group=nagcmd
make all
make install
make install-init
make install-commandmode
make install-config
make install-webconf
```

> **解説: `make` ターゲットが分かれている理由**
>
> Nagios の Makefile は、目的別にターゲットが細かく分かれている。`install` は本体、`install-init` は systemd 起動定義、`install-commandmode` は外部コマンド受け付け設定、`install-config` はサンプル設定、`install-webconf` は Apache 連携設定。全部実行することで一式が整う。「ソースビルド型 OSS の典型的なパターン」として体感しておくと、他の OSS でも応用が利く。

#### 6-3. 【mon2 で実施】Nagios Plugins の導入

```bash
cd /usr/local/src
NAGIOS_PLUGINS_VERSION=2.4.11
wget https://github.com/nagios-plugins/nagios-plugins/releases/download/release-${NAGIOS_PLUGINS_VERSION}/nagios-plugins-${NAGIOS_PLUGINS_VERSION}.tar.gz
tar xvf nagios-plugins-${NAGIOS_PLUGINS_VERSION}.tar.gz
cd nagios-plugins-${NAGIOS_PLUGINS_VERSION}

./configure --with-nagios-user=nagios --with-nagios-group=nagios
make
make install
```

#### 6-4. 【mon2 で実施】Web UI のログインユーザー作成

```bash
htpasswd -c -b /usr/local/nagios/etc/htpasswd.users nagiosadmin nagios

systemctl restart httpd
```

#### 6-5. 【mon2 で実施】監視対象(app1, app2)の定義

`/usr/local/nagios/etc/objects/` 配下に独自の設定ファイルを作る。

```bash
vi /usr/local/nagios/etc/objects/app_servers.cfg
```

```
# === app1 のホスト定義 ===
define host {
    use                     linux-server
    host_name               app1
    alias                   App Server 1
    address                 <APP1_PRI>
}

# === app2 のホスト定義 ===
define host {
    use                     linux-server
    host_name               app2
    alias                   App Server 2
    address                 <APP2_PRI>
}

# === app1/app2 をまとめたホストグループ ===
define hostgroup {
    hostgroup_name          app-servers
    alias                   App Servers
    members                 app1, app2
}

# === SSH サービス監視(app1, app2 共通) ===
define service {
    use                     generic-service
    hostgroup_name          app-servers
    service_description     SSH
    check_command           check_ssh
}

# === HTTP サービス監視(app1, app2 共通) ===
define service {
    use                     generic-service
    hostgroup_name          app-servers
    service_description     HTTP
    check_command           check_http
}
```

`<APP1_PRI>`, `<APP2_PRI>` を実際のIPに置換すること。

メイン設定ファイルにこの定義ファイルを読み込ませる:

```bash
vi /usr/local/nagios/etc/nagios.cfg
# ファイル末尾に以下を追記
cfg_file=/usr/local/nagios/etc/objects/app_servers.cfg
```

#### 6-6. 【mon2 で実施】通知先アドレスの設定

デフォルトの通知先 `nagiosadmin` のメールアドレスを、ローカル配送で受信できるよう変更する。

```bash
vi /usr/local/nagios/etc/objects/contacts.cfg
```

`contact_name nagiosadmin` のブロックを探し、`email` 行を以下に変更:

```
email                           nagiosadmin@localhost
```

#### 6-7. 【mon2 で実施】設定検証と起動

```bash
/usr/local/nagios/bin/nagios -v /usr/local/nagios/etc/nagios.cfg
# Things look okay - No serious problems were detected during the pre-flight check
# が出ればOK

systemctl start nagios
systemctl enable nagios
```

ブラウザで `http://<MON2_PUB>/nagios/` を開き、ユーザー `nagiosadmin` / パスワード `nagios` でログイン。

左メニューから **Hosts** や **Services** を選び、app1/app2 の SSH/HTTP サービスが OK(緑)になっていることを確認する(初回は PENDING のことがあるので、1〜2分待つ)。

> **解説: Nagios の「アクティブチェック」**
>
> Nagios は定期的に自分から監視対象にアクセスする(=アクティブチェック)。`check_ssh` は実際に SSH ポートに TCP 接続して banner を読み、`check_http` は実際に HTTP リクエストを投げてレスポンスを確認する。「動いているはず」を仮定するのではなく「動いていることを証明する」アプローチ。
>
> 一方の Prometheus は基本的に pull 型だが、対象が公開したエンドポイントを読みに行くだけで、「サービスとして正しく応答するか」までは保証しない(`up` メトリクスは Exporter プロセスの応答有無であり、Nginx 自体の応答有無ではない)。**両者は似ているようで監視の射程が違う**。

---

### Step 7: 障害シミュレーション

**目的:** 障害を 3 種類発生させ、各監視ツールが「何を捉え、何を捉えないか」を観察する。

> **事前準備:** ブラウザで以下のタブを開いておくと観察しやすい。
> - Prometheus targets: `http://<MON1_PUB>:9090/targets`
> - Prometheus alerts: `http://<MON1_PUB>:9090/alerts`
> - Alertmanager: `http://<MON1_PUB>:9093/`
> - Grafana(node_exporter ダッシュボード): `http://<MON1_PUB>:3000/`
> - Grafana Explore(Loki): `http://<MON1_PUB>:3000/explore`
> - Nagios: `http://<MON2_PUB>/nagios/`

#### 7-1. シナリオ①: app1 の Nginx 停止

```bash
# app1 で実施
systemctl stop nginx
```

**観察ポイント:**

| ツール | 期待される挙動 |
|---|---|
| Nagios | 1〜2分以内に app1 の HTTP サービスが CRITICAL になる |
| Nagios | mon2 で `cat /var/spool/mail/nagiosadmin` すると通知メールが届いている |
| Prometheus | `nginx_exporter` ジョブの app1 ターゲットが Down 表示になる(nginx-exporter が stub_status を取れなくなるため) |
| Prometheus | 1分後に `TargetDown` アラートが発火 |
| Alertmanager | Web UI にアラートが届いている |
| Grafana | node_exporter ダッシュボードはそのまま(node_exporter は別プロセスのため影響なし) |

確認後、復旧:

```bash
systemctl start nginx
```

#### 7-2. シナリオ②: app2 の node_exporter だけ停止

```bash
# app2 で実施
systemctl stop node_exporter
```

**観察ポイント:**

| ツール | 期待される挙動 |
|---|---|
| Prometheus | `node_exporter` ジョブの app2 ターゲットが Down 表示になる |
| Prometheus | 1分後に `TargetDown` アラートが発火 |
| Grafana | node_exporter ダッシュボードで app2 のグラフが途切れる |
| Nagios | **何も検知しない**(Nagios は node_exporter を監視していないため) |

> **考えるポイント: なぜ Nagios は気づかないのか**
>
> 監視ツールは「自分が見るように指示された対象」しか見ない。node_exporter は内部メトリクスを Prometheus に公開するためのプロセスで、サービスとしての価値は Prometheus にだけ意味がある。Nagios は SSH/HTTP の応答有無を見ていて、node_exporter の有無は監視範囲外。
>
> 「**監視ツールを増やすほどカバー範囲は広がるが、増やしただけでは死角はなくならない**」。何をどのツールに任せるか、の設計が監視の本質。

復旧:

```bash
systemctl start node_exporter
```

#### 7-3. シナリオ③: app1 で大量の 404 を発生させる

```bash
# 自分のPC、または mon2 から実行
# 1秒に1回、存在しないURLを 60 回叩く
for i in $(seq 1 60); do
  curl -s -o /dev/null http://<APP1_PUB>/no-such-path-$i
  sleep 1
done
```

**観察ポイント:**

Grafana Explore(Loki) で以下のクエリを実行:

```
{job="fluent-bit", host="app1.local"} |= "404"
```

過去 5 分の時間範囲を指定して Run query すると、404 を含むログ行がずらりと表示される。

メトリクスでも確認:

```
sum(rate(nginx_http_requests_total{instance=~".*<APP1_PRI>.*"}[1m]))
```

(Prometheus の Graph タブで、リクエストレートの急上昇が見える。ただし `nginx_http_requests_total` はステータスコード別ではないので、「404 だけの増加」はメトリクスでは見えず、ログ側で見るのが正解、という体感ができる)

> **考えるポイント: メトリクスとログ、それぞれの得意分野**
>
> メトリクスは「総数の傾向」(リクエスト数全体の急増)は捉えやすいが、「個別の意味」(どの URL が叩かれているか)は失われている。ログは個別の意味は保持しているが、集計には別途処理が必要。
>
> 両者を併用することで「総数の異常 → ログで原因特定」という調査フローが成立する。Grafana で両データソースを切り替えながら使う体験は、まさに現代的な運用の縮図。

復旧は特に必要なし(攻撃ではなくただの404アクセスなので)。

---

## 5. 動作確認・検証

### 5-1. 確認チェックリスト

- [ ] **確認①**: Prometheus targets で全 Exporter が UP
- [ ] **確認②**: Grafana の node_exporter ダッシュボードでメトリクス表示
- [ ] **確認③**: Grafana Explore(Loki)で Nginx ログ表示
- [ ] **確認④**: Nagios で app1/app2 の SSH/HTTP が OK
- [ ] **確認⑤**: Alertmanager Web UI が表示される
- [ ] **確認⑥**: 障害シミュレーション 3 パターンの挙動が想定通り

### 5-2. 個別確認コマンド

#### 確認①: Prometheus targets

```bash
curl -s http://<MON1_PUB>:9090/api/v1/targets | python3 -m json.tool | grep -E '"job"|"health"'
# 全 5 ターゲット(prometheus + node_exporter x2 + nginx_exporter x2)が "health": "up" であればOK
```

#### 確認②: Grafana ダッシュボード

ブラウザで `http://<MON1_PUB>:3000/` → Dashboards → Node Exporter Full を開き、Instance を app1 → app2 と切り替えてグラフが表示されること。

#### 確認③: Loki ログ取得

```bash
curl -s -G 'http://<MON1_PUB>:3100/loki/api/v1/query_range' \
  --data-urlencode 'query={job="fluent-bit"}' \
  --data-urlencode "start=$(date -d '5 minutes ago' +%s)000000000" \
  --data-urlencode "end=$(date +%s)000000000" \
  --data-urlencode 'limit=5' | python3 -m json.tool
# values 配列にログ行が含まれていればOK
```

> ※ `<MON1_PUB>` への 3100 ポートは SG で塞いでいるので、mon1 上で 127.0.0.1 に変えて実行するか、SG を一時的に開ける。

#### 確認④: Nagios

ブラウザで `http://<MON2_PUB>/nagios/` → Services → app1, app2 の SSH/HTTP が緑(OK)。

#### 確認⑤: Alertmanager

ブラウザで `http://<MON1_PUB>:9093/` を開いて Web UI が表示される。アラート発火中なら一覧に表示される。

---

## 6. トラブルシューティング

### エラー①: Prometheus の targets が DOWN になる

**原因:** SG で Exporter ポートが開いていない、または Exporter が起動していない。

```bash
# mon1 から
curl -v http://<APP1_PRI>:9100/metrics
# 接続できなければ app1 の SG で 9100 を 172.31.0.0/16 に開放
# 接続できるなら app1 上で systemctl status node_exporter を確認
```

### エラー②: Fluent Bit が Loki に送れない

```bash
# app1 で
journalctl -u fluent-bit -n 50
# 「connection refused」「dial tcp」等のエラー → mon1 の Loki 起動状況と SG を確認

# app1 から疎通テスト
curl -v http://<MON1_PRI>:3100/ready
```

### エラー③: Nagios の HTTP チェックが CRITICAL のまま

**原因:** app1/app2 の SG で `172.31.0.0/16` からの 80 番が開いていない、または `check_http` プラグインが対象のホスト名/IP を解決できない。

```bash
# mon2 から
/usr/local/nagios/libexec/check_http -H <APP1_PRI>
# HTTP OK が返ればプラグイン側は正常
# 返らなければ SG または Nginx を確認
```

### エラー④: Grafana の Prometheus データソース追加で接続失敗

**原因:** Prometheus が起動していない、または URL のスキーム間違い。

```bash
# mon1 で
curl http://127.0.0.1:9090/-/healthy
# Prometheus Server is Healthy. が返ればOK
```

データソース URL は `http://127.0.0.1:9090` で間違いないか確認。

### エラー⑤: Loki 起動直後にエラー

```bash
journalctl -u loki -n 100
# 「failed to create directory」等が出る場合は /var/lib/loki の所有者を確認
chown -R loki:loki /var/lib/loki
systemctl restart loki
```

### エラー⑥: Nagios のメール通知が来ない

```bash
# mon2 で Postfix のキューと配送ログを確認
mailq
tail -n 50 /var/log/maillog
# Nagios の通知ログを確認
tail -n 50 /usr/local/nagios/var/nagios.log | grep NOTIFICATION
```

### 主要ログの確認場所

| サービス | 確認コマンド |
|---|---|
| Prometheus | `journalctl -u prometheus -f` |
| Alertmanager | `journalctl -u alertmanager -f` |
| Loki | `journalctl -u loki -f` |
| Grafana | `journalctl -u grafana-server -f` |
| Fluent Bit | `journalctl -u fluent-bit -f` |
| node_exporter | `journalctl -u node_exporter -f` |
| nginx-exporter | `journalctl -u nginx_exporter -f` |
| Nginx | `tail -f /var/log/nginx/error.log` |
| Postfix | `tail -f /var/log/maillog` |
| Nagios | `tail -f /usr/local/nagios/var/nagios.log` |

---

## 7. 参考リソース

| 資料名 | URL |
|---|---|
| Prometheus 公式ドキュメント | https://prometheus.io/docs/ |
| Alertmanager 公式ドキュメント | https://prometheus.io/docs/alerting/latest/alertmanager/ |
| Grafana 公式ドキュメント | https://grafana.com/docs/grafana/latest/ |
| Loki 公式ドキュメント | https://grafana.com/docs/loki/latest/ |
| Fluent Bit 公式ドキュメント | https://docs.fluentbit.io/manual |
| Nagios Core ドキュメント | https://www.nagios.org/documentation/ |
| node_exporter | https://github.com/prometheus/node_exporter |
| nginx-prometheus-exporter | https://github.com/nginx/nginx-prometheus-exporter |
| Grafana Dashboard 1860 | https://grafana.com/grafana/dashboards/1860 |

---

## 付録

### A. パラメータまとめ

| パラメータ | 自分の環境の値 | 説明 |
|---|---|---|
| `<MON1_PUB>` | | mon1 グローバルIP(Prom/Graf/Alertmanager Web UI) |
| `<MON1_PRI>` | | mon1 プライベートIP(Fluent Bit → Loki 送信先) |
| `<MON2_PUB>` | | mon2 グローバルIP(Nagios Web UI) |
| `<MON2_PRI>` | | mon2 プライベートIP |
| `<APP1_PUB>` | | app1 グローバルIP(動作確認用) |
| `<APP1_PRI>` | | app1 プライベートIP(Prometheus/Nagios の監視対象) |
| `<APP2_PUB>` | | app2 グローバルIP(動作確認用) |
| `<APP2_PRI>` | | app2 プライベートIP(Prometheus/Nagios の監視対象) |

### B. ポート一覧

| ポート | サービス | サーバ |
|---|---|---|
| 22 | SSH | 全台 |
| 25 | Postfix(ローカル配送のみ) | mon2 |
| 80 | Nginx | app1, app2 |
| 80 | Apache(Nagios Web UI) | mon2 |
| 3000 | Grafana | mon1 |
| 3100 | Loki | mon1 |
| 8080 | Nginx stub_status(ローカル) | app1, app2 |
| 9090 | Prometheus | mon1 |
| 9093 | Alertmanager | mon1 |
| 9100 | node_exporter | app1, app2 |
| 9113 | nginx-prometheus-exporter | app1, app2 |

### C. 用語解説

| 用語 | 説明 |
|---|---|
| pull 型監視 | 監視サーバ側が対象に取りに行く方式。Prometheus が代表例 |
| アクティブチェック | 監視サーバが定期的にサービスへ実通信して応答を確認。Nagios が代表例 |
| Exporter | 対象固有のメトリクスを Prometheus 形式に変換する小さなプロセス |
| LogQL | Loki のクエリ言語。`{label="value"} |= "filter"` の形 |
| stub_status | Nginx の状態情報を出力する標準モジュール |
| ホストグループ | Nagios で複数ホストをまとめる概念。サービス定義を1回で済ませられる |
| Alertmanager | Prometheus から受け取ったアラートをグルーピング・抑制・通知する |

### D. クリーンアップ手順

1. app1, app2 で `systemctl stop fluent-bit node_exporter nginx_exporter nginx`
2. mon1 で `systemctl stop prometheus alertmanager loki grafana-server`
3. mon2 で `systemctl stop nagios httpd postfix`
4. EC2 4 台を終了する
5. セキュリティグループを削除する
6. 必要に応じてキーペアを削除する
