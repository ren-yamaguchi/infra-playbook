# 【全文検索エンジン搭載のドキュメント基盤(Lighttpd + uWSGI/Flask + OpenSearch + MinIO)】環境構築手順書

---

## 1. ドキュメント情報

| 項目 | 内容 |
|------|------|
| 手順書名 | 全文検索エンジン搭載のドキュメント基盤(Lighttpd + uWSGI/Flask + OpenSearch + MinIO) |
| 作成日 | 2026-06-25 |
| バージョン | v1.1 |
| 対象環境 | AWS |
| 構築規模 | 約1.5日 |

> **改訂履歴**
>
> | バージョン | 日付 | 変更内容 |
> |-----------|------|---------|
> | v1.0 | 2026-06-25 | 初版作成 |
> | v1.1 | 2026-06-27 | 構築実施で判明した課題を反映(MinIO/OpenSearch/Dashboards/Lighttpd の各種改善、各MW役割解説の新設、その他細部修正) |

---

## 2. 目的・概要

### 2-1. 目的

本手順書では、**全文検索エンジン OpenSearch** と **S3互換オブジェクトストレージ MinIO** を組み合わせた、ドキュメント管理基盤を構築する。テキストファイルをアップロードすると、本文は MinIO に保存され、検索用のインデックスは OpenSearch に登録される。利用者は全文検索で目的のドキュメントを見つけ、MinIO からダウンロードできる。

学習ポイント:

- 軽量Webサーバ **Lighttpd** によるリバースプロキシ・静的配信
- **uWSGI** によるWSGIアプリの常駐(Gunicornとの違いを体感する)
- **OpenSearch** による全文検索インデックスの作成と検索クエリ
- **kuromoji** プラグインによる日本語形態素解析
- **OpenSearch Dashboards** での可視化・インデックス管理
- **MinIO** によるS3互換オブジェクトストレージの構築と boto3 からの操作

### 2-2. 構成概要(アーキテクチャ)

```
        [クライアント(curl/ブラウザ)]
                  |
                  | HTTP (80)
                  v
   +---------------------------------------+
   |   web.docsearch.local (Lighttpd)      |
   |   - /          → 静的HTML(検索フォーム)|
   |   - /static/*  → 静的ファイル          |
   |   - /api/*     → mod_proxy で転送     |
   +---------------------------------------+
                  |
                  | HTTP (8000)
                  v
   +---------------------------------------+
   |   app.docsearch.local (uWSGI+Flask)   |
   |   - /api/upload   : MinIO保存+OS登録  |
   |   - /api/search   : OpenSearch検索    |
   |   - /api/download : MinIOから取得     |
   +---------------------------------------+
        |                       |
        | HTTP(9200)            | HTTP(9000) S3 API
        v                       v
 +----------------+      +----------------+
 | search.        |      | storage.       |
 | docsearch.local|      | docsearch.local|
 |  OpenSearch    |      |   MinIO        |
 |  + Dashboards  |      |                |
 |  + kuromoji    |      |                |
 +----------------+      +----------------+

   +-------------------------------------+
   |      [client.docsearch.local]       |
   |       (動作確認用クライアント)        |
   +-------------------------------------+
```

### 2-3. 完成イメージ(ゴール定義)

- [ ] クライアントから `curl` でテキストファイルをアップロードできる
- [ ] アップロードしたファイルは MinIO バケットに保存され、OpenSearch にも本文がインデックスされる
- [ ] 日本語キーワードで全文検索ができ、kuromoji の形態素解析が効いている
- [ ] 検索結果のドキュメントIDから MinIO 経由でダウンロードできる
- [ ] OpenSearch Dashboards にブラウザでアクセスし、インデックス状況を確認できる
- [ ] Lighttpd の静的HTMLから検索フォーム経由で動作確認できる

### 2-4. 各ミドルウェアの役割と特徴

本構成で扱う未経験ミドルウェアについて、構築前に役割と特徴を整理しておく。手順を進める途中で「何をやっているのか」見失わないよう、まず全体像を頭に入れる。

#### 2-4-1. Lighttpd(軽量Webサーバ)

**役割**: web サーバとして静的HTMLの配信と、`/api/*` のリバースプロキシを担当する。

**既知のMWでいうと**: Nginx や Apache と同じ「Webサーバ」カテゴリ。

**Nginx/Apacheとの違い**: より軽量で、組込み機器や低リソース環境で使われることが多い。設定ファイルの構文はNginxよりブロック構造がシンプルで、`mod_xxx` という形のモジュールを動的にロードする方式(Apacheに近い)。

**この構成での役回り**: 外部からの入口となるフロント。静的コンテンツは自分で返し、APIリクエストだけを app サーバに転送する。

**学習ポイント**: Webサーバには Nginx/Apache 以外の選択肢があることを知る。モジュール配置先(`server.modules-path`)を明示する必要があるなど、パッケージインストールと違うソースビルド特有のクセを体感する。

#### 2-4-2. uWSGI(WSGIアプリケーションサーバ)

**役割**: Python製のFlaskアプリケーションを常駐プロセスとして動かす。

**既知のMWでいうと**: 案1で使った Gunicorn と同じ「WSGIサーバ」カテゴリ。Java界でいう Tomcat、PHP界でいう PHP-FPM のような位置づけ。

**Gunicornとの違い**: Gunicorn は Python 製でシンプル設定向き。uWSGI は C 製で、設定オプションが膨大、多言語対応(Perl, Ruby等もホスト可能)、内部プロトコル(uwsgi protocol)も独自に持つ。歴史が長く、機能が豊富な分、設定の選択肢で迷いやすい。

**この構成での役回り**: Flask で書いた検索API・アップロード・ダウンロードのエンドポイントをHTTPで公開する。Lighttpd から HTTP リクエストを受け取り、Python関数を呼んで結果を返す。

**学習ポイント**: 同じ WSGI サーバでも Gunicorn と uWSGI で設定思想が大きく違うことを体感する。`processes` と `threads` の使い分け、`http` モードと `uwsgi` プロトコルモードの違いを知る。

#### 2-4-3. Flask(Pythonウェブフレームワーク)

**役割**: HTTPエンドポイント(`/api/upload` 等)を定義する Python のウェブフレームワーク。

**既知のMWでいうと**: 既習のフレームワークでいうと PHP の素の状態に近い軽量さ。「マイクロフレームワーク」と呼ばれ、必要最小限の機能だけを持つ。

**この構成での役回り**: 受け取ったリクエストを処理し、MinIO や OpenSearch を呼び出す「アプリケーション本体」のロジックを担う。

**学習ポイント**: フレームワーク自体は最小限で、外部サービス(MinIO/OpenSearch)との連携は専用ライブラリ(boto3 / opensearch-py)で行うという「組み合わせて作る」パターンを体感する。

#### 2-4-4. OpenSearch(全文検索エンジン)

**役割**: 大量のテキストデータをインデックス化し、高速な全文検索を提供する。

**既知のMWでいうと**: 既習MWに直接対応するものはない。**RDB(MySQL/PostgreSQL)とは別カテゴリのデータストア**。RDBが「正確な構造化データの管理」に強いのに対し、OpenSearch は「曖昧な検索」「スコアリング」「形態素解析」が得意。

**仕組みのイメージ**: 内部的には Apache Lucene という検索ライブラリを使い、「単語 → その単語を含むドキュメントの一覧」という逆引きインデックス(転置インデックス)を作る。Google のような検索エンジンの仕組みを自前のシステムに組み込めると考えると分かりやすい。

**Elasticsearch との関係**: Elasticsearch からフォークした(派生した)OSS。API もほぼ互換。ライセンス変更を機に分かれた歴史がある。

**この構成での役回り**: アップロードされたドキュメントの本文をインデックスし、`/api/search?q=...` への問い合わせに対してヒットしたドキュメントIDを返す。

**学習ポイント**: RDB とは別の「検索エンジン」というカテゴリの存在を知る。マッピング(スキーマ)・アナライザ(テキスト分解処理)・クエリDSL という独自の概念を体感する。日本語検索には kuromoji のような形態素解析器の利用が必要なことを理解する。

#### 2-4-5. kuromoji(日本語形態素解析器)

**役割**: 日本語のテキストを意味のある単語(形態素)に分解する。

**なぜ必要か**: 日本語は英語と違い、単語の区切りが空白で示されない。「東京都に住む」を OpenSearch にそのまま入れると、標準アナライザでは検索しにくい状態でインデックスされ、「都」で検索しても「東京都」がヒットしないなどの問題が起きる。kuromoji を使うと「東京/都/に/住む」のように分かち書きされ、日本語検索が自然に動く。

