# Prometheus + Grafana 基本・発展課題集

> モダン監視スタック。現場での採用率が急増中。Zabbix との比較で理解を深めます  
> 前提：AWS 無料利用枠の範囲内で実施可能な課題を基本とする  
> 作成日：2026年6月

---

## 目次

1. [基本課題 A：Prometheus のインストールと基本設定](#基本課題-aprometheus-のインストールと基本設定)
2. [基本課題 B：Node Exporter によるメトリクス収集](#基本課題-bnode-exporter-によるメトリクス収集)
3. [基本課題 C：Grafana のインストールとダッシュボード構築](#基本課題-cgrafana-のインストールとダッシュボード構築)
4. [発展課題 D：各種 Exporter の導入](#発展課題-d各種-exporter-の導入)
5. [発展課題 E：PromQL の習得](#発展課題-epromql-の習得)
6. [発展課題 F：アラートルールの設定](#発展課題-fアラートルールの設定)
7. [発展課題 G：Grafana の高度な活用](#発展課題-ggrafana-の高度な活用)
8. [発展課題 H：高可用性と長期保存](#発展課題-h高可用性と長期保存)
9. [発展課題 I：Zabbix / CloudWatch との比較と使い分け](#発展課題-izabbix--cloudwatch-との比較と使い分け)

---

## 基本課題 A：Prometheus のインストールと基本設定

**A-1. EC2 への Prometheus インストール**
- AL2023 の EC2 に Prometheus バイナリをインストールし、`systemd` サービスとして登録・自動起動を設定する
- `prometheus --version` でバージョンを確認し、`http://localhost:9090` でブラウザから Web UI にアクセスする
- Security Group で 9090 番ポートを自分の IP のみに制限する

**A-2. prometheus.yml の基本設定**
- `scrape_interval`・`evaluation_interval`・`scrape_configs` の構造を理解する

```yaml
global:
  scrape_interval: 15s
  evaluation_interval: 15s

scrape_configs:
  - job_name: 'prometheus'
    static_configs:
      - targets: ['localhost:9090']

  - job_name: 'node'
    static_configs:
      - targets: ['10.0.1.10:9100', '10.0.1.11:9100']
```

**A-3. Prometheus Web UI の操作**
- Web UI の「Graph」タブで `up` クエリを実行し、監視対象の状態を確認する
- 「Targets」ページで各ターゲットの scrape 状態（UP/DOWN）をリアルタイムに確認する
- 「TSDB Status」でデータの保存状況を確認する

---

## 基本課題 B：Node Exporter によるメトリクス収集

**B-1. Node Exporter のインストール**
- 監視対象の EC2（複数台）に Node Exporter をインストールし、`systemd` でサービス登録・自動起動を設定する
- `curl http://localhost:9100/metrics` でメトリクスが取得できることを確認する
- Security Group で 9100 番ポートを Prometheus サーバーのプライベート IP のみに制限する

**B-2. 主要メトリクスの理解**
- 以下の主要メトリクスの意味と計算方法を理解する

| メトリクス | 意味 |
|-----------|------|
| `node_cpu_seconds_total` | CPU 使用時間（モード別） |
| `node_memory_MemAvailable_bytes` | 利用可能メモリ |
| `node_disk_read_bytes_total` | ディスク読み取りバイト数 |
| `node_network_receive_bytes_total` | ネットワーク受信バイト数 |
| `node_filesystem_avail_bytes` | ファイルシステムの空き容量 |
| `node_load1` | 1 分間のロードアベレージ |

---

## 基本課題 C：Grafana のインストールとダッシュボード構築

**C-1. Grafana のインストール**
- AL2023 の EC2 に Grafana をインストールし、`systemd` でサービス登録・自動起動を設定する
- ブラウザから `http://localhost:3000` にアクセスし、初期パスワード（admin/admin）でログイン後にパスワードを変更する

**C-2. Prometheus データソースの追加**
- Grafana の「Data Sources」で Prometheus を追加し（URL: `http://localhost:9090`）、接続テストが成功することを確認する

**C-3. ダッシュボードのインポート**
- 「Node Exporter Full」（Dashboard ID: 1860）をインポートし、EC2 のシステムメトリクスが可視化されることを確認する
- CPU・メモリ・ディスク・ネットワークの各グラフが正しくデータを表示していることを確認する

---

## 発展課題 D：各種 Exporter の導入

**D-1. ミドルウェア別 Exporter の設定**
- 以下の Exporter をインストールし、Prometheus のスクレイプ設定に追加する

| Exporter | 対象 | ポート |
|---------|------|------|
| `mysqld_exporter` | MySQL / MariaDB | 9104 |
| `postgres_exporter` | PostgreSQL | 9187 |
| `apache_exporter` | Apache（mod_status） | 9117 |
| `nginx-prometheus-exporter` | Nginx（stub_status） | 9113 |
| `redis_exporter` | Redis | 9121 |
| `haproxy_exporter` | HAProxy | 9101 |
| `blackbox_exporter` | HTTP/TCP 死活監視 | 9115 |

**D-2. Blackbox Exporter による死活監視**
- `blackbox_exporter` を設定し、HTTP エンドポイントへの疎通確認・SSL 証明書の有効期限監視を実装する

```yaml
# prometheus.yml に追加
- job_name: 'blackbox_http'
  metrics_path: /probe
  params:
    module: [http_2xx]
  static_configs:
    - targets:
        - http://10.0.1.10/health
        - https://example.com
  relabel_configs:
    - source_labels: [__address__]
      target_label: __param_target
    - target_label: __address__
      replacement: localhost:9115
```

---

## 発展課題 E：PromQL の習得

**E-1. 基本的な PromQL クエリ**
- 以下のクエリを Web UI で実行し、結果を確認する

```promql
# CPU 使用率（%）
100 - (avg by(instance) (rate(node_cpu_seconds_total{mode="idle"}[5m])) * 100)

# メモリ使用率（%）
(1 - node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes) * 100

# ディスク使用率（%）
(1 - node_filesystem_avail_bytes{fstype!~"tmpfs|devtmpfs"} /
     node_filesystem_size_bytes{fstype!~"tmpfs|devtmpfs"}) * 100

# ネットワーク受信レート（bytes/sec）
rate(node_network_receive_bytes_total{device!="lo"}[5m])

# Apache の現在のリクエスト処理数
apache_scoreboard{state="open"}
```

**E-2. 集計関数の活用**
- `sum`・`avg`・`max`・`min`・`count` の集計関数を `by` / `without` と組み合わせて使い、複数インスタンスの集計クエリを作成する
- `rate()`・`irate()`・`increase()` の違いを理解し、適切な場面で使い分ける

---

## 発展課題 F：アラートルールの設定

**F-1. アラートルールファイルの作成**
- `alert.rules.yml` でアラートルールを定義する

```yaml
groups:
  - name: node_alerts
    rules:
      - alert: HighCpuUsage
        expr: 100 - (avg by(instance) (rate(node_cpu_seconds_total{mode="idle"}[5m])) * 100) > 80
        for: 5m
        labels:
          severity: warning
        annotations:
          summary: "CPU 使用率が高い ({{ $labels.instance }})"
          description: "CPU 使用率が {{ $value | printf \"%.1f\" }}% です"

      - alert: LowDiskSpace
        expr: (node_filesystem_avail_bytes{fstype!~"tmpfs|devtmpfs"} / node_filesystem_size_bytes) * 100 < 20
        for: 1m
        labels:
          severity: critical
        annotations:
          summary: "ディスク空き容量が少ない ({{ $labels.instance }})"
```

**F-2. Alertmanager の設定**
- Alertmanager をインストールし、アラート発火時に Slack / SNS / メールに通知する設定を行う
- アラートのグルーピング・重複排除・通知抑制（silence）の動作を確認する

---

## 発展課題 G：Grafana の高度な活用

**G-1. カスタムダッシュボードの作成**
- PromQL クエリを使い、以下のパネルを含むカスタムダッシュボードをゼロから作成する
  - CPU / メモリ / ディスク使用率の時系列グラフ
  - 全サーバーの稼働状態（Stat パネル）
  - HTTP エラーレートの折れ線グラフ
  - アラート発火履歴の一覧（Alert List パネル）

**G-2. 変数の活用**
- ダッシュボードに `$instance` 変数を追加し、プルダウンで監視対象を切り替えられるインタラクティブなダッシュボードを構築する

**G-3. Grafana アラートの設定**
- Grafana のアラート機能を使い、ダッシュボードのパネルから直接アラートルールを作成し、Slack / SNS に通知する設定を行う

---

## 発展課題 H：高可用性と長期保存

**H-1. データ保存期間の設定**
- Prometheus のデフォルトデータ保存期間（15 日）を変更し、EBS の容量に合わせて設定する
- `--storage.tsdb.retention.time` と `--storage.tsdb.retention.size` の使い分けを理解する

**H-2. Thanos による長期保存**
- Thanos Sidecar を Prometheus と同居させ、メトリクスデータを S3 に長期保存する構成を構築する（概念理解と基本設定まで）

---

## 発展課題 I：Zabbix / CloudWatch との比較と使い分け

**I-1. 三者比較表の作成**

| 観点 | Zabbix | Prometheus + Grafana | CloudWatch |
|------|--------|---------------------|-----------|
| データモデル | アイテム（ポーリング） | 時系列メトリクス（スクレイプ） | メトリクス（push / pull） |
| クエリ言語 | なし（GUI） | PromQL | CloudWatch Insights |
| 収集方式 | エージェント（push） | Exporter（pull） | エージェント / API |
| 可視化 | 内蔵 | Grafana（外部） | 内蔵 |
| AWS 統合 | 手動設定 | CloudWatch Exporter で対応 | ネイティブ |
| 学習コスト | 中 | 高（PromQL） | 低 |
| 管理コスト | 高 | 高 | 低（マネージド） |

---

*以上（Prometheus + Grafana 基本・発展課題）*
