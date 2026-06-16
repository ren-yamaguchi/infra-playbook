# ApacheとTomcatを用いてProxyによる冗長化の2台構成のWeb/APサーバーの構築

------------------------------

## 1. ドキュメント情報

| 項目 | 内容 |
|------|------|
| 手順書名 | 手順書_Apache_Tomcat_Proxy_2台構成構築 |
| 作成日 | 2026-05-20 |
| 最終更新日 | 2026-05-20 |
| バージョン | v1.0 |
| 対象環境 | AWS |

> **改訂履歴**
>
> | バージョン | 日付 | 変更内容 |
> |-----------|------|---------|
> | v1.0 | 2026-05-20 | 初版作成 |

------------------------------

## 2. 目的・概要

### 2-1. 目的

> 本手順書では， Webサーバーとして「Apache」，APサーバーとして「Tomcat」を用いて，それぞれ別のEC2で構築する．また同じ構成のAPサーバーをさらにもう1台構築することで冗長化を実現し，情報共有OSSである「knowledge」のWebページを表示させるための構築手順について説明する．
> 構築後はブラウザで「`http://<WebサーバーのパブリックIP>/knowledge`」にアクセスし，Webページを閲覧可能な状態を目指す．

### 2-2. 構成概要（アーキテクチャ）

```
[ローカルPC（ブラウザ）]
       |
       | HTTP（80）
       v
[Webサーバー用EC2]
  Apache（80番ポート / mod_proxy_balancer）
       │
       ├─────────────► [APサーバー1用EC2]
       │  通常時はこちら   Tomcat（8080）→ knowledge
       │
       └─────────────► [APサーバー2用EC2]
          AP1ダウン時のみ  Tomcat（8080）→ knowledge
                          （Hot Standby: status=+H）
```
### 2-3. 完成イメージ（ゴール定義）

- [ ] ブラウザで「`http://<WebサーバーのパブリックIP>`」にアクセスし，「It works!」と表示
- [ ] ブラウザで「`http://<WebサーバーのパブリックIP>/knowledge`」にアクセスし，Webページを閲覧できる
- [ ] APサーバー1を停止させても，knowledgeのWebページを閲覧できること
- [ ] APサーバー1を停止させたときに，APサーバー2がリクエスト応答してること

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
> - 本手順書ではWebサーバー用EC2が1台，APサーバー用EC2が2台の計3台を構築する．各Stepの冒頭に **【実施対象：〇〇サーバー】** を明記しているので，対応するEC2にSSH接続した上で作業を進めること

------------------------------

### Step 1 システム設定（共通設定）

**【実施対象：Webサーバー / APサーバー1 / APサーバー2 すべて】**

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

**【実施対象：APサーバー1 / APサーバー2】**

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

**【実施対象：APサーバー1 / APサーバー2】**

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

### Step 4 knowledgeアプリケーションの設定

**【実施対象：APサーバー1 / APサーバー2】**

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

# 不要となったファイルの削除（プロンプトが表示されたら yes と入力）
rm knowledge.war

# カレントディレクトリの親ディレクトリに移動
cd ..

# knowledgeディレクトリとその中のファイルとサブディレクトリの所有ユーザーと所有グループの変更
chown -R tomcat:tomcat knowledge/

# Tomcatの再起動
systemctl restart tomcat
```

> **重要：** ここまでのStep 1〜4を **APサーバー1とAPサーバー2の両方のEC2** に対して実施し，APサーバーを2台構築すること．

------------------------------

### Step 5 Apacheの設定

**【実施対象：Webサーバー】**

**目的：** Apacheのシステム設定と転送設定（ロードバランサー）の手順について説明する．

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
# ファイル名はわかりやすい名前を任意で指定する（例：proxy_balancer.conf）
vi /etc/httpd/conf.d/<任意の名前>.conf

    #---以下を記入----------------------------------------------
    <Proxy "balancer://<任意の名前>">
        BalancerMember http://<APサーバー1のプライベートIP>:8080/knowledge
        BalancerMember http://<APサーバー2のプライベートIP>:8080/knowledge status=+H
    </Proxy>

    ProxyRequests Off
    ProxyPass /knowledge balancer://<上記で設定した任意の名前>/
    ProxyPassReverse /knowledge balancer://<上記で設定した任意の名前>/
    #----------------------------------------------------------

# Apacheの設定ファイルの構文チェック（Syntax OK と表示されれば問題なし）
httpd -t

# 設定変更を反映するためApacheをリロード
systemctl reload httpd
```

