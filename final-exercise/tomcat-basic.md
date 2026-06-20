# Tomcatを用いたAPサーバー構築

------------------------------

## 1. ドキュメント情報

| 項目 | 内容 |
|------|------|
| 手順書名 | Tomcatを用いたAPサーバー構築 |
| 作成日 | 2026-06-18 |
| 最終更新日 | 2026-06-18 |
| バージョン | v1.0 |
| 対象環境 | AWS（Amazon Linux 2023） |

> **改訂履歴**
>
> | バージョン | 日付 | 変更内容 |
> |-----------|------|---------|
> | v1.0 | 2026-06-18 | 初版作成（テンプレートに沿って再構成．構成図追加．`tomcat.service`に`PIDFile`追加．プレースホルダーを意味ベースに統一．パラメータ定義表を統合．各Stepに【実施対象】明示．句読点を「，．」に統一．サーバー表記を「サーバー」に統一．付録A〜D追加．） |

------------------------------

## 2. 目的・概要

### 2-1. 目的

> 本手順書では，AWSのEC2インスタンス上にApache Tomcatをインストールし，バックエンドのAPサーバーとして稼働させる手順について説明する．
> Java実行環境にはAmazon Corretto，Tomcatの起動・自動起動制御にはsystemdを使用する．
> 構築後はWebサーバー（Nginx等）から「`http://<APサーバーのFQDN>:8080/`」へのリクエストを受けてアプリケーションを返す状態を目指す．
> 本手順書は **Tomcat本体の構築まで** を範囲とする．アプリケーション（`ROOT.war`等）の配置は別手順書で実施する．

### 2-2. 構成概要（アーキテクチャ）

```
[Webサーバー（Nginx）]
       |
       | HTTP（8080）
       v
┌────────────────────────── VPC ──────────────────────────┐
│                                                          │
│  [EC2: APサーバー]                                        │
│    ├─ Amazon Corretto（Java実行環境）                     │
│    ├─ Apache Tomcat（8080番ポート）                       │
│    │    └─ /tomcat-default → Tomcat標準ページ             │
│    └─ systemd（tomcat.service で起動管理）                │
│                                                          │
│    [systemd-resolved → 内部DNS]                          │
│       └─ <APサーバーのFQDN> 名前解決                       │
│                                                          │
└──────────────────────────────────────────────────────────┘
```

### 2-3. 完成イメージ（ゴール定義）

- [ ] Amazon CorrettoがインストールされJavaコマンドが実行できる
- [ ] tomcatユーザーが存在し，Tomcat配下のファイルがtomcat所有になっている
- [ ] `tomcat.service` がsystemdで`active (running)`かつ自動起動有効である
- [ ] 8080番ポートでJavaプロセスがLISTENしている
- [ ] APサーバー上で「`curl -I http://localhost:8080/tomcat-default/`」が `HTTP/1.1 200` を返す
- [ ] Webサーバーから「`curl -I http://<APサーバーのFQDN>:8080/tomcat-default/`」が `HTTP/1.1 200` を返す
- [ ] `catalina.out` に `SEVERE` / `ERROR` レベルのログが出ていない

------------------------------

## 3. 前提条件・準備

### 3-1. 環境要件

| 項目 | 要件 |
|------|------|
| OS | Amazon Linux 2023 |
| CPU | 2コア以上推奨 |
| メモリ | 2GB以上 |
| ストレージ | 16GB以上 |
| Java | Amazon Corretto（バージョンはパラメータで指定） |
| Tomcat | Apache Tomcat 9.x（バージョンはパラメータで指定） |
| 配置サブネット | internal-ap サブネット（AZ2 または AZ4） |

### 3-2. セキュリティグループ設定

#### 3-2-1. APサーバーのインバウンドルール

| タイプ | プロトコル | ポート範囲 | ソース | 説明 |
|-------|------------|----------|--------|------|
| SSH | TCP | 22 | マイIP | ローカルPCからSSHで接続（踏み台経由） |
| カスタムTCP | TCP | 8080 | WebサーバーのプライベートIP | Webサーバーからのプロキシ転送許可 |

#### 3-2-2. APサーバーのアウトバウンドルール