**この構成での役回り**: OpenSearch のプラグインとしてインストールし、ドキュメントの `content` フィールドのインデックス・検索時に使われる。

**学習ポイント**: 全文検索における「アナライザ」という概念と、言語ごとに専用のアナライザが必要なことを知る。

#### 2-4-6. OpenSearch Dashboards(可視化・管理UI)

**役割**: OpenSearch のデータをブラウザで可視化・検索・管理する Web UI。

**既知のMWでいうと**: Elasticsearch における Kibana に相当するツール。

**この構成での役回り**: 構築したインデックスやドキュメントの状況を、CLIではなくブラウザで確認するための補助ツール。検索やマッピングの結果を視覚的に追える。

**学習ポイント**: OpenSearch のような複雑なデータストアには「ブラウザで状態を見る用のUI」が用意されることが多いことを知る。本番では監視や分析のダッシュボードとしても使える。

#### 2-4-7. MinIO(S3互換オブジェクトストレージ)

**役割**: AWS S3 と互換性のあるAPIを提供する、オンプレでも動かせるオブジェクトストレージ。

**既知のMWでいうと**: 既習MWに直接対応するものはない。**ファイルシステム(NFS等)とも、RDBとも違う、第三のストレージカテゴリ**。

**特徴**: 「バケット」と「オブジェクト」という単位でファイルを管理する。フォルダ階層は表面上のもので、内部的にはフラットなキーバリュー構造。HTTP API で操作する。

**S3互換であることの意味**: AWS S3 用に書いたクライアント(boto3 等)が、エンドポイントURLを差し替えるだけでそのまま MinIO に対しても動く。本番でS3、開発環境でMinIO、というパターンが現場ではよく使われる。

**この構成での役回り**: アップロードされたドキュメント本体(.txtファイル)を保存する。OpenSearch にはインデックス用のテキストを入れ、本体ファイルはMinIO側、と役割分担。

**学習ポイント**: ファイルサーバ(NFS)とオブジェクトストレージ(S3/MinIO)の使い分けを意識する。AWS S3 のAPIを「自前で立てた基盤で」体感できる。

#### 2-4-8. boto3(AWS SDK for Python)

**役割**: Python から AWS のサービス(S3 など)を操作するための公式SDK。

**この構成での役回り**: Flask アプリから MinIO(S3互換)へファイルをアップロード・ダウンロードする際に使う。`endpoint_url` を MinIO のURLに差し替えることで、AWS S3 ではなく MinIO に接続している。

**学習ポイント**: 「S3互換」というキーワードの実装上の意味を、コードレベルで理解する。

#### 2-4-9. opensearch-py(OpenSearch Pythonクライアント)

**役割**: Python から OpenSearch を操作するための公式クライアントライブラリ。

**この構成での役回り**: Flask アプリから OpenSearch へインデックス登録・検索クエリを発行する際に使う。

**学習ポイント**: OpenSearch のREST APIを直接叩いてもよいが、Pythonからは専用クライアントを使うのが一般的なパターン。

---

## 3. 前提条件・準備

### 3-1. AWS環境(起動済み前提)

- AWSアカウントを保有していること
- VPCが作成されており、CIDRは `172.31.0.0/16` であること(異なる場合は手順中の該当箇所を読み替え)
- EC2インスタンスが **5台起動済み** であること
- 全EC2は **パブリックサブネット** に配置されていること
- 全EC2にSSHログインできること
- 各EC2には **パブリックIPが付与されている** こと

> **注意:EC2のパブリックIPはインスタンス停止/起動で変動する**
>
> 学習中にEC2を停止して再起動するとパブリックIPが変わる。再開時には改めてIPを確認し、各種設定を更新する必要がある。EIPを使えば固定化できるがコストが発生するため、本手順書では使わない。

### 3-2. 各サーバのスペック要件

| サーバ | 用途 | 推奨インスタンスタイプ |
|------|------|------|
| web | Lighttpd | t3.micro |
| app | uWSGI + Flask | t3.micro |
| search | OpenSearch + Dashboards | **メモリ4GB以上(例: t3.medium / c7i-flex.large)** |
| storage | MinIO | t3.micro |
| client | 動作確認用 | t3.micro |

> **注意:OpenSearch は JVM ベースでメモリを大量に使う**
>
> OpenSearch はデフォルトで JVM ヒープ 1GB を確保し、Dashboards も同居させると合計2GB以上のメモリが必要になる。t3.micro(1GB)では起動途中で OOM Killer に殺される。**search サーバはメモリ4GB以上のインスタンスを選ぶこと**。

### 3-3. 環境要件(ミドルウェア一覧)

| サーバ | 主要ミドルウェア |
|------|------|
| web | Lighttpd |
| app | uWSGI, Python3, Flask, boto3, opensearch-py |
| search | OpenSearch 2.x, OpenSearch Dashboards, analysis-kuromoji |
| storage | MinIO |
| client | jq(curl はプリインストール済み) |

### 3-4. セキュリティグループ設定

#### 3-4-1. web サーバ

| タイプ | プロトコル | ポート | ソース | 目的 |
|---|---|---|---|---|
| SSH | TCP | 22 | マイIP | SSHログイン |
| HTTP | TCP | 80 | 0.0.0.0/0 | 外部からの動作確認 |
| すべての ICMP - IPv4 | ICMP | すべて | 172.31.0.0/16 | VPC内疎通確認(ping)用 |

#### 3-4-2. app サーバ

| タイプ | プロトコル | ポート | ソース | 目的 |
|---|---|---|---|---|
| SSH | TCP | 22 | マイIP | SSHログイン |
| カスタムTCP | TCP | 8000 | 172.31.0.0/16 | Lighttpd からのリバプロ受信 |
| すべての ICMP - IPv4 | ICMP | すべて | 172.31.0.0/16 | VPC内疎通確認(ping)用 |

#### 3-4-3. search サーバ

| タイプ | プロトコル | ポート | ソース | 目的 |
|---|---|---|---|---|
| SSH | TCP | 22 | マイIP | SSHログイン |
| カスタムTCP | TCP | 9200 | 172.31.0.0/16 | OpenSearch API |
| カスタムTCP | TCP | 5601 | マイIP | Dashboards UI(ブラウザから直接) |
| すべての ICMP - IPv4 | ICMP | すべて | 172.31.0.0/16 | VPC内疎通確認(ping)用 |

> **解説:Dashboards のポート 5601 を「マイIP」に絞る理由**
>
> Dashboards は本来 web サーバ経由で公開すべきだが、学習用途では直接ブラウザでアクセスする方が手早い。代わりに「自分のIPからのみ」に絞り、外部にUIを晒さないようにする。

#### 3-4-4. storage サーバ

| タイプ | プロトコル | ポート | ソース | 目的 |
|---|---|---|---|---|
| SSH | TCP | 22 | マイIP | SSHログイン |
| カスタムTCP | TCP | 9000 | 172.31.0.0/16 | MinIO S3 API |
| カスタムTCP | TCP | 9001 | マイIP | MinIO Console UI |
| すべての ICMP - IPv4 | ICMP | すべて | 172.31.0.0/16 | VPC内疎通確認(ping)用 |

#### 3-4-5. client サーバ

| タイプ | プロトコル | ポート | ソース | 目的 |
|---|---|---|---|---|
| SSH | TCP | 22 | マイIP | SSHログイン |
| すべての ICMP - IPv4 | ICMP | すべて | 172.31.0.0/16 | VPC内疎通確認(ping)用 |

> **解説:なぜ ICMP を VPC内に開けるか**
>
> AWS EC2 のセキュリティグループはデフォルトで ICMP を許可していない。`ping` で疎通確認したいだけなのに `Could not resolve host` ではなく単にタイムアウトする、ということが起きる。学習用途では VPC内(172.31.0.0/16) からの ICMP を開けておくと、トラブル時に切り分けが容易になる。

### 3-5. パラメータ整理表

| パラメータ | 意味 | 自環境の値 |
|---|---|---|
| `<WEB_PUB>` | web サーバのグローバルIP | |
| `<WEB_PRI>` | web サーバのプライベートIP | |
| `<APP_PRI>` | app サーバのプライベートIP | |
| `<SEARCH_PUB>` | search サーバのグローバルIP(Dashboards用) | |
| `<SEARCH_PRI>` | search サーバのプライベートIP | |
| `<STORAGE_PUB>` | storage サーバのグローバルIP(Console用) | |
| `<STORAGE_PRI>` | storage サーバのプライベートIP | |
| `<CLIENT_PUB>` | client サーバのグローバルIP | |

