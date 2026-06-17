# 【手順書名】Docker マルチコンテナ環境構築手順書(Jupyter / Java / PostgreSQL / pgAdmin)

------------------------------

## 1. ドキュメント情報

| 項目 | 内容 |
|------|------|
| 手順書名 | Docker マルチコンテナ環境構築手順書(Jupyter / Java / PostgreSQL / pgAdmin) |
| 作成日 | 2026-06-15 |
| 最終更新日 | 2026-06-15 |
| バージョン | v1.0 |
| 対象環境 | AWS(EC2 / Amazon Linux 2023) |

> **改訂履歴**
>
> | バージョン | 日付 | 変更内容 |
> |-----------|------|---------|
> | v1.0 | 2026-06-15 | 初版作成 |

------------------------------

## 2. 目的・概要

### 2-1. 目的

本手順書では、AWS EC2(Amazon Linux 2023)上に Docker および Docker Compose を用いて、Jupyter Notebook・Java・PostgreSQL・pgAdmin4 の 4 コンテナで構成される学習用環境を構築する。

本来は専用イメージを使えば容易だが、Docker / Compose の理解を深めるため、あえて Jupyter コンテナは Amazon Linux ベースイメージから Anaconda を導入する冗長な構成とする。

### 2-2. 構成概要(アーキテクチャ)

```
[ローカルPC(ブラウザ / SSH)]
        |
        |  HTTP(80, 8888) / SSH(22)
        v
[EC2: Amazon Linux 2023 (t3.micro)]
   |
   └── Docker Engine
         ├── [jupyter]    my_python:latest (Anaconda + pandas + django)   :8888
         ├── [java]       eclipse-temurin:11-jdk                          :8080
         ├── [postgresql] postgres:13.4                                   :5432
         └── [pgadmin4]   dpage/pgadmin4:5.6                              :80
                  ↑
                  ホスト ./work 配下をボリュームマウント
```

### 2-3. 完成イメージ(ゴール定義)

- [ ] `docker compose ps` で 4 コンテナすべて `Up` 状態
- [ ] ブラウザから `http://<EC2パブリックIP>:8888` で Jupyter にアクセスでき、トークン認証を通過できる
- [ ] ブラウザから `http://<EC2パブリックIP>` で pgAdmin にログインでき、PostgreSQL に接続できる
- [ ] Java コンテナで `java -version` が `11.x` を表示する
- [ ] ホスト側 `./work/note` に置いたファイルが Jupyter から参照できる(ボリューム連携)

------------------------------

## 3. 前提条件・準備

### 3-1. 環境要件

| 項目 | 要件 |
|------|------|
| OS | Amazon Linux 2023(x86_64) |
| インスタンスタイプ | **t3.micro 以上**(t2.micro はメモリ 1GB のため Anaconda ビルドで OOM 発生) |
| リージョン | 任意(本手順書では ap-northeast-1 東京を想定) |
| 作業ユーザー | root(教材都合。実運用では一般ユーザー + docker グループ推奨) |
| その他 | EC2 へ SSH 接続できる状態(キーペア・パブリックIP) |

> **任意のディレクトリ名について**: 本手順書では作業ディレクトリを `~/example` として記載するが、これは**任意の名称**。各自の作業ディレクトリ名に読み替えること。

### 3-2. セキュリティグループ設定

AWS コンソールのソース選択で「マイIP」を選ぶと、現在のグローバルIPが `/32` 付きで自動設定される。`0.0.0.0/0` での全開放は厳禁。

| タイプ | プロトコル | ポート範囲 | ソース | 説明 |
|-------|------------|----------|--------|------|
| SSH | TCP | 22 | マイIP | ローカルPCからSSHで接続 |
| カスタムTCP | TCP | 80 | マイIP | pgAdmin にブラウザ接続 |
| カスタムTCP | TCP | 8080 | マイIP | Java サービス用 |
| カスタムTCP | TCP | 8888 | マイIP | Jupyter にブラウザ接続 |
| カスタムTCP | TCP | 5432 | マイIP | PostgreSQL を外部クライアントから接続する場合のみ |

### 3-3. 最終ディレクトリ構成

