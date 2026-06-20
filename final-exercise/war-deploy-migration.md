# Tomcatアプリケーション移行（ROOT.war 配置）

------------------------------

## 1. ドキュメント情報

| 項目 | 内容 |
|------|------|
| 手順書名 | Tomcatアプリケーション移行（ROOT.war 配置） |
| 作成日 | 2026-06-19 |
| 最終更新日 | 2026-06-20 |
| バージョン | v1.2 |
| 対象環境 | AWS（Amazon Linux 2023） |

> **改訂履歴**
>
> | バージョン | 日付 | 変更内容 |
> |-----------|------|---------|
> | v1.0 | 2026-06-19 | 初版作成（元`deploy-app_手順書.md`を基にテンプレートに沿って再構成．**JDBCドライバの入れ替えStepを新規追加**（旧PostgreSQL 11.2ドライバ→新PostgreSQL 15対応ドライバ）．構成図追加．プレースホルダーを意味ベース日本語に統一．パラメータ定義表を整理．各Stepに【実施対象】明示．句読点を「，．」に統一．サーバー表記を「サーバー」に統一．付録A〜D追加．） |
> | v1.1 | 2026-06-19 | 整合性チェックにより`postgresql-migration.md`とプレースホルダー命名を統一．`<DB名>`→`<移行先DB名>`，`<DBユーザー>`→`<移行先ロール>`，`<DBパスワード>`→`<移行先ロールのパスワード>`に変更． |
> | v1.2 | 2026-06-20 | `nfs-server.md` 追加に伴う連携強化．（1）パラメータ表に `<Tomcat実行UID>` `<Tomcat実行GID>` `<アプリケーションデータパス>` を追加．（2）Step 0「Tomcat実行ユーザーのUID/GID統一」を新規追加（AP1／AP2 で UID／GID を揃える）．（3）Step 0-2「NFSマウント確認」を新規追加．（4）構成図にNFS共有を反映．（5）前提条件に `nfs-server.md` 完了を追加．（6）付録D「関連手順書」に `nfs-server.md` を追加． |

------------------------------

## 2. 目的・概要

### 2-1. 目的

> 本手順書では，旧環境から取り出した `ROOT.war` を新環境のTomcatに配置し，新環境のPostgreSQL 15に対応したJDBCドライバへの入れ替えと，`application.yml` のDB／SMTP接続情報の書き換えを行い，アプリケーションを新環境で稼働させる手順について説明する．
> 本手順書はターミナルで1コマンドずつ手動実行することを前提とする．
>
> **本手順書の前提：**
> - Tomcatが構築済み（`tomcat-basic.md` 完了）
> - PostgreSQL 15が起動済み（`postgresql-server.md` 完了）
> - データ移行が完了し，新DBで `<移行先DB名>` ／ `<移行先ロール>` が利用可能（`postgresql-migration.md` 完了）
> - NFSサーバーが構築済みで AP1／AP2 でマウント済み（`nfs-server.md` 完了）
> - 配置対象の `ROOT.war` ファイルを事前に取得済み
> - SMTPサーバー，内部DNSが起動・名前解決可能

### 2-2. 構成概要（アーキテクチャ）

```
[旧APサーバー]
    └─ ROOT.war ── 取得 ──┐
                         │
                         ▼
              <ROOT.war配置元パス>
                         │
                         │ Step 3：配置
                         ▼
┌────────────── 新APサーバー（AP1／AP2）──────────┐
│  [Tomcat]                              │
│    /usr/local/tomcat/                  │
│    ├─ webapps/                         │
│    │   └─ ROOT/                        │
│    │       └─ WEB-INF/                 │
│    │           ├─ classes/             │
│    │           │   └─ application.yml ←Step 7書き換え│
│    │           └─ lib/                 │
│    │               └─ postgresql-42.1.4.jar ←Step 6削除│
│    │                                   │
│    └─ lib/                             │
│        └─ postgresql-<新ドライバ>.jar ←Step 6配置 │
│                                        │
│  [NFSクライアント]                       │
│    /mnt/<アプリケーションデータパス>      │
│       （nfs-server.mdで設定済）          │
│                                        │
└────────────┬───────────────────────────┘
             │ JDBC接続     │ NFSマウント
             │ TCP/5432    │ TCP/2049
             ▼              ▼
       [新DBサーバー（NFS同居）]
        ├─ PostgreSQL 15
        │   └─ <移行先DB名>（移行済）
        │       └─ <移行先ロール>
        └─ NFSサーバー
            └─ /exports/<アプリケーションデータパス>
       [SMTPサーバー]
        └─ Postfix
             └─ TCP/<SMTPポート>
```

### 2-3. 完成イメージ（ゴール定義）

- [ ] AP1／AP2 で `tomcat` ユーザーが同一UID／GID（`<Tomcat実行UID>` ／ `<Tomcat実行GID>`）で作成されている
- [ ] AP1／AP2 で `/mnt/<アプリケーションデータパス>` がNFSマウント済みで読み書き可能
- [ ] `<Tomcat配置ディレクトリ>/tomcat/webapps/ROOT/` が展開されている
- [ ] 旧JDBCドライバ（`postgresql-42.1.4.jar`）が `webapps/ROOT/WEB-INF/lib/` から削除されている
- [ ] 新JDBCドライバ（`postgresql-<新JDBCバージョン>.jar`）が `<Tomcat配置ディレクトリ>/tomcat/lib/` に配置され，所有者が `tomcat:tomcat` である
- [ ] `application.yml` のDB接続URL／ユーザー／パスワード／SMTP接続先が新環境値に置換されている
- [ ] `ROOT.war` 本体が `webapps/` から削除されている（再起動時の自動再展開を防ぐため）
- [ ] Tomcatが `active (running)` で `http://<APサーバーIP>:8080/` がアプリのトップページを返す
- [ ] `catalina.out` にDB接続エラー／SMTP接続エラーが出ていない

