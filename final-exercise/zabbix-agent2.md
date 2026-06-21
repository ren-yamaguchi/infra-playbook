# Zabbix Agent2 7.0 構築

------------------------------

## 1. ドキュメント情報

| 項目 | 内容 |
|------|------|
| 手順書名 | Zabbix Agent2 7.0 構築 |
| 作成日 | 2026-06-18 |
| 最終更新日 | 2026-06-18 |
| バージョン | v1.1 |
| 対象環境 | AWS（Amazon Linux 2023） |

> **改訂履歴**
>
> | バージョン | 日付 | 変更内容 |
> |-----------|------|---------|
> | v1.0 | 2026-06-18 | 初版作成（テンプレートに沿って再構成．構成図追加．プレースホルダーを意味ベース日本語に統一．`zabbix-server.md`と命名を整合．パラメータ定義表を整理．SG設定セクションを追加．ロールバック手順を新設．各Stepに【実施対象】明示．句読点を「，．」に統一．「Zabbixサーバー」（長音記号あり）に統一．`systemctl enable --now`に統一．複数台一括実行は付録Dへ移動．付録A〜D追加．） |
> | v1.1 | 2026-06-20 | 内部DNS（`nsd-private-redundancy.md`）の名前解決設定漏れに対応．Step 1を「タイムゾーン設定」から「システム設定（タイムゾーン・ホスト名・名前解決）」に拡張．重複設定はスキップ可能なテンプレート手順として記載．パラメータ表に `<監視対象サーバーのホスト名>` `<Primary DNSのIP>` `<Secondary DNSのIP>` 追加．ロールバック手順8-6（条件付きDNS削除）を追加し，旧8-6を8-7に繰り上げ． |

------------------------------

## 2. 目的・概要

### 2-1. 目的

> 本手順書では，VPC内の監視対象サーバーにZabbix Agent2をインストールし，Zabbixサーバーからの監視を有効にする手順について説明する．
> 本手順書は監視対象サーバー側の作業を主とし，最終的な紐付け作業のみZabbixサーバー（Web GUI）で実施する．
> Zabbixサーバー本体の構築は別手順書（`zabbix-server.md`），DB側の構築は別手順書（`zabbix-db-postgresql.md`）を参照すること．

### 2-2. 構成概要（アーキテクチャ）

```
┌────────────────────────── VPC ──────────────────────────┐
│                                                          │
│  [EC2: Zabbixサーバー]                                    │
│      ├─ zabbix-server-pgsql（10051番）                    │
│      │    ▲ Active                                      │
│      │    │ TCP/10051                                   │
│      │    │                                             │
│      └─ Web GUI（80番）── ホスト登録・テンプレート割当      │
│           │                                              │
│           │ TCP/10050 (Passive)                          │
│           ▼                                              │
│  [EC2: 監視対象サーバー × N台]                             │
│      └─ zabbix-agent2（10050番）                          │
│           └─ Hostname=<エージェントのホスト名>             │
│                                                          │
│   ホスト登録方式：                                         │
│      A. 自動登録（推奨）                                   │
│      B. 手動登録                                          │
│                                                          │
└──────────────────────────────────────────────────────────┘
```

### 2-3. 完成イメージ（ゴール定義）

- [ ] 監視対象サーバーで `zabbix-agent2` が `active (running)` かつ自動起動有効である
- [ ] 10050番ポートがLISTENしている
- [ ] Web GUI 上に対象ホストが登録されている（自動／手動どちらか）
- [ ] Web GUI 上で対象ホストの ZBX アイコンが緑になっている
- [ ] サーバー種別に応じたテンプレートが割り当てられている（最低でも「Linux by Zabbix agent」）
- [ ] 最新データが収集されている（アイテム数 77 前後）

------------------------------

## 3. 前提条件・準備

### 3-1. 環境要件

