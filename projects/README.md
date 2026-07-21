# projects

複数の技術を組み合わせて構築した**成果物単位**の記録を置くディレクトリです。
単一ミドルウェアの手順は [`../topics/`](../topics/) 側に、ここでは「Web / AP / DB / DNS / SMTP / NFS など、複数の層を一つの環境として組み上げた」ものを集約しています。

各プロジェクトは、構築手順だけでなく **設計時に考えたこと・ハマりどころ・解決過程** をセットで残すことを意識して書いています。

---

## 収録プロジェクト

| プロジェクト | 概要 |
|------|------|
| [`team-exercise/`](team-exercise/) | Web / AP / DB / DNS / SMTP / NFS / NTP / cron を統合したチーム総合演習 |
| [`nginx-tomcat-pg-nfs-redundancy/`](nginx-tomcat-pg-nfs-redundancy/) | Nginx + Tomcat + PostgreSQL + NFS による5台 Web-AP 冗長構成 |
| [`smtp-2-tier-dns-view/`](smtp-2-tier-dns-view/) | DNSサーバ(兼NFS)1台 + 受信SMTPサーバ1台 + 配送SMTPサーバ3台の合計5台構成 |
| [`terraform-aws-handson/`](terraform-aws-handson/) | Terraform で VPC / EC2 / SG / ALB / NAT Gateway を module 化した汎用 AWS 基盤構築 |
| [`haproxy-caddy-flask-mysql-replication/`](haproxy-caddy-flask-mysql-replication/) | HAProxy + Caddy + Gunicorn/Flask + MySQL レプリケーションによる高可用Webシステム |
| [`tengine-nodejs-postgresql-redis/`](tengine-nodejs-postgresql-redis/) | Tengine + Node.js/pm2 + PostgreSQL + Redis によるNode.js本番風配信基盤 |
| [`lighttpd-uwsgi-opensearch-minio/`](lighttpd-uwsgi-opensearch-minio/) | Lighttpd + uWSGI/Flask + OpenSearch + MinIO による全文検索ドキュメント基盤 |
| [`monitoring-prometheus-grafana-loki-nagios/`](monitoring-prometheus-grafana-loki-nagios/) | Prometheus + Grafana + Loki + Fluent Bit + Nagios による監視スタック総合演習 |
| [`rabbitmq-async-job-system/`](rabbitmq-async-job-system/) | RabbitMQ + Gunicorn + PostgreSQL + Prometheus による非同期ジョブ基盤 |
| [`keycloak-openldap-freeradius-nginx/`](keycloak-openldap-freeradius-nginx/) | Keycloak + OpenLDAP + FreeRADIUS + Nginx による認証統合基盤 |
| [`vpn-waf-ids/`](vpn-waf-ids/) | VPN + WAF + IDS による多層防御(Defense in Depth)実験環境 |
| [`samba-vsftpd-rsyncd-chrony/`](samba-vsftpd-rsyncd-chrony/) | Samba + vsftpd + rsyncd + Chrony によるファイルサーバ+バックアップ基盤 |
| [`influxdb-grafana-telegraf-fastapi/`](influxdb-grafana-telegraf-fastapi/) | InfluxDB + Grafana + Telegraf + FastAPI/Gunicorn による時系列データ基盤 |
| [`powerdns-dnsmasq-varnish-nginx/`](powerdns-dnsmasq-varnish-nginx/) | PowerDNS + dnsmasq + Varnish + Nginx によるDNS再構築+配信高速化 |

---

## team-exercise

→ [`team-exercise/`](team-exercise/)

### 構成概要

Web / AP / DB / DNS / SMTP / NFS / NTP など、これまで学んだ技術を統合した総合構築をチームで実施した記録。

---

## nginx-tomcat-pg-nfs-redundancy

→ [`nginx-tomcat-pg-nfs-redundancy/`](nginx-tomcat-pg-nfs-redundancy/)

### 構成概要

Web-AP 層を冗長化した5台構成。Nginx ロードバランサ配下に AP サーバを複数台配置し、NFS でファイル共有、PostgreSQL で永続化する構成。
1台 → 3台 → 3台 + NFS → 5台冗長化、と段階的に積み上げた集大成。

---

## smtp-2-tier-dns-view

→ [`smtp-2-tier-dns-view/`](smtp-2-tier-dns-view/)

### 構成概要

DNSサーバ(兼NFS)1台 + 受信SMTPサーバ1台 + 配送SMTPサーバ3台の合計5台構成。DNS view機能 によって、内部(VPC内)と外部(VPC外)で異なるレコードを返し、SMTPサーバを「受信用」と「配送用」の2層に分離し、責務を明確にする構成。

---

## terraform-aws-handson

→ [`terraform-aws-handson/`](terraform-aws-handson/)

### 構成概要

