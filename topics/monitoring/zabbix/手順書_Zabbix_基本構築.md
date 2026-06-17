# 【Zabbix を用いた監視サーバ構築】環境構築手順書

---

## 1. ドキュメント情報

| 項目 | 内容 |
|------|------|
| 手順書名 | Zabbix を用いた監視サーバ構築 |
| 作成日 | 2026-06-16 |
| 最終更新日 | 2026-06-16 |
| バージョン | v1.2 |
| 対象環境 | AWS |

> **改訂履歴**
>
> | バージョン | 日付 | 変更内容 |
> |-----------|------|---------|
> | v1.0 | 2026-05-06 | 初版作成 |
> | v1.1 | 2026-05-07 | 内容変更 |
> | v1.2 | 2026-06-16 | テンプレート構成に再構成、Step整理、誤記訂正 |

---

## 2. 目的・概要

### 2-1. 目的

> 本手順書では、AWS上にZabbixサーバとZabbixエージェントを構築する。
> 構築後は監視対象であるZabbixエージェントに対して、リソース監視・通知・自動復旧・ダッシュボード作成などの一連の運用を行える状態を目指す。

### 2-2. 構成概要(アーキテクチャ)

```
                            [ローカルPC ブラウザ]
                                    |
                                    | HTTP (80)
                                    v
[Zabbixサーバ EC2]                                    [Zabbixエージェント EC2]
  ├─ Apache + PHP (WebUI)         <-- 10050 -->         ├─ zabbix-agent2
  ├─ Zabbix Server                                       └─ (監視対象のMW)
  ├─ MariaDB                       <-- 10051 --
  └─ Postfix (通知メール用)
```

- **Zabbixサーバ**: WebUI・データベース・通知メール送信・監視対象の管理
- **Zabbixエージェント**: 監視対象EC2上で動作し、各種データをZabbixサーバへ送信

### 2-3. 完成イメージ(ゴール定義)

- [ ] `http://<ZabbixサーバのグローバルIP>/zabbix` でZabbixのログイン画面が表示される
- [ ] ZabbixサーバのWebUIでZabbixエージェントの監視ができる
- [ ] 自分で決めたトリガー(閾値)を超えた際、自身のOutlook宛にメール通知が届く
- [ ] MariaDBのプロセス数監視・自動復旧・ダッシュボード・Web監視・テンプレートが構築できる

---

## 3. 前提条件・準備

### 3-1. 環境要件

| 項目 | 要件 |
|------|------|
| OS | Amazon Linux 2023 |
| インスタンスタイプ | t3.micro |
| インスタンス台数 | 2台(Zabbixサーバ、Zabbixエージェント) |
| Zabbix バージョン | 7.0 LTS |

### 3-2. セキュリティグループ設定

#### 3-2-1. Zabbixサーバ

| タイプ | プロトコル | ポート範囲 | ソース | 説明 |
|--------|-----------|-----------|--------|------|
| SSH | TCP | 22 | マイIP | ローカルPCからSSH接続 |
| HTTP | TCP | 80 | マイIP | ローカルPCからWebUIに接続 |
| カスタムTCP | TCP | 10051 | ZabbixエージェントのプライベートIP | エージェントからのアクティブチェック受信 |

#### 3-2-2. Zabbixエージェント

| タイプ | プロトコル | ポート範囲 | ソース | 説明 |
|--------|-----------|-----------|--------|------|
| SSH | TCP | 22 | マイIP | ローカルPCからSSH接続 |
| カスタムTCP | TCP | 10050 | ZabbixサーバのプライベートIP | Zabbixサーバからのパッシブチェック受信 |

### 3-3. 必要パッケージ・リンク一覧

#### 3-3-1. Zabbixサーバ