```
example/                       ← 任意の名称
├── compose.yml
└── work/
    ├── jupyter/
    │   └── Dockerfile
    ├── note/                  ← Jupyter 作業領域(ホスト⇔コンテナ共有)
    ├── java/                  ← Java ソース/jar 配置
    ├── postgres/
    │   ├── init/              ← 初期化 SQL 配置先
    │   └── data/              ← DB 永続化データ
    └── pgadmin4/              ← pgAdmin ストレージ
```

------------------------------

## 4. 構築手順(詳細)

> **注意事項**
> - コマンド中の `<山カッコ>` は自分の環境の値に置き換えること
> - 本手順書は root 実行を前提とする(プロンプト `[root@...]#`)
> - `~/example` の `example` は任意の名称。読み替え可

------------------------------

### Step 1:EC2 インスタンスタイプの確認・変更

**目的:** Anaconda ビルドに耐えられるスペックのインスタンス(t3.micro 以上)を用意する。

#### 操作手順

1. AWS コンソール → EC2 → 対象インスタンスを選択
2. 現在のタイプが `t2.micro` の場合、インスタンスを**停止**する
3. [アクション] → [インスタンス設定] → [インスタンスタイプを変更] → `t3.micro` を選択
4. インスタンスを**起動**
5. Elastic IP 未割当の場合、パブリックIPが変動するため SSH 接続情報を更新

> **確認:** AWS コンソールのインスタンス詳細画面で、インスタンスタイプが `t3.micro` と表示されること

------------------------------

### Step 2:Docker のインストールと起動

**目的:** Docker Engine を導入し、サービスとして起動・自動起動設定を行う。

#### 操作手順

1. パッケージリストを最新化する

   ```bash
   sudo dnf update -y
   ```

2. Docker をインストールする

   ```bash
   sudo dnf install -y docker
   ```

3. インストール後のバージョン確認

   ```bash
   docker --version
   ```

4. Docker サービスを起動

   ```bash
   sudo systemctl start docker
   ```

5. OS 起動時の自動起動を有効化

   ```bash
   sudo systemctl enable docker
   ```

> **確認:** `sudo systemctl status docker` の出力に `active (running)` と表示されること

------------------------------

### Step 3:Docker Compose / Buildx プラグイン導入

**目的:** Compose による複数コンテナの一括管理、および `docker compose build` 実行に必要な Buildx 0.17.0 以上を準備する。

#### 操作手順

1. プラグイン配置ディレクトリを作成

   ```bash
   mkdir -p /root/.docker/cli-plugins
   ```

2. Docker Compose をダウンロード

   ```bash
   curl -SL https://github.com/docker/compose/releases/latest/download/docker-compose-linux-x86_64 \
     -o /root/.docker/cli-plugins/docker-compose
   chmod +x /root/.docker/cli-plugins/docker-compose
   ```

3. Compose の動作確認

   ```bash
   docker compose version
   ```

4. Buildx v0.18.0 をダウンロード(`-fL`:HTTPエラー時に失敗扱い・リダイレクト追従)

   ```bash
   curl -fL \
     https://github.com/docker/buildx/releases/download/v0.18.0/buildx-v0.18.0.linux-amd64 \
     -o /root/.docker/cli-plugins/docker-buildx
   ```

5. ファイルサイズを確認(数十MBが正常。9バイト等の極小はダウンロード失敗)

   ```bash
   ls -lh /root/.docker/cli-plugins/docker-buildx
   ```

6. 実行権限を付与

   ```bash
   chmod +x /root/.docker/cli-plugins/docker-buildx
   ```

> **確認:**
> - `docker compose version` で `Docker Compose version v2.x` 以上が表示されること
> - `docker buildx version` で `github.com/docker/buildx v0.18.0 ...` が表示されること

------------------------------

### Step 4:スワップ領域の追加(2GB)【任意】

**目的:** メモリ不足によるビルド失敗を防ぐ。**本手順は任意**で、検証環境(t3.micro)ではスワップ未設定でもビルド完走を確認済み。安定性を高めたい場合、または OOM Killer による中断が発生した場合に実施する。

#### 操作手順

1. スワップ用ファイルを作成(2GB = 1MB × 2048)

   ```bash
   sudo dd if=/dev/zero of=/swapfile bs=1M count=2048
   ```

