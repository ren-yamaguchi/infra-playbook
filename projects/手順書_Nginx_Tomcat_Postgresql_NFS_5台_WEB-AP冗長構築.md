# Nginx，Tomcat，Postgresqlを用いたWeb/AP/DBサーバーの5台構築（WEB-AP冗長化）

------------------------------

## 1. ドキュメント情報

| 項目 | 内容 |
|------|------|
| 手順書名 | 手順書_Nginx_Tomcat_Postgresql_NFS_5台_WEB-AP冗長構築 |
| 作成日 | 2026-05-31 |
| 最終更新日 | 2026-06-16 |
| バージョン | v1.1 |
| 対象環境 | AWS |

> **改訂履歴**
>
> | バージョン | 日付 | 変更内容 |
> |-----------|------|---------|
> | v1.0 | 2026-05-31 | 初版作成 |
> | v1.1 | 2026-06-16 | 構成図追加、セキュリティグループの番号誤り修正(3-2-1重複)、dnf重複解消、NFSパッケージの明示インストール追加、Nginx設定改善（location /追加、nginx -t追加、reload追加）、tomcat.serviceにPIDFile追加、各Stepに【実施対象】明示、Step11の「起動したAPサーバー2」誤記を「起動したWebサーバー2」に修正、Webサーバー2のNginx設定追加追記、付録充実 |

------------------------------

## 2. 目的・概要

### 2-1. 目的

> 本手順書では， それぞれ別のEC2でWebサーバーとして「Nginx」のサーバー2台，APサーバーとして「Tomcat」のサーバー2台，DBサーバーとして「Postgresql」のサーバー1台を用いて，情報共有OSSである「knowledge」を運用し，NFSシステムで「knowledge」アプリケーションのデータ共有を行うインフラ環境の構築手順について説明する．
> 構築後はブラウザで「`http://<WebサーバーのパブリックIP>/knowledge`」にアクセスし，NginxのサーバーとTomcatのサーバーで負荷分散されているログを確認できる状態を目指す．

### 2-2. 構成概要（アーキテクチャ）

```
[ローカルPC（ブラウザ）]
       |
       +────────────────────+
       | HTTP（80）           | HTTP（80）
       v                     v
┌────────────────────────── VPC ──────────────────────────┐
│                                                          │
│  [EC2: Webサーバー1]      [EC2: Webサーバー2]              │
│    └─ Nginx                 └─ Nginx                      │
│        upstream {              upstream {                 │
│          AP1:8080;               AP1:8080;                │
│          AP2:8080;               AP2:8080;                │
│        }                       }                          │
│           |  |                    |  |                    │
│           v  v                    v  v                    │
│  ┌───────────────────────────────────────────┐           │
│  │ ラウンドロビンで負荷分散                    │           │
│  └───────────────────────────────────────────┘           │
│           |                       |                       │
│  [EC2: APサーバー1]       [EC2: APサーバー2]               │
│    ├─ Tomcat / knowledge    ├─ Tomcat / knowledge         │
│    └─ NFSクライアント        └─ NFSクライアント            │
│        /var/lib/knowledge_data    /var/lib/knowledge_data │
│                |                       |                  │
│                +─── NFSマウント(2049) ──+                  │
│                          v                                │
│  [EC2: DBサーバー]                                        │
│    ├─ PostgreSQL（5432番ポート）                          │
│    └─ NFSサーバー  /srv/nfs/knowledge_data                │
│                                                          │
└──────────────────────────────────────────────────────────┘
```

### 2-3. 完成イメージ（ゴール定義）

- [ ] ブラウザで「`http://<Webサーバー1/2のパブリックIP>`」にアクセスし，「Welcome to nginx!」と表示
- [ ] ブラウザで「`http://<Webサーバー1/2のパブリックIP>/knowledge`」にアクセスし，Webページを閲覧できる
- [ ] ブラウザで「`http://<Webサーバー1/2のパブリックIP>/knowledge`」にアクセスし，サインインして投稿した時に，Postgresqlと接続できている
- [ ] 各WebサーバーからのリクエストがAP1/AP2で均等に負荷分散され，両APサーバーのログで確認できる