| タイプ | プロトコル | ポート範囲 | 送信先 | 説明 |
|-------|------------|----------|--------|------|
| HTTPS | TCP | 443 | 0.0.0.0/0 | dnf／Tomcat配布物／Correttoのダウンロード |
| HTTP | TCP | 80 | 0.0.0.0/0 | dnfミラー |
| DNS | UDP | 53 | 内部DNSサーバーのSG | 内部名前解決 |

### 3-3. パラメータ定義表

> **注意：** 以下の値は作業前に環境に合わせて記入してから作業を開始すること．

| パラメータ名 | 値 | 説明 |
|------------|---|------|
| `<APサーバーのホスト名>` | `<記入する>` | このサーバーのホスト名（例：`<任意の名前>-ap`） |
| `<プライマリDNSのIP>` | `<記入する>` | 内部DNSプライマリ（AZ2のAPサーバー）のIP |
| `<セカンダリDNSのIP>` | `<記入する>` | 内部DNSセカンダリ（AZ4のAPサーバー）のIP |
| `<Javaバージョン>` | 例：`17` | Amazon Correttoのメジャーバージョン（8系=1.8.0／11系=11／17系=17） |
| `<TOMCAT_URL>` | `<記入する>` | Tomcat配布物URL（Apache公式から最新版を取得） |
| `<TOMCAT_TGZ>` | `<記入する>` | アーカイブファイル名（`<TOMCAT_URL>`のbasename） |
| `<TOMCAT_DIR>` | `<記入する>` | 展開ディレクトリ名（`.tar.gz`を除いた名前） |
| `<TOMCAT_INSTALL_DIR>` | `/usr/local` | Tomcat本体を配置するディレクトリ |
| `<TOMCAT_MAJOR>` | 例：`9` | Tomcatメジャーバージョン |
| `<最小ヒープサイズ>` | 例：`512M` | JVM最小ヒープ（`-Xms`） |
| `<最大ヒープサイズ>` | 例：`1024M` | JVM最大ヒープ（`-Xmx`） |
| `<JAVA_HOME>` | `<Step 3 で確定>` | Javaインストール先（`readlink -f`で確認） |

#### 【ロールバック用（任意）】

| パラメータ名 | 値 | 説明 |
|------------|---|------|
| `<元のホスト名>` | `<記入する>` | 構築前のホスト名（戻す場合のみ記入） |
| `<元のタイムゾーン>` | `<記入する>` | 構築前のタイムゾーン（戻す場合のみ記入） |

### 3-4. リンク一覧

| 項目名 | 目的 |
|-------|------|
| https://tomcat.apache.org/ | Tomcat配布物URLの最新版確認 |
| https://archive.apache.org/dist/tomcat/ | 旧バージョンのアーカイブ |
| https://docs.aws.amazon.com/corretto/ | Amazon Corretto公式ドキュメント |

------------------------------

## 4. 構築手順（詳細）

> **注意事項**
> - コマンド中の `<山カッコ>` は自分の環境の値（パラメータ定義表の値）に置き換えること
> - 各Stepの見出し末尾に **【実施対象：APサーバー】** を明示しているので，対象のサーバーで実施すること
> - 本手順書の作業対象はすべて **APサーバー** である
> - 内部DNS構築手順書（`nsd-private-redundancy.md`）等でsystem-setupを既に実施済みの場合，Step 1はスキップ可能

------------------------------

### Step 1：system-setup（共通システム設定）【実施対象：APサーバー】

**目的：** タイムゾーン，ホスト名，通信確認ツール，名前解決先を設定する

#### 操作手順

```bash
# rootユーザーにスイッチ
sudo su -

# パッケージを最新化
dnf update -y

# タイムゾーンを Asia/Tokyo に設定
timedatectl set-timezone Asia/Tokyo

# ホスト名を設定
hostnamectl set-hostname <APサーバーのホスト名>

# 通信確認ツール（nc）の存在確認
command -v nc
# → 何も表示されなければ未インストール

# nc が未インストールの場合のみ実行
dnf install -y nmap-ncat

# systemd-resolved 設定用ディレクトリ作成
mkdir -p /etc/systemd/resolved.conf.d

# 内部DNSを参照する設定ファイルを作成
vi /etc/systemd/resolved.conf.d/wp-local.conf
```

