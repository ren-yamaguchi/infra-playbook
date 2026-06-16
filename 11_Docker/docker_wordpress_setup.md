# 【手順書名】Docker WordPress 環境構築手順書(Apache / PHP / MariaDB)

------------------------------

## 1. ドキュメント情報

| 項目 | 内容 |
|------|------|
| 手順書名 | Docker WordPress 環境構築手順書(Apache / PHP / MariaDB) |
| 作成日 | 2026-06-16 |
| 最終更新日 | 2026-06-16 |
| 作成者 | RYama |
| バージョン | v1.3 |
| 対象環境 | AWS(EC2 / Amazon Linux 2023) |

> **改訂履歴**
>
> | バージョン | 日付 | 変更内容 | 変更者 |
> |-----------|------|---------|--------|
> | v1.0 | 2026-06-16 | 初版作成 | RYama |
> | v1.1 | 2026-06-16 | ポートを 80 に変更、コンテナ名を wordpress-web / wordpress-db に変更、sudo 方針を整理 | RYama |
> | v1.2 | 2026-06-16 | Dockerfile のファイル名を `amzn2.Dockerfile` → `Dockerfile` に変更 | RYama |
> | v1.3 | 2026-06-16 | Step 7「WordPress 初期セットアップ」を追加 | RYama |

------------------------------

## 2. 目的・概要

### 2-1. 目的

本手順書では、AWS EC2(Amazon Linux 2023)上に Docker および Docker Compose を用いて、Apache + PHP + MariaDB の 2 コンテナ構成による WordPress 環境を構築する。

Web/AP 層は Amazon Linux 2 ベースイメージから Apache + PHP 8.2 を導入する**カスタムビルド**、DB 層は MariaDB 公式イメージを利用する構成とし、Dockerfile と Compose の基本的な使い分けを学習することを目的とする。

### 2-2. 構成概要(アーキテクチャ)

```
[ローカルPC(ブラウザ / SSH)]
        |
        |  HTTP(80) / SSH(22)
        v
[EC2: Amazon Linux 2023 (t2.micro 以上)]
   |
   └── Docker Engine
         ├── [web] wordpress-web  (amazonlinux:2 + Apache + PHP 8.2)  :80→80
         │         └── volume: wp_data → /var/www/html
         └── [db]  wordpress-db   (mariadb:11.4)                       :3306(内部)
                   └── volume: db_data → /var/lib/mysql

  ※ web ⇔ db は Compose のデフォルトネットワーク(bridge)で名前解決
     web コンテナから "db" というホスト名で MariaDB へ接続
```

### 2-3. 完成イメージ(ゴール定義)

- [ ] `docker compose ps` で `wordpress-web` / `wordpress-db` の 2 コンテナがすべて `Up` 状態
- [ ] ブラウザから `http://<EC2パブリックIP>` で **WordPress の初期セットアップ画面**(言語選択画面)が表示される
- [ ] 初期セットアップを完了し、**WordPress 管理画面(ダッシュボード)**にログインできる
- [ ] EC2 / コンテナの再起動後も DB データと WordPress ファイルが保持される(ボリューム永続化の確認)

------------------------------

## 3. 前提条件・準備

### 3-1. 環境要件

| 項目 | 要件 |
|------|------|
| OS | Amazon Linux 2023(x86_64) |
| インスタンスタイプ | t2.micro 以上 |
| リージョン | 任意(本手順書では ap-northeast-1 東京を想定) |
| 作業ユーザー | root(教材都合。冒頭で `sudo su -` により root へ切替えるため、以降のコマンドに `sudo` は付けない) |
| その他 | EC2 へ SSH 接続できる状態(キーペア・パブリックIP) |

> **任意のディレクトリ名について**: 本手順書では作業ディレクトリを `~/dock` として記載するが、これは**任意の名称**。各自の作業ディレクトリ名に読み替えること。なお `sudo su -` 後は root のホーム(`/root`)が基点となるため、`~/dock` は `/root/dock` を指す。