------------------------------

## 3. 前提条件・準備

### 3-1. 環境要件

| 項目 | 要件 |
|------|------|
| OS | Amazon Linux 2023 |
| Tomcat | 構築済み（`tomcat-basic.md` 完了） |
| PostgreSQL | 15（`postgresql-server.md` ＋ `postgresql-migration.md` 完了） |
| NFS | NFSサーバー構築済み・AP1／AP2でマウント済み（`nfs-server.md` 完了） |
| アプリケーション | `ROOT.war` を事前取得 |
| JDBCドライバ | PostgreSQL 15 対応版（PostgreSQL JDBC公式から取得） |

### 3-2. セキュリティグループ設定

#### 3-2-1. APサーバーのアウトバウンドルール

| タイプ | プロトコル | ポート | 送信先 | 説明 |
|-------|------------|-------|--------|------|
| HTTPS | TCP | 443 | 0.0.0.0/0 | JDBCドライバダウンロード（jdbc.postgresql.org） |
| カスタムTCP | TCP | 5432 | DBサーバーのSG | PostgreSQL接続 |
| カスタムTCP | TCP | `<SMTPポート>` | SMTPサーバーのSG | メール送信 |
| DNS | UDP | 53 | 内部DNSサーバーのSG | 内部名前解決 |

#### 3-2-2. DBサーバー側で必要な設定

DBサーバーの `pg_hba.conf` にAPサーバーIPからの接続許可エントリが追加されていること（`postgresql-migration.md` Step 10で実施済み）．

### 3-3. パラメータ定義表

> **注意：** 以下の値は作業前に環境に合わせて記入してから作業を開始すること．
> **重要：** **本手順書に実際のパスワードを直接記載しないこと**．

#### Tomcat関連

| パラメータ名 | 値 | 説明 |
|------------|---|------|
| `<Tomcat配置ディレクトリ>` | `/usr/local` | Tomcatを配置したディレクトリ（`tomcat-basic.md`と同じ値） |
| `<ROOT.war配置元パス>` | `<記入する>` | 配置する `ROOT.war` の格納パス（例：`/home/ec2-user/ROOT.war`） |
| `<Tomcat実行UID>` | `<記入する>` | Tomcat実行ユーザーのUID．AP1／AP2 で揃える必要あり（例：`1001`） |
| `<Tomcat実行GID>` | `<記入する>` | Tomcat実行グループのGID．AP1／AP2 で揃える必要あり（例：`1001`） |
| `<アプリケーションデータパス>` | `<記入する>` | NFS共有ディレクトリ名（`nfs-server.md` と同じ値．例：`knowledge_data`） |

#### JDBCドライバ関連（本手順書の新規Step）

| パラメータ名 | 値 | 説明 |
|------------|---|------|
| `<旧JDBCバージョン>` | 例：`42.1.4` | アプリに同梱されていた旧ドライバのバージョン |
| `<新JDBCバージョン>` | 例：`42.6.2` | PostgreSQL 15対応のドライババージョン |
| `<JDBCダウンロードURL>` | `https://jdbc.postgresql.org/download/postgresql-<新JDBCバージョン>.jar` | PostgreSQL JDBC公式URL |

#### DB接続設定

| パラメータ名 | 値 | 説明 |
|------------|---|------|
| `<DBサーバーのホスト名>` | `<記入する>` | DBサーバーのFQDN（例：`az2-db.wp.local`） |
| `<移行先ロール>` | `<記入する>` | DB接続ユーザー名（例：`hr_dash_user`） |
| `<移行先ロールのパスワード>` | パスワード管理ツール参照 | DB接続パスワード（本書には記載しない） |

#### SMTP接続設定

| パラメータ名 | 値 | 説明 |
|------------|---|------|
| `<SMTPサーバーのホスト名>` | `<記入する>` | SMTPサーバーのFQDN（例：`az1-smtp.wp.local`） |
| `<SMTPポート>` | `25` | SMTPサーバーのポート |
| `<送信元メールアドレス>` | `<記入する>` | アプリからの送信元アドレス |

#### 旧環境（sed 置換元）

| パラメータ名 | 値 | 説明 |
|------------|---|------|
| `<旧DBホスト>` | `localhost` | application.yml に記載されている旧DB接続先 |
| `<旧DBユーザー>` | `postgres` | application.yml に記載されている旧DBユーザー |
| `<旧DBパスワード>` | `postgres` | application.yml に記載されている旧DBパスワード |
| `<旧SMTPホスト>` | `localhost` | application.yml に記載されている旧SMTPホスト |
| `<旧SMTPポート>` | `1025` | application.yml に記載されている旧SMTPポート |
| `<旧送信元メールアドレス>` | `info@mail.rplearn.net` | application.yml に記載されている旧送信元 |

