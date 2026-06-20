# uWSGI / Gunicorn 基本・発展課題集

> Python 系 AP サーバー。Django / Flask アプリケーションのデプロイに必須のミドルウェア  
> Tomcat（Java）との比較視点を随所に盛り込んでいます  
> 前提：AWS 無料利用枠の範囲内で実施可能な課題を基本とする  
> 作成日：2026年6月

---

## 目次

1. [基本課題 A：Python 環境と基本アプリの準備](#基本課題-apython-環境と基本アプリの準備)
2. [基本課題 B：Gunicorn の基本設定と起動](#基本課題-bgunicorn-の基本設定と起動)
3. [基本課題 C：uWSGI の基本設定と起動](#基本課題-cuwsgi-の基本設定と起動)
4. [発展課題 D：Nginx / Apache との連携](#発展課題-dnginx--apache-との連携)
5. [発展課題 E：Django との本格連携](#発展課題-edjango-との本格連携)
6. [発展課題 F：プロセス管理と自動起動](#発展課題-fプロセス管理と自動起動)
7. [発展課題 G：パフォーマンスチューニング](#発展課題-gパフォーマンスチューニング)
8. [発展課題 H：セキュリティと本番設定](#発展課題-hセキュリティと本番設定)
9. [発展課題 I：監視と運用](#発展課題-i監視と運用)
10. [発展課題 J：Gunicorn vs uWSGI 比較と使い分け](#発展課題-jgunicorn-vs-uwsgi-比較と使い分け)

---

## 基本課題 A：Python 環境と基本アプリの準備

**A-1. Python 仮想環境のセットアップ**
- AL2023 の EC2 に Python 3 と `pip` をインストールし、`venv` で仮想環境を作成する
- 仮想環境の有効化・無効化（`source venv/bin/activate` / `deactivate`）を確認し、グローバルと仮想環境の `pip list` の差異を確認する
- `requirements.txt` でパッケージを管理し、`pip install -r requirements.txt` で一括インストールする手順を確立する

**A-2. Flask アプリの作成**
- 最小構成の Flask アプリケーションを作成し、`flask run` での開発サーバー起動との違いを理解する

```python
# app.py
from flask import Flask
app = Flask(__name__)

@app.route("/")
def index():
    return "Hello from Flask!"

@app.route("/health")
def health():
    return "OK", 200
```

**A-3. Django プロジェクトの作成**
- `django-admin startproject myproject` でプロジェクトを作成し、`python manage.py runserver` で開発サーバーを起動する
- `ALLOWED_HOSTS` の設定と開発サーバーと本番サーバーの使い分けの理由を理解する
- `python manage.py migrate` でデータベースマイグレーションを実行し、SQLite から MariaDB / PostgreSQL に切り替える設定を行う

---

## 基本課題 B：Gunicorn の基本設定と起動

**B-1. Gunicorn のインストールと基本起動**
- `pip install gunicorn` でインストールし、Flask アプリを Gunicorn で起動する
- `gunicorn -w 4 -b 0.0.0.0:8000 app:app` でワーカー数・バインドアドレスを指定して起動し、`curl http://localhost:8000/` でレスポンスを確認する
- Flask の開発サーバーと Gunicorn の違い（マルチワーカー・本番対応・WSGI 準拠）をまとめる

**B-2. Gunicorn の設定ファイル**
- `gunicorn.conf.py` で設定をファイル化し、コマンドライン引数なしで起動できるようにする

```python
# gunicorn.conf.py
bind = "0.0.0.0:8000"
workers = 4
worker_class = "sync"
timeout = 30
accesslog = "/var/log/gunicorn/access.log"
errorlog  = "/var/log/gunicorn/error.log"
loglevel  = "info"
```

**B-3. ワーカークラスの違い**
- `sync`（デフォルト）・`gevent`（非同期）・`gthread`（マルチスレッド）の各ワーカークラスの特性を理解し、用途別の選択基準をまとめる
- I/O バウンドなアプリケーション（API 呼び出し多）では `gevent`、CPU バウンド（画像処理多）では `sync` が適切な理由を説明できるようにする

---

## 基本課題 C：uWSGI の基本設定と起動

**C-1. uWSGI のインストールと基本起動**
- `pip install uwsgi` でインストールし、Flask アプリを uWSGI で起動する
- `uwsgi --http 0.0.0.0:8000 --wsgi-file app.py --callable app --processes 4 --threads 2` で起動し、動作を確認する

**C-2. uWSGI の設定ファイル（INI 形式）**
- `uwsgi.ini` で設定をファイル化する

```ini
[uwsgi]
http = 0.0.0.0:8000
wsgi-file = app.py
callable = app
processes = 4
threads = 2
master = true
vacuum = true
die-on-term = true
logto = /var/log/uwsgi/app.log
```

**C-3. Unix ドメインソケット接続**
- `socket = /run/uwsgi/app.sock` で TCP ポートではなく Unix ドメインソケット経由で Nginx と通信する設定に切り替え、パフォーマンスの違いを確認する
- ソケットファイルのパーミッションを Nginx の実行ユーザーに合わせて設定する

---

## 発展課題 D：Nginx / Apache との連携

**D-1. Nginx + Gunicorn 連携**
- Nginx をリバースプロキシとして Gunicorn（ポート 8000）に転送する設定を行う
- `proxy_pass http://127.0.0.1:8000` と `proxy_set_header` の設定を行い、アプリ側で `X-Forwarded-For` からクライアント IP を取得できることを確認する
- Nginx が静的ファイル（`/static/`）を直接配信し、動的リクエストのみ Gunicorn に転送する設定を実装する

```nginx
server {
    listen 80;
    server_name example.com;

    location /static/ {
        alias /var/www/myapp/static/;
    }

    location / {
        proxy_pass http://127.0.0.1:8000;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    }
}
```

**D-2. Nginx + uWSGI 連携（uwsgi プロトコル）**
- `uwsgi_pass` と `include uwsgi_params` を使い、Nginx と uWSGI を uwsgi プロトコル（HTTP より高効率）で接続する
- HTTP 経由接続と uwsgi プロトコル接続のレスポンスタイムを `ab` で比較する

**D-3. Apache + mod_wsgi との比較**
- Apache の `mod_wsgi` を使った Python アプリ接続と、Nginx + Gunicorn / uWSGI の構成を比較し、現場での採用率と選定理由をまとめる

---

## 発展課題 E：Django との本格連携

**E-1. Django + Gunicorn + Nginx の本番構成**
- Django プロジェクトを Gunicorn で起動し、Nginx をフロントエンドに配置する本番構成を構築する
- `DEBUG = False` に設定し、`ALLOWED_HOSTS` を正しく設定した上で Django の静的ファイルを `python manage.py collectstatic` で収集し、Nginx から直接配信する設定を行う
- `STATIC_ROOT`・`MEDIA_ROOT` の設定と、Nginx の `alias` ディレクティブでの配信を実装する

**E-2. Django + PostgreSQL 連携**
- Django の `settings.py` を PostgreSQL に向け、`psycopg2` ドライバーでの接続を設定する
- `python manage.py migrate` でテーブルを自動生成し、Django 管理画面（`/admin`）が動作することを確認する
- データベース接続プーリングを `django-db-geventpool` または `psycopg2` の接続プール設定で実装する

**E-3. 環境変数による設定の外部化**
- `python-decouple` または `django-environ` を使い、`SECRET_KEY`・DB パスワード・`DEBUG` フラグを `.env` ファイルまたは AWS Secrets Manager から取得する設定を実装する

---

## 発展課題 F：プロセス管理と自動起動

**F-1. systemd による自動起動**
- Gunicorn / uWSGI を systemd サービスとして登録し、EC2 再起動後に自動起動されることを確認する

```ini
# /etc/systemd/system/gunicorn.service
[Unit]
Description=Gunicorn daemon for Django
After=network.target

[Service]
User=ec2-user
Group=ec2-user
WorkingDirectory=/var/www/myapp
ExecStart=/var/www/myapp/venv/bin/gunicorn \
          --config /var/www/myapp/gunicorn.conf.py \
          myproject.wsgi:application
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
```

**F-2. プロセス監視と自動再起動**
- Gunicorn のワーカーがクラッシュした場合に `Restart=always` で自動再起動されることを確認する
- uWSGI の `master = true` と `harakiri` タイムアウト設定でハングアップしたワーカーを自動強制終了する設定を行う

---

## 発展課題 G：パフォーマンスチューニング

**G-1. ワーカー数の最適化**
- Gunicorn の推奨ワーカー数（`2 × CPU コア数 + 1`）を t2.micro（1 コア）で計算し、3 ワーカーで設定する
- `ab` で同時接続数を変えながら負荷テストを実施し、ワーカー数を 1・2・4 に変えてスループットの変化を計測する

**G-2. タイムアウトと keepalive の設定**
- `--timeout` を設定し、長時間かかるリクエストがワーカーを占有しないようにする
- `--keep-alive` で HTTP Keep-Alive の接続維持時間を設定し、Nginx との組み合わせで効果を確認する

**G-3. 非同期ワーカーの導入**
- `gevent` をインストールして非同期ワーカーに切り替え、外部 API 呼び出しを多用するアプリケーションでの同時接続処理能力を sync ワーカーと比較する

---

## 発展課題 H：セキュリティと本番設定

**H-1. Django のセキュリティ設定**
- 以下の Django セキュリティ設定をすべて有効化し、`python manage.py check --deploy` でチェックを通過させる
  - `SECURE_SSL_REDIRECT = True`
  - `SESSION_COOKIE_SECURE = True`
  - `CSRF_COOKIE_SECURE = True`
  - `SECURE_HSTS_SECONDS = 31536000`
  - `X_FRAME_OPTIONS = "DENY"`

**H-2. CSRF と XSS 対策の確認**
- Django の CSRF 保護が有効になっていることを確認し、CSRF トークンなしの POST リクエストが 403 で拒否されることを確認する
- Django の `SECURE_CONTENT_TYPE_NOSNIFF`・`SECURE_BROWSER_XSS_FILTER` を有効化する

---

## 発展課題 I：監視と運用

**I-1. アクセスログとエラーログの管理**
- Gunicorn / uWSGI のアクセスログを CloudWatch Logs に転送し、5xx エラーが増加した場合のアラームを設定する
- Django のエラーログ（`logging` 設定）を構造化 JSON 形式で出力し、CloudWatch Logs Insights で分析する

**I-2. ヘルスチェックエンドポイントの実装**
- `/health` エンドポイントで DB 接続・キャッシュ接続の死活を確認し、異常時に 503 を返す実装を行う
- ALB のヘルスチェックターゲットとして `/health` を設定し、Gunicorn プロセス障害時に自動でターゲットグループから除外されることを確認する

**I-3. Zabbix / CloudWatch による監視**
- Gunicorn のワーカープロセス数を Zabbix でリアルタイム監視し、プロセス数が期待値を下回った場合にアラートを発火させる
- CloudWatch カスタムメトリクスで Django のレスポンスタイムを収集するミドルウェアを実装する

---

## 発展課題 J：Gunicorn vs uWSGI 比較と使い分け

**J-1. 比較表の作成**

| 観点 | Gunicorn | uWSGI |
|------|---------|-------|
| セットアップの容易さ | 高（シンプル） | 中（設定項目が多い） |
| 設定ファイル形式 | Python / コマンドライン | INI / XML / JSON |
| ワーカーの種類 | sync / gevent / gthread | prefork / threaded / async |
| Nginx との接続 | HTTP プロキシ | uwsgi プロトコル（より高効率） |
| WebSocket 対応 | gevent 使用で対応 | ネイティブ対応 |
| メモリ使用量 | 少 | 中 |
| 現場採用率 | 高（シンプルさで人気） | 高（機能の豊富さで人気） |

**J-2. Tomcat との役割比較**
- Java アプリケーションの Tomcat と Python アプリケーションの Gunicorn / uWSGI を比較し、「言語ランタイムと AP サーバーの関係」という観点で整理する

---

*以上（uWSGI / Gunicorn 基本・発展課題）*
