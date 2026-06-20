# Elasticsearch / OpenSearch 基本・発展課題集

> 本ファイルでは OSS として利用可能な OpenSearch を主な対象とします  
> Elasticsearch と OpenSearch はほぼ同一の API を持つため、両方に適用できる課題です  
> 前提：AWS 無料利用枠の範囲内で実施可能な課題を基本とする（OpenSearch Service は無料枠対象外のため EC2 上での自己ホストを推奨）  
> 作成日：2026年5月

---

## 目次

1. [基本課題 A：インストールと基本操作](#基本課題-aインストールと基本操作)
2. [基本課題 B：インデックスとドキュメントの管理](#基本課題-bインデックスとドキュメントの管理)
3. [基本課題 C：検索クエリの習得](#基本課題-c検索クエリの習得)
4. [発展課題 D：ログ収集基盤の構築](#発展課題-dログ収集基盤の構築)
5. [発展課題 E：OpenSearch Dashboards による可視化](#発展課題-eopensearch-dashboards-による可視化)
6. [発展課題 F：パフォーマンスチューニング](#発展課題-fパフォーマンスチューニング)
7. [発展課題 G：クラスター構成と高可用性](#発展課題-gクラスター構成と高可用性)
8. [発展課題 H：セキュリティ強化](#発展課題-hセキュリティ強化)

---

## 基本課題 A：インストールと基本操作

**A-1. EC2 への OpenSearch インストール**
- AL2023 の EC2（t2.micro は RAM 1GB のためスワップ 2GB の設定が必須）に OpenSearch をインストールする
- JVM のヒープサイズを RAM の半分（t2.micro の場合 512MB）に設定し、OOM による起動失敗を防ぐ
- `systemd` でサービスとして登録・自動起動を設定し、`curl http://localhost:9200` でレスポンスが返ることを確認する

**A-2. REST API の基本操作**
- `curl` または `httpie` を使い、以下の REST API 操作を実施する
  - `GET /` でクラスターの基本情報を取得する
  - `GET /_cluster/health` でクラスターの健全性（`green`・`yellow`・`red`）を確認する
  - `GET /_cat/indices?v` でインデックス一覧を確認する
  - `GET /_cat/nodes?v` でノードの状態を確認する

**A-3. OpenSearch Dashboards のインストール**
- OpenSearch Dashboards を同一 EC2 にインストールし、ブラウザからアクセスできることを確認する（デフォルトポート：5601）
- Security Group で 5601 番ポートを自分の IP のみ許可する設定を行う

---

## 基本課題 B：インデックスとドキュメントの管理

**B-1. インデックスの作成と設定**
- REST API でインデックスを作成し、シャード数（`number_of_shards`）とレプリカ数（`number_of_replicas`）を指定する
- t2.micro のシングルノード環境では `number_of_replicas: 0` に設定し、クラスターが `green` になることを確認する
- インデックスのマッピング（フィールドの型定義）を明示的に設定し、動的マッピングとの違いを確認する

```bash
# インデックス作成例
curl -X PUT "localhost:9200/logs" -H 'Content-Type: application/json' -d '
{
  "settings": {
    "number_of_shards": 1,
    "number_of_replicas": 0
  },
  "mappings": {
    "properties": {
      "timestamp": { "type": "date" },
      "level":     { "type": "keyword" },
      "message":   { "type": "text" },
      "host":      { "type": "keyword" }
    }
  }
}'
```

**B-2. ドキュメントの CRUD 操作**
- `POST`・`PUT`・`GET`・`DELETE` で Apache アクセスログのデータをドキュメントとして操作する
- `_bulk` API を使って複数ドキュメントを一括投入し、1 件ずつ投入した場合と処理時間を比較する
- `_update` API でドキュメントの特定フィールドのみを部分更新する

**B-3. インデックステンプレートの活用**
- インデックステンプレートを作成し、`logs-*` にマッチするインデックスに自動でマッピングとセッティングが適用されることを確認する
- インデックスの自動ローリング（日次で `logs-2026.05.01`・`logs-2026.05.02` ... と自動作成）の仕組みを理解する

---

## 基本課題 C：検索クエリの習得

**C-1. 基本的な検索クエリ**
- `match`・`term`・`range`・`bool`（`must`・`should`・`must_not`）クエリを組み合わせてログを検索する

```bash
# bool クエリの例：ERROR レベルかつ特定ホストからのログを取得
curl -X GET "localhost:9200/logs/_search" -H 'Content-Type: application/json' -d '
{
  "query": {
    "bool": {
      "must": [
        { "term":  { "level": "ERROR" } },
        { "match": { "host": "web-server-01" } }
      ],
      "filter": [
        { "range": { "timestamp": { "gte": "now-1h" } } }
      ]
    }
  }
}'
```

**C-2. 集計（Aggregation）**
- `terms` 集計でログレベル別の件数を集計する
- `date_histogram` 集計で 1 時間ごとのエラー件数の推移を集計する
- `avg`・`max`・`percentiles` 集計で Apache のレスポンスタイム統計を算出する

**C-3. 全文検索と形態素解析**
- `match` クエリと `term` クエリの違い（アナライザーの有無）を理解する
- 日本語テキストの検索には `kuromoji` プラグインを使った形態素解析が必要なことを確認し、インストールして動作を確認する

---

## 発展課題 D：ログ収集基盤の構築

**D-1. Fluent Bit → OpenSearch パイプライン**
- EC2 の Apache アクセスログを Fluent Bit で収集し、OpenSearch に転送するパイプラインを構築する
- Fluent Bit の OpenSearch 出力プラグイン（`opensearch`）の設定（`Host`・`Index`・`Type`）を行う
- ログが OpenSearch に取り込まれていることを `GET /logs-*/_count` で確認する

**D-2. 複数 EC2 からのログ集約**
- Web サーバー・AP サーバー・DB サーバーの各 EC2 に Fluent Bit を導入し、それぞれのログを中央の OpenSearch に集約する
- ホスト名・サービス名をフィールドとしてログに付加し、OpenSearch 上でサーバーごとにフィルタリングできる構成にする
- Fluent Bit のバッファリング設定（`storage.type filesystem`）を行い、OpenSearch が一時停止してもログが失われない耐障害性を持たせる

**D-3. Logstash との比較**
- Logstash（Java ベース・高機能・重い）と Fluent Bit（C ベース・軽量）を以下の観点で比較する
  - リソース消費量（CPU・メモリ）
  - サポートするプラグイン数と柔軟性
  - t2.micro での動作可否
  - ログ変換・フィルタリングの記述のしやすさ

---

## 発展課題 E：OpenSearch Dashboards による可視化

**E-1. 基本的なダッシュボード構築**
- Index Pattern を作成し、Discover でリアルタイムにログを検索・フィルタリングする
- Visualize で以下のグラフを作成し、Dashboard にまとめる
  - HTTP ステータスコード別のパイチャート
  - 時系列エラー件数の折れ線グラフ
  - アクセス元 IP のワードクラウド（Top N テーブル）

**E-2. アラートの設定**
- OpenSearch の Alerting 機能でモニターを作成し、5xx エラーが 1 分間に 10 件を超えた場合に通知する設定を行う
- 通知先として Slack Webhook または Amazon SNS を設定し、実際にアラートが届くことを確認する

**E-3. Anomaly Detection の活用**
- OpenSearch の Anomaly Detection 機能を使い、アクセス数の異常（急増・急減）を機械学習で自動検出する設定を行う
- 実際に `ab` で大量リクエストを送り、異常として検出されることを確認する

---

## 発展課題 F：パフォーマンスチューニング

**F-1. インデックスの最適化**
- `_forcemerge` でセグメントを統合し、検索パフォーマンスを改善する
- `index.refresh_interval` を調整し、ログ取り込み中は更新頻度を下げてインデックスパフォーマンスを向上させる
- `index.number_of_shards` の設定と検索パフォーマンスの関係（シャード数が多すぎるとオーバーヘッドが大きくなる）を理解する

**F-2. 不要インデックスの管理**
- Index State Management（ISM）ポリシーを設定し、古いインデックス（例：30 日以上前のログ）を自動削除する
- ロールオーバーポリシーで、インデックスのサイズまたは経過日数に応じて新しいインデックスに自動で切り替える設定を行う

---

## 発展課題 G：クラスター構成と高可用性

**G-1. マルチノードクラスターの構築**
- 2 台の EC2 で OpenSearch クラスターを構成し、`GET /_cluster/health` でステータスが `green` になることを確認する
- 一方のノードを停止し、クラスターステータスが `yellow` になり、もう一方のノードで検索が継続できることを確認する

**G-2. OpenSearch Service との比較**
- EC2 上の自前 OpenSearch と Amazon OpenSearch Service を以下の観点で比較する
  - 管理コスト・マルチ AZ 対応・自動バックアップ・スナップショット管理
  - OpenSearch Service は無料枠対象外のため、費用感の把握に留める

---

## 発展課題 H：セキュリティ強化

**H-1. 認証と認可の設定**
- OpenSearch の Security プラグインを使い、ユーザーとロールを作成する
- 読み取り専用ユーザー（Dashboards 閲覧のみ）と管理ユーザーの権限を分離する
- インデックスレベルのアクセス制御を設定し、特定ユーザーが特定インデックスにしかアクセスできない構成を実装する

**H-2. TLS の設定**
- ノード間通信（Transport TLS）とクライアント通信（HTTP TLS）に自己署名証明書を適用する
- `curl -k https://localhost:9200` で TLS 接続が確立されることを確認する

**H-3. 監査ログの有効化**
- OpenSearch の Audit Logging を有効化し、誰がいつどのインデックスにアクセスしたかを記録する
- 監査ログを CloudWatch Logs に転送し、不審なアクセスパターン（深夜の大量削除操作など）を検知するフィルターを設定する

---

*以上（Elasticsearch / OpenSearch 基本・発展課題）*
