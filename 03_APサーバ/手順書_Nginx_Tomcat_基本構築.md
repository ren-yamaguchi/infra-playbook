# NginxとTomcatを用いたWeb/APサーバーの構築

------------------------------

## 1. ドキュメント情報

| 項目 | 内容 |
|------|------|
| 手順書名 | 手順書_Nginx_Tomcat_基本構築 |
| 作成日 | 2026-05-19 |
| 最終更新日 | 2026-05-28 |
| バージョン | v1.1 |
| 対象環境 | AWS |

> **改訂履歴**
>
> | バージョン | 日付 | 変更内容 |
> |-----------|------|---------|
> | v1.0 | 2026-05-19 | 初版作成 |
> | v1.1 | 2026-05-28 | 一部変更 |

------------------------------

## 2. 目的・概要

### 2-1. 目的

> 本手順書では， Webサーバーとして「Nginx」，APサーバーとして「Tomcat」を用いて，情報共有OSSである「knowledge」のWebページを表示させるための構築手順について説明する．
> 構築後はブラウザで「`http://<EC2のパブリックIP>/knowledge`」にアクセスし，Webページを閲覧可能な状態を目指す．

### 2-2. 構成概要（アーキテクチャ）

```
[ローカルPC（ブラウザ）]
       |
       | HTTP（80）
       v
[EC2: Amazon Linux 2023]
  ├── Nginx（Webサーバー / 80番ポート）
  │     └─ /knowledge へのリクエストを127.0.0.1:8080へプロキシ転送
  └── Tomcat（APサーバー / 8080番ポート）
        └─ /usr/local/tomcat/webapps/knowledge
              └─ knowledge（Java製の情報共有OSS）
```

### 2-3. 完成イメージ（ゴール定義）

- [ ] ブラウザで「`http://<EC2のパブリックIP>`」にアクセスし，Nginxの応答（Welcomeページ または 404 Not Found）が返ってくる（Nginxが起動していることが確認できる）
- [ ] ブラウザで「`http://<EC2のパブリックIP>/knowledge`」にアクセスし，knowledgeのWebページを閲覧できる

------------------------------

## 3. 前提条件・準備

### 3-1. 環境要件

| 項目 | 要件 |
|------|------|
| OS | AWS（Amazon Linux 2023）,WSL（Ubuntu 24.04） |
| Webサーバー | Nginx |
| APサーバー | Tomcat |

### 3-2. セキュリティグループ設定

| タイプ | プロトコル | ポート範囲 | ソース | 説明 |
|-------|------------|----------|--------|------|
| SSH | TCP | 22 | マイIP | ローカルPCからSSHで接続 |
| HTTP | TCP | 80 | マイIP | ローカルPCのブラウザから接続 |

### 3-3. リンク一覧

| 項目名 | 目的 |
|-------|------|
| `https://corretto.aws/downloads/latest/amazon-corretto-8-x64-linux-jdk.tar.gz` | JDK（Amazon社のCorretto） |
| `https://downloads.apache.org/tomcat/tomcat-9/v9.0.118/bin/apache-tomcat-9.0.118.tar.gz` | Tomcatのサーバーソフト |
| `https://github.com/support-project/knowledge/releases/download/v1.13.1/knowledge.war` | knowledgeの本体 |

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

# 最新パッケージへの更新（dnf updateはupgradeと同義のため1回でよい）
dnf update -y

# システムの時間を日本時間に設定(これによりログを確認した時の時間が日本時間で表示されるようになる)
timedatectl set-timezone Asia/Tokyo
```

------------------------------

### Step 2 JDKの手動インストールと環境変数設定

**目的：** JDKを手動でインストールした時の設定手順と環境変数設定について説明する．
具体的に説明すると，`dnf install`でシステムが自動設定していることを手動で行うということである．

#### 操作手順

```bash
# 作業ディレクトリの移動
cd /home/ec2-user

# JDKのダウンロード
wget https://corretto.aws/downloads/latest/amazon-corretto-8-x64-linux-jdk.tar.gz

# ダウンロードできているかの確認
ll amazon-corretto-8-x64-linux-jdk.tar.gz

# JDKを解凍
tar zxf amazon-corretto-8-x64-linux-jdk.tar.gz

# JDKを移動
mv amazon-corretto-8.492.09.2-linux-x64 /opt

