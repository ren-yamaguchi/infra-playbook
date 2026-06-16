# 【Web三層構造-LAMP環境でWordPress利用（2台構成）】環境構築手順書

---

## 1. ドキュメント情報

| 項目 | 内容 |
|------|------|
| 手順書名 | Web三層構造-LAMP環境でWordPress利用（2台構成） |
| 作成日 | 2026-06-16 |
| 最終更新日 | 2026-06-16 |
| バージョン | v1.0 |
| 対象環境 | AWS |

> **改訂履歴**
>
> | バージョン | 日付 | 変更内容 |
> |-----------|------|---------|
> | v1.0 | 2026-06-16 | 初版作成（テンプレートに沿って再構成、誤記訂正） |

---

## 2. 目的・概要

### 2-1. 目的

> 本手順書では、AWSのEC2インスタンスを2台用いてWeb三層構造-LAMP環境の構築及びWordPress初期画面の表示の構築手順について説明する。
> Web/APサーバとDBサーバを別インスタンスに分離することで、より実践的な構成での構築手順を学習することを目指す。

### 2-2. 構成概要（アーキテクチャ）

```
[ローカルPC]
    |
    | (HTTP / SSH)
    v
[Web/APサーバ EC2] ---(MySQL:3306)---> [DBサーバ EC2]
  Apache + PHP                          MariaDB
```

- **Web/APサーバ**：Apache + PHP（WordPressのファイルを配置）
- **DBサーバ**：MariaDB（WordPress用データベース）

### 2-3. 完成イメージ（ゴール定義）

- Web/APサーバ、DBサーバの両方にSSHログインできる
- Web/APサーバからDBサーバへMySQL接続できる
- ブラウザから `http://<Web/APサーバのパブリックIP>` にアクセスし、WordPressの初期設定画面が表示される

---

## 3. 前提条件・準備

### 3-1. 環境要件

| 項目 | 要件 |
|------|------|
| OS | Amazon Linux 2023 |
| インスタンスタイプ | t3.micro |
| インスタンス台数 | 2台（Web/APサーバ、DBサーバ） |
| Webサーバ | Apache |
| APサーバ | PHP |
| DBサーバ | MariaDB |
| Webサイト | WordPress |

### 3-2. 必要なアカウント・権限

- AWS アカウント
- SSH クライアントがローカルにインストール済みであること

### 3-3. 事前準備物

- キーペア（`.pem` ファイル）を作成・保存済み
- セキュリティグループを2つ作成済み（Web/APサーバ用、DBサーバ用）

> **自分のグローバル IP 確認コマンド**
> ```bash
> curl ip-net.info
> ```

---

## 4. 構築手順（詳細）

> **注意事項**
> - コマンド中の `<山カッコ>` は自分の環境の値に置き換えること
> - `<任意の名前>` は、自分や他のメンバーと区別できるように決めること

---

### Step 1：セキュリティグループの設定

**目的：** 各サーバへの接続を制御するためのファイアウォールを設定する

#### 操作手順

AWS マネジメントコンソールから、EC2 → セキュリティグループ → 「セキュリティグループを作成」を選択し、以下の2つのセキュリティグループを作成する。

##### Web/APサーバ用セキュリティグループ

| 設定項目 | 設定値 |
|---------|--------|
| セキュリティグループ名 | `<任意の名前>_web_sg` |
| 説明 | `Web/APサーバ用のセキュリティグループ` |

**インバウンドルール：**

| タイプ | プロトコル | ポート範囲 | ソース | 説明 |
|-------|------------|----------|--------|------|
| SSH | TCP | 22 | マイIP | ローカルPCからSSHで接続 |
| HTTP | TCP | 80 | マイIP | ローカルPCのブラウザから接続 |

##### DBサーバ用セキュリティグループ

| 設定項目 | 設定値 |
|---------|--------|
| セキュリティグループ名 | `<任意の名前>_db_sg` |
| 説明 | `DBサーバ用のセキュリティグループ` |

**インバウンドルール：**

| タイプ | プロトコル | ポート範囲 | ソース | 説明 |
|-------|------------|----------|--------|------|
| SSH | TCP | 22 | マイIP | ローカルPCからSSHで接続 |
| MYSQL/Aurora | TCP | 3306 | Web/APサーバのプライベートIP/32 | Web/APサーバからの接続を許可 |

