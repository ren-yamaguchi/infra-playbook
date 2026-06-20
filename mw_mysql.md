# MySQL 基本・発展課題集

> 既習の MariaDB との比較視点を随所に盛り込んでいます  
> MariaDB の知識がそのまま活かせる部分と、MySQL 固有の差異に着目して学習します  
> 前提：AWS 無料利用枠の範囲内で実施可能な課題を基本とする  
> 作成日：2026年6月

---

## 目次

1. [基本課題 A：インストールと MariaDB との差異確認](#基本課題-aインストールと-mariadb-との差異確認)
2. [基本課題 B：ユーザー・権限管理](#基本課題-bユーザー権限管理)
3. [基本課題 C：設定チューニングの基礎](#基本課題-c設定チューニングの基礎)
4. [発展課題 D：レプリケーション構成](#発展課題-dレプリケーション構成)
5. [発展課題 E：バックアップと復旧](#発展課題-eバックアップと復旧)
6. [発展課題 F：パフォーマンスチューニング](#発展課題-fパフォーマンスチューニング)
7. [発展課題 G：RDS for MySQL との連携・比較](#発展課題-grds-for-mysql-との連携比較)
8. [発展課題 H：セキュリティ強化](#発展課題-hセキュリティ強化)
9. [発展課題 I：監視と運用](#発展課題-i監視と運用)

---

## 基本課題 A：インストールと MariaDB との差異確認

**A-1. EC2 への MySQL インストール**
- AL2023 の EC2 に MySQL Community Server をインストールし、`systemd` でサービス登録・自動起動を設定する
- インストール直後の一時パスワードを `/var/log/mysqld.log` から取得し、`mysql_secure_installation` で初期セキュリティ設定を行う
- `mysql --version` でバージョンを確認し、接続後 `SELECT version();` で MySQL と MariaDB のバージョン文字列の違いを確認する

**A-2. MariaDB との互換性と差異の確認**
- 以下の観点で MariaDB と MySQL を比較した一覧表を作成する

| 観点 | MariaDB | MySQL |
|------|---------|-------|
| 開発元 | MariaDB Foundation | Oracle |
| ライセンス | GPL | GPL（Community） / 商用 |
| デフォルトストレージエンジン | InnoDB（Aria も使用可） | InnoDB |
| JSON サポート | あり | より高機能（`JSON_TABLE` 等） |
| 認証プラグイン | `mysql_native_password` がデフォルト | `caching_sha2_password` が MySQL 8.0 のデフォルト |
| `SHOW SLAVE STATUS` | 有効 | MySQL 8.0.22 以降は `SHOW REPLICA STATUS` |
| `information_schema` | 互換あり | 一部構造が異なる |

**A-3. 基本操作の確認**
- `mysql` クライアントで接続し、MariaDB で覚えたコマンド（`SHOW DATABASES`・`CREATE TABLE`・`INSERT`・`SELECT`・`EXPLAIN`）がそのまま動作することを確認する
- MySQL 8.0 で追加された `WITH`（CTE：共通テーブル式）・`WINDOW` 関数を試し、MariaDB との互換性を確認する

---

## 基本課題 B：ユーザー・権限管理

**B-1. ユーザー作成と権限付与**
- アプリケーション用ユーザーを作成し、特定データベースへの最小権限（`SELECT`・`INSERT`・`UPDATE`・`DELETE`）を付与する
- MySQL 8.0 のデフォルト認証プラグイン（`caching_sha2_password`）が原因で古いクライアント・ドライバーから接続できない場合の対処（`mysql_native_password` への変更）を確認する

```sql
-- MySQL 8.0 で古いクライアント向けに認証方式を変更する例
ALTER USER 'appuser'@'%' IDENTIFIED WITH mysql_native_password BY 'password';
FLUSH PRIVILEGES;
```

**B-2. ロールによる権限管理（MySQL 8.0 以降）**
- MySQL 8.0 で追加されたロール機能を使い、「読み取り専用ロール」「読み書きロール」「管理者ロール」を作成してユーザーに割り当てる
- `SHOW GRANTS FOR 'user'@'host';` で付与された権限を確認する

---

## 基本課題 C：設定チューニングの基礎

**C-1. my.cnf の主要パラメーター**
- 以下のパラメーターを設定し、それぞれの意味と適切な値を t2.micro（1GB RAM）向けに調整する

```ini
[mysqld]
innodb_buffer_pool_size = 256M   # RAM の 50〜70%
max_connections         = 100
slow_query_log          = 1
slow_query_log_file     = /var/log/mysql/slow.log
long_query_time         = 1
character-set-server    = utf8mb4
collation-server        = utf8mb4_unicode_ci
```

**C-2. 文字コードの設定**
- `utf8mb4` と `utf8` の違い（絵文字・4バイト Unicode の扱い）を理解し、MySQL・DB・テーブル・カラムすべてを `utf8mb4` に統一する
- `SHOW VARIABLES LIKE 'character%'` で全レベルの文字コード設定を確認する

---

## 発展課題 D：レプリケーション構成

**D-1. Primary / Replica レプリケーション**
- 2 台の EC2 で MySQL の Primary / Replica レプリケーションを構成する
- `CHANGE REPLICATION SOURCE TO`（MySQL 8.0.23 以降）または `CHANGE MASTER TO`（旧構文）でレプリカを設定し、`SHOW REPLICA STATUS\G` でレプリケーション状態を確認する
- MariaDB の `SHOW SLAVE STATUS` と MySQL 8.0 の `SHOW REPLICA STATUS` の違いを確認する

**D-2. GTID ベースのレプリケーション**
- `gtid_mode = ON` と `enforce_gtid_consistency = ON` を設定し、GTID（Global Transaction Identifier）ベースのレプリケーションを構成する
- 従来のバイナリログポジション方式と GTID 方式を比較し、フェイルオーバー時の操作の簡便さの違いをまとめる
- GTID を使ったフェイルオーバー手順を MariaDB の手順と比較する

**D-3. 半同期レプリケーション**
- `rpl_semi_sync_source_enabled` / `rpl_semi_sync_replica_enabled` を有効化し、少なくとも 1 台のレプリカへの書き込み確認を待つ半同期レプリケーションを設定する
- 非同期・半同期・同期レプリケーションの違いをデータロスとパフォーマンスの観点でまとめる

---

## 発展課題 E：バックアップと復旧

**E-1. mysqldump による論理バックアップ**
- `mysqldump` でデータベース単位・テーブル単位・全体バックアップを取得し、リストア手順を確立する
- `--single-transaction` オプションで InnoDB のトランザクション整合性を保ちながらロックなしでバックアップする方法を確認する
- バックアップを cron で定期実行し、`gzip` 圧縮の上で S3 に自動アップロードするスクリプトを作成する

**E-2. mysqlpump / MySQL Shell による高速バックアップ**
- `mysqlpump`（並列バックアップ）と `mysqldump` のバックアップ速度を比較する
- MySQL Shell の `util.dumpInstance()` でダンプし、`util.loadDump()` でリストアする手順を確認する

**E-3. ポイントインタイムリカバリ**
- バイナリログを有効化（`log_bin = mysql-bin`）し、特定時点への復旧手順を確立する
- `mysqlbinlog` でバイナリログを解析し、誤った `DELETE` 操作の直前まで復旧する手順を実施する

---

## 発展課題 F：パフォーマンスチューニング

**F-1. クエリの最適化**
- `EXPLAIN FORMAT=JSON` で詳細な実行計画を確認し、インデックスの使用状況を分析する
- `performance_schema` を使ってクエリごとの実行時間・待機時間を分析する
- `sys` スキーマの `sys.statement_analysis` ビューでスロークエリを特定する

**F-2. インデックス設計**
- 複合インデックスの列順序（選択性の高い列を先頭に）の設計原則を理解し、`EXPLAIN` で効果を確認する
- 使用されていないインデックスを `sys.schema_unused_indexes` で特定し、削除してパフォーマンスへの影響を確認する
- カバリングインデックスを設計し、テーブルアクセスなしでクエリが完結する状態を実現する

**F-3. InnoDB の最適化**
- `innodb_flush_log_at_trx_commit` の設定値（0・1・2）とデータ整合性・パフォーマンスのトレードオフを理解する
- `innodb_io_capacity` を EBS の IOPS に合わせて調整する

---

## 発展課題 G：RDS for MySQL との連携・比較

**G-1. RDS for MySQL への接続**
- RDS for MySQL（db.t3.micro 無料枠）を作成し、EC2 上の Web アプリケーションから接続する
- Security Group で EC2 のプライベート IP からのみ 3306 番ポートを許可する設定を行う
- RDS の Parameter Group で `character_set_server = utf8mb4` を設定する方法を確認する

**G-2. 自前 MySQL vs RDS の比較**
- EC2 上の自前 MySQL と RDS for MySQL を以下の観点で比較する
  - 自動バックアップ・ポイントインタイムリカバリの実装難易度
  - マルチ AZ フェイルオーバーの速度と設定コスト
  - OS・MySQL バージョンの管理コスト
  - 月次コスト（EC2 + EBS vs RDS 料金）

---

## 発展課題 H：セキュリティ強化

**H-1. SSL/TLS 接続の強制**
- MySQL サーバーの SSL を有効化し、`REQUIRE SSL` でユーザーの SSL 接続を強制する
- `mysql --ssl-mode=REQUIRED` でクライアントから SSL 接続し、`\s` で接続情報に SSL が表示されることを確認する

**H-2. 監査ログの有効化**
- MySQL Enterprise Audit（商用）の代替として `audit_log` プラグインまたは `MariaDB Audit Plugin`（互換あり）を使い、DDL・DML 操作を記録する
- 監査ログを CloudWatch Logs に転送し、深夜の `DROP TABLE` 操作を検知するアラームを設定する

**H-3. 不要な機能の無効化**
- `local_infile = 0` で LOAD DATA LOCAL INFILE を無効化し、任意のファイル読み取りリスクを排除する
- デフォルトで存在する `test` データベースを削除し、匿名ユーザーが存在しないことを `SELECT User, Host FROM mysql.user` で確認する

---

## 発展課題 I：監視と運用

**I-1. パフォーマンス監視**
- `performance_schema.events_statements_summary_by_digest` で実行頻度の高いクエリを定期集計するスクリプトを作成する
- Zabbix の MySQL テンプレートで接続数・スロークエリ数・レプリケーションラグを監視し、閾値超過でアラートを発火させる

**I-2. CloudWatch との統合**
- RDS for MySQL の場合は CloudWatch で CPU 使用率・DB 接続数・書き込み IOPS を監視し、フリーストレージスペースが 2GB を下回った場合にアラームを設定する
- カスタムメトリクスで自前 MySQL の接続数をスクリプト経由で CloudWatch に送信する仕組みを構築する

---

*以上（MySQL 基本・発展課題）*