2. パーミッションを root のみアクセス可に設定(セキュリティ要件)

   ```bash
   sudo chmod 600 /swapfile
   ```

3. スワップ領域としてフォーマット

   ```bash
   sudo mkswap /swapfile
   ```

4. スワップを有効化

   ```bash
   sudo swapon /swapfile
   ```

5. 再起動後も自動有効化されるよう `/etc/fstab` に登録

   ```bash
   echo '/swapfile swap swap defaults 0 0' | sudo tee -a /etc/fstab
   ```

> **確認:** `free -h` の `Swap:` 行の `total` 列に `2.0Gi` が表示されること

------------------------------

### Step 5:作業ディレクトリと設定ファイルの配置

**目的:** Dockerfile および compose.yml を所定の場所に配置し、Docker Compose がビルド・起動できる状態にする。

#### 操作手順

1. 作業ディレクトリを作成(`-p` オプションで親ディレクトリも一括作成)

   ```bash
   mkdir -p ~/example/work/jupyter
   cd ~/example
   ```

   > 上記コマンド1行で `~/example`、`~/example/work`、`~/example/work/jupyter` の 3 階層が同時に作られる。
   > その他のディレクトリ(`work/note`、`work/java`、`work/postgres/init`、`work/postgres/data`、`work/pgadmin4`)は compose の起動時にホスト側へ自動作成されるため、事前作成は不要。

2. `~/example/work/jupyter/Dockerfile` を作成

   ```dockerfile
   FROM --platform=linux/x86_64 amazonlinux:2023
   ENV Anaconda anaconda3-2020.11
   ENV JupyterConf /root/.jupyter/jupyter_notebook_config.py
   SHELL ["/bin/bash", "-c"]
   RUN yum update -y
   RUN yum install -y gcc bzip2 bzip2-devel openssl openssl-devel readline readline-devel git wget gcc-c++ unixODBC-devel tar.x86_64 procps
   RUN git clone https://github.com/yyuu/pyenv.git /opt/pyenv
   ENV PYENV_ROOT /opt/pyenv
   ENV PATH $PATH:$PYENV_ROOT/bin
   RUN pyenv install $Anaconda
   ENV PATH $PATH:/opt/pyenv/versions/${Anaconda}/bin
   RUN jupyter notebook --generate-config
   RUN echo "c.NotebookApp.open_browser = False" > ${JupyterConf}
   RUN echo "c.NotebookApp.ip = '0.0.0.0'" >> ${JupyterConf}
   RUN echo "c.NotebookApp.token = 'hogehoge'" >> ${JupyterConf}
   RUN pip3 install pandas
   RUN pip3 install django
   ```

   > **注意**: ファイル名は **必ず `Dockerfile`**(大文字 D、拡張子なし)。

3. `~/example/compose.yml` を作成

   ```yaml
   services:
     jupyter:
       container_name: jupyter
       image: my_python:latest
       build: work/jupyter/.
       ports:
         - 8888:8888
       volumes:
         - ./work/note:/note
       working_dir: /note
       command: jupyter notebook --allow-root
       tty: true

     java:
       image: eclipse-temurin:11-jdk
       ports:
         - 8080:8080
       tty: true
       volumes:
         - ./work/java:/srv/cached
       working_dir: /srv

     postgresql:
       image: postgres:13.4
       container_name: postgresql
       ports:
         - 5432:5432
       volumes:
         - ./work/postgres/init:/docker-entrypoint-initdb.d
         - ./work/postgres/data:/var/lib/postgresql/data
       environment:
         POSTGRES_USER: root
         POSTGRES_PASSWORD: root
         POSTGRES_INITDB_ARGS: "--encoding=UTF-8"
       hostname: postgres
       restart: always
       user: root

     pgadmin4:
       platform: linux/x86_64
       image: dpage/pgadmin4:5.6
       container_name: pgadmin4
       ports:
         - 80:80
       volumes:
         - ./work/pgadmin4:/var/lib/pgadmin/storage
       environment:
         PGADMIN_DEFAULT_EMAIL: root@example.com
         PGADMIN_DEFAULT_PASSWORD: root@example.com
       hostname: pgadmin4
       restart: always
       user: root
   ```

   > **重要**: `openjdk:11-slim` は 2024 年初頭に Docker Hub から削除済み。後継の `eclipse-temurin:11-jdk` を使用する。