> **確認：** ApacheとTomcatの連携確認と今回のゴールの確認
>
> ブラウザで「`http://<WebサーバーのパブリックIP>/knowledge`」にアクセスし，knowledgeのwebページが表示されれば成功

> **確認：** APサーバーの冗長化確認
>
> 1. APサーバー1とAPサーバー2の両方で，Tomcatのアクセスログを確認する：
>    ```
>    tail -f /usr/local/tomcat/logs/localhost_access_log.<年-月-日>.txt
>    ```
>    （例：`localhost_access_log.2026-05-20.txt`）
> 2. ブラウザで「`http://<WebサーバーのパブリックIP>/knowledge`」にアクセスし，knowledgeのwebページを表示させる
> 3. ApacheのProxy設定で `status=+H` を設定していない側（APサーバー1）のログにアクセス記録があり，もう一方（APサーバー2）にはないことを確認
> 4. APサーバー1のTomcatを停止（`systemctl stop tomcat`）してから 2 を実行し，APサーバー2のログにアクセス記録が出ることを確認
> 5. APサーバー1のTomcatを起動（`systemctl start tomcat`）し，再度アクセスするとAPサーバー1のログに記録されるようになっていれば成功

------------------------------

## 付録

### A. コマンド解説

1. `vi /etc/httpd/conf.d/<任意の名前>.conf`：Apacheの設定ファイルである`httpd.conf`に直接書き込むのではなく，`conf.d`配下に新たに設定ファイルを作成するコマンドである．
   - Apacheでは，`conf.d`配下にある末尾が`.conf`である拡張子のファイルを全て読み込む設定となっているため，設定ファイルに直接書き込むのではなく，設定ファイルを新たに作成した．

------------------------------

### B. 設定ファイル解説

```bash
<Proxy "balancer://<任意の名前>">
    BalancerMember http://<APサーバー1のプライベートIP>:8080/knowledge
    BalancerMember http://<APサーバー2のプライベートIP>:8080/knowledge status=+H
</Proxy>

ProxyRequests Off
ProxyPass /knowledge balancer://<上記で設定した任意の名前>/
ProxyPassReverse /knowledge balancer://<上記で設定した任意の名前>/
```

上記の設定はロードバランサー（負荷分散）とリバースプロキシを設定するため設定である．

1. `<Proxy "balancer://<任意の名前>">`
   - 意味：ロードバランサーのグループを定義する「枠」の開始を宣言である．
   - 解説：`balancer://`というスキームを使用することで，Apacheにこれが負荷分散のグループであることを伝える．`<任意の名前>` には，システム内で識別するための独自の名前（例: `mycluster` など）を設定する．
&nbsp;
2. `BalancerMember http://<APサーバー1のプライベートIP>:8080/knowledge`
   - 意味：グループに所属させる1台目のアプリケーション（AP）サーバーを登録している．
   - 解説：クライアントからリクエストが来ると，通常はこのサーバーに通信が振り分けられる．ポート番号 `8080` の `/knowledge` というパスへ転送される．
&nbsp;
3. `BalancerMember http://<APサーバー2のプライベートIP>:8080/knowledge status=+H`
   - 意味：グループに所属させる2台目のAPサーバーを，バックアップ専用として登録している．
   - 解説：末尾の `status=+H` は「ホットスタンバイ（Hot Standby）」を意味するオプションである．1台目のサーバーが正常に動いている間，この2台目には一切リクエストが飛ばない．1台目がダウンしたときだけ，自動的にこの2台目が身代わりとして通信を引き受ける．
&nbsp;
4. `</Proxy>`
   - 意味：ロードバランサーグループの定義（枠）の終了を示す．
   - 解説：1行目の `<Proxy ...>` と対になっており，ここまでがグループの設定であることを表す．
&nbsp;
5. `ProxyRequests Off`
   - 意味：「フォワードプロキシ」としての機能を無効化する．
   - 解説：セキュリティ上の重要な設定である．これが `On` になっていると，外部の不特定多数のユーザーがApacheを中継地点にして別のサイトにアクセスできてしまい，不正利用（踏み台）の原因になる．リバースプロキシを構築する際は必ず Off にする．
&nbsp;
6. `ProxyPass /knowledge balancer://<上記で設定した任意の名前>/`
   - 意味：特定のURLへのアクセスを，ロードバランサーに転送（丸投げ）する設定である．
   - 解説：クライアントが `http://(ApacheのIPやドメイン)/knowledge` にアクセスしたとき，そのリクエストを1行目で定義したロードバランサーグループ（`balancer://...`）へ転送する．