| 項目 | 要件 |
|------|------|
| OS | Amazon Linux 2023 |
| 監視対象サーバー | rootまたはsudo権限を持つユーザーで作業可能であること |
| Zabbixサーバー | 既に起動・稼働していること（`zabbix-server.md` 完了） |
| ネットワーク | Zabbixサーバーとの間で10050／10051の通信が許可されていること |
| インターネット接続 | Zabbixリポジトリからパッケージを取得するため必須 |

### 3-2. セキュリティグループ設定

#### 3-2-1. 監視対象サーバーのインバウンドルール

| タイプ | プロトコル | ポート範囲 | ソース | 説明 |
|-------|------------|----------|--------|------|
| SSH | TCP | 22 | マイIP（踏み台経由） | 構築作業用 |
| カスタムTCP | TCP | 10050 | ZabbixサーバーのSG | Passiveチェック（Zabbixサーバーからの接続） |

#### 3-2-2. 監視対象サーバーのアウトバウンドルール

| タイプ | プロトコル | ポート範囲 | 送信先 | 説明 |
|-------|------------|----------|--------|------|
| HTTPS | TCP | 443 | 0.0.0.0/0 | dnf／Zabbixリポジトリからのパッケージ取得 |
| HTTP | TCP | 80 | 0.0.0.0/0 | dnfミラー |
| カスタムTCP | TCP | 10051 | ZabbixサーバーのSG | Activeチェック（エージェント側送信） |

### 3-3. パラメータ定義表

> **注意：** 以下の値は作業前に環境に合わせて記入してから作業を開始すること．

#### 共通

| パラメータ名 | 値 | 説明 |
|------------|---|------|
| `<ZabbixサーバーのプライベートIP>` | `<記入する>` | Zabbixサーバーのプライベート IP（`zabbix-server.md`で構築済み） |
| `<監視対象サーバーのホスト名>` | `<記入する>` | このサーバーのホスト名（例：`web-az1`，`ap-az2`） |
| `<Primary DNSのIP>` | `<記入する>` | 内部DNSプライマリ（AZ2のAPサーバー）のIP |
| `<Secondary DNSのIP>` | `<記入する>` | 内部DNSセカンダリ（AZ4のAPサーバー）のIP |

#### 監視対象サーバー一覧

> **重要：** **`<エージェントのホスト名>` は，後でWeb GUIに登録するホスト名と必ず一致させること**．不一致だとActiveチェックが機能しない．

| EC2インスタンス名 | `<エージェントのホスト名>` | `<監視対象サーバーのプライベートIP>` | サーバー種別 |
|---|---|---|---|
| `<記入する>` | `<記入する>` | `<記入する>` | 例：Web／AP／DB |
| `<記入する>` | `<記入する>` | `<記入する>` |  |
| `<記入する>` | `<記入する>` | `<記入する>` |  |

### 3-4. リンク一覧

| 項目名 | 目的 |
|-------|------|
| https://www.zabbix.com/documentation/7.0/jp/manual | Zabbix 7.0公式ドキュメント |
| https://www.zabbix.com/documentation/7.0/jp/manual/discovery/auto_registration | 自動登録の仕様 |
| https://repo.zabbix.com/zabbix/7.0/amazonlinux/2023/x86_64/ | Zabbix公式リポジトリ |

------------------------------

## 4. 構築手順（詳細）

> **注意事項**
> - コマンド中の `<山カッコ>` は自分の環境の値（パラメータ定義表の値）に置き換えること
> - 各Stepの見出し末尾に **【実施対象：●●】** を明示しているので，対象のサーバーで実施すること
> - 監視対象サーバーが複数台ある場合は，各サーバーで同じ手順を繰り返すこと
> - 大量にある場合は **付録D-7「複数台への一括実行スクリプト」** を参照

------------------------------

### Step 1：システム設定（タイムゾーン・ホスト名・名前解決）【実施対象：監視対象サーバー】

**目的：** タイムゾーン，ホスト名，内部DNSの名前解決先を設定する

> **補足：** 監視対象サーバーで既に他の構築手順書（`tomcat-basic.md` `postgresql-server.md` `nginx-reverse-proxy.md` 等）により本設定が完了している場合は，本Stepの該当項目はスキップ可能．既存設定との重複は問題なし．

