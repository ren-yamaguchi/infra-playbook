# Nginx，Tomcat，Postgresqlを用いたWeb/AP/DBサーバーの構築

------------------------------

## 1. ドキュメント情報

| 項目 | 内容 |
|------|------|
| 手順書名 | 手順書_Nginx_Tomcat_Postgresql_1台基本構築 |
| 作成日 | 2026-05-28 |
| 最終更新日 | 2026-06-16 |
| バージョン | v1.1 |
| 対象環境 | AWS |

> **改訂履歴**
>
> | バージョン | 日付 | 変更内容 |
> |-----------|------|---------|
> | v1.0 | 2026-05-28 | 初版作成 |
> | v1.1 | 2026-06-16 | 構成図追加、dnf重複解消、Nginx設定改善（location /追加、nginx -t追加、reload追加）、tomcat.serviceにPIDFile追加、付録充実 |

------------------------------

## 2. 目的・概要

### 2-1. 目的

> 本手順書では， Webサーバーとして「Nginx」，APサーバーとして「Tomcat」，DBサーバーとして「Postgresql」を用いて，情報共有OSSである「knowledge」のWebページを表示させるための構築手順について説明する．
> 構築後はブラウザで「`http://<EC2のパブリックIP>/knowledge/dbtest.jsp`」にアクセスし，TomcatとPostgresqlの接続確認を行う．

### 2-2. 構成概要（アーキテクチャ）

```
[ローカルPC（ブラウザ）]
       |
       | HTTP（80）
       v
[EC2: Amazon Linux 2023]
  ├── Nginx（Webサーバー / 80番ポート）
  │     ├─ / へのリクエストはNginxデフォルトのWelcomeページを表示
  │     └─ /knowledge へのリクエストを127.0.0.1:8080へプロキシ転送
  ├── Tomcat（APサーバー / 8080番ポート）
  │     └─ /usr/local/tomcat/webapps/knowledge
  │           └─ knowledge（Java製の情報共有OSS）
  └── Postgresql（DBサーバー / 5432番ポート）
        └─ localhost からのみ接続を許可
```

### 2-3. 完成イメージ（ゴール定義）

- [ ] ブラウザで「`http://<EC2のパブリックIP>`」にアクセスし，「Welcome to nginx!」と表示
- [ ] ブラウザで「`http://<EC2のパブリックIP>/knowledge`」にアクセスし，knowledgeのWebページを閲覧できる
- [ ] ブラウザで「`http://<EC2のパブリックIP>/knowledge/dbtest.jsp`」にアクセスし，PostgreSQLとの接続成功メッセージが表示される

------------------------------

## 3. 前提条件・準備

### 3-1. 環境要件

| 項目 | 要件 |
|------|------|
| OS | AWS（Amazon Linux 2023）,WSL（Ubuntu 24.04） |
| Webサーバー | Nginx |
| APサーバー | Tomcat 9 |
| DBサーバー | PostgreSQL 15 |

### 3-2. セキュリティグループ設定

| タイプ | プロトコル | ポート範囲 | ソース | 説明 |
|-------|------------|----------|--------|------|
| SSH | TCP | 22 | マイIP | ローカルPCからSSHで接続 |
| HTTP | TCP | 80 | マイIP | ローカルPCのブラウザから接続 |

> **補足：** Tomcat（8080）・PostgreSQL（5432）はすべてEC2内部（localhost）で完結するため，セキュリティグループでの公開は不要．

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
> - 本手順書は1台のEC2上ですべてのサーバー（Web/AP/DB）を構築する

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

# シェル設定ファイルの設定反映後のパス確認
echo $PATH

    #------------------------------
    追記したものが表示されていれば成功
    #------------------------------
```

------------------------------

### Step 3 Tomcatの設定

**目的：** Tomcatのダウンロードと手動設定

Amazon Linux 2023 の標準リポジトリに Tomcat のパッケージはないため，手動で設定を行う．

#### 操作手順

```bash
# Tomcatユーザーの作成
useradd -s /sbin/nologin tomcat

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

**目的：** Nginx のシステム設定と転送設定の手順について説明する．

#### 操作手順

```bash
# Nginxのインストール
dnf install -y nginx

# Nginxのプロキシ設定ファイルの作成と記入
vi /etc/nginx/conf.d/proxy.conf

    #---以下を記入--------------------------------------------------------
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
> ブラウザで「`http://<EC2のパブリックIP>`」にアクセスし，「*Welcome to nginx!*」のページが表示されれば成功

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

### Step 6 Postgresqlの設定

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

	#---[IPv4 local connections]セクションを以下のように編集-----------------------
	host    <データベース名>       <ユーザー名>       127.0.0.1/32            scram-sha-256
	#----------------------------------------------------------------------------

