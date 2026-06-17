# ApacheとTomcatを用いたWeb/APサーバーの構築

------------------------------

## 1. ドキュメント情報

| 項目 | 内容 |
|------|------|
| 手順書名 | 手順書_Apache_Tomcat_基本構築 |
| 作成日 | 2026-05-16 |
| 最終更新日 | 2026-05-16 |
| バージョン | v1.0 |
| 対象環境 | AWS |

> **改訂履歴**
>
> | バージョン | 日付 | 変更内容 |
> |-----------|------|---------|
> | v1.0 | 2026-05-16 | 初版作成 |

------------------------------

## 2. 目的・概要

### 2-1. 目的

> 本手順書では， Webサーバーとして「Apache」，APサーバーとして「Tomcat」を用いて，情報共有OSSである「knowledge」のWebページを表示させるための構築手順について説明する．
> 構築後はブラウザで「`http://<EC2のパブリックIP>/knowledge`」にアクセスし，Webページを閲覧可能な状態を目指す．

### 2-2. 構成概要（アーキテクチャ）

```
[ローカルPC（ブラウザ）]
       |
       | HTTP（80）
       v
[EC2: Amazon Linux 2023]
  ├── Apache（Webサーバー / 80番ポート）
  │     └─ /knowledge へのリクエストを127.0.0.1:8080へプロキシ転送
  └── Tomcat（APサーバー / 8080番ポート）
        └─ /usr/local/tomcat/webapps/knowledge にデプロイ
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

**目的：** Apacheのシステム設定と転送設定の手順について説明する．

#### 操作手順

```bash
# Apacheのインストール
dnf install -y httpd

# Apacheのプロキシ設定ファイルの作成と書き込み
vi /etc/httpd/conf.d/proxy.conf

    #---以下を記入---------------------------------------------
    ProxyRequests Off
    ProxyPass /knowledge http://127.0.0.1:8080/knowledge
    ProxyPassReverse /knowledge http://127.0.0.1:8080/knowledge
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

1. `wget <URL>`：インターネット上からファイルをダウンロードするためのコマンドである．
   - ファイルはカレントディレクトリに保存される．
&nbsp;
2. `mv amazon-corretto-8.492.09.2-linux-x64 /opt`：解凍したJDKを`/opt`に移動する理由は，Linuxの標準規格（FHS）で「他者がビルド（製品化）済みの独立したソフトウェア一式は`/opt`に置く」という強力な慣習（お作法）があるからである．この慣習の背景にある理由を，3つのポイントで解説する．
&nbsp;
【Linuxのフォルダの住み分け（慣習）】
　   ├── `/usr/`        : OSの管理用（勝手に触ってはダメ）
　   ├── `/usr/local/`  : 自分でソースから組み立てた（ビルドした）ツール用
　   └── `/opt/`        : 他人が組み立ててくれた（ビルド済み）完成品用
&nbsp;
   1. 「ビルド済み」の完成品フォルダだから
       - ダウンロードしたJDKは，開発元（OracleやAdoptiumなど）がすでにプログラムを組み立て終えた「ビルド済み」の完成品である．
        解凍したフォルダの中に，実行ファイル（`bin`）や設定ファイル，ライブラリ（`lib`）がすべて綺麗にパッケージングされている．
       - Linuxの慣習では，このような「1つのフォルダ内で自己完結している完成品」は `/opt/jdk-21/` のように丸ごと `/opt` に置くことになっている.
&nbsp;
   2. 他の場所（`/usr/local`）だと中身が散らばるから
       - もし慣習を無視して `/usr/local` に中身を移動してしまうと，JDKの中身（`bin` や `lib`）が，システム全体の共通フォルダ（`/usr/local/bin` や `/usr/local/lib`）の中にバラバラに混ざってしまう．
       - これを行うと，将来Javaをアップデートしたい時や，削除したい時に，どのファイルがJavaのものだったか分からなくなり，システムが汚れる原因になる．`/opt` に置いておけば，フォルダを丸ごと削除・差し替えるだけで済むため非常に安全．