### 3-4. リンク一覧

| 項目名 | 目的 |
|-------|------|
| https://jdbc.postgresql.org/ | PostgreSQL JDBC公式 |
| https://jdbc.postgresql.org/documentation/ | JDBCドライバドキュメント |
| 別手順書：Tomcat構築 | `tomcat-basic.md` |
| 別手順書：PostgreSQL構築 | `postgresql-server.md` |
| 別手順書：データ移行 | `postgresql-migration.md` |
| 別手順書：NFS構築・マウント | `nfs-server.md` |

### 3-5. 事前確認

#### 3-5-1. Tomcat稼働確認【実施対象：APサーバー】

```bash
sudo systemctl is-active tomcat.service
ls -ld <Tomcat配置ディレクトリ>/tomcat
```

> **期待する結果：** `active`，シンボリックリンクがTomcat実体を指している．

#### 3-5-2. ROOT.warの存在確認【実施対象：APサーバー】

```bash
ls -l <ROOT.war配置元パス>
```

#### 3-5-3. DB／SMTP疎通確認【実施対象：APサーバー】

```bash
nc -zv <DBサーバーのホスト名> 5432
nc -zv <SMTPサーバーのホスト名> <SMTPポート>
```

> **期待する結果：** 両方とも `Connected` と表示される．

> **注意：** 疎通NGの場合，移行後にアプリが正常動作しない．先にネットワーク・SG・DNS設定を解消すること．

------------------------------

## 4. 構築手順（詳細）

> **注意事項**
> - コマンド中の `<山カッコ>` は自分の環境の値に置き換えること
> - 各Stepの見出し末尾に **【実施対象：APサーバー】** を明示
> - 本手順書の作業対象はすべて **APサーバー（AP1／AP2）** である
> - Step 0／Step 0-2 は AP1／AP2 の両方で実施．Step 1 以降は各APサーバーで個別に実施

------------------------------

### Step 0：Tomcat実行ユーザーのUID/GID統一【実施対象：AP1／AP2】

**目的：** NFS共有を使うため，AP1／AP2 の `tomcat` ユーザー／グループのUID／GIDを揃える．これによりNFSサーバー側で設定した所有者と一致し，書き込み権限が正しく機能する．

> **背景：** NFSはサーバー・クライアント間でUID／GID値を数値ベースで受け渡す．名前ベース（`tomcat`）ではなく数値（UID 1001等）で識別するため，AP1とAP2のUIDが異なるとNFS共有先で書き込み拒否される（詳細は `nfs-server.md` 付録D-3 参照）．

#### 操作手順（AP1／AP2 の両方で実施）

##### 現在のUID/GIDを確認

```bash
id tomcat
```

> **出力例：** `uid=1001(tomcat) gid=1001(tomcat) groups=1001(tomcat)`

#### AP1／AP2 で値が一致している場合

そのまま `<Tomcat実行UID>` `<Tomcat実行GID>` に記入してStep 0-2へ進む．

#### AP1／AP2 で値が異なる場合

どちらかに揃える．通常は **AP1 の値を AP2 で揃える** ことが多い（先に構築した側の値を採用）．

##### 例：AP2 の tomcat UID を `1001` ／GID を `1001` に変更

```bash
# Tomcatを停止
sudo systemctl stop tomcat.service

# グループのGID変更
sudo groupmod -g <Tomcat実行GID> tomcat

# ユーザーのUID変更
sudo usermod -u <Tomcat実行UID> tomcat

# Tomcat関連ファイルの所有者を更新
sudo find / -user <旧UID> -exec chown -h <Tomcat実行UID> {} \; 2>/dev/null
sudo find / -group <旧GID> -exec chgrp -h <Tomcat実行GID> {} \; 2>/dev/null

# 確認
id tomcat
```

> **期待する結果：** AP1／AP2 で `uid=<Tomcat実行UID>(tomcat) gid=<Tomcat実行GID>(tomcat)` が一致する．

> **重要：** UID／GID変更後はTomcat実体ディレクトリ（`<Tomcat配置ディレクトリ>/tomcat`）の所有者も再設定が必要．`find` で対応している．

> **注意：** AP1／AP2 で値が大きく異なり影響範囲が読めない場合，AP2のTomcat一旦停止 → 元ユーザー削除 → 同UID/GIDで再作成 → Tomcat再構築 の方が安全な場合もある．

------------------------------

### Step 0-2：NFSマウントの確認【実施対象：AP1／AP2】

**目的：** `nfs-server.md` で構築・マウント済みのNFS共有が `/mnt/<アプリケーションデータパス>` で利用可能か確認する

#### 操作手順（AP1／AP2 の両方で実施）

##### マウント状態確認

```bash
df -hT | grep <アプリケーションデータパス>
mount | grep <アプリケーションデータパス>
```

> **期待する結果：** `nfs4` タイプでマウントされており，使用量が表示される．

##### 書き込みテスト（tomcatユーザーで）

```bash
sudo -u tomcat touch /mnt/<アプリケーションデータパス>/test-from-$(hostname).txt
ls -l /mnt/<アプリケーションデータパス>/test-from-*.txt
```

> **期待する結果：** ファイルが作成され，所有者が `tomcat:tomcat`（`<Tomcat実行UID>:<Tomcat実行GID>`）になる．

##### 確認後のクリーンアップ