### 3-2. セキュリティグループ要件

EC2 にアタッチされているセキュリティグループのインバウンドルールに、以下を追加しておくこと。

| タイプ | プロトコル | ポート | ソース | 用途 |
|--------|-----------|--------|--------|------|
| SSH | TCP | 22 | マイIP | SSH 接続 |
| HTTP | TCP | 80 | マイIP または 0.0.0.0/0 | WordPress(Apache)アクセス |

> 学習用途で `0.0.0.0/0` を許可する場合でも、不要になったら速やかに削除すること。

### 3-3. 最終ディレクトリ構成

> ルートディレクトリの `dock` は**任意の名称**。以降の手順で `dock` と記載している箇所は、自身が決めた作業ディレクトリ名に読み替えること。

```
dock/
├── compose.yml
└── Dockerfile
```

------------------------------

## 4. 構築手順

### Step 1. EC2 初期設定

#### 4-1-1. root ユーザーへ切替

```bash
sudo su -
```

> 本手順書はここから先のコマンドをすべて **root** で実施する。`sudo su -` を実行した時点で root に切り替わるため、**以降のコマンドに `sudo` は付けない**(root が `sudo` を実行する形は冗長かつ意図が不明瞭になる)。
> 実運用では一般ユーザー + `docker` グループ運用や、各コマンドに `sudo` を都度付与する運用を推奨。

#### 4-1-2. パッケージ更新・タイムゾーン・ホスト名設定

```bash
dnf update -y
timedatectl set-timezone Asia/Tokyo
hostnamectl set-hostname docker
```

| コマンド | 役割 |
|---------|------|
| `dnf update -y` | 既存パッケージを最新化 |
| `timedatectl set-timezone Asia/Tokyo` | システム時刻を日本時間に変更(ログの時刻を見やすくするため) |
| `hostnamectl set-hostname docker` | ホスト名を `docker` に変更(任意・識別用) |

ホスト名はシェルプロンプトに反映させるため、一度ログアウト/再ログインするか、`exec bash` で反映する。

------------------------------

### Step 2. Docker Engine インストール

#### 4-2-1. Docker インストールと起動

```bash
dnf install -y docker
docker --version
systemctl enable --now docker
```

| コマンド | 役割 |
|---------|------|
| `dnf install -y docker` | Amazon Linux 2023 のリポジトリから Docker Engine をインストール |
| `docker --version` | バージョンが表示されればインストール成功 |
| `systemctl enable --now docker` | Docker サービスを **即時起動 + OS起動時に自動起動** の両方を一度に設定 |

#### 4-2-2. 動作確認

```bash
systemctl status docker
```

`Active: active (running)` が表示されれば正常。

------------------------------

### Step 3. Docker Compose / Buildx プラグイン導入

Amazon Linux 2023 標準リポジトリには `docker compose` プラグインが含まれない場合があるため、手動で配置する。

#### 4-3-1. プラグイン配置先ディレクトリ作成

```bash
mkdir -p ~/.docker/cli-plugins
```

> root 実行中のため、実体は `/root/.docker/cli-plugins/` となる。

#### 4-3-2. Docker Compose プラグインのダウンロード

```bash
curl -SL https://github.com/docker/compose/releases/latest/download/docker-compose-linux-x86_64 \
  -o /root/.docker/cli-plugins/docker-compose
chmod +x /root/.docker/cli-plugins/docker-compose
docker compose version
```

| コマンド | 役割 |
|---------|------|
| `curl -SL ... -o ...` | GitHub の最新リリースから `docker-compose` 実行ファイルをダウンロード |
| `chmod +x ...` | 実行権限付与 |
| `docker compose version` | バージョン表示されれば導入成功 |

> ARM 系(Graviton, t4g 等)を使う場合は URL 末尾を `linux-aarch64` に変更すること。