#### 操作手順

```bash
# rootユーザーにスイッチ
sudo su -

# パッケージを最新化
dnf update -y

# タイムゾーンを設定
timedatectl set-timezone Asia/Tokyo
timedatectl status

# ホスト名を設定（未設定の場合のみ）
hostnamectl set-hostname <監視対象サーバーのホスト名>

# 通信確認ツール（nc）の存在確認
command -v nc
# → 何も表示されなければ未インストール

# nc が未インストールの場合のみ実行
dnf install -y nmap-ncat

# systemd-resolved 設定用ディレクトリ作成（既存の場合はスキップ）
mkdir -p /etc/systemd/resolved.conf.d

# 既存設定確認
ls /etc/systemd/resolved.conf.d/ex-local.conf 2>/dev/null && echo "既に設定済み" || echo "未設定．次のステップを実施"

# 未設定の場合のみ実施：内部DNSを参照する設定ファイルを作成
vi /etc/systemd/resolved.conf.d/ex-local.conf
```

設定ファイルの記述内容（未設定の場合のみ）：

```
[Resolve]
DNS=<Primary DNSのIP> <Secondary DNSのIP>
```

```bash
# 新規作成した場合のみ実施：systemd-resolved を再起動
systemctl restart systemd-resolved

# 名前解決確認（共通実施）
resolvectl status | grep -A 2 "Current DNS"
```

> **期待する結果：** `Current DNS Server: <Primary DNSのIP>` が表示される．

> **注意：** 本ステップは `nsd-private-redundancy.md` で内部DNSが構築されていることが前提．未構築の場合は名前解決確認はスキップして次のStepに進む．

------------------------------

### Step 2：Zabbix 7.0 リポジトリ追加【実施対象：監視対象サーバー】

**目的：** Zabbix公式リポジトリをAmazon Linux 2023に登録する

#### 操作手順

```bash
rpm -Uvh https://repo.zabbix.com/zabbix/7.0/amazonlinux/2023/x86_64/zabbix-release-latest-7.0.amzn2023.noarch.rpm
```

> **補足：** `rpm -Uvh` の `-U` はアップグレード（無ければインストール）フラグ．既にリポジトリ登録済みの場合はエラーになるが続行可能．

------------------------------

### Step 3：zabbix-agent2 インストール【実施対象：監視対象サーバー】

**目的：** Zabbix Agent2本体をインストールする

#### 操作手順

```bash
dnf install -y zabbix-agent2
```

#### 追加プラグイン（サーバー種別に応じて任意）

| サーバー種別 | 追加コマンド | 説明 |
|---|---|---|
| DBサーバー（PostgreSQL） | `dnf install -y zabbix-agent2-plugin-postgresql` | PostgreSQL内部を監視する場合 |
| MongoDBサーバー | `dnf install -y zabbix-agent2-plugin-mongodb` | MongoDBを監視する場合 |
| SQL Serverサーバー | `dnf install -y zabbix-agent2-plugin-mssql` | SQL Serverを監視する場合 |

> **注意：** プロセス死活・リソース監視（CPU／メモリ等）は **プラグイン不要** ．`zabbix-agent2` 本体のみで監視可能．

------------------------------

### Step 4：zabbix_agent2.conf 設定【実施対象：監視対象サーバー】

**目的：** エージェント設定ファイルを編集し，Zabbixサーバーとの接続情報を設定する

#### 操作手順

```bash
# バックアップ作成
cp -p /etc/zabbix/zabbix_agent2.conf /etc/zabbix/zabbix_agent2.conf.org

# 編集
vi /etc/zabbix/zabbix_agent2.conf
```

設定ファイルの記述内容（既存のコメントアウト行を以下に置き換え）：

```
Server=<ZabbixサーバーのプライベートIP>
ServerActive=<ZabbixサーバーのプライベートIP>
Hostname=<エージェントのホスト名>
```

各設定の説明：

