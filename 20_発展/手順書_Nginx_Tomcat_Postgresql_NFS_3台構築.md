# Nginx，Tomcat，Postgresqlを用いたWeb/AP/DBサーバーの3台構築（NFS連携）

------------------------------

## 1. ドキュメント情報

| 項目 | 内容 |
|------|------|
| 手順書名 | 手順書_Nginx_Tomcat_Postgresql_NFS_3台構築 |
| 作成日 | 2026-05-31 |
| 最終更新日 | 2026-06-16 |
| バージョン | v1.1 |
| 対象環境 | AWS |

> **改訂履歴**
>
> | バージョン | 日付 | 変更内容 |
> |-----------|------|---------|
> | v1.0 | 2026-05-31 | 初版作成 |
> | v1.1 | 2026-06-16 | 構成図追加、セキュリティグループの番号誤り修正(3-2-1重複)、dnf重複解消、NFSパッケージの明示インストール追加、Nginx設定改善（location /追加、nginx -t追加、reload追加）、tomcat.serviceにPIDFile追加、各Stepに【実施対象】明示、付録充実 |

------------------------------

## 2. 目的・概要

### 2-1. 目的

> 本手順書では， それぞれ別のEC2でWebサーバーとして「Nginx」，APサーバーとして「Tomcat」，DBサーバーとして「Postgresql」を用いて，情報共有OSSである「knowledge」を運用し，NFSシステムで「knowledge」アプリケーションのデータ共有を行うインフラ環境の構築手順について説明する．
> 構築後はブラウザで「`http://<WebサーバーのパブリックIP>/knowledge`」にアクセスし，投稿をした時のデータがPostgresqlやNFSシステムで共有しているディレクトリで確認できる状態を目指す．

### 2-2. 構成概要（アーキテクチャ）

```
[ローカルPC（ブラウザ）]
       |
       | HTTP（80）
       v
┌────────────────────────── VPC ──────────────────────────┐
│                                                          │
│  [EC2: Webサーバー]                                       │
│    └─ Nginx（80番ポート） / upstream knowledge_cluster    │
│         ├─ / → Nginxデフォルトページ                       │
│         └─ /knowledge → APサーバー:8080 へプロキシ転送     │
│                                |                         │
│                                v                         │
│  [EC2: APサーバー]                                        │
│    ├─ Tomcat（8080番ポート） / knowledge（OSS）            │
│    └─ NFSクライアント                                      │
│         └─ /var/lib/knowledge_data ─┐                    │
│                                     │ NFSマウント         │
│                                     │ (2049)             │
│                                     v                    │
│  [EC2: DBサーバー]                                        │
│    ├─ PostgreSQL（5432番ポート）                          │
│    └─ NFSサーバー                                          │
│         └─ /srv/nfs/knowledge_data                       │
│                                                          │
└──────────────────────────────────────────────────────────┘
```

### 2-3. 完成イメージ（ゴール定義）

- [ ] ブラウザで「`http://<WebサーバーのパブリックIP>`」にアクセスし，「Welcome to nginx!」と表示
- [ ] ブラウザで「`http://<WebサーバーのパブリックIP>/knowledge`」にアクセスし，Webページを閲覧できる
- [ ] ブラウザで「`http://<WebサーバーのパブリックIP>/knowledge`」にアクセスし，サインインして投稿した時に，Postgresqlと接続できている
- [ ] knowledgeで投稿した添付ファイル等のデータが，NFS共有ディレクトリ（DBサーバー側の `/srv/nfs/knowledge_data`）で確認できる

------------------------------

## 3. 前提条件・準備

### 3-1. 環境要件

| 項目 | 要件 |
|------|------|
| OS | AWS（Amazon Linux 2023）,WSL（Ubuntu 24.04） |
| Webサーバー | Nginx |
| APサーバー | Tomcat 9 |
| DBサーバー | PostgreSQL 15 + NFSサーバー |

### 3-2. セキュリティグループ設定

#### 3-2-1. Webサーバーのインバウンドルール

| タイプ | プロトコル | ポート範囲 | ソース | 説明 |
|-------|------------|----------|--------|------|
| SSH | TCP | 22 | マイIP | ローカルPCからSSHで接続 |
| HTTP | TCP | 80 | マイIP | ローカルPCのブラウザから接続 |