#### 4-3-3. Docker Buildx プラグインのダウンロード

```bash
curl -fL https://github.com/docker/buildx/releases/download/v0.18.0/buildx-v0.18.0.linux-amd64 \
  -o /root/.docker/cli-plugins/docker-buildx
chmod +x /root/.docker/cli-plugins/docker-buildx
```

> Buildx は Dockerfile からのビルド時に内部的に利用される。Compose プラグインと同じディレクトリに配置することで、`docker buildx` サブコマンドとして利用可能になる。

------------------------------

### Step 4. 作業ディレクトリと設定ファイル配置

#### 4-4-1. 作業ディレクトリ作成

```bash
mkdir ~/dock
cd ~/dock
```

> `dock` は**任意のディレクトリ名**。自身の好きな名称に置き換えてよい。root 実行中のため実体は `/root/dock`。

#### 4-4-2. compose.yml 作成

```bash
vi compose.yml
```

以下の内容を貼り付けて保存する。

```yaml
services:
  # 1. データベースサーバー (MariaDB)
  db:
    image: mariadb:11.4
    container_name: wordpress-db
    restart: always
    environment:
      MARIADB_ROOT_PASSWORD: root_password_here
      MARIADB_DATABASE: wordpress
      MARIADB_USER: wp_user
      MARIADB_PASSWORD: wp_user_password
    volumes:
      - db_data:/var/lib/mysql
    command: --character-set-server=utf8mb4 --collation-server=utf8mb4_unicode_ci

  # 2. Webサーバー + PHP (Amazon Linux 2)
  web:
    build:
      context: .
      dockerfile: Dockerfile
    container_name: wordpress-web
    restart: always
    ports:
      - "80:80"
    volumes:
      - wp_data:/var/www/html
    depends_on:
      - db

volumes:
  db_data:
  wp_data:
```

> **ポート設定について**: `"80:80"` は「ホスト側 80番ポート → コンテナ側 80番ポート」へのマッピング。これによりブラウザから `http://<EC2パブリックIP>`(ポート番号省略 = 80)でアクセスできる。
>
> **セキュリティに関する注意**: 上記の compose.yml には DB パスワードが平文で記載されている。学習用途では問題ないが、本番運用や Git 管理する場合は **付録 A** の `.env` ファイル化を必ず行うこと。

#### 4-4-3. Dockerfile 作成

```bash
vi Dockerfile
```

以下の内容を貼り付けて保存する。

```dockerfile
FROM amazonlinux:2

# 1. 最低限のパッケージをインストール
RUN amazon-linux-extras enable php8.2 \
    && yum clean metadata \
    && yum install -y \
       httpd \
       php \
       php-mysqlnd \
       php-mbstring \
       tar \
       gzip \
       wget \
    && yum clean all

# 2. Apacheのパーマリンク対応(URL書き換え設定の有効化)
RUN sed -i '/<Directory "\/var\/www\/html">/,/<\/Directory>/ s/AllowOverride None/AllowOverride All/' \
    /etc/httpd/conf/httpd.conf

# 3. WordPress最新版をダウンロードして配置
WORKDIR /tmp
RUN wget https://wordpress.org/latest.tar.gz \
    && tar -xzf latest.tar.gz \
    && cp -r wordpress/* /var/www/html/ \
    && rm -rf wordpress latest.tar.gz

# 4. wp-config.php の作成と設定値の自動書き換え
WORKDIR /var/www/html
RUN cp wp-config-sample.php wp-config.php \
    && sed -i "s/'database_name_here'/'wordpress'/g" wp-config.php \
    && sed -i "s/'username_here'/'wp_user'/g" wp-config.php \
    && sed -i "s/'password_here'/'wp_user_password'/g" wp-config.php \
    && sed -i "s/'localhost'/'db'/g" wp-config.php \
    && chown -R apache:apache /var/www/html

EXPOSE 80
CMD ["/usr/sbin/httpd", "-D", "FOREGROUND"]
```