設定ファイルの記述内容：

```
[Resolve]
DNS=<プライマリDNSのIP> <セカンダリDNSのIP>
```

```bash
# systemd-resolved を再起動
systemctl restart systemd-resolved

# カーネル更新の確認（任意）
dnf needs-restarting -r
# → 再起動が必要と表示された場合のみ reboot を実行
```

> **注意：** ホスト名をシェルのプロンプトに反映させるため，作業途中で一度SSHを切断して再接続すること．
> **注意：** カーネル更新で再起動した場合は，再度SSH接続してからStep 2以降に進むこと．

------------------------------

### Step 2：基本パッケージ（wget／tar）の確認【実施対象：APサーバー】

**目的：** Tomcat配布物のダウンロードと展開に必要なパッケージを確認する

#### 操作手順

```bash
# wget と tar の存在確認
command -v wget
command -v tar
# → どちらかが空であれば未インストール

# どちらかが未インストールの場合のみ実行
dnf install -y wget tar
```

> **補足：** Amazon Linux 2023には標準で `tar` が含まれているが，`wget` は環境により含まれていない場合がある．

------------------------------

### Step 3：Amazon Correttoのインストール【実施対象：APサーバー】

**目的：** Tomcatの動作に必要なJava実行環境（Amazon Corretto）をインストールする

#### 操作手順

```bash
# Amazon Corretto をインストール
dnf install -y java-<Javaバージョン>-amazon-corretto-devel

# javac の存在確認
command -v javac
# → /usr/bin/javac が表示されること

# JAVA_HOME の特定
readlink -f $(command -v javac)
# → 例：/usr/lib/jvm/java-11-amazon-corretto.x86_64/bin/javac
```

> **注意：** 上記出力の `bin/javac` を除いた部分が `<JAVA_HOME>` となる．例えば上記出力なら `/usr/lib/jvm/java-11-amazon-corretto.x86_64` が `<JAVA_HOME>`．**この値をパラメータ定義表の `<JAVA_HOME>` 欄に記入すること．**

```bash
# JAVA_HOME の確認
ls <JAVA_HOME>/bin/java
# → ファイルが存在することを確認
```

------------------------------

### Step 4：tomcatユーザーの作成【実施対象：APサーバー】

**目的：** Tomcatプロセスを実行するための専用ユーザー（システムユーザー）を作成する

#### 操作手順

```bash
# tomcatユーザーの存在確認
id tomcat
# → "no such user" が出れば未作成

# 未作成の場合のみ実行（ログイン不可のシステムユーザーとして作成）
useradd -r -s /sbin/nologin tomcat

# 作成確認
id tomcat
```

> **補足：** `-r` はシステムユーザー（UID 1000未満）として作成するオプション．`-s /sbin/nologin` はシェルログイン不可とする指定．

------------------------------

### Step 5：Tomcat配布物のダウンロードと展開【実施対象：APサーバー】

**目的：** Apache公式からTomcat配布物を取得し，`<TOMCAT_INSTALL_DIR>` 配下に配置する

#### 操作手順

```bash
# 作業ディレクトリへ移動
cd /tmp

# Tomcat配布物をダウンロード
wget -q <TOMCAT_URL> -O <TOMCAT_TGZ>

# 展開
tar zxf <TOMCAT_TGZ>

# 既存ディレクトリのクリア（冪等性確保のため）
rm -rf <TOMCAT_INSTALL_DIR>/<TOMCAT_DIR>

# 展開先へ移動
mv <TOMCAT_DIR> <TOMCAT_INSTALL_DIR>/
```

> **注意：** Tomcat配布物URLは新しいバージョンがリリースされると古いものはアーカイブ（`https://archive.apache.org/dist/tomcat/`）に移動するため，事前に到達確認しておくこと．

> **テスト：** ダウンロード前に以下で到達確認可能．
> ```bash
> curl -I <TOMCAT_URL>
> # → HTTP/2 200 または HTTP/1.1 200 が返れば成功
> ```

------------------------------

### Step 6：既定ROOTのリネーム【実施対象：APサーバー】

