# Chrony / NTP 基本・発展課題集

> サーバー間の時刻同期。ログ分析・レプリケーション・認証の前提となる基盤技術  
> 前提：AWS 無料利用枠の範囲内で実施可能な課題を基本とする  
> 作成日：2026年6月

---

## 目次

1. [基本課題 A：時刻同期の重要性の理解](#基本課題-a時刻同期の重要性の理解)
2. [基本課題 B：Chrony のインストールと設定](#基本課題-bchrony-のインストールと設定)
3. [基本課題 C：NTP サーバーの設定](#基本課題-cntp-サーバーの設定)
4. [発展課題 D：内部 NTP サーバーの構築](#発展課題-d内部-ntp-サーバーの構築)
5. [発展課題 E：時刻同期の監視](#発展課題-e時刻同期の監視)
6. [発展課題 F：AWS 環境での時刻同期設計](#発展課題-faws-環境での時刻同期設計)
7. [発展課題 G：NTP vs Chrony の比較](#発展課題-gntp-vs-chrony-の比較)

---

## 基本課題 A：時刻同期の重要性の理解

**A-1. 時刻ズレが引き起こす問題の整理**
- 以下のシナリオで時刻がズレた場合の影響をまとめる

| 技術 | 時刻ズレの影響 |
|------|--------------|
| ログ分析 | 複数サーバーのログを時系列で突き合わせられない |
| MariaDB レプリケーション | バイナリログのタイムスタンプがズレて整合性確認が困難 |
| SSL/TLS 証明書 | 証明書の有効期限チェックが誤動作 |
| AWS Signature V4 | 署名の時刻が 5 分以上ズレると API 呼び出しが拒否される |
| Kerberos 認証 | デフォルトで 5 分以上のズレで認証失敗 |
| DKIM 署名 | タイムスタンプの検証失敗 |

**A-2. NTP の動作原理**
- NTP（Network Time Protocol）のストラタム（Stratum）の概念を理解する
  - Stratum 0：原子時計・GPS クロック（直接の時刻源）
  - Stratum 1：Stratum 0 に直接接続したサーバー
  - Stratum 2：Stratum 1 と同期するサーバー（一般的な NTP サーバー）
  - Stratum 3 以降：内部 NTP サーバー等

---

## 基本課題 B：Chrony のインストールと設定

**B-1. Chrony の確認とインストール**
- AL2023 では Chrony がデフォルトでインストール・起動されていることを確認する
- `chronyc tracking` で現在の時刻同期状態（同期先・オフセット・精度）を確認する

```
$ chronyc tracking
Reference ID    : D1B83CCA (169.254.169.123)      # AWS Time Sync Service
Stratum         : 4
Ref time (UTC)  : Mon Jun 17 10:00:00 2026
System time     : 0.000001234 seconds slow of NTP time
Last offset     : -0.000001234 seconds
RMS offset      : 0.000005678 seconds
Frequency       : 1.234 ppm slow
Residual freq   : -0.001 ppm
Skew            : 0.012 ppm
Root delay      : 0.001234567 seconds
Root dispersion : 0.000456789 seconds
```

**B-2. chrony.conf の設定**
- `/etc/chrony.conf` で AWS Time Sync Service（`169.254.169.123`）を同期先として設定する

```
# AWS Time Sync Service（EC2 環境での推奨設定）
server 169.254.169.123 prefer iburst

# 許容するオフセットの設定
makestep 1.0 3

# ハードウェアタイムスタンプの有効化（対応環境のみ）
# hwtimestamp eth0
```

**B-3. 基本的な chronyc コマンドの習得**
- `chronyc sources -v`：現在の同期先サーバーと状態を確認
- `chronyc sourcestats`：各同期先のオフセット・ジッターを確認
- `chronyc makestep`：手動で即時時刻修正を行う
- `timedatectl status`：システムの時刻・タイムゾーン・NTP 同期状態を確認

---

## 基本課題 C：NTP サーバーの設定

**C-1. タイムゾーンの設定**
- `timedatectl set-timezone Asia/Tokyo` でタイムゾーンを設定し、`date` コマンドで JST が表示されることを確認する
- `/etc/localtime` のシンボリックリンクを確認し、タイムゾーンの設定ファイルの場所を理解する

**C-2. RTC（ハードウェアクロック）との関係**
- `hwclock --show` でハードウェアクロックの時刻を確認し、システムクロックとの差異を確認する
- `timedatectl set-local-rtc 0`（UTC）と `set-local-rtc 1`（ローカルタイム）の違いを理解する

---

## 発展課題 D：内部 NTP サーバーの構築

**D-1. 内部 NTP サーバーの設定**
- プライベートサブネットの EC2 には外部インターネットへのアクセスがない場合を想定し、NTP サーバーを兼ねる EC2（パブリックサブネット）を 1 台設置する
- NTP サーバー EC2 は AWS Time Sync Service（`169.254.169.123`）と同期し、内部 EC2 はこの NTP サーバーと同期する階層構造を構築する

```
# NTP サーバー EC2 の chrony.conf
server 169.254.169.123 prefer iburst
allow 10.0.0.0/16    # VPC CIDR からのクライアント接続を許可

# クライアント EC2 の chrony.conf
server 10.0.1.100 iburst    # 内部 NTP サーバーの IP
```

**D-2. クライアント EC2 の同期確認**
- プライベートサブネットの各 EC2 で `chronyc tracking` を実行し、内部 NTP サーバーと正常に同期していることを確認する
- `chronyc sources -v` で同期先が内部 NTP サーバーの IP になっていることを確認する

**D-3. Security Group の設定**
- NTP サーバー EC2 の Security Group で UDP 123 番ポートを VPC CIDR からのみ許可する設定を行う

---

## 発展課題 E：時刻同期の監視

**E-1. オフセットの監視**
- `chronyc tracking` の出力から `System time offset` を定期的に収集し、CloudWatch カスタムメトリクスに送信するスクリプトを作成する
- オフセットが 100ms を超えた場合に SNS でアラートを送る CloudWatch アラームを設定する

**E-2. Zabbix による NTP 監視**
- Zabbix のユーザーパラメーターで Chrony の同期状態を取得し、以下のトリガーを設定する
  - NTP 同期が切れた場合（`chronyc tracking` の `Leap status` が `Not synchronised`）
  - オフセットが閾値（例：50ms）を超えた場合

**E-3. ログへの時刻精度の影響検証**
- 2 台の EC2 で意図的に片方の時刻を数秒ズラし、Apache アクセスログのタイムスタンプが異なることを確認する
- 時刻同期後に同じリクエストのログが時系列で正しく並ぶことを確認する

---

## 発展課題 F：AWS 環境での時刻同期設計

**F-1. AWS Time Sync Service の理解**
- AWS Time Sync Service（`169.254.169.123`）の特徴をまとめる
  - VPC 内のリンクローカルアドレスでアクセス可能（インターネット不要）
  - 非常に低いレイテンシと高精度
  - 追加料金なし
  - すべての EC2 インスタンスから利用可能

**F-2. 既存ミドルウェアとの時刻同期の関係**
- 以下の既習ミドルウェアが時刻同期に依存している理由をまとめる
  - MariaDB レプリケーション：バイナリログのタイムスタンプ
  - Postfix / Dovecot：メールヘッダーの `Date:` フィールド・DKIM 署名のタイムスタンプ
  - SSL/TLS 証明書の検証：有効期限チェック
  - Zabbix：トリガーの発火時刻・グラフのタイムライン
  - AWS API（Ansible / Terraform / AWS CLI）：Signature V4 の時刻検証

---

## 発展課題 G：NTP vs Chrony の比較

**G-1. 比較表の作成**

| 観点 | ntpd（ntp パッケージ） | Chrony |
|------|---------------------|--------|
| 時刻収束速度 | 遅い | 速い（特にネットワーク不安定時） |
| 間欠的な接続への対応 | 苦手 | 得意（ラップトップ・クラウド向け） |
| 大きなオフセットの修正 | 段階的（ステップ不可の設定も） | 柔軟（makestep 設定） |
| メモリ使用量 | 多 | 少 |
| AL2023 のデフォルト | なし | ○（デフォルト採用） |
| 推奨環境 | 常時接続の安定した環境 | クラウド・VM・ラップトップ |

---

*以上（Chrony / NTP 基本・発展課題）*