| 設定 | 説明 |
|------|------|
| `Server` | Passiveチェックの接続元（Zabbixサーバーの IP）を指定 |
| `ServerActive` | Activeチェックの送信先（通常は`Server`と同じ値） |
| `Hostname` | このエージェントを識別する名前．**Web GUIのホスト登録名と必ず一致させること** |

------------------------------

### Step 5：zabbix-agent2 起動・自動起動設定【実施対象：監視対象サーバー】

**目的：** zabbix-agent2を起動し，自動起動を有効化する

#### 操作手順

```bash
systemctl enable --now zabbix-agent2
systemctl status zabbix-agent2 --no-pager
```

> **期待する結果：** `Active: active (running)` および `enabled` が表示される．

------------------------------

### Step 6：ホスト登録【実施対象：Zabbixサーバー（Web GUI）】

Zabbix Web GUI上で対象ホストを登録する．**自動登録（A）** または **手動登録（B）** のいずれかを選択する．

------------------------------

#### Step 6-A：自動登録（推奨）

> **前提：** Zabbixサーバー側で「自動登録アクション」が設定済みであること（別手順書`05_Zabbix_テンプレート自動追加設定手順書.md` を参照）．

監視対象サーバー側で以下を実行：

```bash
systemctl restart zabbix-agent2
tail -f /var/log/zabbix/zabbix_agent2.log
```

> **期待する結果：** 「`active checks on server are active again`」のログが出れば成功．

> **補足：** Zabbixサーバー側で自動登録アクションが動作し，対象ホストが Web GUI に自動的に追加され，事前定義されたテンプレートが割り当てられる．

------------------------------

#### Step 6-B：手動登録

Zabbixサーバー側のWeb GUI（踏み台経由のポートフォワーディング）で以下を実施：

```
1. http://localhost:8080/zabbix にログイン
2. データ収集 → ホスト → 右上「ホストの作成」をクリック
3. 以下を入力：
     - ホスト名         ：<エージェントのホスト名>
     - インターフェース ：タイプ=エージェント／IP=<監視対象サーバーのプライベートIP>／ポート=10050
4. テンプレートタブ → 「Linux by Zabbix agent」を追加
5. 「追加」をクリックして保存
```

> **重要：** ホスト名（GUI上）は，監視対象サーバーの`zabbix_agent2.conf`の`Hostname`と **完全一致** すること．大文字小文字も区別される．

> **確認：** 数分以内に対象ホストのZBXアイコンが緑になれば成功．

------------------------------

### Step 7：テンプレート割り当て【実施対象：Zabbixサーバー（Web GUI）】

サーバー種別に応じてテンプレートを追加割り当てする．

#### サーバー種別ごとの推奨テンプレート

| サーバー種別 | 推奨テンプレート | 備考 |
|---|---|---|
| 全サーバー共通 | `Linux by Zabbix agent` | 自動登録時は自動適用 |
| DBサーバー（PostgreSQL） | `PostgreSQL by Zabbix agent 2` | プラグイン併用 |
| Zabbixサーバー自身 | `Zabbix server health` | Zabbix本体監視 |

#### 操作手順（Web GUI）

```
データ収集 → ホスト → 対象ホストを選択
→ テンプレートタブ → 「リンク」欄でテンプレートを検索・追加
→ 「更新」をクリック
```

> **期待する結果：** ホスト一覧の「テンプレート」列に割当てたテンプレートが表示される．

------------------------------

## 5. 動作確認・検証

> 構築完了後，以下の確認をすべてパスしたら構築成功とみなす．

### 5-1. 確認チェックリスト

- [ ] **確認①**：`zabbix-agent2` が `active (running)` かつ自動起動有効
- [ ] **確認②**：10050番ポートがLISTENしている
- [ ] **確認③**：Web GUI 上で対象ホストの ZBX アイコンが緑
- [ ] **確認④**：Zabbixサーバー側から `zabbix_get` で値が取得できる
- [ ] **確認⑤**：最新データが収集されている（アイテム数 77 前後）

------------------------------