**目的：** Tomcat標準ページ（`webapps/ROOT`）を `tomcat-default` にリネームし，後でアプリ用 `ROOT.war` を配置した際に競合しないようにする

#### 操作手順

```bash
# 既定ROOTディレクトリの存在確認
ls -d <TOMCAT_INSTALL_DIR>/<TOMCAT_DIR>/webapps/ROOT

# 存在する場合のみリネーム
mv <TOMCAT_INSTALL_DIR>/<TOMCAT_DIR>/webapps/ROOT <TOMCAT_INSTALL_DIR>/<TOMCAT_DIR>/webapps/tomcat-default
```

> **補足：** リネーム後，`http://<APサーバーのFQDN>:8080/tomcat-default/` でTomcat標準ページが表示されるようになる．

------------------------------

### Step 7：所有者変更とシンボリックリンク作成【実施対象：APサーバー】

**目的：** Tomcat配下を `tomcat` ユーザー所有に変更し，バージョン非依存のシンボリックリンクを作成する

#### 操作手順

```bash
# 所有者を tomcat に変更
chown -R tomcat:tomcat <TOMCAT_INSTALL_DIR>/<TOMCAT_DIR>

# シンボリックリンク作成（バージョン非依存のパスを提供）
ln -sfn <TOMCAT_INSTALL_DIR>/<TOMCAT_DIR> <TOMCAT_INSTALL_DIR>/tomcat

# 確認
ls -ld <TOMCAT_INSTALL_DIR>/tomcat
# → tomcat -> <TOMCAT_INSTALL_DIR>/<TOMCAT_DIR> が表示されること
```

> **補足：** シンボリックリンク `<TOMCAT_INSTALL_DIR>/tomcat` を経由することで，Tomcatをバージョンアップしてもsystemdユニットファイル等の設定変更が不要になる．

------------------------------

### Step 8：systemdユニットファイルの作成【実施対象：APサーバー】

**目的：** systemdでTomcatを起動・自動起動制御するためのユニットファイルを作成する

#### 操作手順

```bash
# ユニットファイルを新規作成
vi /etc/systemd/system/tomcat.service
```

設定ファイルの記述内容：

```ini
[Unit]
Description=Apache Tomcat <TOMCAT_MAJOR> Web Application Container
After=network.target

[Service]
Type=forking
PIDFile=<TOMCAT_INSTALL_DIR>/tomcat/temp/tomcat.pid

User=tomcat
Group=tomcat

Environment="JAVA_HOME=<JAVA_HOME>"
Environment="CATALINA_PID=<TOMCAT_INSTALL_DIR>/tomcat/temp/tomcat.pid"
Environment="CATALINA_HOME=<TOMCAT_INSTALL_DIR>/tomcat"
Environment="CATALINA_BASE=<TOMCAT_INSTALL_DIR>/tomcat"
Environment="CATALINA_OPTS=-Xms<最小ヒープサイズ> -Xmx<最大ヒープサイズ> -server -XX:+UseParallelGC"
Environment="JAVA_OPTS=-Djava.awt.headless=true -Djava.security.egd=file:/dev/./urandom"

ExecStart=<TOMCAT_INSTALL_DIR>/tomcat/bin/startup.sh
ExecStop=<TOMCAT_INSTALL_DIR>/tomcat/bin/shutdown.sh

Restart=on-failure
RestartSec=10

[Install]
WantedBy=multi-user.target
```

> **重要：** `Type=forking` を使う場合は `PIDFile=` ディレクティブが必須．これがないとsystemdが子プロセスの状態を正しく追跡できず，`systemctl status` が `active (running)` にならない場合がある．

> **補足：** `CATALINA_PID` 環境変数と `PIDFile=` の指定パスは一致させること．

------------------------------

### Step 9：systemdへの反映とTomcat起動【実施対象：APサーバー】

**目的：** systemdに設定を反映し，Tomcatを起動・自動起動有効化する

#### 操作手順

```bash
# systemd の設定リロード（ユニットファイル変更を反映）
systemctl daemon-reload

# Tomcat を起動し，自動起動を有効化
systemctl enable --now tomcat.service

# 起動確認（active (running) であること）
systemctl status tomcat.service --no-pager

# 自動起動確認（enabled であること）
systemctl is-enabled tomcat.service
```