> **注意：** DBサーバ用SGのMYSQL/Auroraのソースは、Web/APサーバを起動してプライベートIPが確定した後に設定する。

---

### Step 2：EC2インスタンスの起動

**目的：** Web/APサーバとDBサーバの2台のEC2インスタンスを作成する

#### 操作手順

以下の2台のEC2インスタンスを起動する。

| 項目 | Web/APサーバ | DBサーバ |
|------|------------|---------|
| 名前タグ | `<任意の名前>_web` | `<任意の名前>_db` |
| AMI | Amazon Linux 2023 | Amazon Linux 2023 |
| インスタンスタイプ | t3.micro | t3.micro |
| キーペア | 作成したキーペア | 作成したキーペア |
| セキュリティグループ | `<任意の名前>_web_sg` | `<任意の名前>_db_sg` |

起動後、両インスタンスの **プライベートIPアドレス** を控えておく。

> **補足：** Web/APサーバ用SGには「マイIP」、DBサーバ用SGには「Web/APサーバのプライベートIP」をソースに設定するため、起動後にDBサーバ用SGのMYSQL/Auroraルールを更新する。

---

### Step 3：Web/APサーバの構築（Webサーバ部分）

**目的：** Web/APサーバ用EC2インスタンスにApacheとPHPをインストールし、Web/APサーバとして機能させる

#### 操作手順

Web/APサーバにSSH接続後、以下を実行する。

```bash
# rootユーザーにスイッチ
sudo su -

# ソフトウェアをアップデート
dnf update -y

# Apache、PHP（必要なモジュール）をインストール
dnf install -y httpd php-fpm php-mysqli php-json php php-devel

# Apacheを起動
systemctl start httpd

# Apacheの起動を確認
systemctl status httpd
# → active(running)と表示されることを確認

# Apacheの自動起動設定
systemctl enable httpd

# Apacheの自動起動設定確認
systemctl is-enabled httpd
# → enabledと表示されることを確認
```

**テスト①：** ブラウザで「http://<Web/APサーバのパブリックIP>」を入力し、「It Works!」と表示されていれば成功

```bash
# /var/www/html/配下にphpinfo.phpを作成し、PHPの情報を記載
echo "<?php phpinfo(); ?>" > /var/www/html/phpinfo.php
```

**テスト②：** ブラウザで「http://<Web/APサーバのパブリックIP>/phpinfo.php」を入力し、PHPの情報が表示されていれば成功

```bash
# PHPの情報をセキュリティ観点から削除
rm /var/www/html/phpinfo.php
# → rm: remove regular file '/var/www/html/phpinfo.php'? と表示されるのでyes
```

---

### Step 4：DBサーバの構築

**目的：** DBサーバ用EC2インスタンスにMariaDBをインストールし、DBサーバとして機能させる

#### 操作手順

DBサーバにSSH接続後、以下を実行する。

```bash
# rootユーザーにスイッチ
sudo su -

# ソフトウェアをアップデート
dnf update -y

# MariaDBをインストール
dnf install -y mariadb105-server

# MariaDBを起動
systemctl start mariadb

# MariaDBの起動を確認
systemctl status mariadb

# MariaDBの自動起動設定
systemctl enable mariadb

# MariaDBの自動起動設定確認
systemctl is-enabled mariadb

# MariaDBのセキュリティの観点から必要のない機能を削除
# ※飛ばしてもよい
mysql_secure_installation
```

対話形式の質問に以下のように回答する：
```
1. rootパスの入力、デフォルトは設定されていないためエンターキー
   Enter current password for root (enter for none): Enter

2. 接続をリモート可能にするか設定、ローカル接続のみにする場合はY
   Switch to unix_socket authentication [Y/n] Y

3. rootパスワードを変更する場合Y
   Change the root password? [Y/n] Y

4. 匿名ユーザアカウントを削除する場合Y
   Remove anonymous users? [Y/n] Y

5. リモートrootログインを無効にする場合Y
   Disallow root login remotely? [Y/n] Y

6. テストデータベースを削除する場合Y
   Remove test database and access to it? [Y/n] Y

7. 権限テーブルをリロードし、変更を保存する場合Y
   Reload privilege tables now? [Y/n] Y
```