| 項目名 | 目的 |
|-------|------|
| zabbix-server-mysql | MySQL/MariaDBをデータベースとして使うZabbixサーバ本体 |
| zabbix-web-mysql | ブラウザから操作する管理画面(PHP製)のパッケージ |
| zabbix-apache-conf | Apache(Webサーバ)用の設定ファイル |
| zabbix-sql-scripts | 初期データベース作成用のSQLスクリプト |
| zabbix-get | CLI上でデータ取得のテストを行うためのユーティリティ |
| mariadb105-server | データベース |
| curl / libcurl | フル機能版(SMTP通知に必要) |
| Zabbix公式リポジトリ | https://repo.zabbix.com/zabbix/7.0/amazonlinux/2023/x86_64/zabbix-release-latest-7.0.amzn2023.noarch.rpm |

#### 3-3-2. Zabbixエージェント

| 項目名 | 目的 |
|-------|------|
| zabbix-agent2 | 監視対象のデータを収集するエージェント |
| zabbix-get | CLI上でデータ取得のテストを行うためのユーティリティ |
| mariadb105-server | 監視データ用のMariaDB(Step 7で使用) |
| stress-ng | Linuxシステムのリソースに意図的な負荷をかけるテストツール |
| Zabbix公式リポジトリ | https://repo.zabbix.com/zabbix/7.0/amazonlinux/2023/x86_64/zabbix-release-latest-7.0.amzn2023.noarch.rpm |

---

## 4. 構築手順(詳細)

> **注意事項**
> - コマンド中の `<山カッコ>` は自分の環境の値に置き換えること
> - `<任意の名前>` は、自分や他のメンバーと区別できるように決めること

---

### Step 1: Zabbixサーバの構築

**目的:** Zabbixサーバ側にApache、PHP、MariaDB、Zabbix本体をインストールして起動する。**Zabbixサーバ側で実施**する。

#### 操作手順

```bash
# ローカルPCからSSHログイン
ssh -i <秘密鍵のファイルパス> ec2-user@<EC2のパブリックIP>

# rootユーザーにスイッチ
sudo su -

# 時刻設定をJSTに変更
timedatectl set-timezone Asia/Tokyo

# 全パッケージを最新バージョンに更新
dnf update -y

# Zabbix公式リポジトリのインストール
rpm -Uvh https://repo.zabbix.com/zabbix/7.0/amazonlinux/2023/x86_64/zabbix-release-latest-7.0.amzn2023.noarch.rpm

# dnfのキャッシュクリア
dnf clean all

# 必要パッケージの一括インストール
dnf install -y zabbix-server-mysql zabbix-web-mysql zabbix-apache-conf zabbix-sql-scripts zabbix-get mariadb105-server

# MariaDBの起動と自動起動設定
systemctl enable --now mariadb

# MariaDBの起動確認
systemctl status mariadb | less

# MariaDBの自動起動設定確認
systemctl is-enabled mariadb

# MariaDBのセキュリティ強化
mysql_secure_installation
```

対話形式の質問への回答:

```
1. rootパスの入力、デフォルトは設定されていないためエンターキー
   Enter current password for root (enter for none): Enter
2. unix_socket認証に変更するか
   Switch to unix_socket authentication [Y/n] Y
3. rootパスワードを変更するか
   Change the root password? [Y/n] Y
4. 匿名ユーザを削除するか
   Remove anonymous users? [Y/n] Y
5. リモートrootログインを無効にするか
   Disallow root login remotely? [Y/n] Y
6. テストDBを削除するか
   Remove test database and access to it? [Y/n] Y
7. 権限テーブルを再読み込みするか
   Reload privilege tables now? [Y/n] Y
```

```bash
# rootユーザーでMariaDBにログイン
mysql -u root -p
```

```sql
-- データベースの作成
CREATE DATABASE zabbix CHARACTER SET utf8mb4 COLLATE utf8mb4_bin;
-- ユーザー作成
CREATE USER 'zabbix'@'localhost' IDENTIFIED BY 'zabbix';
-- データベースに対する全権限をユーザーに付与
GRANT ALL PRIVILEGES ON zabbix.* TO 'zabbix'@'localhost';
-- Zabbix初期スキーマインポート時のエラー回避のための設定変更
SET GLOBAL log_bin_trust_function_creators = 1;
-- 設定を反映
FLUSH PRIVILEGES;
-- ログアウト
EXIT;
```