> **注意：** 起動失敗時は `journalctl -u tomcat.service -n 100 --no-pager` および `cat <TOMCAT_INSTALL_DIR>/tomcat/logs/catalina.out` でログを確認する．

------------------------------

## 5. 動作確認・検証

> 構築完了後，以下の確認をすべてパスしたら構築成功とみなす．

### 5-1. 確認チェックリスト

- [ ] **確認①**：Tomcatサービスが `active (running)` かつ自動起動有効である
- [ ] **確認②**：8080番ポートでJavaプロセスがLISTENしている
- [ ] **確認③**：APサーバー上で `tomcat-default` ページが200で返る
- [ ] **確認④**：`catalina.out` にエラーが出ていない
- [ ] **確認⑤**：Webサーバーから `tomcat-default` ページにアクセスできる（E2E）

------------------------------

### 確認①：サービス状態確認

```bash
systemctl status tomcat.service --no-pager
systemctl is-enabled tomcat.service
```

**期待する結果：** `active (running)` および `enabled` が表示される．

------------------------------

### 確認②：リッスンポート確認

```bash
ss -tlnp | grep :8080
```

**期待する結果：** Javaプロセスが8080番でLISTENしている．

```
LISTEN 0  100  *:8080  *:*  users:(("java",pid=...))
```

------------------------------

### 確認③：HTTPアクセス確認（APサーバー上）

```bash
curl -I http://localhost:8080/tomcat-default/
```

**期待する結果：** `HTTP/1.1 200` が返る．

------------------------------

### 確認④：ログ確認

```bash
tail -n 50 <TOMCAT_INSTALL_DIR>/tomcat/logs/catalina.out
```

> **注意：** `SEVERE` や `ERROR` レベルのログが出ていないか目視確認する．

------------------------------

### 確認⑤：Webサーバーからの疎通確認（E2E）

Webサーバー上で以下を実行：

```bash
curl -I http://<APサーバーのFQDN>:8080/tomcat-default/
```

**期待する結果：** `HTTP/1.1 200` が返る．

> **補足：** 失敗する場合，APサーバー側SGの8080番許可，DNS名前解決，VPC内ルーティングを確認する．

------------------------------

## 6. トラブルシューティング

### よくあるエラーと対処法

------------------------------

#### エラー①：`wget: ERROR 404: Not Found`

**原因：** Tomcat配布物のURLが古い，もしくはバージョンがアーカイブに移動した．

**対処法：**

1. Apache公式（https://tomcat.apache.org/）で最新の配布URLを確認
2. 古いバージョンは https://archive.apache.org/dist/tomcat/ に移動している場合がある
3. 正しいURLに置き換えてStep 5から再実行

------------------------------

#### エラー②：`tomcat.service: Failed to start`

**原因：** ヒープサイズが大きすぎてメモリ不足，もしくはJavaのパス不正．

**対処法：**

```bash
# systemdログを確認
journalctl -u tomcat.service -n 100 --no-pager

# Tomcatログを確認
cat <TOMCAT_INSTALL_DIR>/tomcat/logs/catalina.out
```

必要に応じて `/etc/systemd/system/tomcat.service` を修正後，以下を実行：

```bash
systemctl daemon-reload
systemctl restart tomcat.service
```

------------------------------

#### エラー③：`JAVA_HOME` が想定と異なる

**原因：** 複数バージョンのJavaがインストールされている．

**対処法：**

```bash
# Java実装の切替
alternatives --config java
alternatives --config javac
```

正しいバージョンを選択後，Step 3で `<JAVA_HOME>` を再特定し，Step 8の `tomcat.service` を更新する．

------------------------------

#### エラー④：`systemctl status` で `active (running)` にならない（`active (exited)` になる）

**原因：** `Type=forking` 指定なのに `PIDFile=` が無い，もしくはパスが間違っている．

**対処法：** Step 8の `PIDFile=` と `CATALINA_PID` の指定パスが一致しているか確認．