### 3-6. ホスト名・ドメイン設計

| サーバ | ホスト名 |
|---|---|
| web | `web.docsearch.local` |
| app | `app.docsearch.local` |
| search | `search.docsearch.local` |
| storage | `storage.docsearch.local` |
| client | `client.docsearch.local` |

> **解説:名前解決は `/etc/hosts` で行う**
>
> 本手順書では BIND を立てず、各サーバの `/etc/hosts` にプライベートIPとホスト名のマッピングを書き込む方式を取る。DNSサーバ構築は別案で扱うため、ここでは検索基盤の構築に集中する。

---

## 4. 構築手順(詳細)

### 4-1. 環境構築の流れ

1. 全サーバ共通: 初期設定 (Step 0)
2. storage サーバ: MinIO の構築 (Step 1)
3. search サーバ: OpenSearch + Dashboards + kuromoji の構築 (Step 2)
4. app サーバ: uWSGI + Flask アプリの構築 (Step 3)
5. web サーバ: Lighttpd の構築 (Step 4)
6. client サーバ: 動作確認用の準備 (Step 5)

---

### Step 0: 全サーバ共通の初期設定

**目的:** 全サーバに対し、root化・パッケージ更新・タイムゾーン設定・ホスト名設定を行う。

#### 0-1. 【全サーバで実施】システム初期設定

各サーバに SSH ログイン後、以下を実行する。

```bash
sudo su -
dnf update -y
timedatectl set-timezone Asia/Tokyo
```

ホスト名は各サーバで異なる:

```bash
# web サーバ
hostnamectl set-hostname web.docsearch.local

# app サーバ
hostnamectl set-hostname app.docsearch.local

# search サーバ
hostnamectl set-hostname search.docsearch.local

# storage サーバ
hostnamectl set-hostname storage.docsearch.local

# client サーバ
hostnamectl set-hostname client.docsearch.local
```

ログイン状態をリフレッシュ:

```bash
exec bash
```

#### 0-2. 【全サーバで実施】/etc/hosts の編集

全サーバで以下を `/etc/hosts` の末尾に追記する。

```bash
vi /etc/hosts
```

```
<WEB_PRI>     web.docsearch.local
<APP_PRI>     app.docsearch.local
<SEARCH_PRI>  search.docsearch.local
<STORAGE_PRI> storage.docsearch.local
```

> **解説:なぜ全サーバに同じ内容を入れるか**
>
> サーバ間通信(例: app → search、app → storage)はホスト名で参照させる方が、IP変動時の影響を1ファイル書き換えで済ませられる。`/etc/hosts` を全サーバに配るのは原始的だが、5台規模なら現実的な運用。

> **注意:本番ではDNSを使うべき**
>
> サーバ台数が増えると `/etc/hosts` の同期コストが指数的に増える。本番では BIND や Route 53 などのDNSサーバで一元管理するのが定石。

#### 0-3. 【全サーバで実施】疎通確認

```bash
ping -c 1 web.docsearch.local
ping -c 1 app.docsearch.local
ping -c 1 search.docsearch.local
ping -c 1 storage.docsearch.local
```

すべて応答が返ればOK。応答が返らない場合は、各サーバのSGに ICMP の許可が入っているか(3-4節)を確認すること。

---

### Step 1: 【storageサーバで実施】MinIO の構築

**目的:** S3互換オブジェクトストレージ MinIO をインストールし、ドキュメント保存用バケットを作成する。

#### 1-1. MinIO バイナリのダウンロード

```bash
cd /usr/local/bin
curl -LO https://dl.min.io/server/minio/release/linux-amd64/minio
curl -LO https://dl.min.io/client/mc/release/linux-amd64/mc

# ダウンロード確認(サイズが100MB前後あれば成功、数百バイトしかなければ失敗)
ls -lh minio mc

chmod +x minio mc
```

> **注意:`curl -O` ではなく `curl -LO` を使う**
>
> `curl -O` はリダイレクトを追わないため、配布元がリダイレクトを返す環境では数百バイトのHTML(リダイレクトページ)が保存される。その状態で `systemctl start minio` すると `Exec format error` で起動失敗する。`-L` オプションでリダイレクトを追うことで、本物のバイナリがダウンロードされる。

> **解説:MinIO はシングルバイナリ**
>
> MinIO は Go 製で、サーバ本体(`minio`)もクライアントツール(`mc`)も単一バイナリで配布されている。`dnf install` 等のパッケージは使わない。配置とユーザー、systemd ユニットを自分で作る必要がある。

#### 1-2. データディレクトリと専用ユーザーの作成

```bash
useradd -r -s /sbin/nologin minio-user
mkdir -p /var/lib/minio/data
chown -R minio-user:minio-user /var/lib/minio
```

> **解説:`-r` でシステムユーザー化**
>
> `useradd -r` はUIDを1000未満(システム用領域)で作成する。ログイン不要のサービス専用ユーザーであることを明示できる。

#### 1-3. 環境変数ファイルの作成

```bash
mkdir -p /etc/minio
cat > /etc/minio/minio.env << 'EOF'
MINIO_ROOT_USER=adminuser
MINIO_ROOT_PASSWORD=adminpassword123
MINIO_VOLUMES=/var/lib/minio/data
MINIO_OPTS=--console-address :9001 --address :9000
EOF
chmod 600 /etc/minio/minio.env
```

> **注意:本番のパスワード管理**
>
> 学習用に `adminuser` / `adminpassword123` を直書きしているが、本番では Secrets Manager や Vault 等で管理し、環境変数ファイルに平文で書かないのが基本。

#### 1-4. systemd ユニットファイル作成

```bash
cat > /etc/systemd/system/minio.service << 'EOF'
[Unit]
Description=MinIO Object Storage
After=network-online.target
Wants=network-online.target

[Service]
User=minio-user
Group=minio-user
EnvironmentFile=/etc/minio/minio.env
ExecStart=/usr/local/bin/minio server $MINIO_OPTS $MINIO_VOLUMES
Restart=always
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
EOF
```

> **解説:`EnvironmentFile` で環境変数を注入する**
>
> MinIO は管理者IDやパスワードを環境変数(`MINIO_ROOT_USER` 等)から読み取る。systemd の `EnvironmentFile=` で外部ファイルから読み込ませることで、ユニットファイル本体を汚さず、権限(`chmod 600`)で機密性も確保できる。

#### 1-5. MinIO 起動

```bash
systemctl daemon-reload
systemctl start minio
systemctl enable minio
systemctl status minio
```

ログ確認:

```bash
journalctl -u minio -n 30 --no-pager
```

「API:」と「Console:」のURLが表示されていればOK。

#### 1-6. mc クライアントの初期設定

storage サーバ自身に対してエイリアスを登録する。

```bash
mc alias set local http://localhost:9000 adminuser adminpassword123
mc admin info local
```

`Online` と表示されればOK。

#### 1-7. バケット作成

```bash
mc mb local/documents
mc ls local
```

`documents/` が表示されればOK。

#### 1-8. アプリ用アクセスキーの作成

app サーバから接続する際に使う、root と別のサービスユーザーを作る。

```bash
mc admin user add local appuser apppassword123
mc admin policy attach local readwrite --user appuser
```

> **解説:root を直接使わない**
>
> root 相当の `adminuser` をアプリ側に持たせると、アプリ経由で意図しない管理操作ができてしまう。`appuser` には `readwrite` ポリシー(オブジェクトの読み書きのみ)を付与し、ユーザー管理権限は持たせない。最小権限の原則。

#### 1-9. ブラウザで Console 確認(任意)

ローカルPCのブラウザから `http://<STORAGE_PUB>:9001` にアクセスし、`adminuser` / `adminpassword123` でログイン。`documents` バケットが見えればOK。

---

### Step 2: 【searchサーバで実施】OpenSearch + Dashboards の構築

**目的:** 全文検索エンジン OpenSearch をインストールし、日本語対応(kuromoji)とDashboards UIを準備する。

#### 2-1. Java ランタイムの確認

OpenSearch 2.x はバンドル版 JDK を同梱しているため、別途 Java を入れる必要はない。tar.gz の中に含まれている。

#### 2-2. OpenSearch 用ユーザー作成

```bash
useradd -r -s /bin/bash -d /opt/opensearch -M opensearch
```