```bash
# Zabbix初期スキーマのインポート
zcat /usr/share/zabbix-sql-scripts/mysql/server.sql.gz | mysql --default-character-set=utf8mb4 -uzabbix -pzabbix zabbix
# → 何も表示されずにプロンプトに戻れば成功

# 初期スキーマインポート用の設定を元に戻す
mysql -u root -p -e "SET GLOBAL log_bin_trust_function_creators = 0;"

# Zabbixサーバ設定ファイルのバックアップ取得
cp /etc/zabbix/zabbix_server.conf{,.org}

# Zabbixサーバ設定ファイルの編集(DB接続情報を設定)
vi /etc/zabbix/zabbix_server.conf
```

設定ファイルの編集内容:

```
DBHost=localhost
DBName=zabbix
DBUser=zabbix
DBPassword=zabbix
```

```bash
# サービスの起動と自動起動設定
systemctl enable --now zabbix-server httpd php-fpm mariadb

# サービスの起動確認
systemctl status zabbix-server httpd php-fpm mariadb | less

# サービスの自動起動設定確認
systemctl is-enabled zabbix-server httpd php-fpm mariadb
```

**確認:** ローカルPCのブラウザで `http://<ZabbixサーバのグローバルIP>/zabbix` にアクセスする。

- 初期設定画面が表示されたら、DBパスワードに `zabbix` を入力(Zabbixサーバ設定ファイルで設定したパスワード)
- Zabbixサーバ名は任意の名前
- 初期設定完了後、以下でログイン
  - ユーザー名: `Admin`
  - パスワード: `zabbix`

---

### Step 2: Zabbixエージェントの構築

**目的:** 監視対象のEC2にZabbixエージェントをインストールし、Zabbixサーバと接続できるようにする。**Zabbixエージェント側で実施**する。

#### 操作手順

```bash
# ローカルPCからSSHログイン
ssh -i <秘密鍵のファイルパス> ec2-user@<EC2のパブリックIP>

# rootユーザーにスイッチ
sudo su -

# 時刻設定をJSTに変更
timedatectl set-timezone Asia/Tokyo

# 全パッケージを最新バージョンに更新
dnf update -y

# Zabbix公式リポジトリのインストール
rpm -Uvh https://repo.zabbix.com/zabbix/7.0/amazonlinux/2023/x86_64/zabbix-release-latest-7.0.amzn2023.noarch.rpm

# dnfのキャッシュクリア
dnf clean all

# 必要パッケージの一括インストール
dnf install -y zabbix-agent2 zabbix-get

# Zabbixエージェント設定ファイルのバックアップ取得
cp /etc/zabbix/zabbix_agent2.conf{,.org}

# Zabbixエージェント設定ファイルの編集
vi /etc/zabbix/zabbix_agent2.conf
```

設定ファイルの編集内容:

```
# ---下記を追記/変更---
Server = <ZabbixサーバのプライベートIP>
ServerActive = <ZabbixサーバのプライベートIP>
Hostname = <ZabbixサーバのGUIで表示するZabbixエージェントの名前(任意の名前)>
# ---------------------
```

```bash
# Zabbixエージェントの起動と自動起動設定
systemctl enable --now zabbix-agent2

# 起動確認
systemctl status zabbix-agent2 | less

# 自動起動設定確認
systemctl is-enabled zabbix-agent2
```

---

### Step 3: WebUIでのホスト追加

**目的:** ZabbixサーバのWebUIから監視対象(Zabbixエージェント)をホストとして追加する。

#### 操作手順(WebUI操作)

`監視データ → ホスト → ホストの作成`

| 項目 | 設定値 |
|------|--------|
| ホスト名 | エージェント設定の `Hostname` と**完全一致** |
| テンプレート | 選択 → 選択 → `Templates` → `Linux by Zabbix agent` |
| ホストグループ | 選択 → `Zabbix servers` |
| インターフェース | 追加 → エージェント |
| ├ IPアドレス | ZabbixエージェントのプライベートIP |
| ├ DNS名 | 空欄 |
| ├ 接続方法 | IP |
| └ ポート | 10050 |
| 説明 | 空欄(監視対象に対する説明) |
| 監視するもの | サーバー |
| 有効 | チェックを入れる |