#### 3-2-2. APサーバーのインバウンドルール

| タイプ | プロトコル | ポート範囲 | ソース | 説明 |
|-------|------------|----------|--------|------|
| SSH | TCP | 22 | マイIP | ローカルPCからSSHで接続 |
| カスタムTCP | TCP | 8080 | VPCのCIDR | VPC内のサーバーからのプロキシ転送許可 |

#### 3-2-3. DBサーバーのインバウンドルール

| タイプ | プロトコル | ポート範囲 | ソース | 説明 |
|-------|------------|----------|--------|------|
| SSH | TCP | 22 | マイIP | ローカルPCからSSHで接続 |
| PostgreSQL | TCP | 5432 | APサーバーのプライベートIP | APサーバーからの接続許可 |
| NFS | TCP | 2049 | VPCのCIDR | VPC内のサーバーからのマウント許可 |

### 3-3. リンク一覧

| 項目名 | 目的 |
|-------|------|
| `https://corretto.aws/downloads/latest/amazon-corretto-8-x64-linux-jdk.tar.gz` | JDK（Amazon社のCorretto） |
| `https://downloads.apache.org/tomcat/tomcat-9/v9.0.118/bin/apache-tomcat-9.0.118.tar.gz` | Tomcatのサーバーソフト |
| `https://github.com/support-project/knowledge/releases/download/v1.13.1/knowledge.war` | knowledgeの本体 |
| `https://jdbc.postgresql.org/download/postgresql-42.6.2.jar` | JDBCドライバ |

------------------------------

## 4. 構築手順（詳細）

> **注意事項**
> - コマンド中の `<山カッコ>` は自分の環境の値に置き換えること
> - 各Stepの見出し末尾に **【実施対象：●●サーバー】** を明示しているので，対象のサーバーで実施すること

------------------------------

### Step 1 システム設定 【実施対象：全サーバー共通】

**目的：** システムの変更と更新を行う．Webサーバー・APサーバー・DBサーバーのすべてで同じ手順を実施する．

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

# ホスト名を変更（例：web-server, ap-server, db-server）
hostnamectl set-hostname <任意の名前>

# ホスト名の変更を反映させるため一度exitし再ログイン
exit

# 再度rootユーザーにスイッチ（ホスト名がプロンプトに反映されることを確認）
sudo su -
```

------------------------------

### Step 2 Nginxの設定 【実施対象：Webサーバー】

**目的：** Nginx のシステム設定と転送設定の手順について説明する．

#### 操作手順

```bash
# Nginxのインストール
dnf install -y nginx