```bash
grep -E "^PIDFile|CATALINA_PID" /etc/systemd/system/tomcat.service
```

------------------------------

#### エラー⑤：Webサーバーから8080番に接続できない（タイムアウト）

**原因：** APサーバー側SGがWebサーバーからの8080番を許可していない．

**対処法：** AWSコンソールでAPサーバーのSGインバウンドルールに `カスタムTCP / 8080 / WebサーバーのプライベートIP` を追加．

------------------------------

### ログの確認場所

| ログの種類 | 場所（パス） |
|-----------|------------|
| Tomcat 標準出力 | `<TOMCAT_INSTALL_DIR>/tomcat/logs/catalina.out` |
| Tomcat アクセスログ | `<TOMCAT_INSTALL_DIR>/tomcat/logs/localhost_access_log.*.txt` |
| Tomcat エラーログ | `<TOMCAT_INSTALL_DIR>/tomcat/logs/catalina.*.log` |
| systemd ログ | `journalctl -u tomcat.service` |

------------------------------

## 7. 参考リソース・関連資料

| 資料名 | URL / 場所 | 補足 |
|-------|-----------|------|
| Apache Tomcat 公式ドキュメント | https://tomcat.apache.org/tomcat-9.0-doc/ | Tomcat 9系のドキュメント |
| Amazon Corretto ユーザーガイド | https://docs.aws.amazon.com/corretto/ | Java実行環境 |
| Amazon Linux 2023 ユーザーガイド | https://docs.aws.amazon.com/ja_jp/linux/al2023/ug/ | OS全般 |
| 別手順書：Nginxリバースプロキシ構築 | `nginx-reverse-proxy.md` | Webサーバー側の構築 |
| 別手順書：内部DNS構築 | `nsd-private-redundancy.md` | 名前解決の構築 |

------------------------------

## 8. ロールバック手順

### 8-1. Tomcatの停止と無効化【実施対象：APサーバー】

```bash
systemctl stop tomcat.service
systemctl disable tomcat.service
```

### 8-2. systemdユニットファイルの削除【実施対象：APサーバー】

```bash
rm -f /etc/systemd/system/tomcat.service
systemctl daemon-reload
systemctl reset-failed
```

### 8-3. Tomcat本体の削除【実施対象：APサーバー】

```bash
# 実体ディレクトリの確認
readlink -f <TOMCAT_INSTALL_DIR>/tomcat
# → <TOMCAT_INSTALL_DIR>/<TOMCAT_DIR>（apache-tomcat-X.Y.Z 形式）であること確認

# シンボリックリンクを削除
rm -f <TOMCAT_INSTALL_DIR>/tomcat

# 実体ディレクトリを削除
rm -rf <TOMCAT_INSTALL_DIR>/<TOMCAT_DIR>
```

> **注意：** `webapps/ROOT` などアプリケーションも一緒に削除される．アプリのみ戻したい場合は別途アプリ用ロールバック手順を使用すること．

### 8-4. ダウンロード一時ファイルの削除【実施対象：APサーバー】

```bash
rm -f /tmp/apache-tomcat-*.tar.gz
```

### 8-5. tomcatユーザーの削除【実施対象：APサーバー】

```bash
id tomcat
# → 存在する場合のみ実行
userdel tomcat
```

### 8-6. Amazon Correttoの削除（任意）【実施対象：APサーバー】

> **注意：** 他システムがJavaを使っていない場合のみ実施．

```bash
# インストール済みCorrettoの一覧確認
rpm -qa 'java-*-amazon-corretto-devel'

# 該当パッケージを削除
dnf remove -y java-<Javaバージョン>-amazon-corretto-devel
```

### 8-7. systemd-resolvedのDNS設定削除【実施対象：APサーバー】

```bash
rm -f /etc/systemd/resolved.conf.d/wp-local.conf
systemctl restart systemd-resolved
```

### 8-8. ホスト名・タイムゾーンの復元（任意）【実施対象：APサーバー】

```bash
hostnamectl set-hostname <元のホスト名>
timedatectl set-timezone <元のタイムゾーン>
```

### 8-9. 完了確認【実施対象：APサーバー】