> **解説:`-M` でホームディレクトリを作らない**
>
> `-d /opt/opensearch` でホームディレクトリのパスを指定しているが、`-M` を付けないと useradd が `/opt/opensearch` ディレクトリを実際に作ってしまう。すると後続のダウンロード・展開で `/opt/opensearch` がすでに存在する状態になり、シンボリックリンクが張れずに `/opt/opensearch/opensearch-2.13.0/` という入れ子構造になる。`-M` で抑止することで、後続でクリーンに配置できる。

> **解説:OpenSearch は root では起動できない**
>
> OpenSearch はセキュリティ上、root での起動を拒否する。専用ユーザー(`opensearch`)を作り、そのユーザーで起動する必要がある。

#### 2-3. OpenSearch のダウンロードと配置

```bash
cd /opt
curl -LO https://artifacts.opensearch.org/releases/bundle/opensearch/2.13.0/opensearch-2.13.0-linux-x64.tar.gz

# ダウンロード確認(800MB前後)
ls -lh opensearch-2.13.0-linux-x64.tar.gz

tar xzf opensearch-2.13.0-linux-x64.tar.gz

# シンボリックリンクで「現在のバージョン」を指す
ln -s /opt/opensearch-2.13.0 /opt/opensearch

# 所有権設定(実体側)
chown -R opensearch:opensearch /opt/opensearch-2.13.0

# シンボリックリンク自身の所有者も合わせる(-h で symlink 自身を変更)
chown -h opensearch:opensearch /opt/opensearch

# 確認
ls -l /opt/ | grep opensearch
```

> **解説:なぜシンボリックリンクにするか**
>
> 将来 OpenSearch 2.14.0 にアップグレードしたくなったとき、`/opt/opensearch-2.14.0` を別途展開し、`ln -snf /opt/opensearch-2.14.0 /opt/opensearch` でリンクを張り替えるだけで切り替えできる。問題があれば元のリンクに戻せばロールバック完了。systemd ユニットや設定ファイル内のパスは `/opt/opensearch/...` のまま変更不要。
>
> 一方 `mv` で実体ごとリネームすると、新バージョン展開時に旧版を別名退避→新版を展開→リネーム、と手順が増え、切り戻しもしにくい。

> **解説:`chown -h` の意味**
>
> 通常の `chown` はシンボリックリンクの「リンク先」の所有者を変更する。`-h` を付けると、シンボリックリンク自身の所有者だけを変更できる。シンボリックリンクの所有者はファイルアクセス権限に直接影響しないことが多いが、「サービス資産はサービスユーザー所有」と揃えておく方が監査やトラブルシュート時に見やすい。

#### 2-4. opensearch.yml の編集

```bash
vi /opt/opensearch/config/opensearch.yml
```

末尾に追記:

```yaml
# === 学習用設定 ===
cluster.name: docsearch-cluster
node.name: search-node-1
network.host: 0.0.0.0
http.port: 9200
discovery.type: single-node

# セキュリティプラグインを無効化(学習用)
plugins.security.disabled: true
```

> **解説:`plugins.security.disabled: true` の意味**
>
> OpenSearch 2.x はデフォルトで「HTTPS + admin認証必須」のセキュリティプラグインが有効。本番ではこのまま使うべきだが、学習中はTLS証明書の生成や認証情報の管理に時間を取られるため、無効化して HTTP + 認証なしで動かす。

> **注意:本番では絶対に無効化しないこと**
>
> セキュリティ無効化状態の OpenSearch を外部公開すると、誰でも全インデックスを読み書きできる。本構成も SG で 9200 を VPC 内部のみに絞ることで最低限の防御を行っている。

> **解説:`discovery.type: single-node`**
>
> OpenSearch はクラスタ前提で動くため、デフォルトでは他ノードを探そうとして起動できない。`single-node` を指定することで、1台構成での起動を許可する。

#### 2-5. JVM ヒープサイズの調整

```bash
vi /opt/opensearch/config/jvm.options
```

以下の2行を見つけて編集(デフォルトの `-Xms1g` `-Xmx1g` のままでも本構成は動くが、明示的に確認することを推奨):

```
-Xms1g
-Xmx1g
```

> **解説:JVMヒープサイズの考え方**
>
> 主に2つの原則がある:
>
> 1. **物理メモリの50%以下に抑える**: JVMヒープに割り当てた分は OS のページキャッシュとして使えなくなる。OpenSearch(中身は Lucene)はインデックスファイルを mmap でメモリにマップして読むため、OS のページキャッシュが効くと劇的に速くなる。
> 2. **32GB を超えない**: JVM の Compressed Ordinary Object Pointers(圧縮ポインタ)機能の関係で、32GBを超えると逆に効率が落ちる。
>
> 4GBメモリのインスタンスなら 1GB が安全な値。Dashboards 同居でメモリが厳しい場合は 512MB に絞ってもよい。

#### 2-6. OS側の設定調整

```bash
# vm.max_map_count を増やす(OpenSearch必須)
echo "vm.max_map_count=262144" >> /etc/sysctl.conf
sysctl -p

# ファイルディスクリプタ上限を緩和
cat >> /etc/security/limits.conf << 'EOF'
opensearch soft nofile 65536
opensearch hard nofile 65536
opensearch soft memlock unlimited
opensearch hard memlock unlimited
EOF
```

> **解説:`vm.max_map_count` を増やす理由**
>
> OpenSearch(Lucene)はインデックスをメモリマップドファイルで読み書きする。デフォルトのマップ数上限(65530)では足りず、必ず増やす必要がある。これを忘れると起動時に bootstrap check で失敗する。

#### 2-7. kuromoji プラグインのインストール

```bash
sudo -u opensearch /opt/opensearch/bin/opensearch-plugin install analysis-kuromoji
```

`-> Installed analysis-kuromoji` と表示されればOK。

> **解説:kuromoji は何をしてくれるか**
>
> 日本語は単語の区切りが空白で示されないため、英語のような単純な空白分割では検索インデックスがうまく作れない(「東京都」を検索したいのに「東京」では引っかからない等)。kuromoji は形態素解析器で、「東京都」を「東京/都」のように分解してインデックスする。これにより日本語の検索精度が大きく向上する。

#### 2-8. systemd ユニットファイル作成

```bash
cat > /etc/systemd/system/opensearch.service << 'EOF'
[Unit]
Description=OpenSearch
After=network-online.target

[Service]
Type=simple
User=opensearch
Group=opensearch
LimitNOFILE=65536
LimitMEMLOCK=infinity
ExecStart=/opt/opensearch/bin/opensearch
Restart=always

[Install]
WantedBy=multi-user.target
EOF
```

#### 2-9. OpenSearch 起動

```bash
systemctl daemon-reload
systemctl start opensearch
sleep 60
systemctl status opensearch
```

> **注意:OpenSearch の起動は遅い**
>
> JVM の初期化とプラグインのロードに30秒〜1分かかる。起動直後に `status` を見ると「activating」のままのことがあるので、十分待ってから確認する。

動作確認:

```bash
curl http://localhost:9200
```

JSON で `"cluster_name" : "docsearch-cluster"` などが返ればOK。

自動起動設定:

```bash
systemctl enable opensearch
```

#### 2-10. Dashboards のダウンロードと配置

```bash
cd /opt
curl -LO https://artifacts.opensearch.org/releases/bundle/opensearch-dashboards/2.13.0/opensearch-dashboards-2.13.0-linux-x64.tar.gz

# ダウンロード確認(300MB前後)
ls -lh opensearch-dashboards-2.13.0-linux-x64.tar.gz

tar xzf opensearch-dashboards-2.13.0-linux-x64.tar.gz

# シンボリックリンクで「現在のバージョン」を指す
ln -s /opt/opensearch-dashboards-2.13.0 /opt/opensearch-dashboards

# 所有権設定
chown -R opensearch:opensearch /opt/opensearch-dashboards-2.13.0
chown -h opensearch:opensearch /opt/opensearch-dashboards

# 確認
ls -l /opt/ | grep dashboards
```

#### 2-11. Dashboards 設定ファイルの全置換

デフォルトの `opensearch_dashboards.yml` には末尾にセキュリティプラグイン前提の設定(`opensearch.hosts: [https://...]` や `opensearch.username: kibanaserver` 等)が**有効状態で**最初から記述されている。本構成(セキュリティ無効化)と矛盾するため、設定ファイルを必要最小限のものに全置換する。

```bash
# 元ファイルを同じディレクトリに .org 付きで残す
cp /opt/opensearch-dashboards/config/opensearch_dashboards.yml{,.org}

# 必要な設定だけのファイルに差し替え
cat > /opt/opensearch-dashboards/config/opensearch_dashboards.yml << 'EOF'
server.host: "0.0.0.0"
server.port: 5601
opensearch.hosts: ["http://localhost:9200"]
opensearch.ssl.verificationMode: none
EOF

# 所有者設定
chown opensearch:opensearch /opt/opensearch-dashboards/config/opensearch_dashboards.yml

# 確認
cat /opt/opensearch-dashboards/config/opensearch_dashboards.yml
```