> **確認:**
> - `ls ~/example` で `compose.yml` と `work/` が存在すること
> - `ls ~/example/work/jupyter/Dockerfile` で `Dockerfile` が存在すること
> - `docker compose config` で構文エラーが出ないこと

------------------------------

### Step 6:イメージのビルドとコンテナ起動

**目的:** Dockerfile からイメージをビルドし、4 コンテナを起動する。

#### 操作手順

1. 作業ディレクトリへ移動

   ```bash
   cd ~/example
   ```

2. イメージをビルド(Anaconda ダウンロードを含むため **約 5〜30 分** 要)

   ```bash
   docker compose build
   ```

3. コンテナをバックグラウンドで起動

   ```bash
   docker compose up -d
   ```

4. 起動状態を確認

   ```bash
   docker compose ps
   ```

> **確認:** 全 4 コンテナの STATUS 列が `Up` であること
>
> ```
> NAME          IMAGE                    SERVICE      STATUS
> dock-java-1   eclipse-temurin:11-jdk   java         Up
> jupyter       my_python:latest         jupyter      Up
> pgadmin4      dpage/pgadmin4:5.6       pgadmin4     Up
> postgresql    postgres:13.4            postgresql   Up
> ```

------------------------------

### Step 7:動作確認

**目的:** 各サービスにアクセスでき、ホスト⇔コンテナのファイル共有が機能することを確認する。

#### 操作手順

1. EC2 内部からの疎通確認

   ```bash
   curl -I http://localhost:8888    # Jupyter
   curl -I http://localhost         # pgAdmin
   curl -I http://localhost:8080    # Java
   ```

2. ブラウザから Jupyter にアクセス

   - URL: `http://<EC2パブリックIP>:8888`
   - トークン入力欄に `hogehoge` を入力

3. ブラウザから pgAdmin にアクセス・ログイン

   - URL: `http://<EC2パブリックIP>`
   - Email: `root@example.com`
   - Password: `root@example.com`

4. pgAdmin から PostgreSQL に接続

   - サーバー登録時に以下を入力
     - Name: 任意(例:`local`)
     - Host: `postgresql`(compose 内のサービス名)
     - Port: `5432`
     - Username: `root`
     - Password: `root`

5. Java コンテナの動作確認

   ```bash
   docker compose exec java bash
   java -version
   exit
   ```

6. ホスト⇔コンテナのファイル共有確認

   ```bash
   echo "hello from host" > ~/example/work/note/test.txt
   docker compose exec jupyter cat /note/test.txt
   ```

> **確認:**
> - `curl -I` で各ポートからステータスコードが返ること
> - Jupyter のノートブック画面が表示されること
> - pgAdmin にログインでき、登録した PostgreSQL に接続できること
> - `java -version` で `openjdk version "11.x"` が表示されること
> - `docker compose exec jupyter cat /note/test.txt` で `hello from host` が表示されること

------------------------------

## 5. 運用コマンド

| 操作 | コマンド |
|---|---|
| 停止(コンテナ保持) | `docker compose stop` |
| 再起動 | `docker compose start` |
| 完全停止(コンテナ削除、ボリュームは残る) | `docker compose down` |
| ボリュームも削除(ホスト側 `./work` は残る) | `docker compose down -v` |
| 全サービスのログ | `docker compose logs` |
| 個別ログ(例:Jupyter) | `docker compose logs jupyter` |
| ログをフォロー | `docker compose logs -f postgresql` |
| コンテナ内シェル | `docker compose exec <service> bash` |
| キャッシュ無視で再ビルド | `docker compose build --no-cache` |

------------------------------

## 6. トラブルシューティング

### 6-1. `compose build requires buildx 0.17.0 or later`

- **原因:** AL2023 同梱の buildx が古い(0.12.1 等)
- **対処:** Step 3 の手順で buildx 0.18.0 以上を `/root/.docker/cli-plugins/docker-buildx` に配置

### 6-2. buildx 配置後も `'buildx' is not a docker command`