------------------------------

## 3. 前提条件・準備

### 3-1. 環境要件

| 項目 | 要件 |
|------|------|
| OS | AWS（Amazon Linux 2023）,WSL（Ubuntu 24.04） |
| Webサーバー | Nginx ×2台 |
| APサーバー | Tomcat 9 ×2台 |
| DBサーバー | PostgreSQL 15 + NFSサーバー ×1台 |

### 3-2. セキュリティグループ設定

#### 3-2-1. Webサーバーのインバウンドルール（Webサーバー1/2共通）

| タイプ | プロトコル | ポート範囲 | ソース | 説明 |
|-------|------------|----------|--------|------|
| SSH | TCP | 22 | マイIP | ローカルPCからSSHで接続 |
| HTTP | TCP | 80 | マイIP | ローカルPCのブラウザから接続 |

#### 3-2-2. APサーバーのインバウンドルール（APサーバー1/2共通）

| タイプ | プロトコル | ポート範囲 | ソース | 説明 |
|-------|------------|----------|--------|------|
| SSH | TCP | 22 | マイIP | ローカルPCからSSHで接続 |
| カスタムTCP | TCP | 8080 | VPCのCIDR | VPC内のWebサーバーからのプロキシ転送許可 |

#### 3-2-3. DBサーバーのインバウンドルール

| タイプ | プロトコル | ポート範囲 | ソース | 説明 |
|-------|------------|----------|--------|------|
| SSH | TCP | 22 | マイIP | ローカルPCからSSHで接続 |
| PostgreSQL | TCP | 5432 | VPCのCIDR | VPC内のAPサーバーからの接続許可 |
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
> - Step1〜9 はまず **Webサーバー1 + APサーバー1 + DBサーバーの3台構成** を構築し，その後 Step10〜11 でAMIによる横展開でAPサーバー2・Webサーバー2を追加していく流れ

------------------------------

### Step 1 システム設定 【実施対象：全サーバー共通】

**目的：** システムの変更と更新を行う．Webサーバー1・APサーバー1・DBサーバーのすべてで同じ手順を実施する．

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

# ホスト名を変更（例：web-1, ap-1, db-1）
hostnamectl set-hostname <任意の名前>

# ホスト名の変更を反映させるため一度exitし再ログイン
exit

# 再度rootユーザーにスイッチ（ホスト名がプロンプトに反映されることを確認）
sudo su -
```

------------------------------

### Step 2 Nginxの設定 【実施対象：Webサーバー1】

**目的：** Nginx のシステム設定と転送設定の手順について説明する．

#### 操作手順

```bash
# Nginxのインストール
dnf install -y nginx