> **修正点について**: 提示原本では `wget https://wordpress.org` となっていたが、後続の `tar -xzf latest.tar.gz` で展開している実体は `latest.tar.gz` であるため、**URL を `https://wordpress.org/latest.tar.gz` に修正**している。

#### 4-4-4. ファイル配置の確認

```bash
ls -la ~/dock
```

`compose.yml` と `Dockerfile` が存在することを確認する。

------------------------------

### Step 5. コンテナのビルド・起動

#### 4-5-1. ビルド & 起動

```bash
cd ~/dock
docker compose up -d --build
```

| オプション | 役割 |
|-----------|------|
| `up` | サービスの作成と起動 |
| `-d` | デタッチドモード(バックグラウンド実行) |
| `--build` | キャッシュではなく Dockerfile から再ビルド |

初回ビルドは Amazon Linux 2 ベースイメージのプル、php8.2 インストール、WordPress ダウンロード等が走るため数分かかる。

#### 4-5-2. コンテナ状態確認

```bash
docker compose ps
```

以下のように 2 つとも `Up` または `running` であれば成功。

```
NAME            IMAGE           STATUS         PORTS
wordpress-web   dock-web        Up X seconds   0.0.0.0:80->80/tcp
wordpress-db    mariadb:11.4    Up X seconds   3306/tcp
```

#### 4-5-3. ログ確認(任意)

問題があるときのみ確認する。

```bash
docker compose logs web
docker compose logs db
```

------------------------------

### Step 6. 動作確認(WordPress 初期セットアップ画面)

#### 4-6-1. EC2 内部からの疎通確認

```bash
curl -I http://localhost
```

`HTTP/1.1 302 Found` で `Location: /wp-admin/install.php` が返れば、Apache + PHP + WordPress が正常稼働している。

#### 4-6-2. ブラウザからアクセス

ブラウザで以下にアクセスする。

```
http://<EC2のパブリックIP>
```

> ポート番号(`:80`)はブラウザが HTTP 通信時に自動で 80 番を使うため、URL には付ける必要はない。

WordPress の **「ようこそ」言語選択画面** が表示されれば構築成功。

> 表示されない場合は **5. トラブルシューティング** を参照。

------------------------------

### Step 7. WordPress 初期セットアップ

ブラウザ上で WordPress のセットアップウィザードを進め、管理画面(ダッシュボード)へログインできる状態にする。本ステップはサーバー側のコマンド操作は不要で、すべてブラウザ操作で完結する。

#### 4-7-1. 言語選択

`http://<EC2のパブリックIP>` でアクセスした際の最初の画面。

| 操作 | 内容 |
|------|------|
| 言語 | `日本語` を選択 |
| ボタン | 画面下部の **[続ける]** をクリック |

#### 4-7-2. ようこそ画面(サイト情報の入力)

「ようこそ」画面が表示されたら、以下の情報を入力する。

| 項目 | 入力例 | 説明 |
|------|--------|------|
| サイトのタイトル | `My WordPress Site` | サイトのタイトル。後から管理画面で変更可能 |
| ユーザー名 | `admin_user` | **WordPress 管理者のログイン名**。`admin` は推測されやすいため避ける |
| パスワード | (強固なパスワード) | デフォルトで強力なパスワードが自動生成される。**必ずメモまたは保存しておくこと** |
| パスワードの確認 | (パスワードが脆弱な場合のみ表示) | 「脆弱なパスワードの使用を確認」にチェック(非推奨) |
| メールアドレス | `admin@example.com` | パスワードリセット等で使用するため、**受信可能なアドレス**を推奨。学習用ならダミーで可 |
| 検索エンジンでの表示 | チェックなし(推奨) | チェックを入れると検索エンジンにインデックスされないよう要請する(学習用なら ON で OK) |

