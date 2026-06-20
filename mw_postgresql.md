# PostgreSQL 発展課題集

> PostgreSQL はこれから初めて触れるミドルウェアのため、発展課題のみを掲載しています  
> 既習の MariaDB / MySQL との比較視点を随所に盛り込み、既習知識を活かして学習できる構成にしています  
> 前提：AWS 無料利用枠の範囲内で実施可能な課題を基本とする  
> 作成日：2026年5月

---

## 目次

1. [発展課題 A：基本構築と MariaDB との比較](#発展課題-a基本構築と-mariadb-との比較)
2. [発展課題 B：ユーザー・権限管理](#発展課題-bユーザー権限管理)
3. [発展課題 C：パフォーマンスチューニング](#発展課題-cパフォーマンスチューニング)
4. [発展課題 D：バックアップと復旧](#発展課題-dバックアップと復旧)
5. [発展課題 E：レプリケーション構成](#発展課題-eレプリケーション構成)
6. [発展課題 F：Web アプリケーションとの連携](#発展課題-fweb-アプリケーションとの連携)
7. [発展課題 G：監視と運用](#発展課題-g監視と運用)
8. [発展課題 H：セキュリティ強化](#発展課題-hセキュリティ強化)
9. [発展課題 I：高可用性構成への発展](#発展課題-i高可用性構成への発展)

---

## 発展課題 A：基本構築と MariaDB との比較

**A-1. EC2 上への PostgreSQL インストールと初期設定**
- AL2023 の EC2 に PostgreSQL をインストールし、`postgresql.conf` と `pg_hba.conf` の役割を MariaDB の `my.cnf` と比較してまとめる
- `initdb` でデータベースクラスターを初期化し、データディレクトリの構造（`base/`・`global/`・`pg_wal/`）を確認する
- `psql` に接続し、データベース作成（`CREATE DATABASE`）・テーブル作成・データ投入・検索（`SELECT`）の基本操作を MariaDB のコマンドと対比しながら実施する

**A-2. MariaDB との主要な違いの整理**
- 以下の観点で MariaDB と PostgreSQL を比較した一覧表を作成する

| 観点 | MariaDB | PostgreSQL |
|------|---------|-----------|
| デフォルトポート | 3306 | 5432 |
| 設定ファイル | `/etc/my.cnf` | `postgresql.conf` / `pg_hba.conf` |
| 接続クライアント | `mysql` | `psql` |
| ユーザー認証 | `mysql.user` テーブル | `pg_hba.conf` + `pg_authid` |
| トランザクション分離 | REPEATABLE READ（デフォルト） | READ COMMITTED（デフォルト） |
| JSON サポート | あり | より高機能（`jsonb`） |
| 全文検索 | `FULLTEXT` インデックス | `tsvector` / `tsquery` |

**A-3. pg_hba.conf による接続制御**
- `pg_hba.conf` の認証方式（`trust`・`md5`・`scram-sha-256`・`reject`）の違いを理解し、ローカル接続と TCP 接続で異なる認証方式を設定する
- 特定の IP アドレスからのみ特定データベースへの接続を許可する設定を行い、意図しない接続が拒否されることを確認する
- `pg_hba.conf` 変更後に `pg_ctl reload` で設定を反映し、PostgreSQL を再起動せずに設定変更が適用できることを確認する

---

## 発展課題 B：ユーザー・権限管理

**B-1. ロールとユーザーの管理**
- PostgreSQL のロール（`CREATE ROLE`）とユーザー（`CREATE USER`）の違いを理解し、アプリケーション用・管理用・読み取り専用の 3 種類のロールを作成する
- `GRANT` / `REVOKE` でテーブル・スキーマ・データベースへのアクセス権限を細かく制御し、最小権限の原則を実装する
- `pg_roles` / `pg_user` / `information_schema.role_table_grants` で現在の権限設定を確認するクエリを作成する

**B-2. スキーマの活用**
- デフォルトの `public` スキーマに加えてアプリケーション用のスキーマを作成し、同名テーブルをスキーマで分離して管理する
- `search_path` を設定してデフォルトで参照するスキーマを切り替え、アプリケーション側の接続文字列を変えずに環境を切り替える仕組みを実装する

**B-3. パスワードポリシーの実装**
- `passwordcheck` 拡張を有効化し、簡単なパスワードの設定を拒否する仕組みを実装する
- `VALID UNTIL` でユーザーのパスワード有効期限を設定し、期限切れ後に接続が拒否されることを確認する

---

## 発展課題 C：パフォーマンスチューニング

**C-1. postgresql.conf の主要パラメーター調整**
- 以下のパラメーターをサーバーのスペック（t2.micro: 1GB RAM）に合わせて調整し、`pg_reload_conf()` で反映する

| パラメーター | デフォルト | 調整の考え方 |
|------------|---------|------------|
| `shared_buffers` | 128MB | 利用可能メモリの 25% 程度 |
| `work_mem` | 4MB | ソート・ハッシュ結合に使用 |
| `maintenance_work_mem` | 64MB | VACUUM・インデックス構築に使用 |
| `max_connections` | 100 | 接続数に応じて調整 |
| `effective_cache_size` | 4GB | OS のページキャッシュ見積もり |

**C-2. クエリ最適化**
- `EXPLAIN ANALYZE` でクエリの実行計画と実際の実行時間を確認し、シーケンシャルスキャンが発生している箇所を特定する
- インデックスを作成（`CREATE INDEX`）して `EXPLAIN ANALYZE` の結果がインデックスキャンに変わることを確認する
- `pg_stat_statements` 拡張を有効化し、実行頻度・合計時間・平均時間の上位クエリを特定する

**C-3. VACUUM と AUTOVACUUM の理解**
- PostgreSQL の MVCC（Multi-Version Concurrency Control）アーキテクチャによる「デッドタプル」の発生を理解する
- `VACUUM VERBOSE` を実行し、削除されたタプル数・解放されたページ数を確認する
- `pg_stat_user_tables` で各テーブルの `n_dead_tup`（デッドタプル数）と `last_autovacuum` を確認し、AUTOVACUUM の動作を監視する
- `VACUUM FULL` と通常の `VACUUM` の違い（テーブルロックの有無・ディスク容量の解放）を理解した上で使い分けを整理する

**C-4. 接続プーリング（PgBouncer）**
- PgBouncer を EC2 にインストールし、PostgreSQL の前段に接続プーラーを置く構成を構築する
- `session`・`transaction`・`statement` の各プーリングモードの違いを理解し、Web アプリケーションでの適切なモードを選択する
- PgBouncer の管理コンソール（`psql -p 6432 pgbouncer`）で接続状況をリアルタイムに確認する

---

## 発展課題 D：バックアップと復旧

**D-1. pg_dump / pg_dumpall による論理バックアップ**
- `pg_dump` でデータベース単位のバックアップを取得し、`pg_restore` で別のデータベースに復元する手順を確立する
- `pg_dumpall` でクラスター全体（ロール・テーブルスペース含む）をバックアップし、新しい PostgreSQL インスタンスへの完全移行手順をまとめる
- カスタム形式（`-Fc`）とプレーンテキスト形式の違いを確認し、大規模データでの並列リストア（`pg_restore -j`）の効果を検証する

**D-2. 定期バックアップの自動化**
- `pg_dump` の結果を cron で日次実行し、`gzip` 圧縮の上で S3 に自動アップロードするスクリプトを作成する
- 7 世代のバックアップを保持する世代管理ロジックを実装する
- バックアップの成否を CloudWatch カスタムメトリクスに送信し、失敗時にアラームが発火する仕組みを構築する

**D-3. ポイントインタイムリカバリ（PITR）**
- WAL アーカイブを有効化し（`archive_mode = on`・`archive_command`）、WAL ファイルを S3 に継続的に転送する設定を行う
- ベースバックアップ（`pg_basebackup`）を取得し、WAL アーカイブと組み合わせて特定時点へのリカバリを実施する
- `recovery_target_time` を指定して意図的にデータを削除した直前の時点に復旧し、PITR の動作を検証する

---

## 発展課題 E：レプリケーション構成

**E-1. ストリーミングレプリケーション（Primary / Standby）**
- 2 台の EC2 で Primary / Standby のストリーミングレプリケーションを構成する
  1. Primary で `wal_level = replica`・`max_wal_senders = 3` を設定
  2. `pg_hba.conf` にレプリケーション接続を許可するエントリを追加
  3. Standby で `pg_basebackup` によるベースバックアップを取得
  4. `standby.signal` ファイルと `postgresql.conf` の `primary_conninfo` を設定して起動
- `pg_stat_replication` でレプリケーションの状態（送信済み LSN・受信済み LSN・ラグ）を監視する

**E-2. レプリケーションラグの監視**
- Primary と Standby の LSN（Log Sequence Number）差分を計算するクエリを作成し、レプリケーションラグをバイト数と時間で確認する

```sql
-- Primary 側で実行
SELECT
  client_addr,
  state,
  sent_lsn,
  write_lsn,
  flush_lsn,
  replay_lsn,
  (sent_lsn - replay_lsn) AS replay_lag_bytes
FROM pg_stat_replication;
```

**E-3. フェイルオーバーの手順確立**
- Primary を意図的に停止し、Standby を `pg_ctl promote` で新しい Primary に昇格させる手順を確立する
- 旧 Primary が復旧した後、新 Primary の Standby として再参加させる手順をまとめる
- フェイルオーバー時間（Primary 停止からアプリケーションが新 Primary に接続できるまで）を計測し、目標復旧時間（RTO）を設定する

**E-4. 読み取りスケールアウト**
- アプリケーションからの読み取りクエリを Standby に向け、Primary の負荷を削減する構成を実装する
- `hot_standby_feedback = on` を設定し、Standby 上で実行中のクエリが Primary の VACUUM によってキャンセルされないようにする
- PgBouncer を使い、書き込みは Primary、読み取りは Standby へルーティングする接続プーリングを設定する

---

## 発展課題 F：Web アプリケーションとの連携

**F-1. Django / Flask（Python）との連携**
- EC2 上に Django をインストールし、`settings.py` の `DATABASES` を PostgreSQL に向けた Web アプリケーションを構築する
- `psycopg2` ドライバーのインストールと接続設定を行い、Django の `migrate` コマンドでテーブルを自動生成する
- Django ORM で生成される SQL を `EXPLAIN ANALYZE` で確認し、N+1 問題が発生していないかを検証する

**F-2. Tomcat（JDBC）との連携**
- Tomcat の `context.xml` に PostgreSQL 用の JDBC データソースを設定し、接続プーリングを有効にする
- `pgjdbc`（PostgreSQL JDBC ドライバー）のバージョンと `scram-sha-256` 認証の互換性を確認する（バージョン 42.2.x 以上が必要）
- JNDI 経由でデータソースを取得するサンプルアプリを Tomcat にデプロイし、PostgreSQL へのクエリ結果を Web ページに表示する

**F-3. RDS（PostgreSQL）との比較**
- EC2 上の自前 PostgreSQL と RDS for PostgreSQL（db.t3.micro 無料枠）を構築し、以下の観点で比較をまとめる
  - 管理コスト（OS・PostgreSQL バージョン管理の有無）
  - 自動バックアップ・ポイントインタイムリカバリの実装難易度
  - フェイルオーバー速度（マルチ AZ）
  - 料金（EC2 + EBS vs RDS 料金）

---

## 発展課題 G：監視と運用

**G-1. 統計情報ビューの活用**
- 以下の統計情報ビューを使った運用クエリを作成し、日常的なヘルスチェックスクリプトとしてまとめる

| ビュー | 確認できる情報 |
|--------|--------------|
| `pg_stat_activity` | 現在の接続・実行中クエリ・待機状態 |
| `pg_stat_user_tables` | テーブルごとのアクセス頻度・デッドタプル数 |
| `pg_stat_user_indexes` | インデックスの使用頻度（未使用インデックスの検出） |
| `pg_stat_bgwriter` | バックグラウンドライター・チェックポイントの統計 |
| `pg_locks` | ロックの状態・ロック待ちの検出 |

**G-2. Zabbix による PostgreSQL 監視**
- Zabbix の PostgreSQL テンプレートを使い、以下のメトリクスを監視する
  - 接続数（`max_connections` の 80% 超でアラート）
  - デッドロックの発生回数
  - レプリケーションラグ（10 秒超でアラート）
  - データベースサイズの増加率
- ユーザーパラメーターで `pg_stat_activity` の長時間実行クエリ（60 秒超）を検知するスクリプトを作成する

**G-3. ログの設定と分析**
- `log_min_duration_statement = 1000` でスロークエリログを有効化し、1 秒以上かかったクエリを記録する
- `pgBadger` をインストールし、PostgreSQL のログから HTML 形式のパフォーマンスレポートを生成する
- `log_lock_waits = on` でロック待ちを記録し、デッドロックの原因となっているクエリを特定する

---

## 発展課題 H：セキュリティ強化

**H-1. 通信の暗号化（SSL/TLS）**
- PostgreSQL の SSL 接続を有効化し（`ssl = on`）、自己署名証明書またはACMの証明書を使ってクライアントと暗号化通信を行う
- `pg_hba.conf` で `hostssl` エントリを設定し、SSL 接続のみを受け付けるようにする
- `psql` の `\conninfo` で現在の接続が SSL を使用しているかを確認する

**H-2. 監査ログの有効化**
- `pgaudit` 拡張をインストールし、DDL 操作（`CREATE`・`DROP`・`ALTER`）と DML 操作（`SELECT`・`INSERT`・`UPDATE`・`DELETE`）のログを取得する
- 特定のロールの操作のみを監査対象にする設定を行い、不要なログ出力を抑制する
- 監査ログを CloudWatch Logs に転送し、不審な操作（深夜の `DROP TABLE` など）を検知するフィルターを設定する

**H-3. Secrets Manager との統合**
- PostgreSQL の接続パスワードを AWS Secrets Manager に格納し、アプリケーションが起動時に Secrets Manager から取得する設定を実装する
- Secrets Manager の自動ローテーション機能で PostgreSQL のパスワードを定期的に変更し、アプリケーションへの影響がないことを確認する

---

## 発展課題 I：高可用性構成への発展

**I-1. RDS マルチ AZ との比較**
- 自前ストリーミングレプリケーション構成と RDS マルチ AZ を以下の観点で比較し、現場での選定基準をまとめる
  - フェイルオーバー時間（自前: 数分〜 / RDS: 60〜120 秒）
  - フェイルオーバーの自動化（自前: 手動または Pacemaker / RDS: 自動）
  - バックアップ・リストアの運用コスト
  - 月次コスト（EC2 × 2 + EBS vs RDS マルチ AZ 料金）

**I-2. Patroni による自動フェイルオーバー**
- `Patroni`（Python 製 HA ソリューション）を 2 台の EC2 に導入し、Primary 障害時に自動でフェイルオーバーする構成を構築する
- `etcd` を分散ロックストアとして使い、スプリットブレインを防ぐ設計を理解する
- `patronictl` コマンドでクラスターの状態確認・計画的なフェイルオーバー・設定変更を行う

**I-3. バックアップの完全自動化**
- `pgBackRest` をインストールし、増分バックアップと差分バックアップを S3 に自動で取得する仕組みを構築する
- `pgBackRest restore` でバックアップから新しい EC2 に PostgreSQL を復旧し、RTO（目標復旧時間）と RPO（目標復旧時点）を計測する

---

*以上（PostgreSQL 発展課題）*