# Nginxのプロキシ設定ファイルの作成と記入
vi /etc/nginx/conf.d/proxy.conf

    #---以下を記入--------------------------------------------------------
    upstream knowledge_cluster {
        # 現時点ではAPサーバー1のみ。Step10でAPサーバー2を追記する
        server <APサーバー1のプライベートIP>:8080;
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
> ブラウザで「`http://<Webサーバー1のパブリックIP>`」にアクセスし，「*Welcome to nginx!*」のページが表示されれば成功

------------------------------

### Step 3 JDKの手動インストールと環境変数設定 【実施対象：APサーバー1】

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

### Step 4 Tomcatの設定 【実施対象：APサーバー1】

**目的：** Tomcatのダウンロードと手動設定．冗長化のための負荷分散ログ出力設定とリバースプロキシ越しのクライアントIP復元設定（RemoteIpValve）も合わせて行う．

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

# Tomcatサーバーのネットワーク構成定義ファイルの編集と追記
vi /usr/local/tomcat/conf/server.xml
```

**【編集箇所①】Hostタグの属性変更**

```
#---変更前--------------------------------
<Host name="localhost" appBase="webapps"
    unpackWARs="true" autoDeploy="true">
#-----------------------------------------
#---変更後--------------------------------
<Host name="localhost" appBase="webapps"
    unpackWARs="false" autoDeploy="false">
#-----------------------------------------
```

**【編集箇所②】AccessLogValveに `requestAttributesEnabled="true"` を追加（リバースプロキシ経由でも本来のクライアントIPをログ記録するため）**

```
#---変更前--------------------------------
<Valve className="org.apache.catalina.valves.AccessLogValve" directory="logs"
    prefix="localhost_access_log" suffix=".txt"
    pattern="%h %l %u %t &quot;%r&quot; %s %b" />
#-----------------------------------------
#---変更後--------------------------------
<Valve className="org.apache.catalina.valves.AccessLogValve" directory="logs"
    prefix="localhost_access_log" suffix=".txt"
    pattern="%h %l %u %t &quot;%r&quot; %s %b"
    requestAttributesEnabled="true" />
#-----------------------------------------
```

**【編集箇所③】`<Host name="localhost"` タグの直下に RemoteIpValve を追記**

```
<Valve className="org.apache.catalina.valves.RemoteIpValve"
    internalProxies="<internalProxiesの正規表現>"
    remoteIpHeader="X-Forwarded-For"
    proxiesHeader="X-Forwarded-By"
    protocolHeader="X-Forwarded-Proto" />
```

**【参考】`internalProxies` の正規表現の書き方（VPCのCIDRをエスケープする）**

| VPC CIDR | internalProxies の値 |
|----------|----------------------|
| 172.31.0.0/16 | `172\.31\.\d{1,3}\.\d{1,3}` |
| 192.168.0.0/24 | `192\.168\.0\.\d{1,3}` |
| 10.0.0.0/16 | `10\.0\.\d{1,3}\.\d{1,3}` |

```bash
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

**目的：** NFSサーバーで公開するディレクトリの設定とAPサーバー1のTomcatユーザーと同じUIDのユーザーを作成する手順を説明する．

> **重要：** NFSはUID（ユーザーID）でアクセス制御するため，APサーバー1とDBサーバーで **同じUID** のtomcatユーザーが必要．Step4で確認したUIDを指定すること．
> APサーバー2はStep10でAMI複製により作成するので，UIDも自動的に同じ値が引き継がれる．

#### 操作手順

```bash
# NFSサーバーパッケージのインストール
dnf install -y nfs-utils

# NFSクライアントであるAPサーバー1のTomcatユーザーと同じUIDのTomcatユーザーを作成
useradd -u <APサーバー1のid tomcatで確認したUID> -s /sbin/nologin tomcat

# TomcatユーザーのUIDがAPサーバー1と同一か確認
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

### Step 6 NFSクライアントのマウント設定 【実施対象：APサーバー1】

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
> 1. NFSクライアント（APサーバー1）側で「`sudo su -s /bin/bash -c "touch <マウントポイントパス>/test.txt" tomcat`」を実行
> 2. NFSサーバー（DBサーバー）側で「`ls -l <公開ディレクトリ>`」
> 作成したファイルが確認でき，**所有者がtomcatになっていれば成功**（UIDが一致している証拠）

------------------------------

### Step 7 knowledgeアプリケーションの設定 【実施対象：APサーバー1】

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

**【実施対象：Webサーバー1】** Tomcat側のアプリ配置が完了したのでNginxの設定を再読み込み

```bash
# Nginxの設定再読み込み
systemctl reload nginx
```

> **確認：** NginxとTomcatの連携確認と今回のゴールの確認
>
> ブラウザで「`http://<Webサーバー1のパブリックIP>/knowledge`」にアクセスし，knowledgeのwebページが表示されれば成功

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

### Step 9 JDBCドライバの入れ替えと接続設定 【実施対象：APサーバー1】

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

# データベース接続先設定ファイルの作成と記入（NFS共有上に配置するためAPサーバー2でも自動的に共有される）
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
> 1. ブラウザで「`http://<Webサーバー1のパブリックIP>/knowledge`」にアクセス
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
>   テーブル一覧が表示されれば成功

------------------------------

### Step 10 APサーバーの追加（冗長化） 【実施対象：AWSコンソール → APサーバー2 → Webサーバー1】

**目的：** 冗長化のためのAPサーバー追加構築の説明をする．APサーバー1のAMIを取って横展開する方式．

#### 操作手順

**(1) 【実施対象：AWSコンソール】 AMIの作成とEC2の起動**

1. AWSコンソールですでに構築済みのAPサーバー1を停止
2. APサーバー1が「停止済み」になったことを確認
3. APサーバー1を選択 => アクション => イメージとテンプレート => イメージを作成

    | 設定項目 | 内容 |
    |----------|------|
    | イメージ名 | 任意の名前 |
    | イメージの説明 | 任意 |
    | インスタンスを再起動 | インスタンスが停止済みの状態になっていることを確認してからAMIの作成に入っているのでどちらでもよい |
    | インスタンスボリューム | そのまま |
    | タグ | AMIとストレージに対してそれぞれ同じ名前を付けるか個別の名前を付けるかなのでどちらでもよい |

4. イメージを作成
5. 作成したAMIを使ってEC2を起動（**セキュリティグループはAPサーバーと同じものを指定すること**）
6. APサーバー1も忘れず再起動する

**(2) 【実施対象：APサーバー2】 起動したAPサーバー2の初期設定**

```bash
# ローカルPCからsshログイン
ssh -i <秘密鍵のファイルパス> ec2-user@<APサーバー2のパブリックIP>

# rootユーザーにスイッチ
sudo su -

# ホスト名を変更（例：ap-2）
hostnamectl set-hostname <任意の名前>

# ホスト名の変更を反映させるため一度exitし再ログイン
exit

# 再度rootユーザーにスイッチ
sudo su -

# Tomcatとnfs-mountの状態確認（AMIから引き継ぎで自動起動しているはず）
systemctl status tomcat
df -h | grep knowledge_data
```

**(3) 【実施対象：Webサーバー1】 Nginxのupstreamにサーバー2を追記**

```bash
# Nginxのプロキシ設定ファイルに追記
vi /etc/nginx/conf.d/proxy.conf

    #---upstreamセクションに以下を追記--------------
    upstream knowledge_cluster {
        server <APサーバー1のプライベートIP>:8080;
        server <APサーバー2のプライベートIP>:8080;   # ← この行を追加
    }
    #---------------------------------------------

# Nginx設定の構文チェック
nginx -t

# 設定反映のためNginxを再読み込み（reloadなら無停止）
systemctl reload nginx
```

> **確認：** APサーバーの冗長化と負荷分散の確認
>
> 1. 2台のAPサーバーで「`tail -f /usr/local/tomcat/logs/localhost_access_log.YYYY-MM-DD.txt`」を実行し、リアルタイムでログを監視（`YYYY-MM-DD` は当日の日付に置き換え）
> 2. ブラウザで「`http://<Webサーバー1のパブリックIP>/knowledge`」に複数回アクセス（ブラウザの更新ボタンを連打）
> 3. 2台のAPサーバーに均等にログが記録されていれば成功（Nginxのupstreamデフォルトはラウンドロビン方式）

------------------------------

### Step 11 WEBサーバーの追加（冗長化） 【実施対象：AWSコンソール → Webサーバー2】

**目的：** 冗長化のためのWEBサーバー追加構築の説明をする．Webサーバー1のAMIを取って横展開する方式．

#### 操作手順

**(1) 【実施対象：AWSコンソール】 AMIの作成とEC2の起動**

1. AWSコンソールですでに構築済みのWEBサーバー1を停止
2. WEBサーバー1が「停止済み」になったことを確認
3. WEBサーバー1を選択 => アクション => イメージとテンプレート => イメージを作成

    | 設定項目 | 内容 |
    |----------|------|
    | イメージ名 | 任意の名前 |
    | イメージの説明 | 任意 |
    | インスタンスを再起動 | インスタンスが停止済みの状態になっていることを確認してからAMIの作成に入っているのでどちらでもよい |
    | インスタンスボリューム | そのまま |
    | タグ | AMIとストレージに対してそれぞれ同じ名前を付けるか個別の名前を付けるかなのでどちらでもよい |

4. イメージを作成
5. 作成したAMIを使ってEC2を起動（**セキュリティグループはWebサーバーと同じものを指定すること**）
6. WEBサーバー1も忘れず再起動する

**(2) 【実施対象：Webサーバー2】 起動したWebサーバー2の初期設定**

```bash
# ローカルPCからsshログイン
ssh -i <秘密鍵のファイルパス> ec2-user@<Webサーバー2のパブリックIP>

# rootユーザーにスイッチ
sudo su -

# ホスト名を変更（例：web-2）
hostnamectl set-hostname <任意の名前>

# ホスト名の変更を反映させるため一度exitし再ログイン
exit

# 再度rootユーザーにスイッチ
sudo su -

# Nginxの状態確認（AMIから引き継ぎで自動起動しているはず）
systemctl status nginx

# Nginxの設定もAMIから引き継がれているため，Webサーバー1と同じupstream設定（AP1+AP2）になっていることを確認
cat /etc/nginx/conf.d/proxy.conf
```

> **補足：** Webサーバー2はAMI複製のため，Step10で更新済みのNginx設定（AP1+AP2のupstream）がそのまま引き継がれている．追加の設定変更は不要．

> **確認：** WEBサーバーの冗長化と負荷分散の確認
>
> 1. 2台のAPサーバーで「`tail -f /usr/local/tomcat/logs/localhost_access_log.YYYY-MM-DD.txt`」を実行し、リアルタイムでログを監視
> 2. ブラウザで「`http://<Webサーバー1のパブリックIP>/knowledge`」に複数回アクセス → 2台のAPサーバーに均等にログが記録されていることを確認
> 3. ブラウザで「`http://<Webサーバー2のパブリックIP>/knowledge`」に複数回アクセス → 2台のAPサーバーに均等にログが記録されていることを確認
> 4. 2,3の確認が両方できていれば成功

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
| `df -h` | マウントされているファイルシステムを人間に読みやすい形式で表示。 |
| `nginx -t` | Nginxの設定ファイルの構文チェック。 |
| `systemctl reload <サービス>` | サービスを停止せずに設定だけ再読み込み。 |
| `tail -f <ログファイル>` | ログファイルをリアルタイムで監視する（追記内容を即時表示）。 |

------------------------------

### B. 設定ファイル解説

**`/etc/nginx/conf.d/proxy.conf` の upstream（Webサーバー）**

```
upstream knowledge_cluster {
    server <APサーバー1のプライベートIP>:8080;
    server <APサーバー2のプライベートIP>:8080;
}
```

- 複数の `server` を並べると **デフォルトでラウンドロビン**（順番に振り分け）。
- セッション固定が必要な場合は `ip_hash;` ディレクティブを `upstream` ブロックの先頭に追加する。
- 重み付け：`server <IP>:8080 weight=2;` のように指定すると配分を変えられる。

**Tomcat `server.xml` の RemoteIpValve（APサーバー）**

```
<Valve className="org.apache.catalina.valves.RemoteIpValve"
    internalProxies="<VPCのCIDRの正規表現>"
    remoteIpHeader="X-Forwarded-For"
    proxiesHeader="X-Forwarded-By"
    protocolHeader="X-Forwarded-Proto" />
```

- Nginxからの転送リクエストには `X-Forwarded-For` ヘッダに本来のクライアントIPが入っている。
- このValveがそのヘッダを解釈して，Tomcatから見たアクセス元IP（`%h`）を本来のクライアントIPに書き換える。
- `internalProxies` で「信頼するプロキシのIP」を正規表現で指定する必要がある（任意のヘッダ偽装を防ぐため）。

**AccessLogValve の `requestAttributesEnabled="true"`**

- RemoteIpValveが書き換えたクライアントIPをアクセスログに反映させるための設定。
- これを `true` にしないと，ログには常にNginxのIPが記録されてしまう。

**`/etc/exports`（DBサーバー）**

- 3台構成と同じ。VPC内のすべてのAPサーバーからマウントできる設定にしてある。
- APサーバーが増えても `/etc/exports` の変更は不要（VPCのCIDRで一括許可しているため）。

------------------------------

### C. 用語解説

| 用語 | 説明 |
|------|------|
| 冗長化 | 同じ役割のサーバーを複数台用意し，1台が故障しても全体が止まらないようにすること。 |
| 負荷分散（ロードバランシング） | 複数台のサーバーにリクエストを振り分けて負荷を均すこと。 |
| ラウンドロビン | リクエストを順番に各サーバーへ振り分けるシンプルな負荷分散方式。Nginx upstream のデフォルト。 |
| スティッキーセッション | 同じクライアントを常に同じサーバーに振り分ける方式。Nginxの `ip_hash` で実現できる。 |
| AMI | Amazon Machine Image。EC2のディスクイメージのスナップショット。これから複製して同じ構成のEC2を量産できる。 |
| upstream | Nginxにおける転送先サーバーのグループ定義。 |
| RemoteIpValve | Tomcatのフィルタの一つ。プロキシ経由のリクエストから本来のクライアント情報を復元する。 |
| X-Forwarded-For | プロキシが転送時に追加するHTTPヘッダ。元のクライアントIPを記録するためのもの。 |
| SPOF | Single Point of Failure（単一障害点）。そこが壊れるとシステム全体が止まる箇所。 |

------------------------------

### D. 補足解説

- **本構成で冗長化されているもの・されていないもの**
  - 冗長化されている：Webサーバー（×2），APサーバー（×2）
  - 冗長化されていない（SPOF）：DBサーバー，NFSサーバー（DBと同居），ローカルPCからの接続先（どちらかのWebサーバーのIPを直接指定しているため）
  - 本格的な可用性向上には，DBのレプリケーション，Amazon EFS（マネージドNFS）への移行，ALB（Application Load Balancer）の前段配置が必要。

- **AMI複製による横展開のメリット**
  - 同じ構成のEC2を素早く立ち上げられる。
  - 設定漏れや人的ミスを減らせる。
  - 一方で，AMI作成後にオリジナル側でのみ変更があると差分が出るため，変更管理に注意が必要。

- **負荷分散の挙動確認のコツ**
  - 1度のアクセスではどちらか一方にしかログが出ない（リクエストが1つだから）。
  - 必ず複数回（10回程度）アクセスして両方のサーバーにログが分散することを確認する。
  - ブラウザのキャッシュが効くと2回目以降のリクエストが飛ばないこともあるので，シークレットウィンドウや `curl` でのテストも有効。

- **AMI作成時にインスタンスを停止する理由**
  - 起動中にAMIを取ると，メモリ上のデータがディスクに書き込まれる前のスナップショットになり，データ整合性が損なわれることがある。
  - 「インスタンスを再起動」をチェックしておくとAWSが安全に再起動してから取ってくれるが，停止中ならその必要はない。

- **Webサーバー2はNginx設定の変更が不要な理由**
  - Step10でWebサーバー1のNginx設定にAP2を追加してから，Step11でWebサーバー1のAMIを取得しているため。
  - AMI取得のタイミングが順序通りであれば，Webサーバー2は最初から AP1+AP2 のupstream設定で起動する。

- **knowledgeのデフォルト管理者アカウント**
  - 初期状態：ユーザー名 `admin` / パスワード `admin123`
  - 本番運用前に必ず変更すること。