「追加」をクリック。

---

### Step 4: グラフでの監視確認

**目的:** Zabbixエージェントから取得したデータがグラフで確認できることを確認する。

#### 操作手順(WebUI操作)

`監視データ → 最新データ`

| 項目 | 設定値 |
|------|--------|
| ホスト | 選択 → ホストグループの検索欄横の選択 → `Zabbix servers` → 作成したホストを選択 |
| 名前欄 | `CPU utilization` |

「適用」をクリック。

下に表示されるホストの左側にチェックを入れて「グラフ表示」を選択。

---

### Step 5: CPU負荷テスト

**目的:** Step 4のグラフを確認するため、Zabbixエージェント側でCPUに意図的な負荷をかける。

#### 操作手順

```bash
# stress-ngをインストール
dnf install -y stress-ng

# 全CPUに対して2分間負荷をかける
stress-ng --cpu 0 --timeout 2m
```

WebUIで `監視データ → 最新データ` のグラフが上昇することを確認する。

---

### Step 6: メール通知の設定

**目的:** トリガー(閾値)を超えた際に、自身のOutlook宛にメール通知が届くように設定する。
本Stepでは「CPU使用率が80%を超えた時にメール通知する」設定を行う。

具体的な設定は以下の5つ:
1. ZabbixサーバのSMTP設定
2. メディアタイプの作成
3. ユーザーの追加
4. トリガーの作成
5. アクションの作成

#### 6-1. ZabbixサーバのSMTP設定

Amazon Linux 2023では `curl-minimal` と `libcurl-minimal` が標準のため、この状態ではメール転送のSMTPプロトコルが入っていない。よって、これらのパッケージをフル機能版に入れ替える。

```bash
# パッケージの入れ替え
dnf swap curl-minimal curl
dnf swap libcurl-minimal libcurl

# Zabbixサーバの再起動
systemctl restart zabbix-server
```

#### 6-2. メディアタイプの作成

`通知 → メディアタイプ → メディアタイプの作成`

| タブ | 項目 | 設定値 |
|------|------|--------|
| メディアタイプタブ | 名前 | `outlook`(任意の名前) |
| | タイプ | メール |
| | メールプロバイダ | Generic SMTP |
| | SMTPサーバー | `localhost` (Zabbixサーバ側にPostfixをインストール・起動させておく) |
| | SMTPサーバーポート番号 | 25 |
| | メール | 任意のメールアドレス |
| | SMTP helo | メールの `@` 以降 |
| | 接続セキュリティ | なし |
| | 認証 | なし |
| | メッセージフォーマット | HTML |
| | 説明 | 空欄 |
| | 有効 | チェックを入れる |
| メッセージテンプレートタブ | 追加 | メッセージタイプ:障害、件名・メッセージはそのまま |

「追加」をクリック。

**確認:** 追加したメディアタイプの右の「テスト」をクリックし、送信先に自身のメールアドレスを入力。テストをクリックし、メールが届くか確認。

#### 6-3. ユーザーの追加(メディア紐付け)

`ユーザー → ユーザー → Admin`

| タブ | 項目 | 設定値 |
|------|------|--------|
| メディアタブ | タイプ | 作成したメディアタイプを選択 |
| | 送信先 | 自身のメールアドレス |
| | 有効な時間帯 | そのまま |
| | 指定した深刻度のときに使用 | そのまま |
| | 有効 | チェックを入れる |

「追加」→「更新」をクリック。

#### 6-4. トリガーの作成

`データ収集 → ホスト → 作成したホストのトリガーをクリック → トリガーの作成`

| 項目 | 設定値 |
|------|--------|
| 名前 | CPU高負荷(任意の名前) |
| 深刻度 | 警告 |
| 条件式 | 追加 → アイテム:`CPU utilization`、結果:`> 80` → 挿入 |
| 有効 | チェックを入れる |

「追加」をクリック。

#### 6-5. アクションの作成

`通知 → アクション → トリガーアクション → アクションの作成`