# Nginxのプロキシ設定ファイルの作成と記入
vi /etc/nginx/conf.d/proxy.conf

    #---以下を記入--------------------------------------------------------
    upstream knowledge_cluster {
        ip_hash;
        server <APサーバーのプライベートIP>:8080;
    }
    server {
        listen       80;
        server_name  _;

        # ルート（/）へのアクセス時はNginxデフォルトのWelcomeページを表示
        location / {
            root   /usr/share/nginx/html;
            index  index.html index.htm;
        }

        # /knowledge へのアクセスはupstreamで定義したAPサーバーへプロキシ
        location /knowledge {
            proxy_pass http://knowledge_cluster/knowledge;

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
> ブラウザで「`http://<WebサーバーのパブリックIP>`」にアクセスし，「*Welcome to nginx!*」のページが表示されれば成功

------------------------------

### Step 3 JDKの手動インストールと環境変数設定 【実施対象：APサーバー】

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

    #---設定ファイルの一番下に追記--------------------------------
    export JAVA_HOME=/opt/amazon-corretto-8.492.09.2-linux-x64
    export PATH=$JAVA_HOME/bin:$PATH
    #----------------------------------------------------------

# シェル設定ファイルの設定反映前のパス確認
echo $PATH

# シェル設定ファイルの設定を反映
source /root/.bashrc

# シェル設定ファイルの設定反映後のパス確認
echo $PATH

    #------------------------------
    追記したものが表示されていれば成功
    #------------------------------
```

------------------------------

### Step 4 Tomcatの設定 【実施対象：APサーバー】

**目的：** Tomcatのダウンロードと手動設定

Amazon Linux 2023 の標準リポジトリに Tomcat のパッケージはないため，手動で設定を行う．

#### 操作手順

```bash
# Tomcatユーザーの作成
useradd -s /sbin/nologin tomcat

# TomcatユーザーのUIDを確認（NFSサーバー側で同じUIDのユーザーを作るため必ず控えておくこと）
id tomcat

# 作業ディレクトリの移動
cd /home/ec2-user

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

    #---以下を記入---------------------------------------------
    #!/bin/sh
    export CATALINA_HOME=/usr/local/tomcat
    export JAVA_HOME=/opt/amazon-corretto-8.492.09.2-linux-x64
    export JAVA_OPTS="-Xms128m -Xmx512m"
    export KNOWLEDGE_HOME=/var/lib/knowledge_data

    export PATH=$JAVA_HOME/bin:$PATH
    #---------------------------------------------------------

# Tomcatの環境変数設定ファイルの所有ユーザーと所有グループを変更
chown tomcat:tomcat /usr/local/tomcat/bin/setenv.sh

# Tomcatの環境変数設定ファイルの権限変更
chmod 750 /usr/local/tomcat/bin/setenv.sh

# knowledgeアプリケーションのデータ保存先を作成（後でNFSマウントポイントとなる）
mkdir /var/lib/knowledge_data

# knowledgeアプリケーションのデータ保存先の所有ユーザーと所有グループを変更
chown tomcat:tomcat /var/lib/knowledge_data

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

### Step 5 NFSサーバー側の公開ディレクトリ設定と同一UIDのユーザー作成 【実施対象：DBサーバー】

**目的：** NFSサーバーで公開するディレクトリの設定とAPサーバーのTomcatユーザーと同じUIDのユーザーを作成する手順を説明する．

> **重要：** NFSはUID（ユーザーID）でアクセス制御するため，APサーバーとDBサーバーで **同じUID** のtomcatユーザーが必要．Step4で確認したUIDを指定すること．

#### 操作手順

```bash
# NFSサーバーパッケージのインストール
dnf install -y nfs-utils

# NFSクライアントであるAPサーバーのTomcatユーザーと同じUIDのTomcatユーザーを作成
useradd -u <APサーバーのid tomcatで確認したUID> -s /sbin/nologin tomcat

# TomcatユーザーのUIDがAPサーバーと同一か確認
id tomcat

# NFSの公開ディレクトリを親ディレクトリも一緒に作成
mkdir -p /srv/nfs/knowledge_data

# 公開ディレクトリの所有ユーザーと所有グループをTomcatに変更
chown tomcat:tomcat /srv/nfs/knowledge_data/

# NFSの公開ディレクトリ設定ファイルのバックアップ取得（原本保存）
cp /etc/exports{,.org}

# NFSの公開ディレクトリ設定ファイルの追記
vi /etc/exports

    #---以下を追記--------------------------------------------------------------
    # NFSv4 疑似ルート（Pseudo Root）の定義
    /srv/nfs             <VPCのCIDR>(rw,sync,fsid=0,crossmnt,no_subtree_check)

    # 個別の公開ディレクトリ
    /srv/nfs/knowledge_data <VPCのCIDR>(rw,sync,no_subtree_check,root_squash)
    #--------------------------------------------------------------------------

# NFSの起動と自動起動設定
systemctl enable --now nfs-server

# NFSの起動確認
systemctl status nfs-server

# NFSの自動起動設定確認
systemctl is-enabled nfs-server

# 公開状態の確認
exportfs -v
```

------------------------------

### Step 6 NFSクライアントのマウント設定 【実施対象：APサーバー】

**目的：** NFSクライアント側のマウントポイントの作成とマウント設定

#### 操作手順

```bash
# NFSクライアントパッケージのインストール
dnf install -y nfs-utils

# マウント定義ファイルのバックアップ取得（原本保存）
cp /etc/fstab{,.org}

# マウント定義ファイルの追記
vi /etc/fstab

    #---以下を一番下に追記---------------------------------------------------------------------------------
    <NFSサーバー(DBサーバー)のプライベートIP>:<公開ディレクトリパス> <マウントポイントパス> nfs rw,nfsvers=4,soft,timeo=60,retrans=2,nofail,x-systemd.automount 0 0
    #----------------------------------------------------------------------------------------------------
    例：<DBサーバーのプライベートIP>:/knowledge_data /var/lib/knowledge_data nfs rw,nfsvers=4,soft,timeo=60,retrans=2,nofail,x-systemd.automount 0 0
    
    ※ NFSサーバー側で疑似ルート(fsid=0)を設定しているため，<公開ディレクトリパス>は疑似ルート以降のみの宣言でOK
       （/srv/nfs/knowledge_data ではなく /knowledge_data と書く）

# systemdに設定変更を通知
systemctl daemon-reload

# マウントポイントをマウント
mount <マウントポイントパス>

# マウントできているか確認
df -h
    #---以下のようになっていれば成功
    <NFSサーバーのプライベートIP>:<公開ディレクトリパス>    xxxxx   xxxxx   xxxxx   xx% <マウントポイントパス>
    #----------------------------
```

> **確認：** NFSサーバーとクライアントが共有できているか確認
>
> 今回の場合は、ログイン不可のTomcatユーザーが所有ユーザーとなっているので以下のコマンドでNFSクライアント側のマウントポイントにファイルを作成し、NFSサーバーの公開ディレクトリで確認する．
> 1. NFSクライアント（APサーバー）側で「`sudo su -s /bin/bash -c "touch <マウントポイントパス>/test.txt" tomcat`」を実行
> 2. NFSサーバー（DBサーバー）側で「`ls -l <公開ディレクトリ>`」
> 作成したファイルが確認でき，**所有者がtomcatになっていれば成功**（UIDが一致している証拠）

------------------------------

### Step 7 knowledgeアプリケーションの設定 【実施対象：APサーバー】

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
```

**【実施対象：Webサーバー】** Tomcat側のアプリ配置が完了したのでNginxの設定を再読み込み

```bash
# Nginxの設定再読み込み
systemctl reload nginx
```

> **確認：** NginxとTomcatの連携確認と今回のゴールの確認
>
> ブラウザで「`http://<WebサーバーのパブリックIP>/knowledge`」にアクセスし，knowledgeのwebページが表示されれば成功

------------------------------

### Step 8 Postgresqlの設定 【実施対象：DBサーバー】

**目的：** Postgresqlの設定手順について説明する．

#### 操作手順

```bash
# Postgresqlをインストール
dnf install -y postgresql15-server

# Postgresqlの初期化
postgresql-setup --initdb

# Postgresqlの起動と自動起動設定
systemctl enable --now postgresql

# Postgresqlの状態確認
systemctl status postgresql | less

# Postgresqlの自動起動設定確認
systemctl is-enabled postgresql

# Postgresqlの特権ユーザー（postgres）でpostgresqlにログイン
sudo -u postgres psql

	# ユーザー作成とパスワード設定
	create user <ユーザー名> with password '<パスワード>';
	
	# データベース作成とその所有者の設定
	create database <データベース名> owner <ユーザー名>;

	# ログアウト
	\q

# Postgresqlの接続設定ファイルのバックアップ取得（原本保存）
cp /var/lib/pgsql/data/pg_hba.conf{,.org}

# Postgresqlの接続設定ファイルの編集
vi /var/lib/pgsql/data/pg_hba.conf

	#---一番下に追記--------------------------------------------------------------------------------
	host    <データベース名>       <ユーザー名>       <VPCのCIDR>            scram-sha-256
	#----------------------------------------------------------------------------------------------

# Postgresqlの待ち受けアドレス設定ファイルのバックアップ取得（原本保存）
cp /var/lib/pgsql/data/postgresql.conf{,.org}

# Postgresqlの待ち受けアドレス設定ファイルの編集
vi /var/lib/pgsql/data/postgresql.conf

    #---以下のように編集（コメントアウト「#」を外して書き換える）----
	listen_addresses = '<自サーバー（DBサーバー）のプライベートIP>'
	#----------------------------------------------------------

# Postgresqlの再起動
systemctl restart postgresql.service
```

------------------------------

### Step 9 JDBCドライバの入れ替えと接続設定 【実施対象：APサーバー】

**目的：** JDBCドライバの入れ替えと接続設定について説明する．

#### 操作手順

```bash
# knowledgeアプリケーションの古いJDBCドライバを削除
rm /usr/local/tomcat/webapps/knowledge/WEB-INF/lib/postgresql-42.1.4.jar

# 作業ディレクトリの移動
cd /usr/local/tomcat/lib/

# Postgresqlと互換性のあるJDBCドライバのダウンロード
wget https://jdbc.postgresql.org/download/postgresql-42.6.2.jar

# JDBCドライバの所有ユーザーと所有グループの変更
chown tomcat:tomcat postgresql-42.6.2.jar

# データベース接続先設定ファイルの作成と記入
sudo su -s /bin/bash -c "vi /var/lib/knowledge_data/custom_connection.xml" tomcat

    #---以下を記入---------------------------------------------------------
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <connectionConfig>
        <name>custom</name>
        <driverClass>org.postgresql.Driver</driverClass>
        <URL>jdbc:postgresql://<DBサーバーのプライベートIP>:5432/<Postgresql設定時のデータベース名></URL>
        <user><Postgresql設定時のユーザー名></user>
        <password><Postgresql設定時のパスワード></password>
        <schema>public</schema>
        <maxConn>100</maxConn>
        <autocommit>false</autocommit>
    </connectionConfig>
    #---------------------------------------------------------------------

# 設定反映のためTomcatを再起動
systemctl restart tomcat
```

> **確認：** TomcatとPostgresqlの接続確認と今回のゴールの確認
>
> **方法1：** knowledgeアプリケーションのGUI画面から確認
> 
> 1. ブラウザで「`http://<WebサーバーのパブリックIP>/knowledge`」にアクセス
> 2. サインイン画面にリダイレクトされるので管理者でログイン
>   ユーザー名：admin パスワード：admin123
> 3. 画面右上のメニューからシステム設定を選択
> 4. データ管理のデータベースの接続先変更を選択
>   `custom_connection.xml`で設定したものが反映されていれば成功

> **方法2：** DBサーバーで作成したデータベースの中にテーブルが作成されているか確認
>
> 1. DBサーバーでpostgresqlにPostgresユーザーでログイン `sudo -u postgres psql`
> 2. 作成したデータベースに接続 `\c <作成したデータベース名>`
> 3. テーブル一覧を確認 `\dt`
>   テーブル一覧が表示されれば成功（knowledge起動時にテーブルが自動作成される）

------------------------------

## 付録

### A. コマンド解説

| コマンド | 説明 |
|---------|------|
| `hostnamectl set-hostname <名前>` | システムのホスト名を変更する。プロンプトへの反映には再ログインが必要。 |
| `id <ユーザー名>` | ユーザーのUID/GIDを確認する。NFS構成では特に重要。 |
| `useradd -u <UID> -s /sbin/nologin <名前>` | 指定したUIDでログイン不可のユーザーを作成する。 |
| `exportfs -v` | NFSの現在の公開状態を確認する。 |
| `mount <マウントポイント>` | `/etc/fstab` の定義に従ってマウントする。 |
| `df -h` | マウントされているファイルシステムを人間に読みやすい形式（K/M/G）で表示。 |
| `nginx -t` | Nginxの設定ファイルの構文チェック。 |
| `systemctl reload <サービス>` | サービスを停止せずに設定だけ再読み込み。 |

------------------------------

### B. 設定ファイル解説

**`/etc/nginx/conf.d/proxy.conf`（Webサーバー）**

```
upstream knowledge_cluster {
    ip_hash;
    server <APサーバーのプライベートIP>:8080;
}
```

- `upstream`：転送先のグループを定義する。複数台のAPサーバーを束ねる時に便利。
- `ip_hash`：クライアントのIPに基づいて常に同じAPサーバーに転送する（セッション固定，スティッキーセッション）。
- 1台の今は `ip_hash` の意味は薄いが，将来的にAPサーバーを増やす想定として残してある。

**`/etc/exports`（DBサーバー＝NFSサーバー）**

```
/srv/nfs             <VPCのCIDR>(rw,sync,fsid=0,crossmnt,no_subtree_check)
/srv/nfs/knowledge_data <VPCのCIDR>(rw,sync,no_subtree_check,root_squash)
```

- `rw`：読み書き許可。
- `sync`：書き込みを即座にディスクに反映（データ整合性重視）。
- `fsid=0`：このディレクトリをNFSv4の「疑似ルート」とする。クライアントは `<IP>:/` でマウントできるようになる。
- `crossmnt`：疑似ルート以下に別のマウントポイントがある場合に通り抜けを許可。
- `no_subtree_check`：サブツリーチェック無効化（パフォーマンス向上，モダンなNFSv4では推奨）。
- `root_squash`：クライアントのrootユーザーをnobodyにマップ（セキュリティ）。

**`/etc/fstab`（APサーバー＝NFSクライアント）**

```
<NFSサーバーIP>:/knowledge_data /var/lib/knowledge_data nfs rw,nfsvers=4,soft,timeo=60,retrans=2,nofail,x-systemd.automount 0 0
```

- `nfsvers=4`：NFSv4を使う。
- `soft`：NFSサーバーが応答しない時に一定時間後にI/Oをエラーにする（システムを止めない）。
- `timeo=60`：タイムアウト時間（1/10秒単位なので6秒）。
- `retrans=2`：リトライ回数。
- `nofail`：起動時にNFSが利用不可でもブート失敗にしない。
- `x-systemd.automount`：実際にアクセスがあった時に初めてマウントする（遅延マウント）。

**`/var/lib/knowledge_data/custom_connection.xml`（APサーバー）**

knowledgeアプリケーションのDB接続先を上書きする独自設定ファイル。NFS共有上に置くことで，将来APサーバーが複数台になっても同じ設定を共有できる。

------------------------------

### C. 用語解説

| 用語 | 説明 |
|------|------|
| NFS | Network File System。ネットワーク越しにファイルシステムを共有するUNIX標準プロトコル。 |
| 疑似ルート（Pseudo Root） | NFSv4から導入された，公開ディレクトリ群をひとつの仮想的なルートツリーとして見せる仕組み。 |
| UID/GID | UNIX系OSにおけるユーザーID/グループID。NFSはこの数値でアクセス制御するため，サーバーとクライアントで一致させる必要がある。 |
| マウント | ストレージ（ローカル/NFS）をディレクトリツリーに接続して使えるようにする操作。 |
| `root_squash` | クライアント側のrootユーザーをサーバー側のnobodyにマップする仕組み。クライアントのrootでもサーバー側ファイルを自由に操作させないためのセキュリティ機能。 |
| upstream | Nginxにおける転送先サーバーのグループ定義。 |
| ip_hash | NginxロードバランサーでクライアントIPに基づき転送先を固定する方式（スティッキーセッション）。 |
| コネクションプール | DB接続をあらかじめ複数作っておき，アプリで使い回す仕組み。 |

------------------------------

### D. 補足解説

- **なぜNFSが必要か？**
  - knowledgeはアプリケーションのデータ（添付ファイル，インデックスなど）をローカルディスクに保存する。
  - APサーバーを冗長化（複数台）すると，各APサーバーのローカルディスクにバラバラに保存されてしまい，整合性が取れない。
  - 全APサーバーが同じディレクトリを見るようにNFSで共有する必要がある。
  - **3台構成の今はAPサーバーは1台だが，将来5台構成（WEB-AP冗長化）に拡張する前提でNFSを導入している。**

- **NFSのUID一致が必要な理由**
  - NFSはファイルの所有者を「ユーザー名」ではなく「UID（数字）」で管理する。
  - APサーバーで作った `tomcat`（UID=1001）がDBサーバーで `tomcat`（UID=1002）になっていると，
    APサーバー側からは「自分が書いたファイルなのに別人扱い」となり権限エラーになる。
  - したがって両方のサーバーで同じUIDのtomcatユーザーを作る必要がある。

- **NFSとPostgreSQLの同居について**
  - 本手順ではDBサーバーがNFSサーバーも兼ねている。
  - 学習・小規模向けの構成。本番ではAmazon EFSやNFS専用サーバーへの分離を検討するのが望ましい。

- **`dnf update` と `dnf upgrade` の違い**
  - DNFベースのAmazon Linux 2023では両者は同義。1回でよい。

- **knowledgeのデフォルト管理者アカウント**
  - 初期状態：ユーザー名 `admin` / パスワード `admin123`
  - 本番運用前に必ず変更すること。