> **解説:なぜ `vi` での部分編集ではなく全置換するか**
>
> Dashboards のデフォルト設定ファイルは大量のコメントと、`opensearch.hosts: [https://localhost:9200]` `opensearch.username: kibanaserver` 等のセキュリティプラグイン前提の設定が**有効状態で**末尾に記述されている。`vi` で「追記」する方式では、これら既存の有効行が残ってしまい、本構成(セキュリティ無効)と矛盾して起動失敗する。
>
> `cat > ... << 'EOF'` で全置換することで、ファイルの初期状態に依存せず、必要最小限の設定だけが残る冪等な手順になる。万一戻したい場合は `.org` バックアップから復元できる。

> **解説:`cp file{,.org}` のブレース展開**
>
> Bashのブレース展開で `cp file{,.org}` は `cp file file.org` に展開される。「同じディレクトリにオリジナルファイルをそのままの名前+ `.org` 拡張子で残す」という典型パターンを短く書ける書き方。

#### 2-12. Dashboards のセキュリティプラグイン削除

Dashboards 側もセキュリティプラグインをアンインストールする(OpenSearch側で無効化したため整合性が取れなくなるのを防ぐ)。

```bash
sudo -u opensearch /opt/opensearch-dashboards/bin/opensearch-dashboards-plugin remove securityDashboards
```

#### 2-13. Dashboards 用 systemd ユニット作成・起動

```bash
cat > /etc/systemd/system/opensearch-dashboards.service << 'EOF'
[Unit]
Description=OpenSearch Dashboards
After=opensearch.service

[Service]
Type=simple
User=opensearch
Group=opensearch
ExecStart=/opt/opensearch-dashboards/bin/opensearch-dashboards
Restart=always

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl start opensearch-dashboards
sleep 20
systemctl enable opensearch-dashboards
systemctl status opensearch-dashboards
```

ログ確認:

```bash
journalctl -u opensearch-dashboards -n 30 --no-pager
```

`Server running at http://0.0.0.0:5601` のようなログが出ればOK。

#### 2-14. ブラウザで Dashboards 確認

ローカルPCから `http://<SEARCH_PUB>:5601` にアクセス。Dashboards の Welcome 画面(「Start by adding your data」等)が表示されればOK。インデックスパターン作成は動作確認セクション(5-1)で行う。

> **考えるポイント:なぜ OpenSearch と Dashboards を同居させたか**
>
> 学習用途では Dashboards は「インデックスを覗き見るための補助ツール」であり、本番のような独立した可用性は求めない。同じサーバに置くことで、サーバ台数とコストを抑えつつ、リソース管理(JVMの取り合い)を体感できる。本番では別ノードに分離するのが定石。

---

### Step 3: 【appサーバで実施】uWSGI + Flask アプリの構築

**目的:** ドキュメント管理アプリを Flask で書き、uWSGI で常駐させる。

#### 3-1. Python とビルドツールのインストール

```bash
dnf install -y python3.11 python3.11-pip python3.11-devel gcc
```

#### 3-2. アプリ用ディレクトリと専用ユーザー作成

```bash
useradd -r -m -d /opt/docapp -s /bin/bash docapp
mkdir -p /opt/docapp/app
chown -R docapp:docapp /opt/docapp
```

#### 3-3. Python 仮想環境の作成と依存パッケージのインストール

```bash
sudo -u docapp -i
python3.11 -m venv /opt/docapp/venv
source /opt/docapp/venv/bin/activate
pip install --upgrade pip
pip install flask uwsgi boto3 opensearch-py
deactivate
exit
```

> **解説:なぜ仮想環境を使うか**
>
> OSパッケージの Python に直接 pip install すると、OS側パッケージとの依存衝突が起きやすい。仮想環境(venv)でアプリ固有の依存関係を隔離するのが定石。

> **解説:uWSGI と Gunicorn の違い**
>
> どちらも WSGI アプリ(Flask等)を本番常駐させるサーバ。Gunicorn は Python 製でシンプル設定向き、uWSGI は C 製で設定オプションが豊富かつ多言語対応(Perl等)。Lighttpd やNginxとは独自プロトコル(uwsgi protocol)でも繋げるが、本案ではシンプルさを優先して HTTP モードで繋ぐ。

#### 3-4. Flask アプリの作成

```bash
vi /opt/docapp/app/app.py
```

```python
import os
import uuid
from io import BytesIO
from flask import Flask, request, jsonify, send_file, abort

import boto3
from botocore.client import Config
from opensearchpy import OpenSearch

app = Flask(__name__)

# === 接続情報(環境変数から) ===
MINIO_ENDPOINT = os.environ.get("MINIO_ENDPOINT", "http://storage.docsearch.local:9000")
MINIO_ACCESS_KEY = os.environ.get("MINIO_ACCESS_KEY", "appuser")
MINIO_SECRET_KEY = os.environ.get("MINIO_SECRET_KEY", "apppassword123")
MINIO_BUCKET = os.environ.get("MINIO_BUCKET", "documents")

OS_HOST = os.environ.get("OS_HOST", "search.docsearch.local")
OS_PORT = int(os.environ.get("OS_PORT", "9200"))
OS_INDEX = os.environ.get("OS_INDEX", "documents")

# === クライアント初期化 ===
s3 = boto3.client(
    "s3",
    endpoint_url=MINIO_ENDPOINT,
    aws_access_key_id=MINIO_ACCESS_KEY,
    aws_secret_access_key=MINIO_SECRET_KEY,
    config=Config(signature_version="s3v4"),
    region_name="us-east-1",
)

os_client = OpenSearch(
    hosts=[{"host": OS_HOST, "port": OS_PORT}],
    http_compress=True,
    use_ssl=False,
    verify_certs=False,
)


@app.route("/api/health", methods=["GET"])
def health():
    return jsonify({"status": "ok"})


@app.route("/api/upload", methods=["POST"])
def upload():
    if "file" not in request.files:
        return jsonify({"error": "file is required"}), 400
    f = request.files["file"]
    filename = f.filename or "noname.txt"
    body = f.read()

    try:
        text = body.decode("utf-8")
    except UnicodeDecodeError:
        return jsonify({"error": "file must be utf-8 text"}), 400

    doc_id = str(uuid.uuid4())
    object_key = f"{doc_id}/{filename}"

    # MinIOに保存
    s3.put_object(Bucket=MINIO_BUCKET, Key=object_key, Body=body)

    # OpenSearchにインデックス
    os_client.index(
        index=OS_INDEX,
        id=doc_id,
        body={
            "filename": filename,
            "object_key": object_key,
            "content": text,
        },
        refresh=True,
    )

    return jsonify({"id": doc_id, "filename": filename, "object_key": object_key})


@app.route("/api/search", methods=["GET"])
def search():
    q = request.args.get("q", "")
    if not q:
        return jsonify({"error": "q is required"}), 400

    result = os_client.search(
        index=OS_INDEX,
        body={
            "query": {
                "match": {"content": q}
            },
            "highlight": {
                "fields": {"content": {}}
            },
            "size": 10,
        },
    )

    hits = []
    for h in result["hits"]["hits"]:
        hits.append({
            "id": h["_id"],
            "score": h["_score"],
            "filename": h["_source"].get("filename"),
            "object_key": h["_source"].get("object_key"),
            "highlight": h.get("highlight", {}).get("content", []),
        })

    return jsonify({"total": result["hits"]["total"]["value"], "hits": hits})


@app.route("/api/download/<doc_id>", methods=["GET"])
def download(doc_id):
    try:
        doc = os_client.get(index=OS_INDEX, id=doc_id)
    except Exception:
        abort(404)

    object_key = doc["_source"]["object_key"]
    filename = doc["_source"]["filename"]

    obj = s3.get_object(Bucket=MINIO_BUCKET, Key=object_key)
    return send_file(
        BytesIO(obj["Body"].read()),
        mimetype="text/plain",
        as_attachment=True,
        download_name=filename,
    )
```

権限調整:

```bash
chown -R docapp:docapp /opt/docapp/app
```

#### 3-5. uWSGI 設定ファイル作成

```bash
vi /opt/docapp/uwsgi.ini
```

```ini
[uwsgi]
chdir = /opt/docapp/app
module = app:app
home = /opt/docapp/venv

master = true
processes = 2
threads = 2

http = 0.0.0.0:8000

uid = docapp
gid = docapp

logto = /var/log/docapp/uwsgi.log
die-on-term = true
```