```bash
sudo -u tomcat rm /mnt/<アプリケーションデータパス>/test-from-$(hostname).txt
```

> **マウントされていない場合：** `nfs-server.md` の Step 7／Step 8 を再確認してマウント手順を実施．

> **書き込みが Permission denied になる場合：**
> - AP1／AP2 の `tomcat` UID／GID が NFSサーバー側の所有者と一致しているか確認（Step 0を再確認）
> - NFSサーバー側 `/exports/<アプリケーションデータパス>` の所有者を確認
> - 詳細は `nfs-server.md` のトラブルシューティング エラー④を参照

------------------------------

### Step 1：Tomcatの停止【実施対象：APサーバー】

**目的：** 既存の `webapps/ROOT` を安全にクリアするためTomcatを停止する

#### 操作手順

```bash
sudo systemctl stop tomcat.service
sudo systemctl is-active tomcat.service
```

> **期待する結果：** `inactive`．

------------------------------

### Step 2：既存ROOTのクリア【実施対象：APサーバー】

**目的：** 冪等性確保のため，既存のアプリディレクトリとwarファイルを削除する

#### 操作手順

```bash
sudo rm -rf <Tomcat配置ディレクトリ>/tomcat/webapps/ROOT
sudo rm -f  <Tomcat配置ディレクトリ>/tomcat/webapps/ROOT.war

ls <Tomcat配置ディレクトリ>/tomcat/webapps/
```

> **期待する結果：** `ROOT` および `ROOT.war` が存在しない（`tomcat-default` 等は残る）．

------------------------------

### Step 3：ROOT.warの配置【実施対象：APサーバー】

**目的：** アプリのwarファイルをTomcatのwebappsに配置する

#### 操作手順

```bash
# warファイルをコピー
sudo cp -p <ROOT.war配置元パス> <Tomcat配置ディレクトリ>/tomcat/webapps/ROOT.war

# 所有者を tomcat に変更
sudo chown tomcat:tomcat <Tomcat配置ディレクトリ>/tomcat/webapps/ROOT.war

# 確認
ls -l <Tomcat配置ディレクトリ>/tomcat/webapps/ROOT.war
```

> **期待する結果：** 所有者が `tomcat:tomcat`．

------------------------------

### Step 4：Tomcatの起動と自動展開待機【実施対象：APサーバー】

**目的：** Tomcatを起動して `ROOT.war` を自動展開させる

#### 操作手順

```bash
# Tomcatを起動
sudo systemctl start tomcat.service

# 自動展開の完了を待つ（最大60秒）
for i in $(seq 1 60); do
  ls <Tomcat配置ディレクトリ>/tomcat/webapps/ROOT/WEB-INF/classes/application.yml 2>/dev/null && break
  sleep 1
done

# 展開確認
ls <Tomcat配置ディレクトリ>/tomcat/webapps/ROOT/WEB-INF/classes/application.yml
```

> **期待する結果：** `application.yml` が存在する．

> **注意：** 60秒経っても展開されない場合は `<Tomcat配置ディレクトリ>/tomcat/logs/catalina.out` で展開エラーを確認すること（トラブルシューティング参照）．

------------------------------

### Step 5：ROOT.war本体の削除【実施対象：APサーバー】

**目的：** war本体を残すと再起動時に再展開され`application.yml` の編集が消えてしまうため，展開後はwar本体を削除する

#### 操作手順

```bash
sudo rm -f <Tomcat配置ディレクトリ>/tomcat/webapps/ROOT.war

ls <Tomcat配置ディレクトリ>/tomcat/webapps/
```

> **期待する結果：** `ROOT.war` が消え，`ROOT` ディレクトリのみ残っている．

------------------------------

### Step 6：JDBCドライバの入れ替え【実施対象：APサーバー】

**目的：** 旧PostgreSQL用のJDBCドライバを削除し，PostgreSQL 15対応の新ドライバを配置する

> **重要：** これは旧環境からの移行で特に重要なStep．旧バージョンの `postgresql-42.1.4.jar` は PostgreSQL 14以降の `scram-sha-256` 認証に対応していないため，新環境では認証失敗の原因となる．

#### Step 6-1：Tomcatを一旦停止

```bash
sudo systemctl stop tomcat.service
```

> **注意：** JARファイル入れ替え中の競合を避けるため一旦停止．

#### Step 6-2：旧JDBCドライバの削除（webapps配下）

```bash
# 既存の確認
ls <Tomcat配置ディレクトリ>/tomcat/webapps/ROOT/WEB-INF/lib/postgresql-*.jar

# 旧ドライバを削除
sudo rm -f <Tomcat配置ディレクトリ>/tomcat/webapps/ROOT/WEB-INF/lib/postgresql-<旧JDBCバージョン>.jar

# 確認
ls <Tomcat配置ディレクトリ>/tomcat/webapps/ROOT/WEB-INF/lib/postgresql-*.jar 2>/dev/null
```

> **期待する結果：** 旧バージョンのJARが消えている（何も表示されない，もしくは別バージョンが残っている）．

#### Step 6-3：新JDBCドライバのダウンロード

```bash
# 作業ディレクトリへ移動
cd <Tomcat配置ディレクトリ>/tomcat/lib/

# PostgreSQL公式から新ドライバをダウンロード
sudo wget <JDBCダウンロードURL>

# 確認
ls -l postgresql-<新JDBCバージョン>.jar
```