# Postgresqlの再起動
systemctl restart postgresql.service
```

------------------------------

### Step 7 JDBCドライバの入れ替えと接続設定

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

# Postgresqlのコネクションプールを定義する設定ファイルのバックアップ取得（原本保存）
cp /usr/local/tomcat/conf/context.xml{,.org}

# Postgresqlのコネクションプールを定義
vi /usr/local/tomcat/conf/context.xml

	#---</Context>の直上に追記-----------------------------------
	<Resource name="jdbc/KnowledgeDB"
          auth="Container"
          type="javax.sql.DataSource"
          driverClassName="org.postgresql.Driver"
          url="jdbc:postgresql://localhost:5432/<Postgresql設定時のデータベース名>"
          username="<Postgresql設定時のユーザー名>"
          password="<Postgresql設定時のパスワード>" />
	#------------------------------------------------------------

# 接続確認ファイルを作成
vi /usr/local/tomcat/webapps/knowledge/dbtest.jsp

	#---以下を記入---------------------------------------------------------------------------------------------
	<%@ page language="java" contentType="text/html; charset=UTF-8" pageEncoding="UTF-8"%>
	<%@ page import="java.sql.*" %>
	<!DOCTYPE html>
	<html>
	<head>
		<title>PostgreSQL Connection Test</title>
	</head>
	<body>
		<h2>Tomcat <-> PostgreSQL 接続テスト結果</h2>
		<%
			// 1. 接続設定（これまでの設定値に合わせて書き換えてください）
			String url = "jdbc:postgresql://localhost:5432/<Postgresql設定時のデータベース名>";
			String user = "<Postgresql設定時のユーザー名>";
			String password = "<Postgresql設定時のパスワード>";

			Connection conn = null;
			try {
				// 2. ドライバのロード
				Class.forName("org.postgresql.Driver");

				// 3. データベースへの接続試行
				conn = DriverManager.getConnection(url, user, password);

				if (conn != null) {
					out.println("<p style='color:green; font-weight:bold;'>【成功】PostgreSQLへの接続が正常に確立されました！</p>");

					// 4. ついでにPostgreSQLのバージョンも取得してみる
					DatabaseMetaData meta = conn.getMetaData();
					out.println("<p>接続先DBバージョン: " + meta.getDatabaseProductVersion() + "</p>");
				}
			} catch (ClassNotFoundException e) {
				out.println("<p style='color:red;'>【エラー】JDBCドライバ（JARファイル）が見つかりません: " + e.getMessage() + "</p>");
			} catch (SQLException e) {
				out.println("<p style='color:red;'>【エラー】データベース接続に失敗しました: " + e.getMessage() + "</p>");
			} finally {
				if (conn != null) {
					try { conn.close(); } catch (SQLException e) {}
				}
			}
		%>
	</body>
	</html>
	#----------------------------------------------------------------------------------------------------------

# 接続確認ファイルをtomcatが操作できるように所有ユーザーと所有グループの変更
chown tomcat:tomcat /usr/local/tomcat/webapps/knowledge/dbtest.jsp

# 設定を反映させるために再起動
systemctl restart tomcat
```

> **確認：** TomcatとPostgresqlの接続確認と今回のゴールの確認
>
> 1. ブラウザで「`http://<EC2のパブリックIP>/knowledge/dbtest.jsp`」にアクセス
> 2. サインイン画面にリダイレクトされるので管理者でログイン
> ユーザー名：admin パスワード：admin123
> 「*【成功】PostgreSQLへの接続が正常に確立されました！*」と表示されれば成功

------------------------------

## 付録

### A. コマンド解説

| コマンド | 説明 |
|---------|------|
| `dnf update -y` | システムのパッケージを最新に更新する。`dnf upgrade -y` と同義のため，どちらか1回でよい。 |
| `timedatectl set-timezone Asia/Tokyo` | システムのタイムゾーンを日本時間に設定する。 |
| `useradd -s /sbin/nologin <ユーザー名>` | ログイン不可のシステムユーザーを作成する。サービス専用ユーザーを安全に扱うため。 |
| `tar zxf <ファイル名>` | gzip圧縮されたtarファイルを解凍する。`z`=gzip，`x`=展開，`f`=ファイル指定。 |
| `ln -s <リンク元> <リンク名>` | シンボリックリンク（ショートカット）を作成する。バージョンアップ時にリンク先を変えるだけで済む。 |
| `chown -R <ユーザー>:<グループ> <ディレクトリ>` | 指定ディレクトリ配下すべての所有者を再帰的に変更する。`-R`=recursive。 |
| `systemctl daemon-reload` | systemdの設定ファイルを再読み込み。serviceファイルを編集した後に必要。 |
| `systemctl enable --now <サービス>` | サービスの自動起動を有効化し，同時に起動する。 |
| `systemctl is-enabled <サービス>` | サービスが自動起動に設定されているか確認する。 |
| `nginx -t` | Nginxの設定ファイルの構文チェック。`test is successful` と表示されれば問題なし。 |
| `systemctl reload <サービス>` | サービスを停止せずに設定だけ再読み込みする。 |
| `postgresql-setup --initdb` | PostgreSQLのデータベースクラスタを初期化する。インストール後に1度だけ実行する。 |
| `sudo -u postgres psql` | OSの`postgres`ユーザーになってPostgreSQLに接続する。 |
| `jar xf <warファイル>` | warファイル（zip形式）を展開する。 |

------------------------------

### B. 設定ファイル解説