```bash
# rootユーザーでMariaDBにログインし、WordPress用のDB・ユーザーを作成
mysql -u root -p
```

```sql
-- ユーザーの作成（Web/APサーバのプライベートIPからの接続を許可）
CREATE USER '<新規ユーザー名>'@'<Web/APサーバのプライベートIP>' IDENTIFIED BY '<新規パスワード>';

-- データベースの作成
CREATE DATABASE <新規データベース名>;

-- 作成したデータベースに対する全権限をユーザーに付与
GRANT ALL PRIVILEGES ON <新規データベース名>.* TO '<新規ユーザー名>'@'<Web/APサーバのプライベートIP>';

-- 変更を有効にする
FLUSH PRIVILEGES;

-- MariaDBからログアウト
exit
```

```bash
# DBサーバの外部接続を許可するため、bind-addressを変更
vi /etc/my.cnf.d/mariadb-server.cnf
```

設定ファイルの編集内容：
```
[mysqld]
#bind-address = 0.0.0.0
→ bind-address = <DBサーバのプライベートIP>
```

```bash
# 設定変更を反映するためMariaDBを再起動
systemctl restart mariadb
```

---

### Step 5：Web/APサーバの構築（WordPress設定）

**目的：** Web/APサーバにWordPressをインストールし、DBサーバと連携させる

#### 操作手順

Web/APサーバにSSH接続後、以下を実行する。

```bash
# rootユーザーにスイッチ（既にrootの場合は不要）
sudo su -

# WordPressをダウンロード
wget https://wordpress.org/latest.tar.gz

# ダウンロードしたファイルを解凍
tar -xzf latest.tar.gz

# WordPressの設定サンプルをコピーし、設定ファイルを作成
cp wordpress/wp-config-sample.php wordpress/wp-config.php

# 設定ファイルを編集
vi wordpress/wp-config.php
```

設定ファイルの編集内容：
```php
define('DB_NAME', '<新規データベース名>');
define('DB_USER', '<新規ユーザー名>');
define('DB_PASSWORD', '<新規パスワード>');
define('DB_HOST', '<DBサーバのプライベートIP>');
```

```bash
# WordPress表示に必要なファイル・ディレクトリをApacheのドキュメントルート配下にコピー
cp -r wordpress/* /var/www/html/

# ApacheがWordPressのディレクトリ・ファイルを書き込めるよう所有者を変更
chown -R apache:apache /var/www/html/

# ApacheがWordPressのディレクトリ・ファイルを書き込めるよう権限を変更
chmod -R 755 /var/www/html

# /var/www/html/配下の所有者・権限を確認
ll /var/www/html/

# WordPressのパーマリンクを使用できるように設定を変更
vi /etc/httpd/conf/httpd.conf
```

設定ファイルの編集内容：
```
<Directory "/var/www/html">セクション内
AllowOverride None → AllowOverride All
```

```bash
# Apacheを再起動し設定を反映
systemctl restart httpd
```

---

## 5. 動作確認・検証

> 構築完了後、以下の確認をすべてパスしたら構築成功とみなす。

### 5-1. 確認チェックリスト

- [ ] **確認①**：Web/APサーバ、DBサーバの両方にSSHログインできること
- [ ] **確認②**：Web/APサーバからDBサーバへMySQL接続できること
- [ ] **確認③**：WordPressの初期画面が表示されること

---

### 確認①：SSHログイン確認

```bash
# Web/APサーバへのSSH接続
ssh -i <秘密鍵のファイルパス> ec2-user@<Web/APサーバのパブリックIP>

# DBサーバへのSSH接続
ssh -i <秘密鍵のファイルパス> ec2-user@<DBサーバのパブリックIP>
```

---

### 確認②：Web/APサーバからDBサーバへの接続確認

Web/APサーバ上で以下を実行する。

```bash
mysql -u <新規ユーザー名> -p -h <DBサーバのプライベートIP> <新規データベース名>
# → Password: 設定したパスワードを入力
```

**期待する結果：** `MariaDB [(新規データベース名)]>` のプロンプトになれば成功。`exit` でログアウトする。