### 確認①:サービス状態確認【実施対象：監視対象サーバー】

```bash
systemctl status zabbix-agent2 --no-pager
systemctl is-enabled zabbix-agent2
```

> **期待する結果：** `active (running)` および `enabled`．

------------------------------

### 確認②:リッスンポート確認【実施対象：監視対象サーバー】

```bash
ss -tlnp | grep :10050
```

> **期待する結果：** `0.0.0.0:10050` でzabbix_agent2プロセスがLISTENしている．

------------------------------

### 確認③:Web GUI 上のZBXアイコン確認【実施対象：Zabbixサーバー（Web GUI）】

```
データ収集 → ホスト → 対象ホストを検索
→ Availability列のZBXアイコンが緑になっていること
```

------------------------------

### 確認④:Zabbixサーバーからのzabbix_get接続テスト【実施対象：Zabbixサーバー】

Zabbixサーバー側で以下を実行：

```bash
# zabbix_get を未インストールの場合
dnf install -y zabbix-get

# 接続テスト
zabbix_get -s <監視対象サーバーのプライベートIP> -p 10050 -k agent.ping
```

> **期待する結果：** `1` が返る（agent.pingが成功）．

> **補足：** 戻り値の `1` は「成功」を意味するZabbixの内部仕様．

------------------------------

### 確認⑤:最新データの収集確認【実施対象：Zabbixサーバー（Web GUI）】

```
データ収集 → ホスト → 対象ホストの「最新データ」をクリック
→ 各アイテムに値が表示されていること
```

> **補足：** 「Linux by Zabbix agent」テンプレートでは約77個のアイテムが収集される．

------------------------------

### 5-2. ログ確認

```bash
tail -n 50 /var/log/zabbix/zabbix_agent2.log
```

> **注意：** `Error` や `Failed` といったログが頻発していないか確認．

------------------------------

## 6. トラブルシューティング

### よくあるエラーと対処法

------------------------------

#### エラー①：ZBXアイコンが赤い

**原因：** Zabbixサーバーから10050番への接続不可．SG／プロセス停止／Hostname不一致．

**対処法：**

```bash
# 監視対象サーバー側
ss -tlnp | grep 10050
grep "^Hostname=" /etc/zabbix/zabbix_agent2.conf

# Zabbixサーバー側
dnf install -y zabbix-get
zabbix_get -s <監視対象サーバーのプライベートIP> -p 10050 -k agent.ping
```

それぞれの結果に応じて対処：
- LISTENしていない → サービス再起動
- Hostname不一致 → `zabbix_agent2.conf` 修正後 `systemctl restart`
- `zabbix_get` でtimeout → SG確認

------------------------------

#### エラー②：ZBXアイコンが灰色のまま

**原因：** テンプレート未適用，もしくはHostname不一致でデータが取り込まれていない．

**対処法：**

```bash
tail -20 /var/log/zabbix/zabbix_agent2.log
# → "host [XXX] not found" が出る場合はHostname不一致

grep "^Hostname=" /etc/zabbix/zabbix_agent2.conf
# 値を確認しWeb GUIのホスト名と一致させる
systemctl restart zabbix-agent2
```

------------------------------

#### エラー③：Web GUI にホストが表示されない

**原因：** Status が「Disabled」になっている，もしくは検索条件のミス．

**対処法：**

```
データ収集 → ホスト → 対象ホストを検索
→ Status が「Disabled」の場合は「Enabled」に変更
→ ホスト名が zabbix_agent2.conf の Hostname と一致しているか確認
```

------------------------------

#### エラー④：`tail -f /var/log/zabbix/zabbix_agent2.log` でログが流れない

**原因：** ログレベルが低い，もしくはログファイルパスが異なる．

**対処法：**

```bash
# 設定ファイルでログファイルパス確認
grep "^LogFile=" /etc/zabbix/zabbix_agent2.conf
# → /var/log/zabbix/zabbix_agent2.log であること

# DebugLevelを一時的に上げる場合
sed -i 's/^# DebugLevel=3/DebugLevel=4/' /etc/zabbix/zabbix_agent2.conf
systemctl restart zabbix-agent2
```

