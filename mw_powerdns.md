# PowerDNS 基本・発展課題集

> データベースバックエンド対応の高機能 DNS サーバー。BIND との比較視点で学習します  
> 前提：AWS 無料利用枠の範囲内で実施可能な課題を基本とする  
> 作成日：2026年6月

---

## 目次

1. [基本課題 A：インストールと基本設定](#基本課題-aインストールと基本設定)
2. [基本課題 B：MySQL バックエンドとの連携](#基本課題-bmysql-バックエンドとの連携)
3. [基本課題 C：PowerDNS Recursor の設定](#基本課題-cpowerdns-recursor-の設定)
4. [発展課題 D：PowerDNS API による動的 DNS 管理](#発展課題-dpowerdns-api-による動的-dns-管理)
5. [発展課題 E：DNSSEC の実装](#発展課題-ednssec-の実装)
6. [発展課題 F：高可用性構成](#発展課題-f高可用性構成)
7. [発展課題 G：監視と運用](#発展課題-g監視と運用)
8. [発展課題 H：BIND との比較と使い分け](#発展課題-hbind-との比較と使い分け)

---

## 基本課題 A：インストールと基本設定

**A-1. EC2 への PowerDNS Authoritative Server インストール**
- AL2023 の EC2 に PowerDNS（`pdns`）をインストールし、`systemd` でサービス登録・自動起動を設定する
- `pdns_server --version` でバージョンを確認し、`pdnsutil check-all-zones` でゾーンの整合性チェックを行う
- 設定ファイル（`/etc/pdns/pdns.conf`）の基本構造と BIND の `named.conf` との違いを比較してまとめる

**A-2. SQLite バックエンドによる基本動作確認**
- 最初は SQLite バックエンド（`launch=gsqlite3`）でシンプルに設定し、ゾーンを作成して名前解決が動作することを確認する

```bash
# ゾーン作成
pdnsutil create-zone example.local
pdnsutil add-record example.local @ SOA 'ns1.example.local. admin.example.local. 1 3600 900 604800 300'
pdnsutil add-record example.local @ NS ns1.example.local.
pdnsutil add-record example.local ns1 A 10.0.1.100
pdnsutil add-record example.local web A 10.0.1.10

# 確認
dig @127.0.0.1 web.example.local
```

---

## 基本課題 B：MySQL バックエンドとの連携

**B-1. MySQL バックエンドへの切り替え**
- MariaDB / MySQL にスキーマ（`pdns` データベース）を作成し、PowerDNS 用のテーブルを作成する
- `launch=gmysql` に切り替え、MySQL バックエンドでゾーンデータを管理する設定を行う
- `pdnsutil` コマンドでゾーン・レコードを追加し、MySQL テーブルにデータが格納されることを確認する

**B-2. MySQL でのレコード管理**
- MySQL クライアントから直接 `domains` / `records` テーブルを操作してゾーンデータを変更し、DNS 応答に即座に反映されることを確認する（BIND のゾーンファイル編集＋reload との違いを体感する）
- BIND のゾーンファイル形式と PowerDNS の MySQL テーブル形式の対応関係をまとめる

---

## 基本課題 C：PowerDNS Recursor の設定

**C-1. Recursor のインストールと設定**
- PowerDNS Recursor（`pdns-recursor`）をインストールし、キャッシュ DNS リゾルバーとして設定する
- Authoritative Server と Recursor を同一サーバーで動作させる場合のポート競合を避ける設定（Authoritative を 5300 番で動作させ、Recursor がローカルの 5300 番に転送）を実装する

**C-2. フォワーディング設定**
- 内部ドメイン（`example.local`）のみ Authoritative Server に転送し、外部ドメインは再帰問い合わせで解決する設定を行う

---

## 発展課題 D：PowerDNS API による動的 DNS 管理

**D-1. REST API の有効化**
- `api=yes` と `api-key` を設定し、PowerDNS の REST API を有効化する
- `curl` で API エンドポイントにアクセスし、ゾーン一覧・レコードの追加・削除を API 経由で実行する

```bash
# API 経由でレコード追加
curl -X PATCH http://localhost:8081/api/v1/servers/localhost/zones/example.local. \
  -H "X-API-Key: mysecretkey" \
  -H "Content-Type: application/json" \
  -d '{
    "rrsets": [{
      "name": "new.example.local.",
      "type": "A",
      "ttl": 300,
      "changetype": "REPLACE",
      "records": [{"content": "10.0.1.20", "disabled": false}]
    }]
  }'
```

**D-2. 自動 DNS 登録スクリプト**
- EC2 の起動時に User Data スクリプトから PowerDNS API を呼び出し、インスタンス名と IP を自動でDNS 登録するスクリプトを作成する
- EC2 の停止時に DNS レコードを自動削除するスクリプトも作成し、DNS エントリの自動ライフサイクル管理を実現する

---

## 発展課題 E：DNSSEC の実装

**E-1. ゾームへの DNSSEC 署名**
- `pdnsutil secure-zone example.local` でゾームに DNSSEC 署名を追加する
- `pdnsutil show-zone example.local` で KSK・ZSK の情報を確認する
- `dig @127.0.0.1 +dnssec example.local SOA` で RRSIG レコードが返ることを確認する

---

## 発展課題 F：高可用性構成

**F-1. Primary / Secondary 構成**
- PowerDNS の Primary / Secondary ゾーン転送を 2 台の EC2 で設定し、Primary のゾーンデータが Secondary に自動同期されることを確認する
- BIND の Primary / Secondary 構成と設定量・管理コストを比較する

**F-2. MySQL レプリケーションとの組み合わせ**
- PowerDNS のバックエンド MySQL を Primary / Replica レプリケーション構成にし、Replica からも DNS 応答が返せる高可用性構成を構築する

---

## 発展課題 G：監視と運用

**G-1. API 経由の統計情報取得**
- `GET /api/v1/servers/localhost/statistics` で CPU 使用率・クエリ数・キャッシュヒット率を取得するスクリプトを作成する
- Zabbix のユーザーパラメーターで統計情報を定期取得し、クエリ数の急増でアラートを発火させる

---

## 発展課題 H：BIND との比較と使い分け

**H-1. 比較表の作成**

| 観点 | BIND | PowerDNS |
|------|------|---------|
| ゾーンデータ管理 | テキストファイル | DB（MySQL / PostgreSQL / SQLite 等） |
| 動的レコード更新 | `nsupdate`・reload | REST API・DB 直接操作 |
| DNSSEC | 対応（設定が複雑） | 対応（`pdnsutil` で簡単） |
| 高可用性 | Secondary ゾーン転送 | DB レプリケーション |
| GUI 管理ツール | サードパーティ製 | PowerDNS-Admin（OSS）が有名 |
| 学習コスト | 高 | 中 |
| 現場採用率 | 非常に高い | 中（大規模・自動化が必要な現場） |

---

*以上（PowerDNS 基本・発展課題）*