```bash
systemctl status tomcat.service 2>&1 | head -3
# → "Unit tomcat.service could not be found." が表示されれば削除完了
```

> **注意：**
> - `dnf update` で適用したパッケージ更新は取り消さない（依存破壊リスクを避けるため）．
> - ホスト名を変更した場合はSSHを一度切断して再ログインすること．

------------------------------

## 付録

### A. コマンド解説

| コマンド | 説明 |
|---------|------|
| `dnf install -y <パッケージ>` | dnfからパッケージを非対話インストール． |
| `dnf needs-restarting -r` | カーネル等の更新で再起動が必要か確認． |
| `timedatectl set-timezone <TZ>` | システムのタイムゾーンを変更． |
| `hostnamectl set-hostname <名前>` | システムのホスト名を変更．プロンプトへの反映には再ログインが必要． |
| `useradd -r -s /sbin/nologin <名前>` | システムユーザー（ログイン不可）を作成． |
| `id <ユーザー名>` | ユーザーのUID/GIDを確認． |
| `command -v <コマンド>` | コマンドの実体パスを表示．存在しなければ空． |
| `readlink -f <パス>` | シンボリックリンクを再帰的にたどって実体パスを表示． |
| `chown -R <ユーザー>:<グループ> <パス>` | 所有者・所有グループを再帰的に変更． |
| `ln -sfn <ターゲット> <リンク名>` | シンボリックリンク作成．既存リンクは上書き． |
| `systemctl daemon-reload` | systemdのユニットファイル変更を読み込み直す． |
| `systemctl enable --now <サービス>` | サービスを起動し，自動起動を有効化． |
| `systemctl status <サービス> --no-pager` | サービスの稼働状態を確認（lessを使わない）． |
| `journalctl -u <サービス> -n <行数>` | 指定サービスのsystemdログを末尾N行表示． |
| `ss -tlnp` | TCPでLISTEN中のポートとプロセスを一覧表示． |
| `tail -n <数> <ファイル>` | ファイルの末尾N行を表示． |

------------------------------

### B. 設定ファイル解説

**`/etc/systemd/system/tomcat.service`（APサーバー）**

```
[Unit]
Description=Apache Tomcat <TOMCAT_MAJOR> Web Application Container
After=network.target
```

- `Description`：サービスの説明（`systemctl status` で表示される）．
- `After=network.target`：ネットワークが起動してからTomcatを起動する依存指定．

```
[Service]
Type=forking
PIDFile=<TOMCAT_INSTALL_DIR>/tomcat/temp/tomcat.pid
```

- `Type=forking`：起動コマンドが子プロセスをforkして親が終了する形式．Tomcatの`startup.sh`はこの形式で動作する．
- `PIDFile`：子プロセスのPIDが書かれるファイルパス．`Type=forking`では**必須**．

```
User=tomcat
Group=tomcat
```

- Tomcatプロセスを実行するユーザー／グループ．rootで動かすのはセキュリティ上避けるべき．

```
Environment="CATALINA_OPTS=-Xms<最小ヒープサイズ> -Xmx<最大ヒープサイズ> -server -XX:+UseParallelGC"
```

- `-Xms`：JVM最小ヒープサイズ．
- `-Xmx`：JVM最大ヒープサイズ．
- `-server`：サーバー用VM（長時間稼働向け最適化）．
- `-XX:+UseParallelGC`：パラレルGCを使用．

```
Environment="JAVA_OPTS=-Djava.awt.headless=true -Djava.security.egd=file:/dev/./urandom"
```

- `java.awt.headless=true`：GUI不要のサーバー環境向け設定．
- `java.security.egd=file:/dev/./urandom`：Tomcat起動時のエントロピー確保（起動高速化）．

```
ExecStart=<TOMCAT_INSTALL_DIR>/tomcat/bin/startup.sh
ExecStop=<TOMCAT_INSTALL_DIR>/tomcat/bin/shutdown.sh
Restart=on-failure
RestartSec=10
```

- `ExecStart` / `ExecStop`：起動・停止コマンド．Tomcat標準のスクリプトを使用．
- `Restart=on-failure`：プロセスが異常終了した場合に再起動．
- `RestartSec=10`：再起動までの待機時間（秒）．