# シェル設定ファイルのバックアップ取得（原本保存）
cp /root/.bashrc{,.org}

# シェル設定ファイルの追記
vi /root/.bashrc

    #---設定ファイルの一番下に追記-------------------------------------------------------------
    export JAVA_HOME=/opt/amazon-corretto-8.492.09.2-linux-x64
    export PATH=$JAVA_HOME/bin:$PATH
    #------------------------------------------------------------------------------------

# シェル設定ファイルの設定反映前のパス確認
echo $PATH

# シェル設定ファイルの設定を反映
source /root/.bashrc

# シェル設定ファイルの設定反映前のパス確認
echo $PATH

    #------------------------------
    追記したものが表示されていれば成功
    #------------------------------

```

------------------------------

### Step 3 Tomcatの設定

**目的：** Tomcatのダウンロードと手動設定

#### 操作手順

```bash
# Tomcatユーザーの作成
useradd -s /sbin/nologin tomcat

# Tomcatをダウンロード
wget https://downloads.apache.org/tomcat/tomcat-9/v9.0.118/bin/apache-tomcat-9.0.118.tar.gz

# ダウンロードできているかの確認
ll apache-tomcat-9.0.118.tar.gz

# Tomcatの解凍
tar zxf apache-tomcat-9.0.118.tar.gz

# 作業ディレクトリの移動
cd /usr/local

# Tomcatの移動
mv /home/ec2-user/apache-tomcat-9.0.118 ./

# Tomcatの所有ユーザーと所有グループを変更
chown -R tomcat:tomcat apache-tomcat-9.0.118/

# シンボリックリンクの作成
ln -s /usr/local/apache-tomcat-9.0.118/ tomcat

# Tomcatの環境変数設定ファイルの作成と設定記入
vi /usr/local/tomcat/bin/setenv.sh

    #---以下を記入--------------------------------------
    #!/bin/sh
    export CATALINA_HOME=/usr/local/tomcat
    export JAVA_HOME=/opt/amazon-corretto-8.492.09.2-linux-x64
    export JAVA_OPTS="-Xms128m -Xmx512m"

    export PATH=$JAVA_HOME/bin:$PATH
    #--------------------------------------------------

# Tomcatサーバーのネットワーク構成定義ファイルのバックアップ取得（原本保存）
cp /usr/local/tomcat/conf/server.xml{,.org}

# Tomcatサーバーのネットワーク構成定義ファイルの編集
vi /usr/local/tomcat/conf/server.xml

    #---以下のように編集-----------------------
    #---変更前--------------------------------
    <Host name="localhost" appBase="webapps"
        unpackWARs="true" autoDeploy="true">
    #-----------------------------------------
    #---変更後--------------------------------
    <Host name="localhost" appBase="webapps"
        unpackWARs="false" autoDeploy="false">
    #-----------------------------------------

# TomcatをLinuxのサービスとして自動起動・管理するための設定ファイルの作成と設定記入
vi /etc/systemd/system/tomcat.service

    #---以下を記入------------------------------
    [Unit]
    Description=Apache Tomcat 9
    After=network.target

    [Service]
    User=tomcat
    Group=tomcat
    Type=forking
    PIDFile=/usr/local/tomcat/tomcat.pid

    ExecStart=/usr/local/tomcat/bin/startup.sh
    ExecStop=/usr/local/tomcat/bin/shutdown.sh

    [Install]
    WantedBy=multi-user.target
    #--------------------------------------------

# Tomcatサービスの権限変更
chmod 644 /etc/systemd/system/tomcat.service

# LinuxシステムにTomcatサービスの設定を再読み込み
systemctl daemon-reload

# Tomcatの起動と自動起動設定
systemctl enable --now tomcat

# Tomcatの起動確認
systemctl status tomcat | less

# Tomcatの自動起動設定確認
systemctl is-enabled tomcat
```

------------------------------

### Step 4 Nginxの設定

**目的：** Nginxのシステム設定と転送設定の手順について説明する．

#### 操作手順

```bash
# Nginxのインストール
dnf install -y nginx