| タブ | 項目 | 設定値 |
|------|------|--------|
| アクションタブ | 名前 | アクションの名前(任意の名前) |
| | 実行条件 | 追加 → タイプ:トリガー、オペレータ:等しい、トリガー発生元:ホスト、トリガー → 選択 → 作成したトリガーを選択 → 追加 |
| | 有効 | チェックを入れる |
| 実行内容タブ | 実行内容 | 追加 → ユーザーに送信:`Admin` を選択、それ以外はそのまま → 追加 |

「追加」をクリック。

**確認:** Step 5のCPU負荷をかけ、自身のOutlook宛にメールが届くことを確認する。

---

### Step 7: シェルスクリプトを使ったカスタム監視

**目的:** MariaDBのプロセス数をアイテムとして登録し、グラフで確認できるようにする。
プロセス数取得にはシェルスクリプトを用いる。

具体的な設定は以下の4つ:
1. ZabbixエージェントにMariaDBをインストール・起動
2. プロセス数を取得するシェルスクリプトの作成
3. Zabbixエージェント設定ファイルの編集
4. ZabbixサーバのWebUIでアイテムの作成

#### 7-1. MariaDBのインストールと起動

Zabbixエージェント側で実施:

```bash
# MariaDBをインストール
dnf install -y mariadb105-server

# MariaDBを起動
systemctl start mariadb
```

#### 7-2. プロセス数を取得するシェルスクリプトの作成

Zabbixエージェント側で実施:

```bash
# シェルスクリプトを保存するディレクトリを作成
mkdir /etc/zabbix/scripts/

# シェルスクリプトを作成
vi /etc/zabbix/scripts/<任意のファイル名>.sh
```

スクリプトの内容(どちらか一方):

```bash
pgrep -fc mariadb
# または
ps -ef | grep mariadb | grep -v grep | wc -l
```

```bash
# Zabbixエージェントのユーザーが実行できるように権限付与
chmod 744 /etc/zabbix/scripts/<任意のファイル名>.sh

# 所有ユーザーと所有グループを変更
chown zabbix:zabbix /etc/zabbix/scripts/<任意のファイル名>.sh
```

> **補足:** 一般的に自作シェルスクリプトはそのサービスの設定ディレクトリ配下に置くため、`/etc/zabbix/scripts/` の下に配置している。

#### 7-3. Zabbixエージェント設定ファイルの編集

Zabbixエージェント設定ファイルに、作成したシェルスクリプトを `UserParameter` として登録する。

```bash
# 設定ファイルのバックアップ取得(既にあれば不要)
cp /etc/zabbix/zabbix_agent2.conf{,.org}

# 設定ファイルの編集
vi /etc/zabbix/zabbix_agent2.conf
```

設定ファイルの編集内容:

```
# ---[UserParameter]セクションに以下を追記---
UserParameter=<キー名>,<シェルスクリプトのコマンドかフルパス>
# 例) UserParameter=check.db.ps,/etc/zabbix/scripts/check_db_ps.sh
# -----------------------------------------
```

```bash
# 設定を反映させるため再起動
systemctl restart zabbix-agent2
```

**確認:** Zabbixエージェント側のCLIで値が取得できるか確認する。

```bash
zabbix_agent2 -t <キー名>
# → <キー名>  [s|1] のように表示されれば成功
```

#### 7-4. ZabbixサーバのWebUIでアイテムの作成

`データ収集 → ホスト → Zabbixエージェントのアイテムをクリック → アイテムの作成`

| 項目 | 設定値 |
|------|--------|
| 名前 | 任意の名前 |
| タイプ | Zabbixエージェント |
| キー | Zabbixエージェント側で作成したキーと**完全一致** |
| データ型 | 数値(整数) ← グラフを表示させるため |
| 有効 | チェックを入れる |

「追加」をクリック。

グラフ表示:
`監視データ → 最新データ → 名前:作成したアイテムの名前 → 適用` → ホスト名にチェック → 「グラフ表示」をクリック。

---

### Step 8: 自動復旧アクションの設定

**目的:** MariaDBがダウンしたときに、自動でMariaDBを再起動するアクションを構築する。