- **原因:**
  - ダウンロードファイルサイズが極端に小さい(リダイレクト未追従によるエラー応答が保存された)
  - 実行ユーザーと配置ディレクトリの不一致(プラグインは実行ユーザーのホーム配下を参照)
- **対処:** `ls -lh` でサイズ確認(数十MBが正常)。不足時は `-fL` オプション付きで再ダウンロード

### 6-3. `failed to read dockerfile: open Dockerfile: no such file or directory`

- **原因:** Dockerfile のファイル名違い(例:`dockerfile`、`Dockerfile.txt`)、または配置場所の誤り
- **対処:** `ls -la work/jupyter/` でファイル名を確認。ファイル名は**必ず `Dockerfile`**

### 6-4. `manifest for openjdk:11-slim not found`

- **原因:** `openjdk` イメージは 2024 年初頭に Docker Hub から削除済み
- **対処:** `compose.yml` の image を `eclipse-temurin:11-jdk` に変更

### 6-5. ブラウザで `ERR_CONNECTION_TIMED_OUT`

- **確認順序:**
  1. URL のポート番号が正しいか(`:8888` を忘れて pgAdmin(80番)に繋がる事例多発)
  2. セキュリティグループに該当ポートのインバウンド許可があるか
  3. EC2 のパブリックIPが変わっていないか(停止→起動で変動。Elastic IP 未割当時)
  4. EC2 内から `curl -I http://localhost:<port>` で疎通確認

### 6-6. ビルド中にメモリ不足で停止

- **原因:** メモリ不足(特に t2.micro)
- **対処:**
  - インスタンスタイプを t3.micro 以上に変更
  - Step 4 のスワップ追加を実施

### 6-7. `pyenv install` で失敗

- **原因:** `yyuu/pyenv` リポジトリが古い、または Anaconda ダウンロード元の URL 変更
- **対処:** Dockerfile の `yyuu/pyenv` を `pyenv/pyenv` に変更して再ビルド

------------------------------

## 付録

### A. コマンド解説

| コマンド | 役割 |
|---|---|
| `dnf update -y` | パッケージリストを最新化し、インストール済みパッケージを更新。`-y` は対話確認をスキップ |
| `systemctl start/enable <サービス>` | `start` は即時起動、`enable` は OS 起動時の自動起動設定 |
| `curl -fL <URL> -o <出力先>` | `-f`:HTTP エラー時に失敗扱い、`-L`:リダイレクト追従、`-o`:出力先指定。バイナリダウンロードに必須の組み合わせ |
| `chmod +x <ファイル>` | 実行権限を付与 |
| `mkdir -p <パス>` | `-p` で親ディレクトリも一括作成、既存ディレクトリでもエラーにしない |
| `docker compose build` | `compose.yml` の `build:` 指定に従いイメージをビルド |
| `docker compose up -d` | コンテナをバックグラウンド(`-d` = detached)で起動 |
| `docker compose ps` | Compose で管理されているコンテナの状態一覧 |
| `docker compose exec <service> <cmd>` | 起動中コンテナ内でコマンド実行 |

------------------------------

### B. 設定ファイル解説

#### B-1. Dockerfile(jupyter)

| 命令 | 内容 |
|---|---|
| `FROM --platform=linux/x86_64 amazonlinux:2023` | ベースイメージ。プラットフォーム明示で ARM 環境との混在を防止 |
| `ENV Anaconda anaconda3-2020.11` | Anaconda のバージョンを環境変数化(後続で再利用) |
| `SHELL ["/bin/bash", "-c"]` | デフォルトシェルを bash に変更(配列構文や変数展開のため) |
| `RUN yum install -y ...` | Anaconda ビルドに必要な開発ツール群を一括インストール |
| `RUN git clone https://github.com/yyuu/pyenv.git /opt/pyenv` | pyenv を取得。Python(Anaconda)バージョン管理用 |
| `RUN pyenv install $Anaconda` | Anaconda をインストール(最も時間がかかる工程) |
| `RUN jupyter notebook --generate-config` | Jupyter の設定ファイル雛形を生成 |
| `RUN echo "..." > / >> ${JupyterConf}` | 設定ファイルに 3 項目(ブラウザ起動抑止 / 全 IF バインド / トークン固定)を書き込み |
| `RUN pip3 install pandas / django` | 追加 Python ライブラリ |