VPC / EC2 / Security Group / ALB / NAT Gateway を module 化し、`terraform.tfvars` の変数だけで台数・サブネット種別・ALB / NAT の有無を切替できる汎用 AWS 基盤。MW 検証用途を想定しており、EC2 は素の Amazon Linux 2023 として起動する。Terraform の基本ワークフロー(init → plan → apply → destroy)を一連の手順で習得した記録。

---

## haproxy-caddy-flask-mysql-replication

→ [`haproxy-caddy-flask-mysql-replication/`](haproxy-caddy-flask-mysql-replication/)

### 構成概要

HAProxy 1台 + Caddy/Gunicorn/Flask 2台 + MySQL マスタ/スレーブ 2台の合計5台構成。HAProxy によるL7ロードバランシング、MySQL レプリケーションによる読み書き分離を実装した高可用Webシステム。

---

## tengine-nodejs-postgresql-redis

→ [`tengine-nodejs-postgresql-redis/`](tengine-nodejs-postgresql-redis/)

### 構成概要

Tengine 1台 + Node.js/pm2 AP サーバ複数台 + PostgreSQL + Redis の4台構成。Tengine の標準モジュールによるヘルスチェック、pm2 クラスタモードによるプロセス管理を学ぶ本番風配信基盤。

---

## lighttpd-uwsgi-opensearch-minio

→ [`lighttpd-uwsgi-opensearch-minio/`](lighttpd-uwsgi-opensearch-minio/)

### 構成概要

Lighttpd + uWSGI/Flask + OpenSearch + MinIO による全文検索ドキュメント基盤。テキストファイルを MinIO に保存しながら OpenSearch にインデックスを登録し、全文検索で取得できる構成。

---

## monitoring-prometheus-grafana-loki-nagios

→ [`monitoring-prometheus-grafana-loki-nagios/`](monitoring-prometheus-grafana-loki-nagios/)

### 構成概要

監視基盤2台 + 監視対象2台の合計4台構成。Prometheus + Grafana + Loki + Fluent Bit による現代的な監視スタックと、Nagios による死活監視を組み合わせた監視環境。

---

## rabbitmq-async-job-system

→ [`rabbitmq-async-job-system/`](rabbitmq-async-job-system/)

### 構成概要

API + RabbitMQ(MQ) + Worker + PostgreSQL + Prometheus の4層構成による非同期ジョブ処理基盤。メッセージキューを介した非同期処理の仕組みをAWS上に手動構築。

---

## keycloak-openldap-freeradius-nginx

→ [`keycloak-openldap-freeradius-nginx/`](keycloak-openldap-freeradius-nginx/)

### 構成概要

Keycloak + OpenLDAP + FreeRADIUS + Nginx による認証統合基盤。LDAP でユーザー管理、Keycloak で OIDC/SSO、FreeRADIUS で RADIUS 認証、Nginx + oauth2-proxy でリバースプロキシ認証を実装。

---

## vpn-waf-ids

→ [`vpn-waf-ids/`](vpn-waf-ids/)

### 構成概要

VPN・WAF・侵入検知(IDS)を組み合わせた多層防御(Defense in Depth)実験環境。4台のサーバが連携してネットワーク境界から内部まで複数の防御層を形成する構成。

---

## samba-vsftpd-rsyncd-chrony

→ [`samba-vsftpd-rsyncd-chrony/`](samba-vsftpd-rsyncd-chrony/)

### 構成概要

EC2 4台構成によるファイルサーバ+バックアップ基盤。Samba による Windows 共有、vsftpd による FTP、rsyncd による差分バックアップ、Chrony による NTP 時刻同期を組み合わせた実用的なファイル管理環境。

---

## influxdb-grafana-telegraf-fastapi

→ [`influxdb-grafana-telegraf-fastapi/`](influxdb-grafana-telegraf-fastapi/)

### 構成概要

InfluxDB + Grafana + Telegraf + FastAPI/Gunicorn による時系列データ基盤。Telegraf でメトリクスを収集し InfluxDB に蓄積、Grafana で可視化、FastAPI でデータ投入 API を提供する構成。

---

## powerdns-dnsmasq-varnish-nginx

→ [`powerdns-dnsmasq-varnish-nginx/`](powerdns-dnsmasq-varnish-nginx/)

### 構成概要

PowerDNS + dnsmasq + Varnish + Nginx によるDNS再構築と配信高速化の構成。権威DNS(PowerDNS)・キャッシュDNS(dnsmasq)・HTTPキャッシュ(Varnish)・リバースプロキシ(Nginx)を組み合わせた多層キャッシュアーキテクチャ。

---

## 補足

各プロジェクトの詳細(コマンド・設定ファイル・完了基準など)は、各サブディレクトリの `README.md` を参照してください。
このディレクトリの README は、プロジェクト全体の見取り図を残すことを目的にしています。