> **期待する結果：** JARファイルがダウンロードされている．

#### Step 6-4：所有者を tomcat に変更

```bash
sudo chown tomcat:tomcat <Tomcat配置ディレクトリ>/tomcat/lib/postgresql-<新JDBCバージョン>.jar

ls -l <Tomcat配置ディレクトリ>/tomcat/lib/postgresql-<新JDBCバージョン>.jar
```

> **期待する結果：** 所有者が `tomcat:tomcat`．

> **補足：** `Tomcat配置ディレクトリ/tomcat/lib/` に配置することで，全てのWebアプリで共有される．`webapps/ROOT/WEB-INF/lib/` に置く方法もあるが，今回は共通化を選択．

------------------------------

### Step 7：application.ymlのバックアップ【実施対象：APサーバー】

**目的：** 置換前のオリジナルを `.org` 拡張子で退避する

#### 操作手順

```bash
sudo cp -p \
  <Tomcat配置ディレクトリ>/tomcat/webapps/ROOT/WEB-INF/classes/application.yml \
  <Tomcat配置ディレクトリ>/tomcat/webapps/ROOT/WEB-INF/classes/application.yml.org

ls -l <Tomcat配置ディレクトリ>/tomcat/webapps/ROOT/WEB-INF/classes/application.yml*
```

> **期待する結果：** `application.yml` と `application.yml.org` の両方が存在する．

------------------------------

### Step 8：application.ymlを環境値に置換【実施対象：APサーバー】

**目的：** `sed` で `application.yml` 内のデフォルト値を新環境固有値に置換する

#### Step 8-1：DB URLの置換

```bash
sudo sed -i "/url/s/<旧DBホスト>/<DBサーバーのホスト名>/g" \
  <Tomcat配置ディレクトリ>/tomcat/webapps/ROOT/WEB-INF/classes/application.yml
```

#### Step 8-2：DBユーザー名の置換

```bash
sudo sed -i "/username/s/<旧DBユーザー>/<移行先ロール>/g" \
  <Tomcat配置ディレクトリ>/tomcat/webapps/ROOT/WEB-INF/classes/application.yml
```

#### Step 8-3：DBパスワードの置換

```bash
sudo sed -i "/password/s/<旧DBパスワード>/<移行先ロールのパスワード>/g" \
  <Tomcat配置ディレクトリ>/tomcat/webapps/ROOT/WEB-INF/classes/application.yml
```

#### Step 8-4：SMTPホストの置換

```bash
sudo sed -i "/host/s/<旧SMTPホスト>/<SMTPサーバーのホスト名>/g" \
  <Tomcat配置ディレクトリ>/tomcat/webapps/ROOT/WEB-INF/classes/application.yml
```

#### Step 8-5：SMTPポートの置換

```bash
sudo sed -i "/port/s/<旧SMTPポート>/<SMTPポート>/g" \
  <Tomcat配置ディレクトリ>/tomcat/webapps/ROOT/WEB-INF/classes/application.yml
```

#### Step 8-6：送信元メールアドレスの置換

```bash
sudo sed -i "/from/s/<旧送信元メールアドレス>/<送信元メールアドレス>/g" \
  <Tomcat配置ディレクトリ>/tomcat/webapps/ROOT/WEB-INF/classes/application.yml
```

#### Step 8-7：置換結果の確認

```bash
sudo grep -E "url|username|password|host|port|from" \
  <Tomcat配置ディレクトリ>/tomcat/webapps/ROOT/WEB-INF/classes/application.yml
```

> **期待する結果：** 旧値（`<旧DBホスト>`／`<旧DBユーザー>`／`<旧SMTPポート>`／`<旧送信元メールアドレス>`等）が残っておらず，パラメータ定義表の値が反映されている．

> **重要：** 元値がapplication.yml内に存在しない場合，その`sed` コマンドは何も置換せずに正常終了する（=エラーにはならない）が，結果として置換が反映されない．必ずStep 8-7で結果確認すること．

------------------------------

### Step 9：ROOTディレクトリの所有者再設定【実施対象：APサーバー】

**目的：** 編集後のファイル所有者を tomcat に戻す

#### 操作手順

```bash
sudo chown -R tomcat:tomcat <Tomcat配置ディレクトリ>/tomcat/webapps/ROOT
```

------------------------------

### Step 10：Tomcatの起動【実施対象：APサーバー】

**目的：** `application.yml` の変更と新JDBCドライバを反映させるためTomcatを起動

#### 操作手順

```bash
sudo systemctl start tomcat.service
sudo systemctl is-active tomcat.service
```

> **期待する結果：** `active`．

> **注意：** 起動失敗時は `catalina.out` で原因確認．

------------------------------

## 5. 動作確認・検証

### 5-1. 確認チェックリスト

- [ ] **確認①**：`webapps/ROOT/` が展開済み
- [ ] **確認②**：新JDBCドライバが配置済み
- [ ] **確認③**：`application.yml` の置換が正しく反映
- [ ] **確認④**：Tomcatが `active (running)`
- [ ] **確認⑤**：`http://localhost:8080/` でアプリが応答
- [ ] **確認⑥**：`catalina.out` にDB接続エラーが出ていない
- [ ] **確認⑦**：アプリからのメール送信が成功する（任意）