> **注意：** デバッグレベル変更後は，問題解決後に必ず戻すこと（ログ肥大化防止）．

------------------------------

### ログの確認場所

| ログの種類 | 場所（パス） |
|-----------|------------|
| Zabbix Agent2 ログ | `/var/log/zabbix/zabbix_agent2.log` |
| systemd ログ | `journalctl -u zabbix-agent2` |

------------------------------

## 7. 参考リソース・関連資料

| 資料名 | URL / 場所 | 補足 |
|-------|-----------|------|
| Zabbix 7.0 公式ドキュメント | https://www.zabbix.com/documentation/7.0/jp/manual | Zabbix全般 |
| Zabbix Agent2 公式 | https://www.zabbix.com/documentation/7.0/jp/manual/concepts/agent2 | Agent2の仕様 |
| 自動登録の仕様 | https://www.zabbix.com/documentation/7.0/jp/manual/discovery/auto_registration | 自動登録動作 |
| 別手順書：Zabbixサーバー構築 | `zabbix-server.md` | サーバー側の構築（前提手順） |
| 別手順書：Zabbix用DB構築 | `zabbix-db-postgresql.md` | DB側の構築 |

------------------------------

## 8. ロールバック手順

### 8-1. zabbix-agent2 の停止と無効化【実施対象：監視対象サーバー】

```bash
systemctl disable --now zabbix-agent2
```

### 8-2. Web GUI からのホスト削除【実施対象：Zabbixサーバー（Web GUI）】

```
データ収集 → ホスト → 対象ホストにチェック
→ 「削除」をクリック → 確認ダイアログで「削除」
```

> **注意：** ホストを削除すると過去の監視データも削除される．保持したい場合はホスト Status を「Disabled」にする運用を検討．

### 8-3. パッケージのアンインストール【実施対象：監視対象サーバー】

```bash
# プラグインを入れた場合は先に削除
dnf remove -y zabbix-agent2-plugin-postgresql 2>/dev/null
dnf remove -y zabbix-agent2-plugin-mongodb 2>/dev/null
dnf remove -y zabbix-agent2-plugin-mssql 2>/dev/null

# Agent2本体
dnf remove -y zabbix-agent2
```

### 8-4. 設定ファイルの削除（任意）【実施対象：監視対象サーバー】

```bash
rm -rf /etc/zabbix /var/log/zabbix
```

### 8-5. リポジトリ登録の削除【実施対象：監視対象サーバー】

```bash
rpm -e zabbix-release
```

### 8-6. systemd-resolvedのDNS設定削除（任意）【実施対象：監視対象サーバー】

> **重要：** 本サーバーで他のMW（Tomcat／PostgreSQL／Nginx等）も稼働している場合は，このStepはスキップすること．DNS設定を削除すると他のMWの名前解決に影響する．**zabbix-agent2 のみが稼働している監視対象サーバーで，本手順書の Step 1 で初めてDNS設定した場合のみ実施する**．

```bash
# 他MWが稼働していない監視対象サーバーの場合のみ
rm -f /etc/systemd/resolved.conf.d/ex-local.conf
systemctl restart systemd-resolved
```

### 8-7. 完了確認【実施対象：監視対象サーバー】

```bash
systemctl status zabbix-agent2 2>&1 | head -3
# → Unit zabbix-agent2.service could not be found.

rpm -qa | grep zabbix
# → 何も表示されないこと
```

> **注意：** `dnf update` で適用したパッケージ更新は取り消さない（依存破壊リスク回避）．

------------------------------

## 付録

### A. コマンド解説