```bash
mkdir -p /var/log/docapp
chown docapp:docapp /var/log/docapp
```

> **解説:`http = 0.0.0.0:8000` で HTTPモード**
>
> uWSGI はデフォルトでは `uwsgi` プロトコル(独自バイナリ)で待ち受けるが、`http = ...` を指定すると HTTPサーバとしても動く。Lighttpd 側で `mod_proxy` を使う場合は HTTP の方が設定が簡単なので、本構成では HTTPモードを採用する。

> **考えるポイント:`processes` と `threads` の使い分け**
>
> `processes` はOSプロセスをフォークする数、`threads` は各プロセス内のスレッド数。CPU bound(計算重視)ならプロセスを増やし、I/O bound(外部API呼び出し重視)ならスレッドを増やすのが基本。本アプリは OpenSearch と MinIO への外部呼び出しが主なのでスレッドを2つ持たせている。

#### 3-6. systemd ユニットファイル作成

```bash
cat > /etc/systemd/system/docapp.service << 'EOF'
[Unit]
Description=Document App (uWSGI + Flask)
After=network-online.target

[Service]
Type=simple
ExecStart=/opt/docapp/venv/bin/uwsgi --ini /opt/docapp/uwsgi.ini
Environment=MINIO_ENDPOINT=http://storage.docsearch.local:9000
Environment=MINIO_ACCESS_KEY=appuser
Environment=MINIO_SECRET_KEY=apppassword123
Environment=MINIO_BUCKET=documents
Environment=OS_HOST=search.docsearch.local
Environment=OS_PORT=9200
Environment=OS_INDEX=documents
Restart=always

[Install]
WantedBy=multi-user.target
EOF
```

> **解説:`Environment=` で接続情報を注入**
>
> Flaskコード内で `os.environ.get()` で読み込んでいる値を、systemd の `Environment=` 行で渡す。アプリのコードに接続情報を直書きせず、デプロイ環境ごとに切り替えられる構造になっている。

#### 3-7. OpenSearchインデックスの作成(kuromoji 適用)

> **⚠️ 重要:必ずアプリ起動(Step 3-8)より前に実行すること**
>
> このステップを省略または後回しにしてアプリを先に起動すると、最初のアップロード時に OpenSearch が「動的マッピング」でインデックスを自動生成してしまう。動的マッピングでは `content` フィールドに kuromoji が適用されないため、日本語の全文検索が正常に動作しない。
>
> 動的マッピングで作られてしまった場合は、インデックスを削除して作り直す必要がある(エラー⑤を参照)。

app から OpenSearch へ kuromoji 設定付きのインデックスを作る。

```bash
curl -X PUT "http://search.docsearch.local:9200/documents" \
  -H 'Content-Type: application/json' \
  -d '{
    "settings": {
      "analysis": {
        "analyzer": {
          "ja_kuromoji": {
            "type": "custom",
            "tokenizer": "kuromoji_tokenizer"
          }
        }
      }
    },
    "mappings": {
      "properties": {
        "filename":   { "type": "keyword" },
        "object_key": { "type": "keyword" },
        "content":    { "type": "text", "analyzer": "ja_kuromoji" }
      }
    }
  }'
```

`"acknowledged":true` が返ればOK。

> **解説:インデックスを「事前に」作る理由**
>
> OpenSearch はインデックスがない状態で書き込みすると、フィールド型を自動推測した「動的マッピング」のインデックスを勝手に作る。この場合 `content` は標準アナライザでインデックスされ、日本語の形態素解析が効かない。**事前にマッピングを明示**することで、kuromoji を確実に使わせる。

> **考えるポイント:マッピングは後から変更できない**
>
> 一度作ったマッピングは原則変更不可。既存のフィールドの型やアナライザを変えたい場合は、新しいインデックスを作って reindex する必要がある。「最初に決めたスキーマがずっと付いて回る」という意味では RDB の DDL に近い。

#### 3-8. アプリ起動

```bash
systemctl daemon-reload
systemctl start docapp
systemctl status docapp
systemctl enable docapp
```

ローカルで疎通確認:

```bash
curl http://localhost:8000/api/health
# {"status":"ok"} が返ればOK
```

---

### Step 4: 【webサーバで実施】Lighttpd の構築

**目的:** Lighttpd をリバースプロキシ + 静的配信用Webサーバとして構築する。

#### 4-1. Lighttpd ビルド(meson方式)

Amazon Linux 2023 のデフォルトリポジトリには Lighttpd がないため、ソースからビルドする。Lighttpd 1.4 系は autoconf 方式から **meson ビルドシステムに移行している** ため、`./configure` ではなく `meson` を使う。

```bash
dnf install -y gcc meson ninja-build pcre2-devel zlib-devel openssl-devel

cd /usr/local/src
curl -LO https://download.lighttpd.net/lighttpd/releases-1.4.x/lighttpd-1.4.76.tar.gz
tar xzf lighttpd-1.4.76.tar.gz
cd lighttpd-1.4.76

# meson でビルド設定(別ディレクトリ build/ に出力される)
meson setup build --prefix=/usr/local/lighttpd

# ビルド・インストール
cd build
ninja
ninja install
```

> **解説:meson ビルド方式の使い勝手**
>
> - `meson setup build`: 旧 `./configure` 相当。`build` ディレクトリを作って中で設定
> - `ninja`: 旧 `make` 相当。並列ビルドが速い
> - `ninja install`: 旧 `make install` 相当
>
> ソースディレクトリと別の `build/` ディレクトリで作業するため、ソースが汚れず、複数のビルド設定を共存させやすい。

ビルド成功確認:

```bash
ls -l /usr/local/lighttpd/sbin/lighttpd
/usr/local/lighttpd/sbin/lighttpd -v
# lighttpd/1.4.76 と表示されればOK

# mod_proxy が含まれているか確認
ls /usr/local/lighttpd/lib/lighttpd/ | grep proxy
# mod_proxy.so が表示されればOK
```

> **注意:モジュールは `lib/lighttpd/` 配下に置かれる**
>
> meson ビルドでは、モジュールは `<prefix>/lib/lighttpd/` という1階層深い場所に配置される。後の lighttpd.conf でモジュール検索パスを明示する必要がある(4-3参照)。

#### 4-2. 専用ユーザーとディレクトリ作成

```bash
useradd -r -s /sbin/nologin lighttpd
mkdir -p /var/log/lighttpd
mkdir -p /var/www/html/static
chown -R lighttpd:lighttpd /var/log/lighttpd
chown -R lighttpd:lighttpd /var/www/html
```

#### 4-3. lighttpd.conf の作成

```bash
mkdir -p /etc/lighttpd
vi /etc/lighttpd/lighttpd.conf
```

```
# モジュール配置先を明示(meson ビルドの場合)
server.modules-path = "/usr/local/lighttpd/lib/lighttpd"

server.modules = (
    "mod_proxy",
    "mod_access",
    "mod_accesslog",
)

server.document-root = "/var/www/html"
server.port          = 80
server.username      = "lighttpd"
server.groupname     = "lighttpd"

server.errorlog      = "/var/log/lighttpd/error.log"
accesslog.filename   = "/var/log/lighttpd/access.log"

index-file.names = ( "index.html" )

mimetype.assign = (
    ".html" => "text/html",
    ".txt"  => "text/plain",
    ".css"  => "text/css",
    ".js"   => "application/javascript",
    ".json" => "application/json",
)

# /api/* を app サーバの uWSGI に転送
$HTTP["url"] =~ "^/api/" {
    proxy.server = ( "" => (
        ( "host" => "<APP_PRI>", "port" => 8000 )
    ))
}
```

> **解説:`server.modules-path` を明示する理由**
>
> meson ビルドではモジュールが `/usr/local/lighttpd/lib/lighttpd/` 配下に置かれる。Lighttpd のデフォルト検索パスではこの場所が見つからず、起動時に「mod_proxy が読めない」というエラー(`status=255/EXCEPTION`)で失敗する。明示的にパスを指定することで、確実にモジュールをロードできる。

> **解説:`mod_proxy` の指定方法**
>
> Lighttpd 1.4 系の `mod_proxy` は接続先を `host` と `port` で指定するシンプルな書き方。`$HTTP["url"] =~ "^/api/"` で「URLが `/api/` で始まる場合のみ転送」する条件分岐になっている。

#### 4-4. 静的HTMLの作成(簡易検索フォーム)