#### B-2. compose.yml(主要キー)

| キー | 役割 |
|---|---|
| `services:` | コンテナ定義のルート |
| `image:` | 使用イメージ。指定が無い場合は `build:` の結果を使用 |
| `build:` | Dockerfile の場所(Dockerfile ベースのビルド時) |
| `container_name:` | コンテナ名(明示しないと `<プロジェクト名>-<サービス名>-<番号>`) |
| `ports:` | `ホスト側ポート:コンテナ側ポート` のフォワーディング |
| `volumes:` | `ホストパス:コンテナパス` のボリュームマウント。ホストパスは compose.yml からの相対パス可 |
| `environment:` | コンテナに渡す環境変数 |
| `working_dir:` | コンテナ内のカレントディレクトリ |
| `command:` | コンテナ起動時に実行するコマンド(イメージのデフォルト CMD を上書き) |
| `tty: true` | TTY 割当(対話的に exec で入る場合の必須設定) |
| `restart: always` | 異常終了時の自動再起動 |
| `hostname:` | コンテナ内 `/etc/hostname` の値。他コンテナからの名前解決にも利用可 |

------------------------------

### C. 用語解説

| 用語 | 説明 |
|---|---|
| Docker Engine | コンテナを実行するランタイム本体 |
| Docker Compose | 複数コンテナを YAML で宣言的に管理するツール |
| Buildx | Docker の拡張ビルド機能。Compose v2 のビルドでも内部的に使用 |
| OOM Killer | Linux カーネルがメモリ枯渇時にプロセスを強制終了する仕組み |
| スワップ | RAM 不足時にディスクをメモリの代替として使う領域 |
| pyenv | 複数の Python バージョンを切り替えて管理するツール |
| Anaconda | データサイエンス向けの Python ディストリビューション(Python + 大量のライブラリ群) |
| Eclipse Temurin | Eclipse Adoptium 提供の OpenJDK ディストリビューション。Docker 公式が `openjdk` 廃止後の後継として案内 |
| `cli-plugins` ディレクトリ | `docker compose` や `docker buildx` などサブコマンドを実体ファイルとして配置する場所 |

------------------------------

### D. 補足解説

#### D-1. スワップが必要な理由

t3.micro はメモリ 1GB しかなく、Jupyter コンテナのビルド時に Anaconda(数 GB)を展開する過程でメモリが枯渇する可能性がある。スワップを 2GB 追加することでビルド中のピーク需要を吸収し、OOM Killer によるビルド中断を防ぐ。

ただし**スワップはディスク I/O ベースで RAM の数百倍遅い**ため、恒常的にスワップを使う状況は本来インスタンスタイプ見直しの合図。今回はあくまでビルド時の一時対策。

| メモリ | 推奨スワップ |
|---|---|
| 〜2GB | RAM の 2 倍 |
| 2GB〜8GB | RAM と同サイズ |
| 8GB〜 | 4GB〜8GB(用途次第) |

#### D-2. `openjdk` イメージ廃止について

Docker Hub の `openjdk` 公式イメージは 2024 年初頭に **deprecated** となり、新しいタグの提供が停止した。後継として Docker 公式が案内しているのが以下の 2 つ。

| イメージ | 特徴 |
|---|---|
| `eclipse-temurin:<ver>-jdk` | Adoptium 公式の OpenJDK。Docker 公式が後継として案内 |
| `amazoncorretto:<ver>` | AWS 提供の OpenJDK。AWS 環境との親和性が高い |

学習用途では `eclipse-temurin` が無難。

#### D-3. セキュリティ上の注意点

- 本手順書の認証情報(`root` / `hogehoge` / `root@example.com` 等)は**学習用**。実運用では必ず変更
- `0.0.0.0/0` での全開放は厳禁。特に PostgreSQL(5432)と pgAdmin(80)はインターネットからの直接接続を絶対に許可しない
- root での docker 実行はホスト側のセキュリティリスクが大きい。実運用では一般ユーザー + docker グループ運用が原則
- スワップファイルは `chmod 600` が必須(メモリ内容漏洩防止)