| コマンド | 説明 |
|---------|------|
| `dnf install -y <パッケージ>` | dnfからパッケージを非対話インストール． |
| `dnf remove -y <パッケージ>` | dnfからパッケージを非対話アンインストール． |
| `rpm -Uvh <RPM URL>` | RPMパッケージをURLから取得しインストール／アップグレード． |
| `rpm -e <パッケージ>` | RPMパッケージを削除． |
| `rpm -qa \| grep <名前>` | インストール済みパッケージを名前で検索． |
| `systemctl enable --now <サービス>` | サービスを起動し，自動起動を有効化． |
| `systemctl is-enabled <サービス>` | 自動起動有効／無効の確認． |
| `systemctl restart <サービス>` | サービスを再起動（設定変更の反映）． |
| `ss -tlnp` | TCPでLISTEN中のポートとプロセスを一覧表示． |
| `zabbix_get -s <IP> -p <ポート> -k <キー>` | Zabbixサーバー側からエージェントへ値を問い合わせ． |
| `tail -f <ログファイル>` | ログをリアルタイム追尾．`Ctrl+C` で終了． |
| `journalctl -u <サービス>` | systemdログを表示． |
| `timedatectl set-timezone <TZ>` | システムのタイムゾーンを設定． |

------------------------------

### B. 設定ファイル解説

**`/etc/zabbix/zabbix_agent2.conf`（監視対象サーバー）**

```
Server=<ZabbixサーバーのプライベートIP>
```

- `Server`：Passiveチェック時の接続元として許可するIP．カンマ区切りで複数指定可．
- 指定外のIPからの接続は拒否される．

```
ServerActive=<ZabbixサーバーのプライベートIP>
```

- `ServerActive`：Activeチェックでメトリクスを送信する先．通常`Server`と同じ値．
- `<IP>:10051` のようにポートを指定可（省略時は10051）．

```
Hostname=<エージェントのホスト名>
```

- `Hostname`：このエージェントを識別する名前．
- **Web GUIのホスト登録名と完全一致必須**．大文字小文字も区別される．
- 不一致だとActiveチェックが機能せず，ZBXアイコンが灰色のまま．

その他の主要ディレクティブ：

| ディレクティブ | デフォルト | 説明 |
|---|---|---|
| `LogFile` | `/var/log/zabbix/zabbix_agent2.log` | ログファイルパス |
| `LogFileSize` | 1 | ログローテーションのサイズ（MB） |
| `DebugLevel` | 3 | ログレベル（0〜5）．本番は3で十分．デバッグ時のみ4〜5に上げる |
| `RefreshActiveChecks` | 5 | Activeチェック設定の更新間隔（秒） |
| `BufferSend` | 5 | 値の送信間隔（秒） |
| `Timeout` | 3 | エージェントの処理タイムアウト（秒） |
| `Include` | `/etc/zabbix/zabbix_agent2.d/*.conf` | 追加設定の読み込みディレクトリ |

------------------------------

### C. 用語解説

| 用語 | 説明 |
|------|------|
| Zabbix Agent2 | Zabbix Agentの後継．Go言語で実装され，プラグイン機構を持つ次世代エージェント． |
| Zabbix Agent（旧Agent） | C言語実装の従来エージェント．Zabbix 7.0以降は新規導入はAgent2が推奨． |
| Passiveチェック | Zabbixサーバー → エージェント方向の問い合わせ．エージェントが10050でLISTEN． |
| Activeチェック | エージェント → Zabbixサーバー方向の送信．サーバーが10051でLISTEN． |
| プラグイン | Agent2固有の機能拡張．PostgreSQL／MongoDB／MSSQL等の専用監視を提供． |
| ホスト | Zabbix上で監視対象を表す論理単位．Hostname と対応． |
| テンプレート | アイテム・トリガー・グラフ等をまとめて再利用可能にする定義集． |
| 自動登録 | エージェントが起動時にZabbixサーバーへ自己紹介し，所定のアクションでホスト登録・テンプレート割当が自動で行われる仕組み． |
| 手動登録 | Web GUIで管理者が手動で対象ホストを登録する方法． |
| ZBXアイコン | Web GUI上でAgent接続状態を示すアイコン．緑=正常／赤=接続不可／灰色=未試行． |
| Hostname | エージェント設定の識別子．Web GUI上のホスト名と一致必須． |
| HostMetadata | 自動登録時にエージェントが送信する追加情報．サーバー種別の判別に利用可能． |