```bash
cat > /var/www/html/index.html << 'EOF'
<!DOCTYPE html>
<html lang="ja">
<head>
<meta charset="UTF-8">
<title>Document Search</title>
<style>
body { font-family: sans-serif; max-width: 800px; margin: 2em auto; padding: 1em; }
input[type=text] { width: 60%; padding: 0.5em; }
button { padding: 0.5em 1em; }
.hit { border: 1px solid #ccc; padding: 1em; margin: 1em 0; }
em { background: yellow; font-style: normal; }
</style>
</head>
<body>
<h1>Document Search</h1>

<h2>Search</h2>
<input type="text" id="q" placeholder="検索ワード">
<button onclick="search()">検索</button>
<div id="results"></div>

<h2>Upload (curl example)</h2>
<pre>curl -F "file=@your.txt" http://&lt;WEB_PUB&gt;/api/upload</pre>

<script>
async function search() {
  const q = document.getElementById('q').value;
  const res = await fetch('/api/search?q=' + encodeURIComponent(q));
  const data = await res.json();
  const div = document.getElementById('results');
  div.innerHTML = '<p>Total: ' + data.total + '</p>';
  for (const h of data.hits) {
    const hl = (h.highlight || []).join(' ... ');
    div.innerHTML += '<div class="hit"><b>' + h.filename + '</b> (id: ' + h.id +
                     ', score: ' + h.score.toFixed(2) + ')<br>' + hl + '<br>' +
                     '<a href="/api/download/' + h.id + '">Download</a></div>';
  }
}
</script>
</body>
</html>
EOF

chown lighttpd:lighttpd /var/www/html/index.html
```

#### 4-5. systemd ユニットファイル作成

```bash
cat > /etc/systemd/system/lighttpd.service << 'EOF'
[Unit]
Description=Lighttpd Web Server
After=network-online.target

[Service]
Type=simple
ExecStart=/usr/local/lighttpd/sbin/lighttpd -D -f /etc/lighttpd/lighttpd.conf
Restart=always

[Install]
WantedBy=multi-user.target
EOF
```

> **解説:`-D` オプションの意味**
>
> Lighttpd はデフォルトでデーモン化(バックグラウンド化)するが、systemd 配下では「フォアグラウンド実行」が望ましい。`-D` でフォアグラウンド起動させ、systemd にプロセス管理を任せる。

#### 4-6. 起動と確認

```bash
# 起動前に設定ファイルの文法チェック
/usr/local/lighttpd/sbin/lighttpd -t -f /etc/lighttpd/lighttpd.conf
# Syntax OK と表示されればOK

systemctl daemon-reload
systemctl start lighttpd
systemctl status lighttpd
systemctl enable lighttpd

curl http://localhost/
# HTMLが返ればOK

curl http://localhost/api/health
# {"status":"ok"} が返ればOK(app サーバまで疎通している)
```

---

### Step 5: 【clientサーバで実施】動作確認用クライアントの準備

**目的:** 検証用にツールとテストデータを準備する。

#### 5-1. ツール導入

Amazon Linux 2023 では `curl` が `curl-minimal` としてプリインストール済み(本構成に必要な機能はすべて利用可能)なので、`jq` のみインストールする。

```bash
dnf install -y jq

# 確認
curl --version
jq --version
```

> **注意:`dnf install curl` は実行しない**
>
> Amazon Linux 2023 では `curl-minimal` がプリインストールされており、`dnf install curl`(フルパッケージ)を実行すると競合エラーになる。`curl-minimal` で `-F`, `-O`, `-L` 等の本構成に必要な機能はすべて使えるため、追加インストール不要。

#### 5-2. テスト用ファイルの作成

```bash
mkdir -p /root/testdata
cd /root/testdata

cat > tokyo.txt << 'EOF'
東京都は日本の首都であり、政治・経済・文化の中心地です。
人口は約1400万人で、世界有数の大都市圏を形成しています。
EOF

cat > kyoto.txt << 'EOF'
京都府は日本の古都として知られ、千年以上の歴史を持ちます。
神社仏閣が多く、観光地として世界中から人が訪れます。
EOF

cat > server.txt << 'EOF'
Linuxサーバの基本的な運用には、systemdによるサービス管理、
rsyslogによるログ管理、cronによるジョブ管理などが含まれます。
OpenSearchやMinIOといったミドルウェアも、systemdで常駐させるのが一般的です。
EOF
```

---

## 5. 動作確認・検証

> 構築完了後、以下の確認をすべてパスしたら構築成功とみなす。

### 5-1. 確認チェックリスト

- [ ] **確認①**: web → app の疎通確認【clientサーバで実施】
- [ ] **確認②**: ドキュメントのアップロード【clientサーバで実施】
- [ ] **確認③**: 全文検索(日本語)【clientサーバで実施】
- [ ] **確認④**: ダウンロード【clientサーバで実施】
- [ ] **確認⑤**: Dashboards でのインデックス確認【手元PCのブラウザで実施】

---

### 確認①: 疎通確認【clientサーバで実施】

```bash
curl http://web.docsearch.local/api/health
```

期待: `{"status":"ok"}`

このルートは `client → web(Lighttpd) → app(uWSGI) → 応答` を全部経由している。

> **解説:疎通できない場合の切り分け**
>
> - `Could not resolve host` → client の `/etc/hosts` に `web.docsearch.local` が登録されていない(Step 0-2の確認)
> - `Connection refused` → web サーバの Lighttpd が起動していない
> - `502 Bad Gateway` → web は応答するが app に届いていない(app サーバ起動・SG確認)

### 確認②: アップロード【clientサーバで実施】

```bash
cd /root/testdata

curl -F "file=@tokyo.txt"  http://web.docsearch.local/api/upload | jq
curl -F "file=@kyoto.txt"  http://web.docsearch.local/api/upload | jq
curl -F "file=@server.txt" http://web.docsearch.local/api/upload | jq
```

各レスポンスで `"id"` と `"object_key"` が返ればOK。`id` は後で使うのでメモする。

storage サーバから確認(必要に応じて):

```bash
mc ls local/documents --recursive
# 3つのオブジェクトが見えればOK
```

### 確認③: 全文検索【clientサーバで実施】

```bash
# 「都」を検索(kuromoji が「東京都」「京都府」を「都」で分かち書きしていれば両方ヒットする)
curl "http://web.docsearch.local/api/search?q=%E9%83%BD" | jq

# 「サーバ」を検索 → server.txt がヒット
curl "http://web.docsearch.local/api/search?q=%E3%82%B5%E3%83%BC%E3%83%90" | jq

# 「歴史」を検索 → kyoto.txt がヒット
curl "http://web.docsearch.local/api/search?q=%E6%AD%B4%E5%8F%B2" | jq
```

> **考えるポイント:kuromoji が効いていない場合の挙動**
>
> もし `analysis-kuromoji` が入っていない、またはインデックスのマッピングで指定し忘れていた場合、「都」を検索しても「東京都」がヒットしないことがある(標準アナライザは日本語を分かち書きできない)。挙動がおかしいときはマッピング確認(Step 3-7 の curl PUT を `_mapping` GET に置き換える)。

マッピング確認コマンド:

```bash
curl "http://search.docsearch.local:9200/documents/_mapping" | jq
```

`"analyzer": "ja_kuromoji"` が見えればOK。

### 確認④: ダウンロード【clientサーバで実施】

確認②で得た id を使う:

```bash
curl -O -J "http://web.docsearch.local/api/download/<id>"
ls
cat <ダウンロードされたファイル>
```

元のテキストと一致すればOK。

### 確認⑤: Dashboards でのインデックス確認【手元PCのブラウザで実施】

ブラウザで `http://<SEARCH_PUB>:5601` にアクセス。

1. Welcome画面が表示されたら **"Explore on my own"** をクリック
2. 左上のハンバーガーメニュー(三本線アイコン)をクリック
3. メニューから **"Management" → "Dashboards Management"** を選択
4. **"Index Patterns" → "Create index pattern"** をクリック
5. インデックスパターン名に `documents` を入力 → Next
6. Time field のステップが表示される場合は `I don't want to use the time filter` を選択 → Create
   (本構成のドキュメントには時系列フィールドがないため、このステップが省略される場合あり)
7. 左メニューから **"Discover"** を選択 → `documents` インデックスを選択 → アップロードしたドキュメントが見えればOK

---

## 6. トラブルシューティング

### エラー①: OpenSearch が起動しない

**原因候補:**
- `vm.max_map_count` が足りない
- メモリ不足(t3.micro 等の小さいインスタンスを使っている)

**対処法:**