---

### 確認③：WordPressの初期画面表示

ブラウザで「http://<Web/APサーバのパブリックIP>/」を入力し、WordPressの設定画面が表示されることを確認する。

**期待する結果：** WordPressの言語設定を行う画面が表示される

---

## 6. トラブルシューティング

### よくあるエラーと対処法

---

#### エラー①：Web/APサーバからDBサーバに接続できない

**エラーメッセージ例：**

```
ERROR 2003 (HY000): Can't connect to MySQL server on 'xx.xx.xx.xx'
```

**原因：** 以下のいずれかが考えられる
- DBサーバ用SGのインバウンドルールで3306ポートが許可されていない
- DBサーバの `bind-address` がプライベートIPに設定されていない
- DB上のユーザーが正しいホスト（Web/APサーバのプライベートIP）から作成されていない

**対処法：**

1. DBサーバ用SGのインバウンドルールを確認し、ソースがWeb/APサーバのプライベートIP/32になっているか確認する
2. DBサーバで `cat /etc/my.cnf.d/mariadb-server.cnf` を実行し、bind-addressが正しく設定されているか確認する
3. DBサーバで以下を実行してユーザーのホストを確認する
   ```sql
   SELECT user, host FROM mysql.user;
   ```

---

#### エラー②：SSH 接続がタイムアウトする

**エラーメッセージ例：**

```
ssh: connect to host xx.xx.xx.xx port 22: Connection timed out
```

**原因：** セキュリティグループのインバウンドルールでSSH（ポート22）が許可されていない可能性がある

**対処法：**

1. AWSコンソール → EC2 → セキュリティグループを開く
2. 対象のセキュリティグループのインバウンドルールを確認する
3. SSH（TCP/22）が自分のIPから許可されているか確認する
4. 許可されていなければ「インバウンドルールを編集」から追加する

---

### ログの確認場所

| ログの種類 | 場所（パス） | 確認コマンド |
|-----------|------------|------------|
| OS システムログ | `/var/log/messages` | `sudo tail -f /var/log/messages` |
| Apache アクセスログ | `/var/log/httpd/access_log` | `sudo tail -f /var/log/httpd/access_log` |
| Apache エラーログ | `/var/log/httpd/error_log` | `sudo tail -f /var/log/httpd/error_log` |
| MariaDB エラーログ | `/var/log/mariadb/mariadb.log` | `sudo tail -f /var/log/mariadb/mariadb.log` |

---

## 7. 参考リソース・関連資料

| 資料名 | URL / 場所 | 補足 |
|-------|-----------|------|
| AWS 公式：チュートリアル：AL2023にLAMPサーバーをインストールする | https://docs.aws.amazon.com/ja_jp/linux/al2023/ug/ec2-lamp-amazon-linux-2023.html | 環境構築の参考 |
| AWS 公式：チュートリアル：AL2023でWordPressブログをホストする | https://docs.aws.amazon.com/ja_jp/linux/al2023/ug/hosting-wordpress-aml-2023.html | 環境構築の参考 |

---

## 付録（任意）

### A. 環境変数・パラメータまとめ

| パラメータ名 | 自分の環境の値 | 説明 |
|------------|-------------|------|
| Web/APサーバ パブリックIP | `xx.xx.xx.xx` | SSH・HTTP接続先 |
| Web/APサーバ プライベートIP | `xx.xx.xx.xx` | DBサーバSGのソースに指定 |
| DBサーバ パブリックIP | `xx.xx.xx.xx` | SSH接続先 |
| DBサーバ プライベートIP | `xx.xx.xx.xx` | Web/APサーバから接続するホスト |
| データベース名 | `<新規データベース名>` | WordPress用 |
| DBユーザー名 | `<新規ユーザー名>` | WordPress用 |
| キーペア名 | `<秘密鍵の名前>` | SSH認証に使用 |

### B. 削除・クリーンアップ手順

1. EC2 インスタンスを2台とも終了する
2. セキュリティグループを2つとも削除する
3. キーペアを削除する（必要に応じて）

> **注意：** セキュリティグループは、相互参照（DBサーバ用SGがWeb/APサーバのIPを参照）している場合があるため、EC2を先に削除すること。
