# ApacheとTomcatをAJPで連携させたWeb/APサーバーの構築

------------------------------

## 1. ドキュメント情報

| 項目 | 内容 |
|------|------|
| 手順書名 | 手順書_Apache_Tomcat_AJP連携構築 |
| 作成日 | 2026-05-19 |
| 最終更新日 | 2026-05-19 |
| バージョン | v1.0 |
| 対象環境 | AWS |

> **改訂履歴**
>
> | バージョン | 日付 | 変更内容 |
> |-----------|------|---------|
> | v1.0 | 2026-05-19 | 初版作成 |

------------------------------

## 2. 目的・概要

### 2-1. 目的

> 本手順書では， Webサーバーとして「Apache」，APサーバーとして「Tomcat」を用いて，ApacheとTomcatをAJPで連携させて，情報共有OSSである「knowledge」のWebページを表示させるための構築手順について説明する．
> 構築後はブラウザで「`http://<EC2のパブリックIP>/knowledge`」にアクセスし，Webページを閲覧可能な状態を目指す．

### 2-2. 構成概要（アーキテクチャ）

```
[ローカルPC（ブラウザ）]
       |
       | HTTP（80）
       v
[EC2: Amazon Linux 2023]
  ├── Apache（80番ポート）
  │     └─ /knowledge へのリクエストをAJPでTomcatへ転送
  └── Tomcat（AJP: 8009番ポート）
        └─ /usr/local/tomcat/webapps/knowledge
              └─ knowledge（Java製の情報共有OSS）
```

### 2-3. 完成イメージ（ゴール定義）

- [ ] ブラウザで「`http://<EC2のパブリックIP>`」にアクセスし，「It works!」と表示
- [ ] ブラウザで「`http://<EC2のパブリックIP>/knowledge`」にアクセスし，Webページを閲覧できる

------------------------------

## 3. 前提条件・準備

### 3-1. 環境要件

| 項目 | 要件 |
|------|------|
| OS | AWS（Amazon Linux 2023）,WSL（Ubuntu 24.04） |
| Webサーバー | Apache |
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

# 最新パッケージへの更新
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

    #---以下のように追記-------------------------------------------------------------
    if ! [[ "$PATH" =~ "$HOME/.local/bin:$HOME/bin:" ]]
    then
        PATH="$HOME/.local/bin:$HOME/bin:$PATH"
    fi
    #------------------------------------------------------------------------------------

    #---変更後----------------------------------------------------------------------------
    if ! [[ "$PATH" =~ "$HOME/.local/bin:$HOME/bin:/opt/amazon-corretto-8.492.09.2-linux-x64/bin:" ]]
    then
        PATH="$HOME/.local/bin:$HOME/bin:/opt/amazon-corretto-8.492.09.2-linux-x64/bin:$PATH"
    fi
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
    CATALINA_HOME=/usr/local/tomcat
    JAVA_HOME=/opt/amazon-corretto-8.492.09.2-linux-x64
    JAVA_OPTS="-Xms128m -Xmx512m"

    export PATH=$JAVA_HOME/bin:$PATH
    #--------------------------------------------------

# Tomcatサーバーのネットワーク構成定義ファイルのバックアップ取得（原本保存）
cp /usr/local/tomcat/conf/server.xml{,.org}

# Tomcatサーバーのネットワーク構成定義ファイルの編集
vi /usr/local/tomcat/conf/server.xml

    #---編集箇所① AJP Connectorのコメントアウトを解除し、属性を変更---
    #---変更前（コメントアウトされた状態）-----------------------
    <!-- Define an AJP 1.3 Connector on port 8009 -->
    <!--
    <Connector protocol="AJP/1.3"
               address="::1"
               port="8009"
               redirectPort="8443"
               maxParameterCount="1000"
               />
    -->
    #-----------------------------------------------------------
    #---変更後（コメントアウト解除＋addressを127.0.0.1に変更＋secretRequired="false"追加）---
    <!-- Define an AJP 1.3 Connector on port 8009 -->
    <Connector protocol="AJP/1.3"
               address="127.0.0.1"
               port="8009"
               redirectPort="8443"
               maxParameterCount="1000"
               secretRequired="false"
               />
    #-----------------------------------------------------------

    #---編集箇所② Hostタグの属性を変更----------------------------
    #---変更前--------------------------------------------------
    <Host name="localhost" appBase="webapps"
        unpackWARs="true" autoDeploy="true">
    #-----------------------------------------------------------
    #---変更後--------------------------------------------------
    <Host name="localhost" appBase="webapps"
        unpackWARs="false" autoDeploy="false">
    #-----------------------------------------------------------

# ※ 注意：secretRequired="false" は本来セキュリティ上推奨されない設定である．
#         研修・学習用途のため許容しているが，本番環境では secret 属性で共有シークレットを
#         設定するか，AJP Connector自体を有効化しない構成が望ましい．

