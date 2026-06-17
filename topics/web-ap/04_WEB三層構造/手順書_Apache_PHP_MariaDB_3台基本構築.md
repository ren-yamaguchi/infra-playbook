# 【Web三層構造-LAMP環境でWordPress利用（3台構成）】環境構築手順書

---

## 1. ドキュメント情報

| 項目 | 内容 |
|------|------|
| 手順書名 | Web三層構造-LAMP環境でWordPress利用（3台構成） |
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

> 本手順書では、AWSのEC2インスタンスを3台用いてWeb三層構造-LAMP環境の構築及びWordPress初期画面の表示の構築手順について説明する。
> Webサーバ、APサーバ、DBサーバをそれぞれ別インスタンスに分離することで、Web三層構造の本来の構成を学習することを目指す。

### 2-2. 構成概要（アーキテクチャ）

```
[ローカルPC]
    |
    | (HTTP / SSH)
    v
[Webサーバ EC2] --(FastCGI:9000)--> [APサーバ EC2] --(MySQL:3306)--> [DBサーバ EC2]
   Apache                              PHP-FPM                          MariaDB
```

- **Webサーバ**：Apache（リクエストを受け付け、PHPの処理はAPサーバに転送）
- **APサーバ**：PHP-FPM（PHPの処理を実行し、必要に応じてDBサーバに問い合わせ）
- **DBサーバ**：MariaDB（WordPress用データベース）

### 2-3. 完成イメージ（ゴール定義）

- Webサーバ、APサーバ、DBサーバの3台すべてにSSHログインできる
- WebサーバからAPサーバ（PHP-FPM）にFastCGI経由で接続できる
- APサーバからDBサーバへMySQL接続できる
- ブラウザから `http://<WebサーバのパブリックIP>` にアクセスし、WordPressの初期設定画面が表示される

---

## 3. 前提条件・準備

### 3-1. 環境要件

| 項目 | 要件 |
|------|------|
| OS | Amazon Linux 2023 |
| インスタンスタイプ | t3.micro |
| インスタンス台数 | 3台（Webサーバ、APサーバ、DBサーバ） |
| Webサーバ | Apache |
| APサーバ | PHP-FPM |
| DBサーバ | MariaDB |
| Webサイト | WordPress |

### 3-2. 必要なアカウント・権限

- AWS アカウント
- SSH クライアントがローカルにインストール済みであること

### 3-3. 事前準備物

- キーペア（`.pem` ファイル）を作成・保存済み
- セキュリティグループを3つ作成済み（Webサーバ用、APサーバ用、DBサーバ用）

> **自分のグローバル IP 確認コマンド**
> ```bash
> curl ip-net.info
> ```

---

## 4. 構築手順（詳細）

> **注意事項**
> - コマンド中の `<山カッコ>` は自分の環境の値に置き換えること
> - `<任意の名前>` は、自分や他のメンバーと区別できるように決めること
> - 本構成では、Webサーバ・APサーバ・DBサーバの3台間でIPアドレスを相互参照するため、各インスタンスのプライベートIPを必ず控えておくこと

---

### Step 1：セキュリティグループの設定

**目的：** 各サーバへの接続を制御するためのファイアウォールを設定する

#### 操作手順

AWS マネジメントコンソールから、EC2 → セキュリティグループ → 「セキュリティグループを作成」を選択し、以下の3つのセキュリティグループを作成する。

##### Webサーバ用セキュリティグループ

| 設定項目 | 設定値 |
|---------|--------|
| セキュリティグループ名 | `<任意の名前>_web_sg` |
| 説明 | `Webサーバ用のセキュリティグループ` |

**インバウンドルール：**

| タイプ | プロトコル | ポート範囲 | ソース | 説明 |
|-------|------------|----------|--------|------|
| SSH | TCP | 22 | マイIP | ローカルPCからSSHで接続 |
| HTTP | TCP | 80 | マイIP | ローカルPCのブラウザから接続 |

##### APサーバ用セキュリティグループ

| 設定項目 | 設定値 |
|---------|--------|
| セキュリティグループ名 | `<任意の名前>_ap_sg` |
| 説明 | `APサーバ用のセキュリティグループ` |