具体的な設定は以下の5つ:
1. 監視用アイテムの作成(Step 7-4で作成済みのアイテムを流用)
2. ダウン検知トリガーの作成
3. Zabbixエージェントの設定変更
4. 自動復旧スクリプトの作成
5. 自動復旧アクションの作成

#### 8-1. 監視用アイテムの作成

Step 7-4で作成したアイテムを使用するので割愛。

#### 8-2. ダウン検知トリガーの作成

`データ収集 → ホスト → Zabbixエージェントのトリガーをクリック → トリガーの作成`

| 項目 | 設定値 |
|------|--------|
| 名前 | 任意の名前 |
| 深刻度 | 任意 |
| 条件式 | 追加 → アイテム:Step 7-4で作成したアイテムを選択、結果:`= 0` → 挿入 |
| 有効 | チェックを入れる |

「追加」をクリック。

#### 8-3. Zabbixエージェントの設定変更

監視対象のホストでトリガー発生時に、Zabbixエージェント上でコマンドやスクリプトを自動実行する **リモートコマンド** を、ZabbixユーザーがNOPASSWDで実行できるように設定する。

Zabbixエージェント側で実施:

```bash
# Zabbixエージェントの設定ファイルに追記
vi /etc/zabbix/zabbix_agent2.conf
```

設定ファイルの編集内容:

```
# ---[AllowKey]セクションに以下を追記---
AllowKey=system.run[*]
# -------------------------------------
```

```bash
# ZabbixユーザーがNOPASSWDでsudoできるように設定
vi /etc/sudoers.d/zabbix
```

設定ファイルの編集内容:

```
zabbix ALL=(ALL) NOPASSWD: /usr/bin/systemctl restart mariadb
```

```bash
# 設定を反映させるため再起動
systemctl restart zabbix-agent2
```

#### 8-4. 自動復旧スクリプトの作成

`通知 → スクリプト → スクリプトの作成`

| 項目 | 設定値 |
|------|--------|
| 名前 | 任意の名前 |
| 範囲 | アクション処理 |
| タイプ | スクリプト |
| 次で実行 | Zabbixエージェント |
| コマンド | `sudo systemctl restart mariadb` |
| ホストグループ | 選択 → `Zabbix servers` |

「追加」をクリック。

#### 8-5. 自動復旧アクションの作成

`通知 → アクション → トリガーアクション → アクションの作成`

| タブ | 項目 | 設定値 |
|------|------|--------|
| アクションタブ | 名前 | 任意の名前 |
| | 実行条件 | 追加 → タイプ:トリガー、オペレータ:等しい、トリガー発生元:ホスト、トリガー → 選択 → Step 8-2で作成したトリガーを選択 → 追加 |
| | 有効 | チェックを入れる |
| 実行内容タブ | 実行内容 | 追加 → 処理内容:Step 8-4で作成したスクリプトを選択、ターゲットリスト:現在のホストにチェック → 追加 |

「追加」をクリック。

**確認:** 実際にMariaDBを停止させ、以下を確認する。

リモートコマンド実行の確認:
1. WebUIで確認: `監視データ → 障害 → MariaDBがダウンした障害のアクションを選択し詳細を確認`

復旧確認:
1. WebUI障害画面: `監視データ → 障害` → ステータスが「解決済」
2. WebUI最新データ画面: `監視データ → 最新データ` → グラフで復旧を確認
3. Zabbixエージェント側CLI: `systemctl status mariadb | less`

---

### Step 9: ダッシュボード作成

**目的:** 必要な情報を一目で確認できるダッシュボードを作成する。

#### 操作手順(WebUI操作)

`ダッシュボード → すべてのダッシュボード → ダッシュボードの作成`

| 項目 | 設定値 |
|------|--------|
| 名前 | 任意の名前 |

「適用」をクリック。

「+追加」をクリック:

| 項目 | 設定値 |
|------|--------|
| タイプ | グラフや障害など、表示させたい項目を選択 |
| 名前 | 任意の名前 |
| その他の設定 | 好きなように設定 |

---

### Step 10: Webシナリオ監視

**目的:** ZabbixエージェントにWordPressを構築し、Webシナリオ監視を追加する。