# TomcatをLinuxのサービスとして自動起動・管理するための設定ファイルの作成と設定記入
vi /etc/systemd/system/tomcat.service

    #---以下を記入------------------------------
    [Unit]
    Description=Apache Tomcat 9
    After=network.target

    [Service]
    User=tomcat
    Group=tomcat
    Type=oneshot
    PIDFile=/usr/local/tomcat/tomcat.pid
    RemainAfterExit=yes
    ExecStart=/usr/local/tomcat/bin/startup.sh
    ExecStop=/usr/local/tomcat/bin/shutdown.sh

    [Install]
    WantedBy=multi-user.target
    #--------------------------------------------

# Tomcatサービスの権限変更
chmod 755 /etc/systemd/system/tomcat.service

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

### Step 4 Apacheの設定

**目的：** Apacheのシステム設定と転送設定の手順について説明する．

#### 操作手順

```bash
# Apacheのインストール
dnf install -y httpd

# Apacheのプロキシ設定ファイルの作成と書き込み（conf.d配下に新規ファイルとして作成）
vi /etc/httpd/conf.d/proxy_ajp.conf

    #---以下を記入----------------------------------------------
    ProxyRequests Off
    ProxyPass /knowledge ajp://127.0.0.1:8009/knowledge
    ProxyPassReverse /knowledge ajp://127.0.0.1:8009/knowledge
    #----------------------------------------------------------

# Apacheの設定ファイルの構文チェック（Syntax OK と表示されれば問題なし）
httpd -t

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

# Apacheの設定再読み込み（プロキシ先のTomcatが起動完了したため）
systemctl reload httpd
```

> **確認：** ApacheとTomcatの連携確認と今回のゴールの確認
>
> ブラウザで「`http://<EC2のパブリックIP>/knowledge`」にアクセスし，knowledgeのwebページが表示されれば成功

------------------------------

## 付録

### A. コマンド解説

| コマンド | 説明 |
|---------|------|
| `httpd -t` | Apacheの設定ファイルの構文チェックを行う。`Syntax OK` と表示されれば問題なし。 |
| `vi /etc/httpd/conf.d/proxy_ajp.conf` | `/etc/httpd/conf.d/` 配下の `.conf` ファイルはApacheが自動で読み込むため、メインの設定ファイルを直接編集せずに済む。 |

------------------------------

### B. 設定ファイル解説

```
ProxyRequests Off
ProxyPass /knowledge ajp://127.0.0.1:8009/knowledge
ProxyPassReverse /knowledge ajp://127.0.0.1:8009/knowledge
```

- `ProxyRequests Off`：フォワードプロキシ機能を無効化（外部から踏み台にされないようにする）。
- `ProxyPass /knowledge ajp://...`：`/knowledge` へのリクエストを、AJPプロトコルでTomcatの8009番ポートへ転送する。
- `ProxyPassReverse /knowledge ajp://...`：Tomcatからのリダイレクト応答URLを、Apacheの公開URLに書き換える。

------------------------------

### C. 用語解説

| 用語 | 説明 |
|------|------|
| AJP（Apache JServ Protocol） | ApacheとTomcatを連携するための専用バイナリプロトコル。HTTPと違いテキストではなくバイナリで通信するため、オーバーヘッドが小さい。 |
| Connector | Tomcatが外部からのリクエストを受け付けるための入口（ポート設定）。HTTP用とAJP用がある。 |
| リバースプロキシ | クライアントからのリクエストを受け取り、裏側のサーバーに転送する仕組み。 |

------------------------------

### D. 補足解説

- **HTTPプロキシ連携とAJP連携の違い**
  - **HTTPプロキシ連携**：Apache → Tomcat の通信に通常のHTTPを使う。テキストベースで読みやすく、デバッグしやすい。
  - **AJP連携**：Apache → Tomcat の通信に専用のAJPプロトコル（バイナリ）を使う。HTTPに比べてオーバーヘッドが小さく、リクエスト情報（クライアントの本来のIPなど）をTomcatに自然に渡せる。
  - 同一サーバー内の連携であればHTTPでも十分なケースが多いが、Apacheの背後で複雑なJavaアプリを動かす場合にAJPが選ばれることがある。

- **`secretRequired="false"` のセキュリティ上の注意**
  AJP Connectorは過去にGhostcat（CVE-2020-1938）という脆弱性が報告されており、現在のTomcatでは `secretRequired="true"` がデフォルトで、共有シークレットの設定が必須になっている。本手順書では学習目的のため `false` にしているが、本番環境では以下のいずれかを推奨する。
  - `secret="<秘密の文字列>"` を設定し、ApacheのProxyPass側も `secret=<同じ文字列>` を指定する
  - AJP Connector自体を有効化せず、HTTPプロキシ連携を使う

- **AJP Connectorの `address="127.0.0.1"` の意味**
  AJP Connectorのバインドアドレスを `127.0.0.1`（ループバック）に限定することで、同一サーバー内のApacheからのみアクセスを受け付け、外部からの直接接続を遮断している。