------------------------------

### 確認①：展開ディレクトリの確認

```bash
ls -ld <Tomcat配置ディレクトリ>/tomcat/webapps/ROOT
```

> **期待する結果：** ディレクトリが存在．

------------------------------

### 確認②：新JDBCドライバの配置確認

```bash
ls -l <Tomcat配置ディレクトリ>/tomcat/lib/postgresql-<新JDBCバージョン>.jar
```

> **期待する結果：** ファイルが存在し，所有者が `tomcat:tomcat`．

#### 旧JDBCが残っていないか確認

```bash
find <Tomcat配置ディレクトリ>/tomcat -name "postgresql-<旧JDBCバージョン>.jar" 2>/dev/null
```

> **期待する結果：** 何も表示されない（旧JDBC削除済み）．

------------------------------

### 確認③：application.ymlの置換確認

```bash
sudo grep -E "url|username|password|host|port|from" \
  <Tomcat配置ディレクトリ>/tomcat/webapps/ROOT/WEB-INF/classes/application.yml
```

> **期待する結果：** パラメータ定義表の値が反映されている．

------------------------------

### 確認④：Tomcatサービス状態確認

```bash
sudo systemctl status tomcat.service --no-pager
```

> **期待する結果：** `active (running)`．

------------------------------

### 確認⑤：HTTPアクセス確認

```bash
curl -I http://localhost:8080/
```

> **期待する結果：** `HTTP/1.1 200`．

------------------------------

### 確認⑥：ログ確認

```bash
sudo tail -n 100 <Tomcat配置ディレクトリ>/tomcat/logs/catalina.out
```

> **注意：** 以下のエラーが出ていないこと：
>
> - `Connection refused`（DB）
> - `SocketTimeoutException`（SMTP）
> - `org.postgresql.util.PSQLException`（JDBCドライバ）
> - `FATAL: password authentication failed`（DB認証）

------------------------------

### 確認⑦：メール送信テスト（任意）

アプリのメール送信機能（パスワードリセット等）を使って，実際にメール送信が成功することを確認する．

------------------------------

## 6. トラブルシューティング

------------------------------

#### エラー①：自動展開が完了しない

**原因：** warの破損，もしくはTomcatが起動していない．

**対処法：**

```bash
sudo systemctl status tomcat.service
sudo tail -n 200 <Tomcat配置ディレクトリ>/tomcat/logs/catalina.out
```

warが破損している場合は正しいwarを再配置してStep 1から実施．

------------------------------

#### エラー②：DB接続でエラー（`Connection refused` / `FATAL: password authentication failed`）

**原因：**

- `application.yml` の置換値が誤っている
- DB側の `pg_hba.conf` 設定不足
- 旧JDBCドライバが残っていて `scram-sha-256` 認証に対応していない

**対処法：**

```bash
# application.yml 確認
sudo grep -A1 "url\|username\|password" \
  <Tomcat配置ディレクトリ>/tomcat/webapps/ROOT/WEB-INF/classes/application.yml

# JDBCドライバの確認（旧バージョンが残っていないか）
find <Tomcat配置ディレクトリ>/tomcat -name "postgresql-*.jar" 2>/dev/null

# 直接DB接続テスト
psql -h <DBサーバーのホスト名> -U <移行先ロール> -d <移行先DB名>
```

旧ドライバ（`postgresql-42.1.4.jar`等の42.2.5未満）が残っていれば，`webapps/ROOT/WEB-INF/lib/` から削除し，Tomcat再起動．

------------------------------

#### エラー③：sedの置換が反映されない

**原因：** 元 `application.yml` にデフォルト値が存在しない，もしくはバージョン差異．

**対処法：**

```bash
sudo diff \
  <Tomcat配置ディレクトリ>/tomcat/webapps/ROOT/WEB-INF/classes/application.yml.org \
  <Tomcat配置ディレクトリ>/tomcat/webapps/ROOT/WEB-INF/classes/application.yml
```

差分が無ければ置換失敗．`application.yml.org` を確認し，置換対象の元値を特定してから `vi` で直接編集：

```bash
sudo vi <Tomcat配置ディレクトリ>/tomcat/webapps/ROOT/WEB-INF/classes/application.yml
sudo systemctl restart tomcat.service
```

------------------------------

#### エラー④：`The driver could not establish a secure connection ... scram-sha-256`

**原因：** JDBCドライバが古く `scram-sha-256` 認証に対応していない．

**対処法：** Step 6で新JDBCドライバ（42.2.5以降）が正しく配置されているか確認．`webapps/ROOT/WEB-INF/lib/` 配下に旧JDBCドライバが残っていないか確認．

------------------------------

#### エラー⑤：`No suitable driver found for jdbc:postgresql://...`

**原因：** JDBCドライバが見つからない（配置先間違い，または所有者がtomcat以外）．

**対処法：**

```bash
# 配置場所と所有者確認
ls -l <Tomcat配置ディレクトリ>/tomcat/lib/postgresql-*.jar

# 必要なら所有者修正
sudo chown tomcat:tomcat <Tomcat配置ディレクトリ>/tomcat/lib/postgresql-*.jar

# Tomcat再起動
sudo systemctl restart tomcat.service
```

------------------------------

### ログの確認場所

