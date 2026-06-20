# Fluentd / Fluent Bit 基本・発展課題集

> ログ収集・転送基盤。現場のログ管理で広く使われる  
> 前提：AWS 無料利用枠の範囲内で実施可能な課題を基本とする  
> 作成日：2026年6月

---

## 目次

1. [基本課題 A：Fluent Bit のインストールと基本設定](#基本課題-afluent-bit-のインストールと基本設定)
2. [基本課題 B：ログの収集と転送](#基本課題-bログの収集と転送)
3. [基本課題 C：フィルタリングとパース](#基本課題-cフィルタリングとパース)
4. [発展課題 D：CloudWatch Logs への転送](#発展課題-dcloudwatch-logs-への転送)
5. [発展課題 E：OpenSearch / Elasticsearch への転送](#発展課題-eopensearch--elasticsearch-への転送)
6. [発展課題 F：複数 EC2 からのログ集約](#発展課題-f複数-ec2-からのログ集約)
7. [発展課題 G：Fluentd との比較と使い分け](#発展課題-gfluentd-との比較と使い分け)
8. [発展課題 H：耐障害性と監視](#発展課題-h耐障害性と監視)

---

## 基本課題 A：Fluent Bit のインストールと基本設定

**A-1. EC2 への Fluent Bit インストール**
- AL2023 の EC2 に Fluent Bit をインストールし、`systemd` でサービス登録・自動起動を設定する
- `fluent-bit --version` でバージョンを確認する
- 設定ファイル（`/etc/fluent-bit/fluent-bit.conf`）の基本構造（`[SERVICE]`・`[INPUT]`・`[FILTER]`・`[OUTPUT]`）を理解する

**A-2. 基本的な設定ファイルの作成**
- 標準入力からログを受け取り、標準出力に表示する最小構成を作成する

```ini
[SERVICE]
    Flush        1
    Log_Level    info

[INPUT]
    Name   tail
    Path   /var/log/messages
    Tag    system.messages

[OUTPUT]
    Name   stdout
    Match  *
```

---

## 基本課題 B：ログの収集と転送

**B-1. Apache / Nginx アクセスログの収集**
- `tail` Input プラグインで Apache のアクセスログを収集し、`stdout` に出力して収集できていることを確認する
- `Tag` の命名規則（`apache.access`・`nginx.access`）を設定し、`Match` パターンで出力先を振り分ける

**B-2. systemd ログの収集**
- `systemd` Input プラグインで `journald` のログを収集し、サービス別にフィルタリングする

**B-3. マルチライン対応**
- Java のスタックトレースや複数行にわたるログを 1 イベントとして扱う `multiline` パーサーを設定する

---

## 基本課題 C：フィルタリングとパース

**C-1. Regex パーサーによるログのパース**
- Apache のアクセスログを Regex パーサーで構造化（IP・メソッド・URL・ステータスコード・レスポンスサイズを個別フィールドに分解）する

```ini
[FILTER]
    Name   parser
    Match  apache.access
    Key_Name log
    Parser apache

# /etc/fluent-bit/parsers.conf に追加
[PARSER]
    Name   apache
    Format regex
    Regex  ^(?<host>[^ ]*) [^ ]* (?<user>[^ ]*) \[(?<time>[^\]]*)\] "(?<method>\S+)(?: +(?<path>[^\"]*?)(?: +\S*)?)?" (?<code>[^ ]*) (?<size>[^ ]*)
    Time_Key time
    Time_Format %d/%b/%Y:%H:%M:%S %z
```

**C-2. grep フィルターによるログの絞り込み**
- `grep` フィルターで HTTP ステータスコードが 5xx のログのみを抽出し、別の出力先に転送する設定を行う

**C-3. record_modifier によるフィールド追加**
- `record_modifier` フィルターでホスト名・環境名（`env: production`）をすべてのログレコードに追加する

---

## 発展課題 D：CloudWatch Logs への転送

**D-1. CloudWatch Logs Output の設定**
- `cloudwatch_logs` Output プラグインを設定し、Apache アクセスログを CloudWatch Logs に転送する
- IAM ロール（インスタンスプロファイル）で CloudWatch Logs への書き込み権限を付与し、アクセスキーをコードに書かない設計にする

```ini
[OUTPUT]
    Name              cloudwatch_logs
    Match             apache.*
    region            ap-northeast-1
    log_group_name    /ec2/apache
    log_stream_prefix ${HOSTNAME}-
    auto_create_group On
```

**D-2. ログの構造化と Logs Insights での分析**
- パース済みの構造化ログを CloudWatch Logs に転送し、Logs Insights でステータスコード別の集計クエリを実行する

---

## 発展課題 E：OpenSearch / Elasticsearch への転送

**E-1. OpenSearch Output の設定**
- `opensearch`（または `es`）Output プラグインを設定し、ログを OpenSearch に転送する
- インデックス名にタイムスタンプを付与（`logstash_format On`）して日次インデックスを自動生成する設定を行う

---

## 発展課題 F：複数 EC2 からのログ集約

**F-1. Forward プロトコルによる集約**
- 各 EC2 に Fluent Bit を導入し、`forward` Output プラグインで中央の集約サーバー（Fluent Bit または Fluentd）にログを転送する
- 集約サーバーで `forward` Input プラグインでログを受信し、CloudWatch Logs / S3 / OpenSearch に転送する

**F-2. バッファリングとリトライ設定**
- ファイルシステムバッファリング（`storage.type filesystem`）を設定し、ネットワーク障害時でもログが失われない設定を行う
- `Retry_Limit` と `Retry_Limit Off`（無制限リトライ）の使い分けをまとめる

---

## 発展課題 G：Fluentd との比較と使い分け

**G-1. 比較表の作成**

| 観点 | Fluent Bit | Fluentd |
|------|-----------|---------|
| 実装言語 | C | Ruby |
| メモリ使用量 | 約 650KB | 約 40MB |
| CPU 使用率 | 低 | 中 |
| プラグイン数 | 少（厳選） | 多（500 以上） |
| 設定の柔軟性 | 中 | 高 |
| 推奨用途 | エッジ・組み込み・コンテナ | 集約サーバー・複雑な変換 |

---

## 発展課題 H：耐障害性と監視

**H-1. Fluent Bit 自体の監視**
- `[SERVICE]` の `HTTP_Server On` を設定し、`http://localhost:2020/api/v1/metrics` で Fluent Bit のメトリクスを取得する
- 取得したメトリクスを Prometheus でスクレイプし、ログの転送遅延・エラー数を Grafana で可視化する

---

*以上（Fluentd / Fluent Bit 基本・発展課題）*