```bash
sysctl vm.max_map_count
# 262144 になっていなければ Step 2-6 を再実行

free -h
# available が 1GB を切っていたらインスタンスタイプを上げる

journalctl -u opensearch -n 50 --no-pager
# bootstrap check failed があれば該当チェック項目を確認
```

### エラー②: Dashboards が起動しない / 「Server is not ready yet」

**原因:** デフォルトの `opensearch_dashboards.yml` 末尾にあるセキュリティプラグイン前提の設定が残っている、または OpenSearch がまだ起動完了していない。

**対処法:**

```bash
# 設定ファイルに余計な設定が残っていないか確認
cat /opt/opensearch-dashboards/config/opensearch_dashboards.yml
# kibanaserver や opensearch_security の行が見えたら、Step 2-11 の全置換手順を再実行

# OpenSearch 側がHTTPで応答するか確認
curl http://localhost:9200

# 再起動
systemctl reset-failed opensearch-dashboards
systemctl restart opensearch-dashboards
journalctl -u opensearch-dashboards -n 50 --no-pager
```

### エラー③: MinIO が起動しない(`Exec format error`)

**原因:** `curl -O`(`-L` なし)でダウンロードしたためバイナリではなくHTMLが保存されている。

**対処法:**

```bash
# サイズ確認(100MB前後あれば正常)
ls -lh /usr/local/bin/minio

# 数百バイトしかない場合はダウンロードし直し
systemctl stop minio
systemctl reset-failed minio
cd /usr/local/bin
rm -f minio mc
curl -LO https://dl.min.io/server/minio/release/linux-amd64/minio
curl -LO https://dl.min.io/client/mc/release/linux-amd64/mc
chmod +x minio mc
systemctl start minio
```

### エラー④: アップロードで 500 エラー

**原因:** MinIO への接続失敗、または OpenSearch への接続失敗。

**対処法:**

```bash
# app サーバで MinIO 疎通
curl http://storage.docsearch.local:9000/minio/health/live
# HTTP/1.1 200 OK が返ればOK

# OpenSearch 疎通
curl http://search.docsearch.local:9200
# JSON が返ればOK

# アプリログ確認
tail -f /var/log/docapp/uwsgi.log
```

### エラー⑤: 検索しても日本語がヒットしない

**原因:** kuromoji が適用されていない。

**対処法:**

```bash
# プラグイン確認
sudo -u opensearch /opt/opensearch/bin/opensearch-plugin list
# analysis-kuromoji が表示されればOK

# マッピング確認
curl "http://search.docsearch.local:9200/documents/_mapping" | jq

# マッピングが「動的マッピング」になっている(analyzer指定がない)場合:
# インデックスを作り直す
curl -X DELETE "http://search.docsearch.local:9200/documents"
# その後 Step 3-7 のPUTを再実行
# アップロードもやり直し
```

### エラー⑥: Lighttpd が起動しない(`status=255/EXCEPTION`)

**原因候補:**
- モジュール検索パス(`server.modules-path`)が指定されていない
- 設定ファイル内の `<APP_PRI>` 等のプレースホルダが置換されていない
- ポート 80 が他のプロセスに使われている

**対処法:**

```bash
# 設定ファイル文法チェック
/usr/local/lighttpd/sbin/lighttpd -t -f /etc/lighttpd/lighttpd.conf

# フォアグラウンドで起動して生エラーを見る
/usr/local/lighttpd/sbin/lighttpd -D -f /etc/lighttpd/lighttpd.conf

# モジュール検索パスの確認
grep modules-path /etc/lighttpd/lighttpd.conf
ls /usr/local/lighttpd/lib/lighttpd/mod_proxy.so

# ポート競合確認
ss -tlnp | grep ':80 '
```

### エラー⑦: `curl: (6) Could not resolve host`

**原因:** 該当サーバの `/etc/hosts` に対象ホストが登録されていない。

**対処法:**

```bash
cat /etc/hosts
# 該当ホスト名がなければ Step 0-2 を再実施
```

### ログの確認場所

| ログ | 場所 | コマンド |
|---|---|---|
| Lighttpd エラー | `/var/log/lighttpd/error.log` | `tail -f /var/log/lighttpd/error.log` |
| uWSGI / Flask | `/var/log/docapp/uwsgi.log` | `tail -f /var/log/docapp/uwsgi.log` |
| OpenSearch | `journalctl -u opensearch` | `journalctl -u opensearch -f` |
| Dashboards | `journalctl -u opensearch-dashboards` | `journalctl -u opensearch-dashboards -f` |
| MinIO | `journalctl -u minio` | `journalctl -u minio -f` |

---

## 7. 参考リソース・関連資料

| 資料名 | URL | 補足 |
|---|---|---|
| Lighttpd 公式 | https://www.lighttpd.net/ | Lighttpd 設定リファレンス |
| uWSGI 公式 | https://uwsgi-docs.readthedocs.io/ | uWSGI 設定リファレンス |
| Flask 公式 | https://flask.palletsprojects.com/ | Flask ドキュメント |
| OpenSearch 公式 | https://opensearch.org/docs/latest/ | OpenSearch ドキュメント |
| OpenSearch Dashboards | https://opensearch.org/docs/latest/dashboards/ | Dashboards 公式 |
| analysis-kuromoji | https://opensearch.org/docs/latest/analyzers/language-analyzers/ | 日本語アナライザ |
| MinIO 公式 | https://min.io/docs/minio/linux/index.html | MinIO ドキュメント |
| boto3 公式 | https://boto3.amazonaws.com/v1/documentation/api/latest/index.html | AWS SDK for Python |
| opensearch-py | https://opensearch.org/docs/latest/clients/python-low-level/ | Python クライアント |

---

## 付録

### A. 環境変数・パラメータまとめ

| パラメータ | 値 | 説明 |
|---|---|---|
| `<WEB_PUB>` | xx.xx.xx.xx | web 公開IP |
| `<WEB_PRI>` | xx.xx.xx.xx | web 内部IP |
| `<APP_PRI>` | xx.xx.xx.xx | app 内部IP |
| `<SEARCH_PUB>` | xx.xx.xx.xx | search 公開IP(Dashboards) |
| `<SEARCH_PRI>` | xx.xx.xx.xx | search 内部IP |
| `<STORAGE_PUB>` | xx.xx.xx.xx | storage 公開IP(Console) |
| `<STORAGE_PRI>` | xx.xx.xx.xx | storage 内部IP |
| MinIO 管理者 | adminuser / adminpassword123 | MinIO root 認証情報 |
| MinIO アプリユーザー | appuser / apppassword123 | アプリ用認証情報 |
| MinIO バケット | documents | ドキュメント保存先 |
| OpenSearch インデックス | documents | 全文検索インデックス |

### B. 用語解説

| 用語 | 説明 |
|---|---|
| OpenSearch | Elasticsearch から派生した OSS の全文検索エンジン |
| Lucene | OpenSearch / Elasticsearch の中で使われている検索ライブラリ |
| インデックス(OpenSearch) | RDB のテーブルに相当する論理的なデータ格納単位 |
| マッピング | インデックスのスキーマ定義(フィールド名・型・アナライザ) |
| アナライザ | テキストをトークン(語)に分解し、検索可能な形式にする処理 |
| kuromoji | 日本語向けの形態素解析器。OpenSearch のプラグインとして提供 |
| Dashboards | OpenSearch の可視化・管理UI(Kibanaに相当) |
| MinIO | S3互換APIを提供するOSSオブジェクトストレージ |
| S3互換 | AWS S3 と同じAPIで操作できる仕組み。boto3 等が流用できる |
| uWSGI | Python等のアプリを常駐させるアプリケーションサーバ |
| WSGIプロトコル | Pythonアプリとサーバの間のインターフェース仕様(PEP 3333) |
| Lighttpd | 軽量・高速なWebサーバ。組込み機器でも使われる |
| mod_proxy(Lighttpd) | Lighttpd のリバースプロキシモジュール |
| meson / ninja | 近代的なビルドシステム。autoconf/make の後継的位置づけ |

### C. 削除・クリーンアップ手順

1. アプリ停止: `systemctl stop docapp lighttpd opensearch-dashboards opensearch minio`
2. インデックス削除(任意): `curl -X DELETE "http://search.docsearch.local:9200/documents"`
3. バケット削除(任意): `mc rb --force local/documents`
4. EC2 インスタンス 5 台を終了
5. セキュリティグループを削除
6. キーペアを削除(必要に応じて)

> **注意:** EC2 を停止だけしている間も EBS のコストは発生する。学習が終わったら終了するかEBSスナップショットだけ残すこと。