| ログの種類 | 場所 |
|-----------|------|
| Tomcat 標準出力 | `<Tomcat配置ディレクトリ>/tomcat/logs/catalina.out` |
| Tomcat アクセスログ | `<Tomcat配置ディレクトリ>/tomcat/logs/localhost_access_log.*.txt` |
| systemd ログ | `journalctl -u tomcat.service` |

------------------------------

## 7. 参考リソース・関連資料

| 資料名 | URL / 場所 | 補足 |
|-------|-----------|------|
| PostgreSQL JDBC 公式 | https://jdbc.postgresql.org/ | ドライバダウンロード |
| JDBC バージョンとPostgreSQLバージョン対応 | https://jdbc.postgresql.org/download/ | 対応バージョン表 |
| Tomcat 公式ドキュメント | https://tomcat.apache.org/tomcat-9.0-doc/ | Tomcat全般 |
| 別手順書：Tomcat構築 | `tomcat-basic.md` | 本手順書の前提 |
| 別手順書：PostgreSQL構築 | `postgresql-server.md` | 本手順書の前提 |
| 別手順書：データ移行 | `postgresql-migration.md` | 本手順書の前提 |

------------------------------

## 8. ロールバック手順

> **実施内容：** アプリを撤去し，Tomcat本体は稼働継続させる．

### 8-1. ロールバック判定基準

以下の場合，ロールバックを検討：

- アプリの動作が不安定で原因特定が困難
- DB接続が安定しない
- ユーザー影響が出ている

### 8-2. Tomcatの停止【実施対象：APサーバー】

```bash
sudo systemctl stop tomcat.service
```

### 8-3. ROOTディレクトリの削除【実施対象：APサーバー】

```bash
ls -d <Tomcat配置ディレクトリ>/tomcat/webapps/ROOT 2>/dev/null && \
  sudo rm -rf <Tomcat配置ディレクトリ>/tomcat/webapps/ROOT
```

### 8-4. ROOT.warの削除（残存している場合）【実施対象：APサーバー】

```bash
sudo rm -f <Tomcat配置ディレクトリ>/tomcat/webapps/ROOT.war
```

### 8-5. JDBCドライバの削除（任意）【実施対象：APサーバー】

> **注意：** 他のアプリが使用していない場合のみ削除する．

```bash
sudo rm -f <Tomcat配置ディレクトリ>/tomcat/lib/postgresql-<新JDBCバージョン>.jar
```

### 8-6. Tomcatの再起動【実施対象：APサーバー】

**目的：** Tomcat本体は稼働継続させる（`tomcat-default` 等は残す）．

```bash
sudo systemctl start tomcat.service
```

### 8-7. 完了確認【実施対象：APサーバー】

```bash
ls <Tomcat配置ディレクトリ>/tomcat/webapps/
# → ROOT および ROOT.war が無く，tomcat-default 等が残ること

curl -I http://localhost:8080/tomcat-default/
# → HTTP/1.1 200（Tomcat本体は稼働）
```

> **注意：**
>
> - 元データの `ROOT.war`（`<ROOT.war配置元パス>`）は削除されない．
> - Tomcat自体も撤去したい場合は `tomcat-basic.md` のロールバック手順を実施．

------------------------------

## 付録

### A. コマンド解説

| コマンド | 説明 |
|---------|------|
| `systemctl stop \| start \| restart tomcat.service` | Tomcatサービスの停止・起動・再起動． |
| `systemctl is-active <サービス>` | サービスがactiveかどうかを返す． |
| `cp -p <src> <dst>` | パーミッション・タイムスタンプを保持してコピー． |
| `chown -R tomcat:tomcat <パス>` | 所有者・グループを再帰的に変更． |
| `wget <URL>` | URLからファイルダウンロード． |
| `sed -i "/<検索行>/s/<置換元>/<置換先>/g" <ファイル>` | ファイル内の指定行のみ置換． |
| `grep -E "<パターン>" <ファイル>` | 拡張正規表現で検索． |
| `find <ディレクトリ> -name <パターン>` | ファイルを検索． |
| `diff <ファイル1> <ファイル2>` | ファイル差分表示． |
| `nc -zv <ホスト> <ポート>` | ポート疎通確認． |
| `tail -n <数> <ログ>` | ログ末尾を表示． |

------------------------------

### B. 設定ファイル解説

**`<Tomcat配置ディレクトリ>/tomcat/webapps/ROOT/WEB-INF/classes/application.yml`（APサーバー）**

主な設定項目（Spring Boot形式の例）：

```yaml
spring:
  datasource:
    url: jdbc:postgresql://<DBサーバーのホスト名>:5432/<移行先DB名>
    username: <移行先ロール>
    password: <移行先ロールのパスワード>
    driver-class-name: org.postgresql.Driver
  mail:
    host: <SMTPサーバーのホスト名>
    port: <SMTPポート>
    properties:
      mail.from: <送信元メールアドレス>
```

- `url`：JDBC接続URL．ホスト名は内部DNSで解決可能なFQDNを推奨．
- `driver-class-name`：JDBCドライバクラス．PostgreSQLは `org.postgresql.Driver`．
- `mail.host` ／ `mail.port`：SMTPリレーサーバーの接続先．

**JDBCドライバ配置場所**

| 場所 | スコープ |
|------|---------|
| `<Tomcat配置ディレクトリ>/tomcat/lib/` | 全Webアプリで共有（本手順書での選択） |
| `<webapps>/<アプリ>/WEB-INF/lib/` | そのアプリのみ |