> **Webシナリオ監視とは:** 人間がWebサイトを操作する手順を自動でシミュレーションする監視方法。

具体的な手順は以下の2つ:
1. セキュリティグループ設定
2. シナリオ監視の作成

#### 10-1. セキュリティグループの設定

ZabbixサーバがWordPressの画面にアクセスして監視するため、Zabbixエージェント側のSGに以下を追加:

| タイプ | ポート範囲 | ソース |
|--------|-----------|-------|
| HTTP | 80 | ZabbixサーバのプライベートIP |

#### 10-2. シナリオ監視の作成

`データ収集 → ホスト → 該当のホストのWebをクリック → Webシナリオの作成`

| タブ | 項目 | 設定値 |
|------|------|--------|
| シナリオタブ | 名前 | 任意の名前 |
| | 監視間隔 | 1m |
| | 試行回数 | 任意の数 |
| | エージェント | Zabbix |
| | 有効 | チェックを入れる |
| ステップタブ | ステップ | 追加 |
| | 名前 | 任意の名前 |
| | URL | 実行するWebページ |
| | POSTフィールド | ログイン確認時のユーザー名やパスワード(例: `log => zabbix` / `pwd => zabbix`) |
| | 要求文字列 | そのWebページが表示されたことを確認する文字列 |
| | 要求ステータスコード | Webページ表示成功時やリダイレクト時のステータスコード |

「追加」をクリック。

**確認:**
1. `データ収集 → ホスト → 該当のホストのWebをクリック` で該当Web監視の情報にエラーが出ていないこと
2. `監視データ → 最新データ` で作成したWeb監視のアイテムを選択し、グラフで確認

---

### Step 11: テンプレート作成

**目的:** Webサーバ用・APサーバ用・DBサーバ用・運用系MW用のテンプレートをそれぞれ作成する。

#### 操作手順(WebUI操作)

`データ収集 → テンプレート → テンプレートの作成`

| 項目 | 設定値 |
|------|--------|
| テンプレート名 | 任意の名前 |
| テンプレートグループ | どのテンプレートグループに所属させるか |

「追加」をクリック。

その後、これまでの演習のようにアイテム、トリガー、グラフなどを作成する。
用途別にテンプレートを作成しておくことで、新たに監視対象を追加するときにテンプレートを当てるだけで対応できる。

---

## 5. 動作確認・検証

### 5-1. 確認チェックリスト

- [ ] **確認①**: `http://<ZabbixサーバのグローバルIP>/zabbix` でログイン画面が表示される
- [ ] **確認②**: WebUIで監視対象のCPU使用率グラフが表示される
- [ ] **確認③**: CPU負荷80%超過時にOutlook宛にメール通知が届く
- [ ] **確認④**: MariaDB停止 → 自動復旧が動作する
- [ ] **確認⑤**: ダッシュボードが正常に表示される
- [ ] **確認⑥**: Webシナリオ監視が動作する

---

## 6. トラブルシューティング

### よくあるエラーと対処法

---

#### エラー①: WebUIにアクセスできない / 「Zabbix server is running: No」と表示される

**原因:** zabbix-server / httpd / php-fpm / mariadb のいずれかが起動していない、または `zabbix_server.conf` のDB接続情報が誤っている

**対処法:**
```bash
# 4サービスの状態を一括確認
systemctl status zabbix-server httpd php-fpm mariadb

# Zabbixサーバのログ確認
tail -f /var/log/zabbix/zabbix_server.log
```

---

#### エラー②: ホストの隣のZBXアイコンが赤い(エージェント通信失敗)

**原因:** SG設定ミス、エージェント設定の `Server` / `Hostname` 誤り

**対処法:**
- ZabbixエージェントのSGで10050ポートがZabbixサーバのプライベートIPから許可されているか確認
- `/etc/zabbix/zabbix_agent2.conf` の `Server`、`Hostname` を確認(WebUI上のホスト名と完全一致が必要)
- Zabbixサーバ側から `zabbix_get -s <エージェントのプライベートIP> -k agent.ping` で疎通確認

---

#### エラー③: メールが届かない(Step 6)