------------------------------

### C. 用語解説

| 用語 | 説明 |
|------|------|
| Tomcat | Apache Software Foundationが提供するJavaサーブレットコンテナ．JSP/Servletの実行環境． |
| Amazon Corretto | Amazonが提供するOpenJDK配布版．長期サポートが特徴． |
| サーブレットコンテナ | JavaのServlet/JSPを実行する環境．Webサーバーとの組み合わせで動作する． |
| Catalina | Tomcatのコアコンポーネント（サーブレットコンテナ部分）の名称． |
| ヒープサイズ | JVMがオブジェクトを格納するメモリ領域のサイズ．`-Xms`（最小）と`-Xmx`（最大）で指定． |
| GC（Garbage Collection） | JVMが不要になったオブジェクトを自動回収する仕組み．`UseParallelGC`はその実装の一つ． |
| systemd | LinuxのPID1プロセス．サービス管理・起動順制御を担う． |
| `Type=forking` | systemdのサービス形式の一つ．起動プロセスが子をforkして親が終了するパターン用． |
| シンボリックリンク | 別ファイル/ディレクトリへの参照ファイル．バージョン違いの差分を吸収する用途で使われる． |
| FQDN | Fully Qualified Domain Name．完全修飾ドメイン名．`<ホスト名>.<ドメイン名>`の形式． |

------------------------------

### D. 補足解説

- **なぜtomcatユーザーを作るか？**
  - Tomcatをrootで動かすと，脆弱性を突かれた際にrootシェルを取られるリスクがある．
  - 専用ユーザー（システムユーザー）で動かすことで影響範囲を限定できる．
  - `-r`オプションでシステムユーザー化，`-s /sbin/nologin`でログイン不可とすることでセキュリティを高める．

- **なぜシンボリックリンクを使うか？**
  - Tomcatのバージョンアップ時，実体ディレクトリは`apache-tomcat-9.0.118` → `apache-tomcat-9.0.119`のように変わる．
  - シンボリックリンク `<TOMCAT_INSTALL_DIR>/tomcat` を経由しておけば，systemdユニットファイルや関連スクリプトの修正なしでバージョンアップ可能．
  - リンクを切り替えるだけで戻すこともできるため，運用性が向上する．

- **`Type=forking` と `PIDFile` の関係**
  - Tomcatの`startup.sh`は起動後すぐに親プロセスが終了し，子プロセス（実際のTomcat）が残る形式．
  - systemdは`Type=forking`の場合，`PIDFile`を見て子プロセスを追跡する．
  - `PIDFile`が無いと「親プロセスが終了 ＝ サービス停止」と誤認識し，`active (exited)` になる場合がある．
  - Tomcat側で`CATALINA_PID`環境変数によりPIDファイルが生成されるため，systemd側でも同じパスを`PIDFile=`に指定する必要がある．

- **JAVA_HOMEの調べ方**
  - `which java` だけだと `/usr/bin/java` のようにシンボリックリンクのパスが返るため，`readlink -f` で実体パスを得る．
  - 実体パスの `bin/javac` を除いた部分が `JAVA_HOME`．
  - 例：`/usr/lib/jvm/java-11-amazon-corretto.x86_64/bin/javac` → `JAVA_HOME=/usr/lib/jvm/java-11-amazon-corretto.x86_64`．

- **既定ROOTをリネームする理由**
  - Tomcat標準では `webapps/ROOT` がデフォルトWebアプリ（Tomcat標準ページ）．
  - アプリ用の `ROOT.war` をデプロイすると，このディレクトリと競合する．
  - 事前に `tomcat-default` にリネームしておくことで，アプリのデプロイ時に競合を避けられる．
  - 同時にTomcat標準ページが残るので動作確認にも使える．

- **`dnf update` と `dnf upgrade` の違い**
  - DNFベースのAmazon Linux 2023では両者は同義．本手順書では `dnf update -y` に統一．

- **system-setupの共通化**
  - 内部DNS構築手順書等で既に同じsystem-setupを実施している場合は，Step 1はスキップ可能．
  - 同一EC2でAPサーバーと内部DNSが同居する構成（AZ2のap+dns同居など）では特に注意．