**インバウンドルール：**

| タイプ | プロトコル | ポート範囲 | ソース | 説明 |
|-------|------------|----------|--------|------|
| SSH | TCP | 22 | マイIP | ローカルPCからSSHで接続 |
| カスタムTCP | TCP | 9000 | WebサーバのプライベートIP/32 | Webサーバからの接続を許可 |

##### DBサーバ用セキュリティグループ

| 設定項目 | 設定値 |
|---------|--------|
| セキュリティグループ名 | `<任意の名前>_db_sg` |
| 説明 | `DBサーバ用のセキュリティグループ` |

**インバウンドルール：**

| タイプ | プロトコル | ポート範囲 | ソース | 説明 |
|-------|------------|----------|--------|------|
| SSH | TCP | 22 | マイIP | ローカルPCからSSHで接続 |
| MYSQL/Aurora | TCP | 3306 | APサーバのプライベートIP/32 | APサーバからの接続を許可 |

> **注意：** APサーバ用SG・DBサーバ用SGのソースは、各EC2インスタンスを起動してプライベートIPが確定した後に設定する。

---

### Step 2：EC2インスタンスの起動

**目的：** Webサーバ、APサーバ、DBサーバの3台のEC2インスタンスを作成する

#### 操作手順

以下の3台のEC2インスタンスを起動する。

| 項目 | Webサーバ | APサーバ | DBサーバ |
|------|----------|---------|---------|
| 名前タグ | `<任意の名前>_web` | `<任意の名前>_ap` | `<任意の名前>_db` |
| AMI | Amazon Linux 2023 | Amazon Linux 2023 | Amazon Linux 2023 |
| インスタンスタイプ | t3.micro | t3.micro | t3.micro |
| キーペア | 作成したキーペア | 作成したキーペア | 作成したキーペア |
| セキュリティグループ | `<任意の名前>_web_sg` | `<任意の名前>_ap_sg` | `<任意の名前>_db_sg` |

起動後、3台すべての **プライベートIPアドレス** を控えておく。
その上で、APサーバ用SGとDBサーバ用SGのインバウンドルールのソースを正しいプライベートIPに更新する。

---

### Step 3：Webサーバの構築（Apache）

**目的：** WebサーバにApacheをインストールし、リクエスト受付の準備を行う

#### 操作手順

WebサーバにSSH接続後、以下を実行する。

```bash
# rootユーザーにスイッチ
sudo su -

# ソフトウェアをアップデート
dnf update -y

# Apache、php-fpm（Apacheからphp-fpmに転送するための設定ファイル用）をインストール
dnf install -y httpd php-fpm

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

**テスト：** ブラウザで「http://<Webサーバのパブリック IP>」を入力し、「It Works!」と表示されていれば成功

```bash
# Apacheからphp-fpmへの転送設定を編集
vi /etc/httpd/conf.d/php.conf
```

設定ファイルの編集内容：
```
SetHandler "proxy:unix:/run/php-fpm/www.sock|fcgi://localhost"
→ SetHandler "proxy:fcgi://<APサーバのプライベートIP>:9000"
```

```bash
# Apacheの設定変更を反映させるため再起動
systemctl restart httpd
```

---

### Step 4：APサーバの構築（PHP-FPM）

**目的：** APサーバにPHP-FPMをインストールし、Webサーバからのリクエストを受け付ける

#### 操作手順

APサーバにSSH接続後、以下を実行する。

```bash
# rootユーザーにスイッチ
sudo su -

# ソフトウェアをアップデート
dnf update -y

# PHP（必要なモジュール）、MariaDB（APサーバからDBサーバへの接続確認のため）をインストール
dnf install -y php-fpm php-mysqli php-json php php-devel mariadb105-server

# php-fpmを起動
systemctl start php-fpm

# php-fpmの起動を確認
systemctl status php-fpm

# php-fpmの自動起動設定
systemctl enable php-fpm

# php-fpmの自動起動設定確認
systemctl is-enabled php-fpm