**`/etc/nginx/conf.d/proxy.conf`**

```
server {
    listen       80;
    server_name  _;

    location / {
        root   /usr/share/nginx/html;
        index  index.html index.htm;
    }

    location /knowledge {
        proxy_pass http://127.0.0.1:8080/knowledge;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }
}
```

- `listen 80`：80番ポートで待ち受ける。
- `server_name _`：任意のホスト名にマッチするワイルドカード。
- `location /`：ルートへのリクエストはNginxのデフォルトページを返す。
- `location /knowledge`：`/knowledge` で始まるURLをTomcat（8080）へ転送。
- `proxy_set_header`：転送時にリクエストヘッダを書き換え，クライアントの本来のIPやプロトコルをTomcatに伝える。

**`/usr/local/tomcat/bin/setenv.sh`**

- `CATALINA_HOME`：Tomcatのインストール先。
- `JAVA_HOME`：Tomcatが使うJavaの場所。
- `JAVA_OPTS="-Xms128m -Xmx512m"`：JVMの初期/最大ヒープサイズ。

**`/etc/systemd/system/tomcat.service`**

- `Type=forking`：Tomcatの起動スクリプトが子プロセスをfork（分岐）して終了するため。
- `PIDFile`：Tomcatのプロセス番号を記録するファイル。`Type=forking`と組み合わせてsystemdがプロセスを正しく追跡できる。
- `User=tomcat / Group=tomcat`：Tomcatをrootではなく専用ユーザーで起動するためのセキュリティ設定。

**`/var/lib/pgsql/data/pg_hba.conf`**

PostgreSQLのクライアント認証設定ファイル。フォーマットは
`<接続方式> <DB名> <ユーザー名> <接続元IP> <認証方式>`。
- `host`：TCP/IPでの接続。
- `scram-sha-256`：PostgreSQL 10以降のデフォルトの強力なパスワード認証方式。

**`/usr/local/tomcat/conf/context.xml` の `<Resource>`**

Tomcatの「コネクションプール」を定義する。アプリがDB接続するたびに新規接続するのは負荷が高いので，あらかじめ接続を作って使い回す仕組み。

------------------------------

### C. 用語解説

| 用語 | 説明 |
|------|------|
| Nginx | 高速・軽量なWebサーバー兼リバースプロキシ。同時接続数の多い環境で強みを発揮する。 |
| Tomcat | Java製のAPサーバー。サーブレットやJSPを実行できる。 |
| PostgreSQL | オープンソースのリレーショナルデータベース管理システム（RDBMS）。 |
| JDK | Java Development Kit。Javaのコンパイル・実行に必要な開発キット。 |
| JDBC | Java Database Connectivity。JavaからDBに接続するためのAPI。実装は「JDBCドライバ」として提供される。 |
| knowledge | Java製の情報共有OSS。Wiki・ナレッジベース用途。 |
| リバースプロキシ | クライアントからのリクエストを受け取り，裏側のサーバーに転送する仕組み。Nginxの典型的な役割。 |
| コネクションプール | DB接続をあらかじめ複数作っておき，アプリで使い回す仕組み。性能向上の常套手段。 |
| シンボリックリンク | Windowsのショートカットに相当するファイル。バージョンアップ時の切替が容易になる。 |

------------------------------

### D. 補足解説

- **1台構成のメリット・デメリット**
  - メリット：構築が簡単，コストが低い，サーバー間通信が不要で速い。
  - デメリット：単一障害点（SPOF）になる，リソースを共有するため負荷分離ができない。学習・検証用途や小規模システム向け。

- **`dnf update` と `dnf upgrade` の違い**
  - Amazon Linux 2023（DNFベース）では両者は **エイリアス（同義）**。
  - 一方で，過去のyumベースシステムでは「`update`はインストール済みパッケージのみ更新」「`upgrade`は廃止予定パッケージの削除も含む」という違いがあった。
  - 結論：DNF環境では1回の `dnf update -y`（または `dnf upgrade -y`）でよい。

- **`server_name _;` の意味**
  - `_` はNginxにおける「任意のホスト名にマッチ」を示すワイルドカード。特定のドメイン名を指定しない場合に使う。

- **Tomcatの `Type=forking` と `PIDFile`**
  - Tomcatの`startup.sh`は親プロセスがすぐ終了し，子プロセス（Javaプロセス）が裏で動き続ける挙動をする。
  - systemdはこれを追跡するために `Type=forking` と `PIDFile` を組み合わせる必要がある。
  - `PIDFile`を指定しないと，systemdが「どのプロセスがTomcatか」を見失い，`systemctl status` が不正確になることがある。

- **`unpackWARs="false" autoDeploy="false"` の意味**
  - `unpackWARs="false"`：warファイルを自動展開しない。本手順では手動で展開済みのためfalseにする。
  - `autoDeploy="false"`：webapps配下のファイル変更を自動検出して再デプロイしない。本番運用では予期しない再起動を避けるためfalseが推奨。

- **knowledgeのデフォルト管理者アカウント**
  - 初期状態：ユーザー名 `admin` / パスワード `admin123`
  - 本番運用前に必ず変更すること。
