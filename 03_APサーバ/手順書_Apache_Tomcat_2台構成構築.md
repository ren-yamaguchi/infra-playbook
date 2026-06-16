# ApacheとTomcatを用いた2台構成のWeb/APサーバーの構築

------------------------------

## 1. ドキュメント情報

| 項目 | 内容 |
|------|------|
| 手順書名 | 手順書_Apache_Tomcat_2台構成構築 |
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

> 本手順書では， Webサーバーとして「Apache」，APサーバーとして「Tomcat」を用いて，それぞれ別のEC2で構築し，情報共有OSSである「knowledge」のWebページを表示させるための構築手順について説明する．
> 構築後はブラウザで「`http://<WebサーバーのパブリックIP>/knowledge`」にアクセスし，Webページを閲覧可能な状態を目指す．

### 2-2. 構成概要（アーキテクチャ）

```
[ローカルPC（ブラウザ）]
       |
       | HTTP（80）
       v
[Webサーバー用EC2]              [APサーバー用EC2]
  Apache（80番ポート） ──────► Tomcat（8080番ポート）
                  HTTPプロキシ        └─ knowledge
```
### 2-3. 完成イメージ（ゴール定義）

- [ ] ブラウザで「`http://<WebサーバーのパブリックIP>`」にアクセスし，「It works!」と表示
- [ ] ブラウザで「`http://<WebサーバーのパブリックIP>/knowledge`」にアクセスし，Webページを閲覧できる

------------------------------

## 3. 前提条件・準備

### 3-1. 環境要件

| 項目 | 要件 |
|------|------|
| OS | AWS（Amazon Linux 2023）,WSL（Ubuntu 24.04） |
| Webサーバー | Apache |
| APサーバー | Tomcat |

### 3-2. セキュリティグループ設定

### 3-2-1. Webサーバーのセキュリティグループ設定

| タイプ | プロトコル | ポート範囲 | ソース | 説明 |
|-------|------------|----------|--------|------|
| SSH | TCP | 22 | マイIP | ローカルPCからSSHで接続 |
| HTTP | TCP | 80 | マイIP | ローカルPCのブラウザから接続 |

### 3-2-2. APサーバーのセキュリティグループ設定

| タイプ | プロトコル | ポート範囲 | ソース | 説明 |
|-------|------------|----------|--------|------|
| SSH | TCP | 22 | マイIP | ローカルPCからSSHで接続 |
| カスタムTCP | TCP | 8080 | WebサーバーのプライベートIP/32 | WebサーバーからのHTTP転送 |

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
> - 本手順書ではWebサーバー用EC2とAPサーバー用EC2の2台を構築する．各Stepの冒頭に **【実施対象：〇〇サーバー】** を明記しているので，対応するEC2にSSH接続した上で作業を進めること

------------------------------

### Step 1 システム設定（共通設定）

**【実施対象：Webサーバー / APサーバー 両方】**

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

**【実施対象：APサーバー】**

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

**【実施対象：APサーバー】**

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

**【実施対象：Webサーバー】**

**目的：** Apacheのシステム設定と転送設定の手順について説明する．

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
> ブラウザで「`http://<WebサーバーのパブリックIP>`」にアクセスし，「It works!」と表示されれば成功

```bash
# Apacheのプロキシ設定ファイルの作成と書き込み
# ファイル名はわかりやすい名前を任意で指定する（例：proxy.conf）
vi /etc/httpd/conf.d/<任意の名前>.conf

    #---以下を記入---------------------------------------------
    ProxyRequests Off
    ProxyPass /knowledge http://<APサーバーのプライベートIP>:8080/knowledge
    ProxyPassReverse /knowledge http://<APサーバーのプライベートIP>:8080/knowledge
    #----------------------------------------------------------

# Apacheの設定ファイルの構文チェック（Syntax OK と表示されれば問題なし）
httpd -t

# 設定変更を反映するためApacheをリロード
systemctl reload httpd
```

------------------------------

### Step 5 knowledgeアプリケーションの設定

**【実施対象：APサーバー】**

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

> **確認：** ApacheとTomcatの連携確認と今回のゴールの確認
>
> ブラウザで「`http://<WebサーバーのパブリックIP>/knowledge`」にアクセスし，knowledgeのwebページが表示されれば成功

------------------------------

## 付録

### A. コマンド解説

| コマンド | 説明 |
|---------|------|
| `httpd -t` | Apacheの設定ファイルの構文チェックを行うコマンド。`Syntax OK` と出れば設定に問題なし。 |
| `systemctl reload <サービス>` | サービスを停止せずに設定ファイルだけを再読み込みする。 |
| `vi /etc/httpd/conf.d/<任意の名前>.conf` | Apacheは `/etc/httpd/conf.d/` 配下の `.conf` ファイルを自動的に読み込むため、メインの `httpd.conf` を直接編集せずに設定を追加できる。 |

------------------------------

### B. 設定ファイル解説

```
ProxyRequests Off
ProxyPass /knowledge http://<APサーバーのプライベートIP>:8080/knowledge
ProxyPassReverse /knowledge http://<APサーバーのプライベートIP>:8080/knowledge
```

- `ProxyRequests Off`：フォワードプロキシ機能を無効化する。これがOnだと外部から踏み台として悪用される恐れがあるため、リバースプロキシ構築時は必ずOffにする。
- `ProxyPass /knowledge http://...`：`/knowledge` というURLへのリクエストを、APサーバーへ転送する。
- `ProxyPassReverse /knowledge http://...`：APサーバーからのリダイレクト応答に含まれるURLを、Apacheの公開URLに書き換える。

------------------------------

### C. 用語解説

| 用語 | 説明 |
|------|------|
| Apache | 世界中で広く使われているWebサーバーソフトウェア。 |
| Tomcat | Java製のAPサーバー。Javaで書かれたWebアプリケーション（war形式）を実行できる。 |
| JDK | Java Development Kit。Javaのプログラムを動かすために必要なソフトウェア一式。 |
| knowledge | Java製の情報共有OSS（オープンソースソフトウェア）。 |
| リバースプロキシ | クライアントからのリクエストを受け取り、裏側のサーバーに転送する仕組み。 |
| プライベートIP | VPC内部でのみ使われるIPアドレス。インターネットからは直接アクセスできない。 |

------------------------------

### D. 補足解説

- **なぜ2台構成にするのか**
  Web/APを分離することで，役割を明確化でき，それぞれのサーバーを独立してスケールアウト・スケールアップできる。また，APサーバーをインターネットから直接アクセスできない場所に配置することで，セキュリティを高められる。

- **APサーバーのSGに HTTP（80） を開けない理由**
  APサーバーはWebサーバーからのみアクセスされる想定のため，インターネットからの直接アクセスを許可する必要がない。ソースに「WebサーバーのプライベートIP/32」を指定することで，Webサーバーからのリクエストのみを受け付けるようにしている。