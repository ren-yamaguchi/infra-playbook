# Apacheとphp-fpmを用いたWeb/APサーバーの構築

------------------------------

## 1. ドキュメント情報

| 項目 | 内容 |
|------|------|
| 手順書名 | 手順書_Apache_php-fpm_基本構築 |
| 作成日 | 2026-05-17 |
| 最終更新日 | 2026-05-17 |
| バージョン | v1.0 |
| 対象環境 | AWS |

> **改訂履歴**
>
> | バージョン | 日付 | 変更内容 |
> |-----------|------|---------|
> | v1.0 | 2026-05-17 | 初版作成 |

------------------------------

## 2. 目的・概要

### 2-1. 目的

> 本手順書では， Webサーバーとして「Apache」，APサーバーとして「php-fpm」を用いて，WordPressの言語選択画面を表示させるための構築手順について説明する．
> 構築後はブラウザで「`http://<EC2のパブリックIP>/`」にアクセスし，WordPressの言語選択画面が表示される状態を目指す．
>
> なお，本手順書の目的は「Apache + php-fpm の連携確認」のため，DB（MariaDB等）の構築は行わない．そのため，WordPressの初期セットアップ（DB接続情報の入力以降）は対象外とする．

### 2-2. 構成概要（アーキテクチャ）

```
[ローカルPC（ブラウザ）]
       |
       | HTTP（80）
       v
[EC2: Amazon Linux 2023]
  ├── Apache（Webサーバー）
  │     └─ 静的コンテンツの応答、PHPリクエストをphp-fpmへ転送
  └── php-fpm（APサーバー）
        └─ /var/www/html/ 配下のPHPファイルを実行
              └─ WordPress（DB未接続のため言語選択画面まで）
```

### 2-3. 完成イメージ（ゴール定義）

- [ ] ブラウザで「`http://<EC2のパブリックIP>`」にアクセスし，「It works!」と表示される
- [ ] ブラウザで「`http://<EC2のパブリックIP>/phpinfo.php`」にアクセスし，phpの情報ページが表示される
- [ ] ブラウザで「`http://<EC2のパブリックIP>/`」にアクセスし，WordPressの言語選択画面（"Select a language" / 日本語などの言語を選ぶ画面）が表示される

------------------------------

## 3. 前提条件・準備

### 3-1. 環境要件

| 項目 | 要件 |
|------|------|
| OS | AWS（Amazon Linux 2023）,WSL（Ubuntu 24.04） |
| Webサーバー | Apache |
| APサーバー | php-fpm |

### 3-2. セキュリティグループ設定

| タイプ | プロトコル | ポート範囲 | ソース | 説明 |
|-------|------------|----------|--------|------|
| SSH | TCP | 22 | マイIP | ローカルPCからSSHで接続 |
| HTTP | TCP | 80 | マイIP | ローカルPCのブラウザから接続 |

------------------------------

## 4. 構築手順（詳細）

> **注意事項**
> - コマンド中の `<山カッコ>` は自分の環境の値に置き換えること

------------------------------

### Step 1 システム設定

**目的：** システムの変更と更新を行う．

#### 操作手順

```bash
# ローカルPCからsshログイン
ssh -i <秘密鍵のファイルパス> ec2-user@<EC2のパブリックIP>

# rootユーザーにスイッチ
sudo su -

# 最新パッケージへの更新
dnf update -y

# システムの時間を日本時間に設定(これによりログを確認した時の時間が日本時間で表示されるようになる)
timedatectl set-timezone Asia/Tokyo
```

------------------------------

### Step 2 Apacheの設定

**目的：** Apacheの設定を行い、Webサーバーの構築を行う

#### 操作手順

```bash
# Apacheのインストール
dnf install -y httpd

# Apacheの起動と自動起動設定
systemctl enable --now httpd

# Apacheの起動確認
systemctl status httpd | less

# Apacheの自動起動設定確認
systemctl is-enabled httpd
```

> **確認：** Apacheの起動と設定の確認
> 
> ブラウザで「`http://<EC2のパブリックIP>`」にアクセスし，「It works!」と表示されれば成功

------------------------------

### Step 3 php-fpmの設定

**目的：** php-fpmの設定を行い、Webサーバーの構築を行う

#### 操作手順