# Nginxのプロキシ設定ファイルの作成と記入
vi /etc/nginx/conf.d/proxy.conf

    #---以下のように記入---------------------------------------------------
    server {
        listen       80;
        server_name  _;

        # ルート（/）へのアクセス時はNginxデフォルトのWelcomeページを表示
        location / {
            root   /usr/share/nginx/html;
            index  index.html index.htm;
        }

        # /knowledge へのアクセスはTomcatへプロキシ
        location /knowledge {
            proxy_pass http://127.0.0.1:8080/knowledge;

            proxy_set_header Host $host;
            proxy_set_header X-Real-IP $remote_addr;
            proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
            proxy_set_header X-Forwarded-Proto $scheme;
        }
    }
    #---------------------------------------------------------------------

# Nginxの設定ファイルの構文チェック（test is successful と表示されれば問題なし）
nginx -t

# Nginxの起動と自動起動設定
systemctl enable --now nginx

# Nginxの起動確認
systemctl status nginx | less

# Nginxの自動起動設定確認
systemctl is-enabled nginx
```

> **確認：** Nginxの起動と設定の確認
> 
> ブラウザで「`http://<EC2のパブリックIP>`」にアクセスし，「Welcome to nginx!」のページが表示されれば成功

------------------------------

### Step 5 knowledgeアプリケーションの設定

**目的：** knowledgeアプリケーションの設定手順について説明する．

#### 操作手順

```bash
# knowledgeを配置するディレクトリの作成
mkdir /usr/local/tomcat/webapps/knowledge

# 作業ディレクトリの移動
cd /usr/local/tomcat/webapps/knowledge/

# knowledgeのダウンロード
wget https://github.com/support-project/knowledge/releases/download/v1.13.1/knowledge.war

# ダウンロードできているかの確認
ll knowledge.war

# knowledgeの解凍
jar xf knowledge.war

# 不要となったファイルの削除
rm knowledge.war

    #---下記のように表示されたら「yes」を入力してエンター
    rm: remove regular file 'knowledge.war'? yes
    #--------------------------------------------

# カレントディレクトリの親ディレクトリに移動
cd ..

# knowledgeディレクトリとその中のファイルとサブディレクトリの所有ユーザーと所有グループの変更
chown -R tomcat:tomcat knowledge/

# Tomcatの再起動
systemctl restart tomcat

# Nginxの設定再読み込み（プロキシ先のTomcatが起動完了したため）
systemctl reload nginx
```

> **確認：** NginxとTomcatの連携確認と今回のゴールの確認
>
> ブラウザで「`http://<EC2のパブリックIP>/knowledge`」にアクセスし，knowledgeのwebページが表示されれば成功

------------------------------

## 付録

### A. コマンド解説

| コマンド | 説明 |
|---------|------|
| `nginx -t` | Nginxの設定ファイルの構文チェック。`test is successful` と表示されれば問題なし。 |
| `systemctl reload <サービス>` | サービスを停止せずに設定だけ再読み込みする。 |

------------------------------

### B. 設定ファイル解説

```
location /knowledge {
    proxy_pass http://127.0.0.1:8080/knowledge;
    proxy_set_header Host $host;
    proxy_set_header X-Real-IP $remote_addr;
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto $scheme;
}
```

- `location /knowledge`：`/knowledge` で始まるURLへのリクエストを処理する。
- `proxy_pass`：転送先（Tomcatの8080番ポート）を指定。
- `proxy_set_header`：Tomcatへ転送する際にリクエストヘッダを書き換える。クライアントの本来のIP（`X-Real-IP`）やプロトコル（`X-Forwarded-Proto`）をTomcatに伝えるために設定する。

------------------------------

### C. 用語解説

| 用語 | 説明 |
|------|------|
| Nginx | 高速・軽量なWebサーバー兼リバースプロキシ。同時接続数の多い環境で強みを発揮する。 |
| Tomcat | Java製のAPサーバー。 |
| リバースプロキシ | クライアントからのリクエストを受け取り、裏側のサーバーに転送する仕組み。 |

------------------------------

### D. 補足解説

- **ApacheとNginxの違い**
  - Apache：プロセスやスレッドベースの古典的な設計。設定の自由度が高く、`.htaccess`によるディレクトリ単位の設定変更が可能。
  - Nginx：イベント駆動型の設計で、同時接続数が多くてもメモリ消費が少ない。設定ファイルはシンプル。
  - 静的コンテンツ配信やリバースプロキシ用途ではNginxが好まれることが多い。

- **`server_name _;` の意味**
  `_` はNginxにおける「任意のホスト名にマッチ」を示すワイルドカード。特定のドメイン名を指定しない場合に使う。
