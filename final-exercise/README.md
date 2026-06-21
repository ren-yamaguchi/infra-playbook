# AWS Infrastructure Playbook

AWS（Amazon Linux 2023）上に **Tomcat + PostgreSQL構成のWebアプリケーション環境** をゼロから構築し，旧環境からアプリケーションを移行するための日本語手順書ライブラリです．

クラウドエンジニア初学者向けに，**統一されたテンプレート**（7章＋ロールバック＋付録A〜D）で17ファイルを整備しています．

![License](https://img.shields.io/badge/license-MIT-blue.svg)
![Platform](https://img.shields.io/badge/platform-AWS-orange.svg)
![OS](https://img.shields.io/badge/OS-Amazon%20Linux%202023-yellow.svg)
![Status](https://img.shields.io/badge/status-stable-green.svg)

------------------------------

## 目次

- [概要](#概要)
- [対象読者](#対象読者)
- [構成](#構成)
- [Quick Start](#quick-start)
- [ファイル一覧](#ファイル一覧)
- [推奨実行順序](#推奨実行順序)
- [依存関係](#依存関係)
- [ユースケース別の進め方](#ユースケース別の進め方)
- [責任境界](#責任境界)
- [パラメータ整合性ガイド](#パラメータ整合性ガイド)
- [プレースホルダー対応表](#プレースホルダー対応表)
- [テンプレート規約](#テンプレート規約)
- [注意事項](#注意事項)
- [ライセンス](#ライセンス)
- [作者](#作者)

------------------------------

## 概要

本ライブラリは，AWS環境にエンタープライズ的なWebアプリケーション基盤を構築するための **17ファイルの手順書セット** です．

- **土台手順書 1ファイル**：VPC・サブネット・踏み台・EC2基盤
- **構築手順書 12ファイル**：PostgreSQL・Tomcat・Nginx・NFS・DNS・SMTP・NTP・ALB・Zabbix
- **移行手順書 3ファイル**：PostgreSQL論理移行・WARデプロイ・ModSecurity移行
- **インデックス 1ファイル**：本README

各手順書は **統一テンプレート** に準拠しており，初学者でも迷わず手を動かせるように設計されています．

------------------------------

## 対象読者

- クラウドエンジニア初学者
- AWS・EC2・VPC・サブネットの基本操作ができる方
- Linux（SSH接続，`vi`，`systemctl`，dnf）の基本ができる方
- TCP/UDP・ポート番号・DNS解決の概念がわかる方

------------------------------

## 構成

```
                          ┌──────────────┐
                          │ Internet     │
                          └──────┬───────┘
                                 │
                          ┌──────┴───────┐
                          │ ALB (HTTPS)  │
                          └──────┬───────┘
                                 │
              ┌──────────────────┴──────────────────┐
              ▼                                     ▼
       ┌──────────────┐                      ┌──────────────┐
       │ Nginx (AZ1)  │                      │ Nginx (AZ3)  │
       │ + ModSecurity│                      │ + ModSecurity│
       └──────┬───────┘                      └──────┬───────┘
              │                                     │
              ▼                                     ▼
       ┌──────────────┐                      ┌──────────────┐
       │ Tomcat AP1   │                      │ Tomcat AP2   │
       │   (AZ2)      │                      │   (AZ4)      │
       └──────┬───────┘                      └──────┬───────┘
              │                                     │
              │   ┌─────────────────────────┐       │
              └───┤ NFS Mount (TCP/2049)    ├───────┘
                  │                         │
                  ▼                         ▼
           ┌──────────────────────────────────┐
           │ DB / NFS 同居サーバー (AZ2)       │
           │  - PostgreSQL 15                 │
           │  - NFSv4 Server                  │
           └──────────────────────────────────┘
                  ▲
                  │
           ┌──────┴───────┐
           │ Zabbix       │
           │ (監視)       │
           └──────────────┘

       基盤：内部DNS（NSD冗長）/ 内部NTP / SMTP / 踏み台 / VPC（4AZ）
```

------------------------------

## Quick Start

### 前提

- AWSアカウント（管理者権限相当）
- 作業端末：ブラウザ + SSHクライアント
- グローバルIPが取得できる環境

### 構築ステップ（概要）

```bash
# 1. リポジトリをクローン
git clone https://github.com/<your-org>/aws-infrastructure-playbook.git
cd aws-infrastructure-playbook

# 2. 推奨実行順序に従って手順書を順番に実行
#    まずは土台から
open docs/aws-infrastructure-setup.md
```

詳細は [推奨実行順序](#推奨実行順序) を参照してください．

------------------------------

## ファイル一覧

| # | ファイル名 | 種別 | 役割 |
| --- | --- | --- | --- |
| 1 | `aws-infrastructure-setup.md` | 土台 | VPC・サブネット・IGW・NATGW・ルートテーブル・踏み台・EC2作成共通手順 |
| 2 | `nsd-private-redundancy.md` | 構築 | 内部DNS（NSD冗長構成） |
| 3 | `chrony-internal-ntp.md` | 構築 | 内部NTPサーバー |
| 4 | `postgresql-server.md` | 構築 | PostgreSQL 15サーバー本体 |
| 5 | `nfs-server.md` | 構築 | NFSサーバー（DB同居）・クライアントマウント |
| 6 | `tomcat-basic.md` | 構築 | Tomcat APサーバー本体 |
| 7 | `nginx-reverse-proxy.md` | 構築 | Nginxリバースプロキシ |
| 8 | `postfix-smtp-relay.md` | 構築 | SMTPリレー |
| 9 | `nsd-public-redundancy.md` | 構築 | 外部DNS（NSD 2台冗長構成）+ Let's Encrypt 証明書取得 |
| 10 | `alb-acm-https.md` | 構築 | ALB + ACM HTTPS化 |
| 11 | `zabbix-db-postgresql.md` | 構築 | Zabbix用DB／ユーザー作成・`pg_hba.conf` |
| 12 | `zabbix-server.md` | 構築 | Zabbixサーバー |
| 13 | `zabbix-agent2.md` | 構築 | Zabbix Agent2（監視対象サーバーに導入） |
| 14 | `postgresql-migration.md` | 移行 | PostgreSQL 11.2 → 15 論理移行 |
| 15 | `war-deploy-migration.md` | 移行 | アプリ移行（WARデプロイ・JDBC差し替え・UID/GID統一・NFS連携） |
| 16 | `modsecurity-migration.md` | 移行 | ModSecurity（WAF）移行 |

------------------------------

## 推奨実行順序

```
[A] 土台         → 1. aws-infrastructure-setup.md
                       ↓
[B] 基盤         → 2. nsd-private-redundancy.md
                  3. chrony-internal-ntp.md
                       ↓
[C] アプリ基盤    → 4. postgresql-server.md
                  5. nfs-server.md
                  6. tomcat-basic.md
                  7. nginx-reverse-proxy.md
                  8. postfix-smtp-relay.md
                       ↓
[D] 公開・HTTPS  → 9. nsd-public-redundancy.md
                  10. alb-acm-https.md
                       ↓
[E] 監視         → 11. zabbix-db-postgresql.md
                  12. zabbix-server.md
                  13. zabbix-agent2.md
                       ↓
[F] 移行         → 14. postgresql-migration.md
                  15. war-deploy-migration.md
                  16. modsecurity-migration.md（任意）
```

### 実行順序の根拠

| ルール | 説明 |
| --- | --- |
| 土台が最初 | VPC・EC2基盤がないと他は実行不能 |
| DNSが基盤の前 | 後続サーバーのFQDN解決に必要 |
| NTPがDBやTLSの前 | 時刻同期は認証・証明書検証の前提 |
| nfs-serverはpostgresql-serverの後 | 同一EC2に同居するためDB側が先 |
| 監視はアプリ基盤の後 | 監視対象が既に存在している必要がある |
| 移行は構築完了後 | 環境構築後に本番データを移行 |

------------------------------

## 依存関係

| 手順書 | 前提手順書 |
| --- | --- |
| `aws-infrastructure-setup.md` | （なし） |
| `nsd-private-redundancy.md` | `aws-infrastructure-setup.md` |
| `chrony-internal-ntp.md` | `aws-infrastructure-setup.md`，`nsd-private-redundancy.md` |
| `postgresql-server.md` | `aws-infrastructure-setup.md`，`nsd-private-redundancy.md` |
| `nfs-server.md` | `postgresql-server.md` |
| `tomcat-basic.md` | `aws-infrastructure-setup.md`，`nsd-private-redundancy.md` |
| `nginx-reverse-proxy.md` | `aws-infrastructure-setup.md`，`tomcat-basic.md` |
| `postfix-smtp-relay.md` | `aws-infrastructure-setup.md`，`nsd-private-redundancy.md` |
| `nsd-public-redundancy.md` | `aws-infrastructure-setup.md` |
| `alb-acm-https.md` | `nginx-reverse-proxy.md`，`nsd-public-redundancy.md` |
| `zabbix-db-postgresql.md` | `postgresql-server.md` |
| `zabbix-server.md` | `zabbix-db-postgresql.md` |
| `zabbix-agent2.md` | `zabbix-server.md` |
| `postgresql-migration.md` | `postgresql-server.md` |
| `war-deploy-migration.md` | `tomcat-basic.md`，`postgresql-server.md`，`postgresql-migration.md`，`nfs-server.md` |
| `modsecurity-migration.md` | `nginx-reverse-proxy.md` |

------------------------------

## ユースケース別の進め方

### ゼロから完全な環境を構築したい

→ 全16ファイルを順番に実行（フェーズA → フェーズF）．

### 既存環境にZabbix監視だけ追加したい

→ `zabbix-db-postgresql.md` → `zabbix-server.md` → `zabbix-agent2.md` の3ファイル．  
前提：PostgreSQL構築済み．

### アプリだけ新環境にデプロイしたい

→ `postgresql-migration.md` → `war-deploy-migration.md` の2ファイル．  
前提：PostgreSQLサーバー・Tomcat・NFSが構築済み．

### HTTPS化だけ追加したい

→ `nsd-public-redundancy.md` → `alb-acm-https.md` の2ファイル．  
前提：Nginxリバースプロキシ構築済み．

### WAF（ModSecurity）だけ追加したい

→ `modsecurity-migration.md` の1ファイル．  
前提：Nginxリバースプロキシ構築済み．

------------------------------

## 責任境界

複数の手順書で同じMW（特にPostgreSQL）を扱う場合の分担です．

### PostgreSQL系

| 担当 | 責任範囲 |
| --- | --- |
| `postgresql-server.md` | PostgreSQLインストール，`postgresql-setup --initdb`，`listen_addresses='*'` 設定．**標準パス `/var/lib/pgsql/data` 使用** |
| `postgresql-migration.md` | 移行先ロール・DB作成，`pg_hba.conf` エントリ追加，pg_dumpall/pg_restoreによる論理移行 |
| `zabbix-db-postgresql.md` | Zabbix用ロール・DB作成，Zabbix用の`pg_hba.conf` |
| `war-deploy-migration.md` | アプリ側のJDBCドライバ差し替え・`application.yml` 書き換えのみ |

### DNS系

| 担当 | 責任範囲 |
| --- | --- |
| `nsd-private-redundancy.md` | 内部DNS（NSD Primary／Secondary） |
| `nsd-public-redundancy.md` | 外部DNS（NSD 2台冗長 Primary/Secondary）・Let's Encrypt用レコード |

### NFS / UID-GID統一

| 担当 | 責任範囲 |
| --- | --- |
| `nfs-server.md` | NFSサーバー構築・`/etc/exports`・AP1／AP2マウント |
| `war-deploy-migration.md` | Tomcat実行ユーザーのUID/GID統一（Step 0），NFSマウント動作確認（Step 0-2） |

------------------------------

## パラメータ整合性ガイド

複数の手順書で **同じ値を使う必要があるパラメータ** です．記入時は手順書間で値を揃えてください．

| パラメータ | 関連手順書 | 値の決定タイミング |
| --- | --- | --- |
| `<VPC CIDR>` | aws-infrastructure-setup ほか全件 | aws-infrastructure-setup.md |
| `<VPC名>` | aws-infrastructure-setup ほか | aws-infrastructure-setup.md |
| `<キーペア名>` | aws-infrastructure-setup ほか全EC2 | aws-infrastructure-setup.md |
| `<PostgreSQLバージョン>` | postgresql-server, postgresql-migration, war-deploy-migration, zabbix-db-postgresql, zabbix-server | postgresql-server.md（`15`固定） |
| `<移行先DB名>` | postgresql-migration, war-deploy-migration | postgresql-migration.md |
| `<移行先ロール>` | postgresql-migration, war-deploy-migration | postgresql-migration.md |
| `<Tomcat配置ディレクトリ>` | tomcat-basic, war-deploy-migration | tomcat-basic.md（`/usr/local`） |
| `<Tomcat実行UID>` `<Tomcat実行GID>` | nfs-server, war-deploy-migration | war-deploy-migration.md Step 0 |
| `<アプリケーションデータパス>` | nfs-server, war-deploy-migration | nfs-server.md |
| `<NFSサーバーのプライベートIP>` | nfs-server | nfs-server.md |
| `<対象FQDN>` | nginx-reverse-proxy, nsd-public-redundancy, alb-acm-https, modsecurity-migration | nsd-public-redundancy.md |
| `<SMTPサーバーのホスト名>` | postfix-smtp-relay, war-deploy-migration | postfix-smtp-relay.md |

------------------------------

## プレースホルダー対応表

手順書ごとに「同じ実体（同じサーバー・同じIP）を別のプレースホルダー名で呼んでいる」ケースがあります．以下は **異なる名前で書かれていても実体は同じもの** をまとめた対応表です．記入時はこの表を参照して値を揃えてください．

### サーバー実体 ⇄ 各手順書での呼称

| サーバー実体（AZ・同居サービス） | 手順書 | 当該手順書での呼称 |
| --- | --- | --- |
| **DBサーバー**（AZ2 Private／PostgreSQL／NFS／NTP同居） | postgresql-server | `<DBサーバーのホスト名>` |
| 〃 | nfs-server | `<NFSサーバーのプライベートIP>` |
| 〃 | chrony-internal-ntp | `<NTPサーバーのFQDN>` `<NTPサーバーのプライベートIP>` |
| 〃 | zabbix-db-postgresql, zabbix-server | `<DBサーバーのIP>` |
| 〃 | postgresql-migration | `<新DBサーバーのIP>` |
| 〃 | war-deploy-migration | `<DBサーバーのホスト名>` |
| **APサーバー1**（AZ2 Private／Tomcat／内部NSD Primary同居） | tomcat-basic | `<APサーバーのFQDN>` `<APサーバーのホスト名>` |
| 〃 | nginx-reverse-proxy | `<APサーバー1のFQDN>` `<APサーバー1のプライベートIP>` |
| 〃 | nfs-server | `<AP1のプライベートIP>` |
| 〃 | nsd-private-redundancy | `<DNSサーバーのホスト名(Primary)>`（NSD観点） |
| 〃 | chrony-internal-ntp | `<AP系AZ2サーバーのホスト名>` `<AP系AZ2サーバーのプライベートIP>` |
| 〃 | war-deploy-migration | `<APサーバーIP>` |
| **APサーバー2**（AZ4 Private／Tomcat／内部NSD Secondary同居） | tomcat-basic | `<APサーバーのFQDN>` `<APサーバーのホスト名>`（同手順を2回適用） |
| 〃 | nginx-reverse-proxy | `<APサーバー2のFQDN>` `<APサーバー2のプライベートIP>` |
| 〃 | nfs-server | `<AP2のプライベートIP>` |
| 〃 | nsd-private-redundancy | `<DNSサーバーのホスト名(Secondary)>`（NSD観点） |
| 〃 | chrony-internal-ntp | `<AP系AZ4サーバーのホスト名>` `<AP系AZ4サーバーのプライベートIP>` |
| **Webサーバー1**（AZ1 Public／Nginx／外部NSD Primary／Postfix同居） | nginx-reverse-proxy | `<Webサーバーのホスト名>` `<WebサーバーのパブリックIP>` |
| 〃 | nsd-public-redundancy | `<Primary NSDサーバーのEIP>` `<Primary NSDサーバーのプライベートIP>` `<Primary NSDサーバーのホスト名>` |
| 〃 | postfix-smtp-relay | `<SMTPリレーサーバーのホスト名>` `<SMTPリレーサーバーのプライベートIP>` |
| 〃 | chrony-internal-ntp | `<Web系AZ1サーバーのホスト名>` `<Web系AZ1サーバーのプライベートIP>` |
| 〃 | alb-acm-https | `<Webサーバーのインスタンス名>` `<WebサーバーのインスタンスID>` `<Webサーバーのパブリック/プライベートIP>` |
| **Webサーバー2**（AZ3 Public／Nginx／外部NSD Secondary／Postfix同居） | nginx-reverse-proxy | 同手順を2回適用 |
| 〃 | nsd-public-redundancy | `<Secondary NSDサーバーのEIP>` `<Secondary NSDサーバーのプライベートIP>` `<Secondary NSDサーバーのホスト名>` |
| 〃 | postfix-smtp-relay | 同手順を2回適用 |
| 〃 | chrony-internal-ntp | `<Web系AZ3サーバーのホスト名>` `<Web系AZ3サーバーのプライベートIP>` |
| **Zabbixサーバー**（AZ4 Private） | zabbix-server | `<Zabbixサーバーのホスト名>` `<ZabbixサーバーのプライベートIP>` |
| 〃 | zabbix-db-postgresql, zabbix-agent2 | `<ZabbixサーバーのプライベートIP>` |
| 〃 | chrony-internal-ntp | `<Zabbixサーバーのホスト名>` `<ZabbixサーバーのプライベートIP>` |
| **踏み台サーバー**（AZ1またはAZ3 Public） | aws-infrastructure-setup | `<踏み台サーバー名>` `<踏み台サーバーのIP>` `<踏み台サーバーのパブリックIP>` |
| 〃 | zabbix-server, postgresql-migration | `<踏み台サーバーのパブリックIP>` `<踏み台サーバーのIP>` |

### 用語のゆらぎ

| 実体 | 別称（手順書により混在） |
| --- | --- |
| プライベートIP | `…のIP` / `…のプライベートIP`（同じものを指す；後者が正式） |
| SMTPリレーサーバー | `SMTPリレーサーバー`（postfix-smtp-relay）／`SMTPサーバー`（war-deploy-migration） |
| Zabbix Agent | `エージェント`（zabbix-agent2）／`監視対象サーバー`（zabbix-agent2 同手順内） |

### 利用のポイント

- 同じ実体を指していると判断したら，**最初に値を決めた手順書の値をそのまま転記**してください．
- 「同手順を2回適用」と書かれているもの（tomcat-basic, nginx-reverse-proxy, postfix-smtp-relay）は，**手順書1ファイルをAZ1／AZ3，または AZ2／AZ4 の2台それぞれに適用**します．
- 汎用例示プレースホルダー（`<FQDN>` `<ホスト名>` `<任意のホスト名>` `<DNSサーバー>` `<NSDサーバー>` `<デバイス>` `<パス>` 等）は，付録のコマンド解説や設定ファイル一般説明で使われるメタプレースホルダーであり，**特定のサーバーを指しません**．文脈に応じて任意の値を当てはめてください．

------------------------------

## テンプレート規約

全17ファイルは以下の規約に統一されています．

| 観点 | 規約 |
| --- | --- |
| 章構成 | 7章（ドキュメント情報／目的・概要／前提条件／構築手順／動作確認／トラブルシューティング／参考リソース）＋8.ロールバック＋付録A〜D |
| 句読点 | 全角 `，．` のみ |
| サーバー表記 | 「サーバー」（長音記号あり）に統一 |
| 区切り線 | 30文字（`------------------------------`） |
| プレースホルダー | 意味ベース日本語＋全角山括弧（例：`<対象FQDN>`） |
| ファイル名 | kebab-case 英語（日本語接頭辞なし） |
| dnfコマンド | `dnf update -y`（upgrade不使用），`dnf install -y <パッケージ>` |
| サービス起動 | `systemctl enable --now <サービス>` 統一形式 |
| ステップ見出し | `【実施対象：●●】` ラベルを全Step見出しに付与 |
| 付録 | A：コマンドリファレンス／B：設定ファイル解説／C：用語集／D：補足情報 |
| 構成図 | 第2章にASCII構成図を必置 |

------------------------------

## 注意事項

### ストレージ方針

本ライブラリでは **追加EBSボリュームを使わない方針** を採用しています．

- DBサーバー：ルートボリューム50GiB（PostgreSQLデータ同居）
- NFSサーバー：DBサーバー同居（NFS共有データもルート上）
- その他：ルートボリューム8〜20GiB

→ 本番運用では，DBデータやNFS共有を別EBSボリュームに分離することを推奨します．

### セキュリティ

- 本ライブラリは演習・学習用です．本番運用ではセキュリティグループのソースを最小権限化してください．
- パスワード・APIキーは絶対に手順書本体に記載しないでください．パスワード管理ツールを参照する形にしてください．

### 改訂の進め方

ファイルを修正する場合：

1. 該当ファイルの改訂履歴に `v1.x` を追記
2. 関連手順書（[パラメータ整合性ガイド](#パラメータ整合性ガイド) 参照）に波及がないか確認
3. 必要なら関連手順書も同時改訂
4. 本README.mdも同期更新

------------------------------

## 推奨作業時間（参考）

| フェーズ | 初心者 | 経験者 |
| --- | --- | --- |
| A：土台（1ファイル） | 4〜6時間 | 1〜2時間 |
| B：基盤（2ファイル） | 4〜6時間 | 1〜2時間 |
| C：アプリ基盤（5ファイル） | 12〜20時間 | 4〜6時間 |
| D：公開HTTPS（2ファイル） | 4〜6時間 | 1〜2時間 |
| E：監視（3ファイル） | 6〜10時間 | 2〜3時間 |
| F：移行（3ファイル） | 8〜12時間 | 3〜5時間 |
| **合計** | **38〜60時間** | **12〜20時間** |

------------------------------

## ライセンス

本リポジトリは [MITライセンス](LICENSE) のもとで公開されています．

```
MIT License

Copyright (c) 2026 <作者名>

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

------------------------------

## 作者

`<作者名>`

------------------------------

## 貢献

Issue・Pull Request は歓迎します．以下を意識してください：

- 改訂は **テンプレ規約** に準拠
- 複数手順書に波及する変更は **パラメータ整合性ガイド** で影響範囲を確認
- 変更内容を該当ファイルの **改訂履歴** に記録