入力後、画面下部の **[WordPress をインストール]** をクリックする。

> **ユーザー名・パスワードは必ず控えること**。WordPress 管理画面に入る唯一のクレデンシャル。
> 紛失した場合は DB を直接編集するか、`wp-cli` 等での復旧操作が必要になる。

#### 4-7-3. インストール完了画面

「成功しました!」の画面が表示される。表示内容:

| 項目 | 内容 |
|------|------|
| ユーザー名 | 4-7-2 で入力したユーザー名 |
| ボタン | **[ログイン]** をクリック |

#### 4-7-4. ログイン

ログイン画面で 4-7-2 で設定した認証情報を入力する。

| 項目 | 入力内容 |
|------|---------|
| ユーザー名またはメールアドレス | 4-7-2 のユーザー名(またはメールアドレス) |
| パスワード | 4-7-2 のパスワード |
| ログイン状態を保存する | 任意 |

**[ログイン]** ボタンをクリックする。

> ログイン画面のURL: `http://<EC2のパブリックIP>/wp-login.php`(以降のログインで直接利用可能)

#### 4-7-5. 管理画面(ダッシュボード)表示

WordPress 管理画面(ダッシュボード)が表示されれば **構築完了**。

確認ポイント:

- [ ] 画面左上に「WordPress へようこそ!」のウィジェットが表示されている
- [ ] 左サイドバーに「投稿」「メディア」「固定ページ」「コメント」「外観」「プラグイン」等のメニューが表示されている
- [ ] 画面左上のサイト名(`My WordPress Site` 等)にマウスを当て、「サイトを表示」をクリックすると、公開サイト(デフォルトテーマ)が表示される

#### 4-7-6. 永続化の動作確認(任意)

ボリューム永続化が正しく機能していることを確認する。

```bash
# コンテナを停止・再起動(ボリュームは残す)
docker compose down
docker compose up -d
```

再度 `http://<EC2のパブリックIP>` にアクセスし、**初期セットアップ画面が表示されず**、サイト(またはログイン画面)に直接アクセスできれば、`db_data` / `wp_data` ボリュームによる永続化が成功している。

> `docker compose down -v`(`-v` 付き)で実行すると、ボリュームも削除されてしまい初期セットアップからやり直しになるため注意。

------------------------------

## 5. トラブルシューティング

### 5-1. ブラウザでタイムアウト/接続できない

| 確認項目 | 確認コマンド・方法 |
|---------|------------------|
| コンテナは起動しているか | `docker compose ps` で `wordpress-web` / `wordpress-db` が Up |
| EC2 内部から到達するか | `curl -I http://localhost` で 302 が返る |
| セキュリティグループに HTTP(80) 開放があるか | AWS コンソールで対象 SG のインバウンドルールを確認 |
| パブリック IP は変わっていないか | EC2 停止→起動で IP が変わる(Elastic IP 未割当時) |

### 5-2. ポート 80 が既に使用されている(`bind: address already in use`)

ホスト側で別の Web サーバー(httpd / nginx 等)が起動している可能性がある。

```bash
# 80番を使っているプロセスを確認
ss -tlnp | grep :80

# 該当サービスを停止(例: httpd)
systemctl stop httpd
systemctl disable httpd
```

その後、`docker compose up -d` を再実行する。

### 5-3. 「データベース接続確立エラー」が表示される

WordPress 画面まで到達したが DB エラーが出るケース。

```bash
# DBコンテナのログを確認
docker compose logs db

# webコンテナから db にホスト名解決できているか
docker compose exec web ping -c 2 db
```

主な原因:

- `wp-config.php` 内の DB 接続情報が compose.yml の `environment` と一致していない
- `db` コンテナが完全に起動する前に `web` が接続しに行った(`docker compose restart web` で再試行)

### 5-4. ビルド時に `amazon-linux-extras: command not found` などのエラー