&nbsp;
   3. 世界中のエンジニアと「共通認識」を持てるから
       - インフラの世界では，「手動で入れた外部ツールは `/opt` を見ればある」という共通のエンジニア間の暗黙の了解がある．
        この慣習に従っておくことで，以下のような実務上のメリットが生まれる．
         - インターネット上の解説記事や手順書のコード（`export JAVA_HOME=/opt/jdk-21` など）をそのまま真似して動かせる．
         - 他のエンジニアがあなたのサーバーを触ったときに，どこにJavaがあるか一発で理解できる．
&nbsp;
3. `echo $PATH`：システムがコマンドを検索するディレクトリの一覧を表示するコマンド
&nbsp;   
4. `source <ファイルパス>`：指定したファイルに書かれた設定やスクリプトを，現在の画面（シェル）に直接読み込んで実行するコマンド
&nbsp;   
5. `ln -s <ファイル・ディレクトリパス（元）> <ファイル・ディレクトリパス（先）>`：ファイルやディレクトリの「シンボリックリンク（ショートカット）」を作成するためのコマンドである．
   各パラメーターの役割
   - `ln`：リンク（Link）を作成するコマンド．
   - `-s`：シンボリックリンク（Symbolic link）を作成するオプションである．これがないと「ハードリンク」という別の仕組みになる．
   - `<ファイル・ディレクトリパス（元）>`：すでにサーバー上に存在する，本物のファイルやディレクトリのパス．
   - `<ファイル・ディレクトリパス（先）>`：これから新しく作成する，ショートカット（リンク）の名前やパス．
&nbsp;
6. `chmod 755 /etc/systemd/system/tomcat.service`：作成したTomcatのサービス定義ファイル（`tomcat.service`）を，Linuxシステム（`systemd`）が正常に読み込んで実行できるようにするための権限設定である．
   `755` の意味は以下の通りである．
   - **所有者（root）**：読み（r）・書き（w）・実行（x） が可能（`7` = `rwx`）
   - **グループ**：読み（r）・実行（x） が可能（`5` = `r-x`）
   - **その他のユーザー**：読み（r）・実行（x） が可能（`5` = `r-x`）
&nbsp;
   このように設定することで，所有者であるrootだけがファイルを編集でき，systemdを含む他のユーザーは内容を読み取ることだけができる．
&nbsp;
   ※ 参考：systemd のユニットファイルは `644`（所有者のみ書き込み可、他は読み取りのみ）で設定されることも多い．本手順書では `755` を採用しているが，`644` でも動作上は問題ない．
&nbsp;
7. `systemctl daemon-reload`：新しく作成・変更したサービスファイルを，Linuxの管理システム（`systemd`）に今すぐ認識させるためである．
   Linuxは，サービスファイルを追加・編集しただけではその内容を認識しないので，このコマンドを実行し，設定をシステムに同期させる．
&nbsp;
8. `chown -R tomcat:tomcat knowledge/`：TomcatがWebアプリケーション（Knowledge）を実行する際に，ファイルの読み込みや書き込み（データの保存，ログの出力など）を正常に行えるようにするため．Linuxのセキュリティと動作の観点から，主に以下の3つの理由がある.
&nbsp;
   1. Tomcat（プログラム）がファイルを操作できるようにするため
       Tomcatはセキュリティを高めるため，通常 `root`（管理者）ではなく，権限を制限した `tomcat` という専用ユーザーでバックグラウンド実行される．
       もしファイルの所有権が `root` のままだと，`tomcat` ユーザーがファイルにアクセス（読み書き）できず，アプリケーションがエラーを起こして起動しない，またはデータの保存や設定の変更ができない状態になる．
&nbsp;
   2. Knowledgeが「書き込み」を行うため
       KnowledgeのようなWebアプリケーションは，動いている最中に以下のようなファイルを新しく作成したり更新したりする．
       - ユーザーがアップロードした画像や添付ファイル
       - 記事やコメントなどのデータ（H2データベースなどのファイル）
       - 動作ログ（ログファイル）
  
       これらの保存先ディレクトリの所有権が `tomcat` になっていないと，「書き込み権限エラー（Permission Denied）」が発生してデータの保存に失敗する．