**原因:** `curl-minimal` のまま、Zabbixサーバ側でPostfixが起動していない、メディアタイプ設定ミス

**対処法:**
- `dnf swap curl-minimal curl` と `dnf swap libcurl-minimal libcurl` を再確認
- Zabbixサーバ側で Postfix が起動しているか確認: `systemctl status postfix`
- メディアタイプの「テスト」機能で個別に切り分け

---

### ログの確認場所

| ログの種類 | 場所(パス) | 確認コマンド |
|-----------|------------|------------|
| Zabbixサーバログ | `/var/log/zabbix/zabbix_server.log` | `sudo tail -f /var/log/zabbix/zabbix_server.log` |
| Zabbixエージェントログ | `/var/log/zabbix/zabbix_agent2.log` | `sudo tail -f /var/log/zabbix/zabbix_agent2.log` |
| Apacheログ | `/var/log/httpd/error_log` | `sudo tail -f /var/log/httpd/error_log` |
| メールログ | `/var/log/maillog` | `sudo tail -f /var/log/maillog` |

---

## 7. 参考リソース・関連資料

| 資料名 | URL / 場所 | 補足 |
|-------|-----------|------|
| Zabbix 公式ドキュメント | https://www.zabbix.com/documentation/current/jp | Zabbix 7.0の設定リファレンス |
| Zabbix 公式リポジトリ | https://repo.zabbix.com/zabbix/7.0/amazonlinux/2023/x86_64/zabbix-release-latest-7.0.amzn2023.noarch.rpm | Amazon Linux 2023向けインストールパッケージ |

---

## 付録(任意)

### A. 環境変数・パラメータまとめ

| パラメータ名 | 自分の環境の値 | 説明 |
|------------|-------------|------|
| Zabbixサーバ パブリックIP | `xx.xx.xx.xx` | SSH接続・WebUIアクセス先 |
| Zabbixサーバ プライベートIP | `xx.xx.xx.xx` | エージェント設定の `Server`、Web監視用SGソース |
| Zabbixエージェント プライベートIP | `xx.xx.xx.xx` | サーバ側ホスト設定のIPアドレス |
| データベース名 | `zabbix` | Zabbix用DB |
| DBユーザー名/パスワード | `zabbix` / `zabbix` | Zabbix用DBユーザー |
| WebUI初期ログイン | `Admin` / `zabbix` | Zabbix初期管理者 |

### B. コマンド解説

| コマンド | 説明 |
|---------|------|
| `timedatectl set-timezone <タイムゾーン>` | OSのタイムゾーンを変更 |
| `rpm -Uvh <URL>` | URL上のrpmファイルをダウンロードしながらインストール(`-U`:アップグレード/`-v`:詳細表示/`-h`:進行状況表示) |
| `dnf clean all` | リポジトリ追加後にキャッシュをクリアし、最新メタデータでパッケージ依存関係を再計算 |
| `systemctl enable --now <サービス>` | 起動と自動起動設定を1コマンドで実施 |
| `mysql_secure_installation` | MariaDB/MySQLのセキュリティ強化スクリプト |
| `zcat <gzファイル> \| mysql ...` | 圧縮済みSQLを解凍せずにDBへインポート |
| `mysql -u <user> -p -e "<SQL>"` | ログインせずシェルから直接SQLを実行 |

### C. SQL解説

| SQL | 説明 |
|-----|------|
| `CREATE DATABASE <名前> CHARACTER SET <文字コード> COLLATE <照合順序>;` | 文字コード・照合順序を指定してDBを作成 |
| `SET GLOBAL log_bin_trust_function_creators = 1;` | Zabbix初期スキーマで関数を作成するため必要な設定。インポート後は0に戻す |

### D. リンク解説

- `https://repo.zabbix.com/zabbix/7.0/amazonlinux/2023/x86_64/zabbix-release-latest-7.0.amzn2023.noarch.rpm`
  Amazon Linux 2023へZabbix 7.0 LTSをインストールするための公式リポジトリパッケージ

### E. 削除・クリーンアップ手順

1. EC2インスタンスを2台とも終了する
2. セキュリティグループを削除する
3. キーペアを削除する(必要に応じて)
