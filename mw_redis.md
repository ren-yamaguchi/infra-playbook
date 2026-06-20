# Redis 基本・発展課題集

> 前提：AWS 無料利用枠の範囲内で実施可能な課題を基本とする  
> 作成日：2026年5月

---

## 目次

1. [基本課題 A：インストールと基本操作](#基本課題-aインストールと基本操作)
2. [基本課題 B：データ型の理解](#基本課題-bデータ型の理解)
3. [基本課題 C：永続化の設定](#基本課題-c永続化の設定)
4. [発展課題 D：Web アプリケーションとのキャッシュ連携](#発展課題-dweb-アプリケーションとのキャッシュ連携)
5. [発展課題 E：セッション管理への活用](#発展課題-eセッション管理への活用)
6. [発展課題 F：パフォーマンスチューニング](#発展課題-fパフォーマンスチューニング)
7. [発展課題 G：レプリケーションと高可用性](#発展課題-gレプリケーションと高可用性)
8. [発展課題 H：監視と運用](#発展課題-h監視と運用)
9. [発展課題 I：セキュリティ強化](#発展課題-iセキュリティ強化)

---

## 基本課題 A：インストールと基本操作

**A-1. EC2 への Redis インストール**
- AL2023 の EC2 に Redis をインストールし、`systemd` でサービスとして登録・自動起動を設定する
- `redis-cli ping` で `PONG` が返ることを確認し、`redis-cli info server` でバージョン・稼働時間・設定ファイルパスを確認する
- `redis.conf` の主要な設定項目（`bind`・`port`・`requirepass`・`maxmemory`）の意味と役割を整理する

**A-2. 基本コマンドの習得**
- `redis-cli` で以下の操作を実施し、各コマンドの動作を確認する
  - `SET`・`GET`・`DEL`・`EXISTS`・`TYPE`・`TTL`・`EXPIRE`
  - `KEYS *`（本番禁止コマンドとして理由も含めて理解する）
  - `SCAN` で安全にキーを列挙する方法を確認する
- `EXPIRE` でキーに有効期限（TTL）を設定し、`TTL` コマンドで残り時間を確認する
- `DEBUG SLEEP` でレイテンシのシミュレーションを行い、`redis-cli --latency` でレイテンシ計測を行う

**A-3. 外部からの接続設定**
- `redis.conf` の `bind` を `127.0.0.1` から EC2 のプライベート IP に変更し、別の EC2 から `redis-cli -h <IP>` で接続できることを確認する
- Security Group で Redis のポート（6379）を特定の EC2 プライベート IP のみに開放する設定を行い、意図しない接続が拒否されることを確認する

---

## 基本課題 B：データ型の理解

**B-1. String（文字列）**
- `SET`・`GET`・`INCR`・`DECR`・`APPEND`・`STRLEN` でカウンター・文字列操作を実施する
- `MSET`・`MGET` で複数キーの一括操作を行い、往復回数を削減する効果を確認する
- `SETNX`（SET if Not eXists）を使った分散ロックの基本的な考え方を理解する

**B-2. List・Set・Hash・Sorted Set**
- List（`LPUSH`・`RPUSH`・`LPOP`・`LRANGE`）でキューとスタックを実装し、それぞれの使い所をまとめる
- Hash（`HSET`・`HGET`・`HGETALL`）でユーザー情報（`user:1001 name "Taro" age 30`）を構造化して格納する
- Sorted Set（`ZADD`・`ZRANGE`・`ZRANK`）でスコアランキングを実装する
- Set（`SADD`・`SMEMBERS`・`SINTER`・`SUNION`）で集合演算（共通ユーザーの抽出など）を実装する

**B-3. パブリッシュ / サブスクライブ**
- `PUBLISH` と `SUBSCRIBE` でシンプルなメッセージキューを実装し、別のターミナルでリアルタイムにメッセージを受信できることを確認する
- `PSUBSCRIBE` でパターンマッチングによる複数チャンネルの購読を試す

---

## 基本課題 C：永続化の設定

**C-1. RDB（スナップショット）の設定**
- `redis.conf` の `save` ディレクティブで RDB スナップショットの取得タイミングを設定する
- `BGSAVE` でバックグラウンドスナップショットを手動実行し、`dump.rdb` ファイルが生成されることを確認する
- Redis を停止・起動し、RDB から自動的にデータが復元されることを確認する

**C-2. AOF（Append Only File）の設定**
- `appendonly yes` を設定して AOF を有効化し、`appendfsync` オプション（`always`・`everysec`・`no`）の違いを整理する
- `redis-check-aof` で AOF ファイルの整合性を確認し、破損した場合の修復手順を試す
- RDB と AOF の両方を有効にした場合の起動時の優先順位（AOF が優先）を確認する

**C-3. RDB vs AOF の比較**
- RDB（復旧速度が速い・データロスが大きい）と AOF（復旧に時間がかかる・データロスが小さい）の特性を整理し、用途別の選択基準をまとめる

---

## 発展課題 D：Web アプリケーションとのキャッシュ連携

**D-1. WordPress のオブジェクトキャッシュ**
- EC2 上の WordPress に `Redis Object Cache` プラグインを導入し、同一 EC2 または別 EC2 の Redis に接続する
- `redis-cli monitor` でリアルタイムにコマンドを監視し、WordPress のページロード時に Redis への GET/SET が発生していることを確認する
- キャッシュ有効・無効で WordPress のレスポンスタイムを `ab` で計測し、効果を数値で確認する

**D-2. キャッシュ戦略の実装**
- 以下の 3 つのキャッシュ戦略をシンプルなスクリプトで実装し、それぞれの特性を比較する
  - **Cache-Aside**：アプリがキャッシュを確認し、なければ DB から取得してキャッシュに格納する
  - **Write-Through**：データ書き込み時にキャッシュと DB の両方を更新する
  - **Write-Behind**：キャッシュへの書き込みのみ行い、非同期で DB に反映する
- キャッシュヒット率を `INFO stats` の `keyspace_hits` / `keyspace_misses` で計算するスクリプトを作成する

**D-3. キャッシュ無効化の戦略**
- TTL ベースの自動失効と、データ更新時に明示的に `DEL` するアクティブ無効化の違いを実装して比較する
- キャッシュスタンピード（キャッシュ失効時に大量リクエストが DB に集中する問題）を再現し、ロック（`SETNX`）による回避策を実装する

---

## 発展課題 E：セッション管理への活用

**E-1. PHP セッションの Redis 格納**
- PHP の `session.save_handler = redis` と `session.save_path = "tcp://127.0.0.1:6379"` を設定し、セッションデータが Redis に格納されることを確認する
- `redis-cli keys "PHPREDIS_SESSION:*"` でセッションキーを確認し、TTL がセッションタイムアウトと連動していることを確認する

**E-2. ALB + 複数 EC2 でのセッション共有**
- 2 台の Web サーバーが共通の Redis にセッションを格納する構成を構築し、ALB でラウンドロビンしてもセッションが維持されることを確認する
- スティッキーセッション（ALB の Cookie ベース固定）との比較で、Redis セッション共有の利点（水平スケールの容易さ）をまとめる

**E-3. セッションの有効期限管理**
- セッション TTL を Redis で管理し、ユーザーのリクエスト毎に `EXPIRE` でリセットするスライディング有効期限を実装する

---

## 発展課題 F：パフォーマンスチューニング

**F-1. maxmemory とエビクションポリシー**
- `maxmemory 512mb` でメモリ上限を設定し、上限に達した場合のエビクションポリシー（`allkeys-lru`・`volatile-lru`・`noeviction` など）の違いを確認する
- `INFO memory` でメモリ使用量・断片化率（`mem_fragmentation_ratio`）を確認し、断片化が大きい場合の対処（`MEMORY PURGE`）を試す

**F-2. パイプラインによるバッチ処理**
- 1000 件のデータを 1 コマンドずつ送信した場合と、`pipeline` でまとめて送信した場合の処理時間を比較し、ネットワーク往復コストの削減効果を確認する

**F-3. redis-benchmark による性能計測**
- `redis-benchmark -n 100000 -c 50` でスループット（ops/sec）を計測する
- 各コマンド（`SET`・`GET`・`LPUSH`・`SADD`）の性能を計測し、EC2 の t2.micro でどの程度の処理能力があるかを把握する

---

## 発展課題 G：レプリケーションと高可用性

**G-1. Primary / Replica レプリケーション**
- 2 台の EC2 で Primary / Replica 構成を設定し、`REPLICAOF <Primary IP> 6379` でレプリケーションを開始する
- `INFO replication` でレプリケーションの状態（接続状況・オフセット・ラグ）を確認する
- Primary への書き込みが Replica に即座に反映されることを `redis-cli -h <Replica IP>` で確認する

**G-2. Sentinel による自動フェイルオーバー**
- Redis Sentinel を 3 台（奇数台が必要）の EC2 に設定し、Primary 障害時に自動でフェイルオーバーする構成を構築する
- Primary を意図的に停止し、Sentinel が障害を検知して新しい Primary を選出するまでの時間を計測する
- アプリケーションが Sentinel 経由で現在の Primary を動的に取得する接続方式を実装する

**G-3. ElastiCache との比較**
- EC2 上の自前 Redis と ElastiCache for Redis（無料枠なし・最小構成で課金）を以下の観点で比較し、現場での選定基準をまとめる
  - 管理コスト・フェイルオーバー速度・スケールアウト対応・バックアップの容易さ・料金

---

## 発展課題 H：監視と運用

**H-1. INFO コマンドによる状態監視**
- `INFO all` の出力から以下の重要メトリクスを定期収集するスクリプトを作成する

| メトリクス | 確認内容 |
|-----------|---------|
| `connected_clients` | 現在の接続クライアント数 |
| `used_memory_human` | メモリ使用量 |
| `keyspace_hits` / `keyspace_misses` | キャッシュヒット率 |
| `evicted_keys` | エビクションが発生しているか |
| `rejected_connections` | maxclients 超過による接続拒否数 |
| `rdb_last_save_time` | 最後の RDB スナップショット時刻 |

**H-2. Zabbix による Redis 監視**
- Zabbix の Redis テンプレートを使い、接続数・メモリ使用率・ヒット率の監視とアラームを設定する
- メモリ使用率 80% 超でアラート、`evicted_keys` が 0 より大きくなった場合に警告を発火するトリガーを設定する

**H-3. slow log の活用**
- `slowlog-log-slower-than 10000`（10ms 以上）を設定し、`SLOWLOG GET` で遅いコマンドを特定する
- `SLOWLOG RESET` でリセット後に負荷テストを実行し、新たなスロークエリを検出する

---

## 発展課題 I：セキュリティ強化

**I-1. 認証設定**
- `requirepass` で Redis へのアクセスパスワードを設定し、認証なしの接続が拒否されることを確認する
- Redis 6.0 以降の ACL（Access Control List）で操作を制限したユーザーを作成し、特定コマンドのみ実行できるアプリケーション用ユーザーを設定する

**I-2. 危険なコマンドの無効化**
- `rename-command FLUSHALL ""` で本番環境で使用してはいけないコマンドを無効化する
- 無効化推奨コマンド（`FLUSHALL`・`FLUSHDB`・`DEBUG`・`CONFIG`・`KEYS`）を一覧化し、理由とともにまとめる

**I-3. TLS による通信暗号化**
- Redis 6.0 以降の TLS 対応機能を使い、クライアントと Redis 間の通信を暗号化する
- 自己署名証明書を生成し、`redis.conf` の TLS 設定（`tls-port`・`tls-cert-file`・`tls-key-file`）を行う

---

*以上（Redis 基本・発展課題）*