&nbsp;
   3. セキュリティのリスクを最小限にするため（最小権限の原則）
       すべてのファイルの所有者を，何でもできる最強の権限を持つ `root` のままにしておくのはセキュリティ上危険である．万が一，Webアプリケーション（Knowledge）に脆弱性があり外部から不正アクセスされた場合，プログラムが `root` 権限で動いていると，サーバー全体のシステムファイルを書き換えられるなどの致命的な被害に遭う可能性がある．所有権を専用の `tomcat` ユーザーに限定しておくことで，被害をそのアプリケーション内だけに閉じ込めることができる．

------------------------------

### B. 設定ファイル解説

```bash
if ! [[ "$PATH" =~ "$HOME/.local/bin:$HOME/bin:" ]]
then
    PATH="$HOME/.local/bin:$HOME/bin:$PATH"
fi
```

上記のスクリプトは，環境変数 `PATH`（コマンドを探す場所のリスト）の先頭に，ユーザー個人の実行ファイル置き場である `$HOME/.local/bin` と `$HOME/bin` を追加する処理である．
また，すでに登録されている場合は二重に登録しない（PATHが汚れない）ように制御している．
- 1行目：`if ! [[ "$PATH" =~ "$HOME/.local/bin:$HOME/bin:" ]]`
  - `$PATH`：現在登録されているコマンドの検索パスの文字列である（例: `/usr/bin:/bin:/usr/sbin`）．
  - `=~`：右側の文字列が，左側の変数の中に含まれているか（部分一致するか）を判定する比較演算子である．
  - `!`：判定結果を反転させる（「〜でなければ」という意味になりる）．
  - まとめ：「もし現在の `$PATH` の中に，`$HOME/.local/bin:$HOME/bin:` という文字列がまだ含まれていなければ」という条件分岐である．
- 2行目：`then`
  - 条件が成り立った場合（まだ登録されていない場合）に，次の処理を実行する．
- 3行目：`PATH="$HOME/.local/bin:$HOME/bin:$PATH"`
  - 新しいパスを先頭に追加して，`PATH` 変数を上書きしている．
  - パスは左側から順番に探されるため，先頭に書くことでシステム標準のコマンドよりも自分のフォルダ内のコマンドを最優先で実行できるようになる．
- 4行目：`fi`
  - if 文の終了を意味する．
なぜこの処理が必要なのか
LinuxやmacOSでは，自分でインストールしたツールやスクリプトを `$HOME/.local/bin` や `$HOME/bin` に配置することがよくある．
このスクリプトを `.bashrc` や `.bash_profile` などの設定ファイルに書いておくことで，シェル（ターミナル）を起動したときに自動でパスが通り，いつでも自作コマンドを呼び出せるようになる．

------------------------------

### C. 用語解説

1. JDK（Java Development Kit）：Javaのプログラムを開発するために必要な道具が全てそろっているパッケージ（Java開発キット）
   Javaを使ってシステムを作ったり，「knowledge」や「Tomcat」などのJava製アプリケーションをサーバーで動かしたりするときに必ず必要になる．

------------------------------

### D. 補足解説

1. WebサーバーとしてのTomcat
   今回はWebサーバーとして「Apache」，APサーバーとして「Tomcat」を利用したので，データフローはHTTPリクエストをApacheが受け取り，Tomcatに転送するという流れだった．
&nbsp;
   しかし，設定を少し変更することで，Tomcat1台のみでWebサーバーとAPサーバーの両方の役割を担った構成になる．
   具体的な変更点は以下の通りである．
&nbsp;
   - セキュリティグループのインバウンドルールに以下の設定を加える

     | タイプ | プロトコル | ポート範囲 | ソース | 説明 |
     |-------|------------|----------|--------|------|
     | HTTP | TCP | 8080 | マイIP | ローカルPCからHTTPアクセス許可 |

   - Apacheのプロキシ設定（`/etc/httpd/conf.d/proxy.conf`）を無効化する（ファイルを削除またはリネーム）
   - ブラウザでのURLを以下に変更する
   `http://<EC2のパブリックIP>:8080/knowledge`