# Apacheからの転送を受け付ける設定
vi /etc/php-fpm.d/www.conf
```

設定ファイルの編集内容：
```
listen = /run/php-fpm/www.sock
→ listen = <APサーバのプライベートIP>:9000

listen.allowed_clients = 127.0.0.1
→ listen.allowed_clients = <WebサーバのプライベートIP>
```

```bash
# php-fpmの設定変更を反映させるため再起動
systemctl restart php-fpm

# /var/www/html/配下にphpinfo.phpを作成し、PHPの情報を記載
echo "<?php phpinfo(); ?>" > /var/www/html/phpinfo.php
```

**テスト：** ブラウザで「http://<WebサーバのパブリックIP>/phpinfo.php」を入力し、PHPの情報が表示されていれば成功

> **補足：** Webサーバ経由でAPサーバのPHP-FPMが呼び出されることを確認するテスト。Webサーバのドキュメントルートにも `phpinfo.php` が必要な場合があるため、後述のStep 6でWeb・AP両方に同じファイルを配置する。

```bash
# PHPの情報をセキュリティ観点から削除
rm /var/www/html/phpinfo.php
# → rm: remove regular file '/var/www/html/phpinfo.php'? と表示されるのでyes
```

---

### Step 5：DBサーバの構築

**目的：** DBサーバにMariaDBをインストールし、WordPress用のDB・ユーザーを作成する

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
systemctl status mariadb | less

# MariaDBの自動起動設定
systemctl enable mariadb

# MariaDBの自動起動設定確認
systemctl is-enabled mariadb

# MariaDBのセキュリティの観点から必要のない機能を削除
# ※飛ばしてもよい
mysql_secure_installation
```

対話形式の質問への回答は2台構成と同様（rootパスワード設定、匿名ユーザー削除、リモートrootログイン無効化、テストDB削除、権限テーブルリロード）。

```bash
# rootユーザーでMariaDBにログインし、WordPress用のDB・ユーザーを作成
mysql -u root -p
```

```sql
-- ユーザーの作成（APサーバのプライベートIPからの接続を許可）
CREATE USER '<新規ユーザー名>'@'<APサーバのプライベートIP>' IDENTIFIED BY '<新規パスワード>';

-- データベースの作成
CREATE DATABASE <新規データベース名>;

-- 作成したデータベースに対する全権限をユーザーに付与
GRANT ALL PRIVILEGES ON <新規データベース名>.* TO '<新規ユーザー名>'@'<APサーバのプライベートIP>';

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

### Step 6：APサーバでのWordPress設定

**目的：** APサーバ上にWordPressのファイルを配置し、DB接続情報を設定する

#### 操作手順

まず、APサーバからDBサーバへの接続確認を行う。

```bash
# APサーバからDBサーバへの接続確認
mysql -u <新規ユーザー名> -p -h <DBサーバのプライベートIP> <新規データベース名>
# → Password: 設定したパスワードを入力
# → MariaDB [(新規データベース名)]> になれば成功
# → exit でログアウト
```

続いて、WordPressをインストールする。

```bash
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

# php-fpmの設定を反映させるため再起動
systemctl restart php-fpm
```

---

### Step 7：WebサーバでのWordPress設定

**目的：** Webサーバ上にもWordPressのファイルを配置し、Apacheから配信できるようにする

> **補足：** 本構成ではApache（Webサーバ）がPHPファイルのパスを認識し、PHP-FPM（APサーバ）に処理を転送する仕組みのため、Webサーバ側にもWordPressのファイル一式が必要となる。

#### 操作手順

WebサーバにSSH接続後、以下を実行する。

```bash
# rootユーザーにスイッチ
sudo su -

# WordPressをダウンロード
wget https://wordpress.org/latest.tar.gz

# ダウンロードしたファイルを解凍
tar -xzf latest.tar.gz

# WordPressの設定サンプルをコピーし、設定ファイルを作成
cp wordpress/wp-config-sample.php wordpress/wp-config.php

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