&nbsp;
7. `ProxyPassReverse /knowledge balancer://<上記で設定した任意の名前>/`
   - 意味：APサーバーから返ってきた「リダイレクト指示」のURLを，Apacheが適切に書き換える設定である．
   - 解説：APサーバーがクライアントに対して「別のページに移動して（リダイレクト）」と返答した際，APサーバーの内部IPアドレスがそのままクライアントに見えてしまうのを防ぐ．Apacheが自分のURL（`/knowledge`）に書き換えてからクライアントに伝えることで，裏側のネットワーク構成を隠蔽し，エラーを防ぐ．

------------------------------

### C. 用語解説

| 用語 | 説明 |
|------|------|
| ロードバランサー | 複数のサーバーへのアクセスを振り分けて負荷を分散する仕組み。 |
| リバースプロキシ | クライアントからのリクエストを受け取り、裏側のサーバーに転送する仕組み。 |
| Hot Standby（ホットスタンバイ） | 通常時は待機状態にしておき、メインのサーバーがダウンした時だけ自動的に切り替わる冗長化方式。 |
| Sticky Session（セッション維持） | 同じユーザーからのリクエストを常に同じサーバーに振り分ける機能。ログイン状態やカート内容を保つために必要。 |
| 冗長化 | 一部のサーバーがダウンしてもサービスを継続できるように、複数の同等な構成を用意すること。 |

------------------------------

### D. 補足解説

**アクティブ/スタンバイ構成（Hot Standby）**
```bash
<Proxy "balancer://<任意の名前>">
    BalancerMember http://<APサーバー1のプライベートIP>:8080/knowledge
    BalancerMember http://<APサーバー2のプライベートIP>:8080/knowledge status=+H
</Proxy>
```

**ロードバランシングとセッション維持（Sticky Session）構成**
```bash
<Proxy "balancer://<任意の名前>">
    BalancerMember http://<APサーバー1のプライベートIP>:8080/knowledge route=ap1
    BalancerMember http://<APサーバー2のプライベートIP>:8080/knowledge route=ap2
</Proxy>
```

1. アクティブ/スタンバイ構成
   - 動作：APサーバー1が「本番用（アクティブ）」、APサーバー2が「待機用（スタンバイ）」
   - `status=+H`の意味：Hot Standby（ホットスタンバイ）
   - トラフィックの挙動：通常時は全てのアクセスがAPサーバー1だけに送信される。APサーバー1がダウン（障害発生）した場合のみ、自動的にAPサーバー2へアクセスが切り替わる。
&nbsp;
2. ロードバランシングとセッション維持構成
   - 動作：APサーバー1とAPサーバー2の両方に、アクセスを分散（ロードバランシング）させる。
   - `route=`の意味：スティッキーセッション（セッション維持）のための識別子（ルート名）を定義している。
   - トラフィックの挙動：通常時は2台のサーバーに均等（デフォルトの重み）にアクセスが振り分けられる。
   - 補足：この`route`設定を有効に機能させるには、`Header`や`ProxyPass`側で`stickysession=JSESSIONID`（Tomcat等の場合）などのセッション追跡設定を組み合わせる必要がある。これにより、一度APサーバー1に繋がったユーザーは、以降も必ずAP1に転送されるようになる。

**セッション維持とは**
負荷分散におけるセッション維持（セッションアフィニティ/パーシステンス）とは、同一のユーザー（クライアント）からの一連のリクエストを、常に同じ背後のサーバーへ継続して振り分ける機能のこと

**なぜセッション維持が必要なのか？**
ロードバランサー（負荷分散装置）は、通常、複数のサーバーにアクセスを均等に割り振る。しかし、以下のような「一連のつながりを持った操作（セッション）」を行う場合、サーバーが変わると困る事態が発生する。
- ECサイトの買い物かご：サーバーAで「カートに商品を入れた」のに、次の「決済画面」でサーバーBに飛ばされると、サーバーBはカートの中身を知らないため商品が消えてしまう。
- ログイン状態の保持：サーバーAでログイン認証を済ませても、次のリクエストがサーバーBに行くと「ログインしていません」と判定され、強制ログアウトされてしまう。
セッション維持機能を使うことで、特定のユーザーの一連の操作が必ず1つのサーバーで完結するため、ユーザーは途切れることなくサービスを利用できる。