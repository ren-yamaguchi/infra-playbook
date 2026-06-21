# infra-playbook

クラウド/インフラ領域の学習記録・構築手順・ナレッジを集約したリポジトリです。
ハンズオンで手を動かした内容を、再現可能な形で残すことを目的としています。

---

## このリポジトリについて

研修課題や自己学習で取り組んだ内容を、**成果物単位(`projects/`)** と **技術カテゴリ単位(`topics/`)** の2つの軸で整理しています。
現状の構築記録は AWS を前提としており、EC2 / VPC / ALB / Route53 等を基盤に各ミドルウェア・多段構成・冗長化を検証しています。今後、Azure・GCP など他クラウドでの構築記録も並行して追加していく予定です。

単なる作業ログではなく、**「半年後の自分が読んで再現できる」** ことを基準に、以下を意識して記録しています。

- 構築手順は **冪等性・ロールバック手順・完了基準** まで含めて記述
- 詰まったポイントと原因・対処を **トラブルシュート** として明示
- 公式ドキュメントへのリンクと、自分の言葉での要約をセットで残す

---

## スキルマップ

| カテゴリ | 技術 |
|---------|------|
| クラウド | AWS (EC2, VPC, ALB, Route53, EBS, Security Group) |
| OS | Amazon Linux 2023, Ubuntu, RHEL 系 |
| Web / AP | Apache, Nginx, Tomcat, PHP-FPM |
| DB | MariaDB, PostgreSQL (JDBC / JNDI 設定含む) |
| ネットワーク | BIND, NSD (Primary / Secondary Zone) |
| ストレージ | NFS |
| メール | Postfix, Dovecot |
| 監視 | Zabbix 7.0 |
| IaC / 自動化 | Ansible (Playbook / Role / Inventory), Docker / Docker Compose |
| Linux | 権限設計 (SUID / SGID / Sticky), systemd, シェルスクリプト, cron |
| 学習中 | AWS IAM, Terraform, Linux ネットワーク (L2 / L3 シミュレーション) |

詳細は [`docs/skills.md`](docs/skills.md) を参照。

---

## ハンズオン実績(ハイライト)

複数技術を組み合わせて構築した代表的な手順書をピックアップしています。

### 総合演習(チーム構築)
→ [`projects/final-exercise/`](projects/final-exercise/)

Web / AP / DB / DNS / SMTP / NFS / NTP など、これまで学んだ技術を統合した総合構築をチームで実施。チーム内でメンバーの技術サポートを行いつつ、期限内の完成に向けて全体の方向性を揃える役割を担当。

### Nginx + Tomcat + PostgreSQL + NFS 5台 Web-AP 冗長構成
→ [`projects/nginx-tomcat-pg-nfs-redundancy/`](projects/nginx-tomcat-pg-nfs-redundancy/)

Web-AP 層を冗長化した5台構成。Nginx ロードバランサ配下に AP サーバを複数台配置し、NFS でファイル共有、PostgreSQL で永続化する構成。1台→3台→3台+NFS→5台冗長化、と段階的に積み上げた集大成。

### Apache + PHP + MariaDB の LAMP 多段構成
→ [`topics/web-ap/lamp/`](topics/web-ap/lamp/)

1台構成から3台多段構成までを段階的に構築。Apache と PHP-FPM の連携、MariaDB との接続、サーバ間通信の設計を含む。

### Nginx + Tomcat + PostgreSQL の LNTP 多段構成
→ [`topics/web-ap/lntp/`](topics/web-ap/lntp/)

Knowledge アプリの実行基盤として、1台→3台→3台+NFS と段階的に構築。JNDI 設定、NFS の `root_squash` による削除エラー、JDBC ドライバの `scram-sha-256` 非対応など、複数の層にまたがる問題を切り分けて解決。

### Postfix + Dovecot + BIND + NFS 4台基本構成
→ [`topics/storage/nfs/postfix-dovecot-bind-nfs-4server.md`](topics/storage/nfs/postfix-dovecot-bind-nfs-4server.md)

メールサーバ・DNS サーバ・NFS サーバを組み合わせた4台構成。SMTP / IMAP / DNS / ファイル共有を統合した実用的な構築記録。

### Ansible による Zabbix + PostgreSQL 自動構築
→ [`topics/iac/ansible/zabbix/ansible-zabbix-pg.md`](topics/iac/ansible/zabbix/ansible-zabbix-pg.md)

手動構築していた Zabbix 監視基盤を Ansible で自動化。Playbook / Role / Inventory による構成管理の実践。

### Let's Encrypt による HTTPS 化
→ [`topics/network/https-letsencrypt/procedure.md`](topics/network/https-letsencrypt/procedure.md)

Certbot を用いた SSL/TLS 証明書の発行設定。Nginx と BIND の連携による証明書取得まで。

---

## ディレクトリ構成

```
.
├── projects/        # 成果物単位(複数技術を組み合わせた構築記録)
├── topics/          # 技術カテゴリ単位(単元別の手順・ナレッジ)
├── multi-cloud/     # AWS 以外のクラウドでの構築記録(今後追加)
└── docs/            # 年表・スキルマップ・調査メモなどメタ情報
```

各ディレクトリには `README.md` を配置し、そのディレクトリの目的・前提・参照順序などを記載しています。

---

## 学習の時系列

学んだ順序・各時期の取り組みは [`docs/timeline.md`](docs/timeline.md) にまとめています。

ざっくりした流れ:

1. **Linux 基礎・AWS 基礎** (VPC / EC2 / EBS)
2. **単体ミドルウェア** (Apache → Tomcat → PHP-FPM → MariaDB → PostgreSQL)
3. **多段構成** (Web / AP / DB 3 層 → 4 層 + DNS)
4. **付帯サービス** (BIND / NSD, Postfix / Dovecot, NFS)
5. **冗長化・監視** (ALB, Zabbix)
6. **自動化** (Ansible, Docker / Compose)
7. **発展領域**(Terraform, Linux ネットワーク、他クラウド)

---

## 今後追加予定

| 領域 | 内容 |
|------|------|
| 他クラウド | Azure / GCP での基本構成・AWS との対応関係 |
| ネットワーク | L2 スイッチシミュレーション(Docker + Linux Bridge)、L3、ファイアウォール |
| IaC | Terraform による AWS リソース管理 |

---

## 主な検証環境

| 環境 | 用途 |
|------|------|
| AWS (EC2 / VPC / ALB / Route53 等) | クラウド上での多段構成・冗長化検証(メイン) |
| Azure / GCP | 他クラウドでの構築検証(今後) |
| WSL (Ubuntu on Windows) | ローカルでの Linux / ネットワーク検証 |
| Docker / Docker Compose | コンテナ・ネットワーク機能のシミュレーション |

---

## 記録の方針

- **再現性**: コマンド・設定ファイルは省略せず記載
- **背景の明示**: なぜその構成・パラメータを選んだかを残す
- **失敗の記録**: ハマったポイントと解決過程を消さずに残す
- **段階的な積み上げ**: 単一構成 → 多段構成 → 冗長化 → 自動化 の順で章立て

---

## 補足

- 本リポジトリは個人の学習目的で作成しています。
- 記載内容は学習時点のバージョン・仕様に基づいています。
