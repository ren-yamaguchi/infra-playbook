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
| [`terraform-aws-handson/`](terraform-aws-handson/) | EC2 や security group を module とすることで柔軟な構築が可能な構成 |

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

台数 / サブネット種別(public/private) / ALB / NAT を**変数や module 呼び出し有無で柔軟に切替**できる汎用コードを書けるようになる。Terraform の基本ワークフロー(init → plan → apply → destroy)を理解する。

---

## 補足

各プロジェクトの詳細(コマンド・設定ファイル・完了基準など)は、各サブディレクトリの `README.md` を参照してください。
このディレクトリの README は、プロジェクト全体の見取り図を残すことを目的にしています。