ベースイメージが `amazonlinux:2023` になっていないか確認する。本手順書は **`amazonlinux:2`**(`amazon-linux-extras` が使える旧版)が前提。

```bash
grep "^FROM" ~/dock/Dockerfile
# → FROM amazonlinux:2 であることを確認
```

### 5-5. 設定を変更して作り直したい

```bash
# コンテナ停止・削除(ボリュームは保持)
docker compose down

# コンテナ・ボリュームを完全削除(DBとWordPressファイルも消える)
docker compose down -v

# 再ビルド & 起動
docker compose up -d --build
```

> `-v` を付けるとボリューム(`db_data` / `wp_data`)も削除されるため、**WordPress のセットアップを最初からやり直したい場合**に使う。データを残したい場合は `-v` を付けないこと。

### 5-6. ディスク容量が逼迫してきた

```bash
# 不要な image / コンテナ / ネットワークを一括削除
docker system prune -a

# ボリューム含めて削除する場合(データ消失注意)
docker system prune -a --volumes
```

------------------------------

## 6. 付録

### 付録 A. .env ファイルによる認証情報の外出し(推奨)

compose.yml に平文でパスワードを書く構成は学習用としては問題ないが、Git 管理や本番に近い構成にする場合は `.env` ファイル化を強く推奨する。

#### A-1. `.env` ファイル作成

`~/dock/.env` を新規作成する。

```bash
cd ~/dock
vi .env
```

```env
MARIADB_ROOT_PASSWORD=root_password_here
MARIADB_DATABASE=wordpress
MARIADB_USER=wp_user
MARIADB_PASSWORD=wp_user_password
```

#### A-2. compose.yml の修正

`db` サービスの `environment:` を以下のように書き換える。

```yaml
    environment:
      MARIADB_ROOT_PASSWORD: ${MARIADB_ROOT_PASSWORD}
      MARIADB_DATABASE: ${MARIADB_DATABASE}
      MARIADB_USER: ${MARIADB_USER}
      MARIADB_PASSWORD: ${MARIADB_PASSWORD}
```

> Compose は同階層の `.env` を自動的に読み込み、`${変数名}` を展開する。

#### A-3. Dockerfile 側について

現状の `Dockerfile` は `wp-config.php` 内の値を `sed` でハードコード書き換えしている。本格的に `.env` 化する場合は、Dockerfile 側でハードコードせず、**`wp-config.php` を環境変数から動的に生成する構成**(`getenv()` を使う形)に改修するのが望ましい。本手順書では学習スコープ外として割愛する。

#### A-4. `.gitignore` 設定

`.env` は絶対に Git にコミットしないこと。

```bash
echo ".env" >> ~/dock/.gitignore
```

### 付録 B. よく使う Docker / Compose コマンド

| コマンド | 役割 |
|---------|------|
| `docker compose up -d` | バックグラウンド起動 |
| `docker compose up -d --build` | 再ビルドして起動 |
| `docker compose down` | コンテナ停止・削除(ボリューム保持) |
| `docker compose down -v` | コンテナ + ボリュームを削除 |
| `docker compose ps` | サービス状態確認 |
| `docker compose logs -f web` | web のログをリアルタイム表示 |
| `docker compose exec web bash` | wordpress-web コンテナに bash で入る |
| `docker compose exec db mariadb -u root -p` | wordpress-db コンテナで MariaDB CLI 起動 |
| `docker images` | ローカルのイメージ一覧 |
| `docker volume ls` | ボリューム一覧 |

### 付録 C. データのバックアップ(任意)

WordPress 運用を想定する場合のバックアップ例。

```bash
# DB ダンプ
docker compose exec db sh -c \
  'mariadb-dump -u root -p"$MARIADB_ROOT_PASSWORD" wordpress' > wp_db_backup.sql

# wp-content のバックアップ
docker compose exec web tar czf - /var/www/html/wp-content > wp_content_backup.tar.gz
```

------------------------------

以上