------------------------------

### D. 補足解説

#### D-1. なぜAgent2なのか（旧Agentとの違い）

- **実装言語**：旧AgentはC言語．Agent2はGo言語．
- **プラグイン機構**：Agent2は外部プラグインによる拡張に対応．PostgreSQL／MongoDB／MSSQLなど専用監視が容易．
- **並列処理**：Agent2はGoのgoroutineで並列処理に強い．多数のメトリクスを高速に収集．
- **互換性**：Agent2は旧Agentと同じプロトコルで通信．サーバー側設定は共通．

#### D-2. 自動登録 vs 手動登録の選択基準

| 観点 | 自動登録 | 手動登録 |
|------|---------|---------|
| 大量サーバー対応 | ◎ | △ |
| 細かい制御 | △ | ◎ |
| 初期設定の手間 | サーバー側に1回 | ホスト毎に必要 |
| ホスト名の規則性 | 厳密ルールが必要 | 任意 |
| 推奨ケース | 数十台以上の同種サーバー群 | 数台の特殊サーバー |

#### D-3. Hostname と GUIホスト名の一致重要性

- Active接続時，エージェントは自分の `Hostname` をサーバーへ送信．
- サーバーは送られてきた `Hostname` でGUI上のホストを検索し，マッチしたホストにメトリクスを紐付ける．
- 不一致だとActiveチェックが全て破棄され，ZBXアイコンが灰色のまま．
- 大文字小文字も区別される（例：`Web01` と `web01` は別物扱い）．

#### D-4. ZBXアイコンの色の意味（再掲）

- **緑**：エージェントへの接続成功，正常監視中．
- **赤**：接続失敗（エージェント停止／ネットワーク／SG／Hostname不一致 等）．
- **灰色**：まだ接続試行されていない（設定変更直後の一時的状態）．

#### D-5. プラグインによる拡張

- Agent2のプラグインは内部組み込み（dnfで個別パッケージ）．
- PostgreSQL監視例：`zabbix-agent2-plugin-postgresql` を追加 → DBの内部統計（接続数，クエリ実行状況等）を取得可能に．
- プラグインを使うとPostgreSQLにZabbix監視用ユーザーが必要．設定詳細はZabbix公式ドキュメント参照．

#### D-6. データ保持とディスク容量

- デフォルトでは生データ90日，トレンドデータ365日保持．
- 監視対象が増えるとDBサイズが急速に増える．
- 不要なホストは「Status: Disabled」または削除で対処．

#### D-7. 複数台への一括実行スクリプト（任意）

監視対象が多数ある場合，踏み台サーバー上で以下のスクリプトを使って一括展開できる．

```bash
# 踏み台サーバー上で実行
# 対象サーバーのIPリストとスクリプト名を定義
SERVERS=(
    "<監視対象サーバー1のIP>"
    "<監視対象サーバー2のIP>"
    "<監視対象サーバー3のIP>"
)

SCRIPTS=(
    "agent_setup_1.sh"
    "agent_setup_2.sh"
    "agent_setup_3.sh"
)

for i in "${!SERVERS[@]}"; do
    IP="${SERVERS[$i]}"
    SCRIPT="${SCRIPTS[$i]}"
    echo "=== ${IP} に ${SCRIPT} を実行中 ==="
    scp "${SCRIPT}" ec2-user@"${IP}":~/
    ssh ec2-user@"${IP}" "sudo bash ~/${SCRIPT}"
done
```

各スクリプトには，本手順書のStep 1〜5の内容を記述する．`Hostname` を各サーバーごとに変える必要があるため，スクリプトを個別に用意するか，引数化する．

> **注意：** スクリプト方式は構築失敗時の切り分けが難しい．**最初の1〜2台は手動で確認しながら構築すること**を推奨．

#### D-8. `dnf update` と `dnf upgrade` の違い

- DNFベースのAmazon Linux 2023では両者は同義．本手順書では `dnf update -y` に統一．