```bash
# php-fpmとWordPressをWebページとして表示させるのに必要なモジュールをインストール
dnf install -y php-fpm php-mysqli php-json php-devel php-mbstring php-gd php-xml

# php-fpmの起動と自動起動設定
systemctl enable --now php-fpm

# php-fpmの起動確認
systemctl status php-fpm | less

# php-fpmの自動起動設定確認
systemctl is-enabled php-fpm

# Apacheがphp-fpmと連携するために再起動
systemctl restart httpd

# /var/www/html/配下にphpinfo.phpを作成し、phpの情報を記載
echo "<?php phpinfo(); ?>" > /var/www/html/phpinfo.php
```

> **確認：** php-fpmの起動とAPサーバーの設定確認
> 
> ブラウザで「`http://<EC2のパブリックIP>/phpinfo.php`」にアクセスし、phpの情報が表示されていれば成功

```bash
# phpの情報をセキュリティ観点から削除（確認プロンプトで yes を入力）
rm /var/www/html/phpinfo.php
```

### Step 4 WordPressの設定

**目的：** WordPressの設定を行う

#### 操作手順

```bash
# 作業ディレクトリの移動
cd /tmp

# WordPressの最新ファイルをダウンロード
wget https://wordpress.org/latest.tar.gz

# WordPressのファイルの解凍
tar -zxf latest.tar.gz

# 解凍したWordPressの中身を全てhtmlディレクトリにコピー
cp -r wordpress/* /var/www/html/

# /var/www/html/とその中身のファイル・サブディレクトリの全ての所有ユーザーと所有グループを変更
chown -R apache:apache /var/www/html/
```

> **確認：** WordPress表示の確認（本手順書のゴール）
> 
> ブラウザで「`http://<EC2のパブリックIP>/`」にアクセスし、WordPressの言語選択画面（"Select a language"）が表示されれば成功
>
> ※本手順書ではDBの構築を行わないため，言語を選んで「次へ」を押した後の画面以降は対象外

------------------------------

## 付録

### A. コマンド解説

| コマンド | 説明 |
|---------|------|
| `dnf install -y <パッケージ名>` | パッケージを確認プロンプトなしでインストールする。 |
| `systemctl enable --now <サービス名>` | サービスを今すぐ起動し、かつ自動起動も有効化する。 |
| `systemctl status <サービス名>` | サービスの起動状態を表示する。`| less` を付けると長い出力をページャで確認できる。 |
| `systemctl is-enabled <サービス名>` | サービスが自動起動に設定されているか確認する。 |
| `chown -R <ユーザー>:<グループ> <ディレクトリ>` | ディレクトリ配下の所有ユーザー・グループを再帰的に変更する。 |
| `wget <URL>` | 指定したURLからファイルをダウンロードする。 |
| `tar -zxf <ファイル名.tar.gz>` | gzip圧縮されたtarアーカイブを解凍する。 |

------------------------------

### B. 設定ファイル解説

本手順書ではApache・php-fpmともデフォルト設定で動作するため、設定ファイルの編集は行わない。

------------------------------

### C. 用語解説

| 用語 | 説明 |
|------|------|
| Apache | 世界中で広く使われているWebサーバーソフトウェア。HTTPリクエストを受け取り、静的ファイルの応答や、動的処理を他のプログラム（php-fpm等）へ転送する。 |
| php-fpm | PHP FastCGI Process Managerの略。PHPを実行するためのアプリケーションサーバー。Apacheから渡されたPHPファイルを実行し、結果を返す。 |
| WordPress | PHP製のCMS（コンテンツ管理システム）。ブログやWebサイトを構築するためのオープンソースソフトウェア。 |
| Webサーバー | クライアント（ブラウザ）からのHTTPリクエストを受け付け、応答を返すサーバー。 |
| APサーバー | アプリケーションを実行し、動的なコンテンツを生成するサーバー。 |

------------------------------

### D. 補足解説

- **なぜphp-fpmが必要なのか**
  Apacheは静的ファイル（HTML・画像など）を返すのは得意だが、PHPのような動的処理は外部プロセスに依頼する必要がある。php-fpmはこの「PHP実行専用のプロセス」として動作し、Apacheから渡されたPHPを実行して結果を返す。

- **WordPressのセットアップを最後まで完了させたい場合**
  本手順書では言語選択画面までで完了とするが、WordPressのインストールを最後まで完了させるには、別途以下の構築が必要となる。
  - MariaDB（またはMySQL）のインストール
  - WordPress用データベース・ユーザーの作成
  - WordPress初期セットアップ画面でのDB接続情報入力

- **`/var/www/html/` の所有権を `apache:apache` にする理由**
  ApacheおよびWordPressが、テーマファイル・アップロードファイル・設定ファイルなどを読み書きできるようにするため。所有権が`root`のままだと、WordPressがファイル操作に失敗する。