- [ ] **確認①**：Webサーバ、APサーバ、DBサーバの3台すべてにSSHログインできること
- [ ] **確認②**：APサーバからDBサーバへMySQL接続できること
- [ ] **確認③**：WordPressの初期画面が表示されること

---

### 確認①：SSHログイン確認

```bash
# Webサーバへの接続
ssh -i <秘密鍵のファイルパス> ec2-user@<WebサーバのパブリックIP>

# APサーバへの接続
ssh -i <秘密鍵のファイルパス> ec2-user@<APサーバのパブリックIP>

# DBサーバへの接続
ssh -i <秘密鍵のファイルパス> ec2-user@<DBサーバのパブリックIP>
```

---

### 確認②：APサーバからDBサーバへの接続確認

APサーバ上で以下を実行する。

```bash
mysql -u <新規ユーザー名> -p -h <DBサーバのプライベートIP> <新規データベース名>
```

**期待する結果：** `MariaDB [(新規データベース名)]>` のプロンプトになれば成功

---

### 確認③：WordPressの初期画面表示

ブラウザで「http://<WebサーバのパブリックIP>/」を入力する。

**期待する結果：** WordPressの言語設定を行う画面が表示される

---

## 6. トラブルシューティング

### よくあるエラーと対処法

---

#### エラー①：WordPressの画面が表示されず、白画面または「File not found.」になる

**原因：** 以下のいずれかが考えられる
- WebサーバとAPサーバの間のFastCGI通信が失敗している
- APサーバの `listen` または `listen.allowed_clients` が正しく設定されていない
- APサーバ用SGの9000ポートが許可されていない

**対処法：**

1. Webサーバで `/etc/httpd/conf.d/php.conf` の `SetHandler` がAPサーバのプライベートIPを指しているか確認
2. APサーバで `/etc/php-fpm.d/www.conf` の `listen` と `listen.allowed_clients` を確認
3. APサーバ用SGで9000ポートがWebサーバのプライベートIPから許可されているか確認
4. APサーバで `ss -tlnp | grep 9000` を実行し、php-fpmが9000ポートでLISTENしているか確認

---

#### エラー②：APサーバからDBサーバへ接続できない

**対処法：** 2台構成の手順書のトラブルシューティングを参照（DBサーバ用SGのソース、bind-address、ユーザーのホスト指定を確認）。

---

#### エラー③：SSH 接続がタイムアウトする

**原因：** セキュリティグループでSSH（ポート22）が許可されていない

**対処法：** 対象SGのインバウンドルールでSSH（TCP/22）を自分のIPから許可する。

---

### ログの確認場所

| ログの種類 | 場所（パス） | 配置サーバ |
|-----------|------------|------------|
| Apache アクセスログ | `/var/log/httpd/access_log` | Webサーバ |
| Apache エラーログ | `/var/log/httpd/error_log` | Webサーバ |
| PHP-FPM エラーログ | `/var/log/php-fpm/error.log` | APサーバ |
| MariaDB エラーログ | `/var/log/mariadb/mariadb.log` | DBサーバ |

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
| Webサーバ パブリックIP | `xx.xx.xx.xx` | SSH・HTTP接続先 |
| Webサーバ プライベートIP | `xx.xx.xx.xx` | APサーバSGのソースに指定 |
| APサーバ パブリックIP | `xx.xx.xx.xx` | SSH接続先 |
| APサーバ プライベートIP | `xx.xx.xx.xx` | WebサーバのSetHandler・DBサーバSGのソースに指定 |
| DBサーバ パブリックIP | `xx.xx.xx.xx` | SSH接続先 |
| DBサーバ プライベートIP | `xx.xx.xx.xx` | APサーバから接続するホスト |
| データベース名 | `<新規データベース名>` | WordPress用 |
| DBユーザー名 | `<新規ユーザー名>` | WordPress用 |
| キーペア名 | `<秘密鍵の名前>` | SSH認証に使用 |

### B. 削除・クリーンアップ手順

1. EC2 インスタンスを3台とも終了する
2. セキュリティグループを3つとも削除する
3. キーペアを削除する（必要に応じて）

> **注意：** セキュリティグループは相互参照しているため、EC2を先に削除すること。