本手順書では共有配置（`tomcat/lib/`）を選択．アプリ間でJDBCドライバのバージョン差異を作らないため．

------------------------------

### C. 用語解説

| 用語 | 説明 |
|------|------|
| ROOT.war | Tomcatの「デフォルトアプリケーション」として配置される `.war` ファイル．`http://<server>:8080/` がそのまま動作する． |
| WAR (Web Application Archive) | Java Webアプリのzip形式パッケージ．Tomcat等のサーブレットコンテナにデプロイする． |
| webapps | Tomcatのアプリ配置ディレクトリ．`.war` を置くと自動展開される． |
| 自動展開 (autoDeploy) | webappsに置かれた `.war` をTomcatが自動で展開する機能． |
| JDBCドライバ | JavaがDBに接続するための実装．DBごとに別のドライバが必要． |
| `org.postgresql.Driver` | PostgreSQL JDBCドライバのメインクラス． |
| `application.yml` | Spring Bootの標準設定ファイル．YAMLフォーマット． |
| scram-sha-256 | PostgreSQL 10以降の強力なパスワード認証．JDBCは42.2.5以降で対応． |
| `catalina.out` | Tomcatの標準出力／エラー出力をまとめたログ． |

------------------------------

### D. 補足解説

#### D-1. なぜJDBCドライバの入れ替えが必須か？

- 旧環境は PostgreSQL 11.2 で `md5` 認証．
- 新環境は PostgreSQL 15 で **デフォルト `scram-sha-256` 認証**．
- `postgresql-42.1.4.jar`（PostgreSQL JDBC 42.1.x系）は **`scram-sha-256` に未対応**．
- これによりアプリは「認証成功するはずなのに失敗する」状態に陥る．
- **JDBC 42.2.5以降** で `scram-sha-256` に対応．本手順書では `42.6.2` を採用（より新しい安定版）．

#### D-2. JDBC配置場所の選択（webapps vs tomcat/lib）

**`webapps/<app>/WEB-INF/lib/` に置くケース：**
- アプリと一緒にバージョン管理したい
- 同じTomcatに別アプリがあり，異なるJDBCバージョンを使う

**`tomcat/lib/` に置くケース（本手順書）：**
- 1つのTomcatに1つのアプリ
- 全アプリで同じJDBCバージョンを使う
- JDBCのバージョン管理を運用で一元化したい

本手順書では `tomcat/lib/` を選択．旧JDBCドライバが `webapps/ROOT/WEB-INF/lib/` に残ったまま `tomcat/lib/` に新ドライバを置くと **クラスローダーの優先順位で `webapps/<app>/WEB-INF/lib/` が先に読み込まれる** ため，必ずStep 6-2 で旧ドライバを削除する．

#### D-3. application.yml編集後に再起動が必要な理由

- Spring Bootアプリは起動時に `application.yml` を読み込んでDBコネクションプール等を初期化．
- 起動後の変更は反映されないため，必ず再起動する．
- 本手順書では Step 6-1 で停止し，Step 10 で起動する流れ．

#### D-4. sed置換が失敗するケース

- application.ymlのバージョンが異なり，置換元の値が存在しない
- インデントや改行が異なる
- YAMLのアンカー機能などで設定が一箇所ではなく複数箇所に分散している

そのため Step 8-7 の **置換結果確認は必須**．

#### D-5. 移行検証の流れ

理想的な移行検証：

1. **新環境のみで動作確認**：旧環境を止めて新環境にアクセスし，主要機能を一通り操作．
2. **データ整合性確認**：移行元と移行先で主要テーブルの件数・最終更新日時を比較．
3. **長時間稼働確認**：数時間〜1日，通常運用でエラーが出ないことを確認．
4. **ロールバック予備手順の確認**：問題があった場合に旧環境に戻す手順をリハーサル．

#### D-6. 旧環境のクリーンアップ

新環境が安定稼働した後（最低1週間程度）：

- 旧APサーバーのTomcat停止
- 旧DBサーバーのPostgreSQL停止
- AMIスナップショット取得（数か月保管）
- インスタンス削除（必要なら）

旧環境はバックアップ用に当面残しておくことを推奨．

#### D-7. `dnf update` と `dnf upgrade` の違い

- DNFベースのAmazon Linux 2023では両者は同義．本手順書では OS パッケージ更新は実施しない．

#### D-8. 関連手順書

本手順書の前後関係：

| 順序 | 手順書 | 連携内容 |
|---|---|---|
| 前 | `aws-infrastructure-setup.md` | VPC・EC2・SG構築 |
| 前 | `tomcat-basic.md` | Tomcat構築（AP1／AP2 両方） |
| 前 | `postgresql-server.md` | PostgreSQLサーバー構築 |
| 前 | `postgresql-migration.md` | データ移行・ロール作成・`pg_hba.conf` 設定 |
| 前 | `nfs-server.md` | NFSサーバー構築・AP1／AP2 クライアントマウント |
| 本手順書 | `war-deploy-migration.md` | Tomcat実行UID／GID統一・NFSマウント確認・WARデプロイ・JDBC差し替え・application.yml書き換え |
| 後 | `modsecurity-migration.md`（任意） | nginxレイヤでModSecurity WAFを有効化 |
