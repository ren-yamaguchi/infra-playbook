# chronyを用いた内部NTPサーバー構築

------------------------------

## 1. ドキュメント情報

| 項目 | 内容 |
|------|------|
| 手順書名 | chronyを用いた内部NTPサーバー構築 |
| 作成日 | 2026-06-01 |
| 最終更新日 | 2026-06-18 |
| バージョン | v1.3 |
| 対象環境 | AWS（Amazon Linux 2023） |

> **改訂履歴**
>
> | バージョン | 日付 | 変更内容 |
> |-----------|------|---------|
> | v1.0 | 2026-06-01 | 初版作成． |
> | v1.1 | 2026-06-01 | 実機確認に基づき手順を修正．port 123の追記・ntpdateの削除・クライアント設定を修正． |
> | v1.2 | 2026-06-03 | 構成図をもとに全体を修正．NTPサーバー・クライアント対象の明記・プレースホルダー化・firewalld確認追加・enable順序修正・同期待ち補足追加・確認作業の進め方追加・証跡保存先明記． |
> | v1.3 | 2026-06-18 | テンプレートに沿って再構成．7章+ロールバック+付録A〜Dの構成に変更．句読点を「，．」に統一．`systemctl enable --now` に統一．各Stepに【実施対象】明示．構成図にAZ配置・クライアント5台を明示．付録A〜D追加． |

------------------------------

## 2. 目的・概要

### 2-1. 目的

> 本手順書では，AWSのPrivate subnet上のEC2（`<NTPサーバーのFQDN>`）にchronyを用いた内部NTPサーバーを構築し，VPC内の対象EC2（クライアント5台）が同サーバーを時刻同期元として使用できる状態にする手順について説明する．
> 時刻同期が取れていない場合，以下の問題が発生するため本作業を実施する．
>
> - アプリケーションログの時刻がずれ，障害調査が困難になる
> - TLS証明書の検証エラーが発生する可能性がある
> - PostgreSQL等のDBで時刻依存処理が誤動作する可能性がある

### 2-2. 構成概要（アーキテクチャ）

```
                          [AWS NTPサーバー]
                         (169.254.169.123)
                                ▲
                                │ UDP 123
                                │
┌────────────────── VPC ────────┼───────────────────────────┐
│                               │                           │
│                    [EC2: NTPサーバー]                      │
│                    AZ3 / Private subnet                   │
│                    <NTPサーバーのFQDN>                     │
│                    chronyd (UDP/123)                      │
│                    stratum 10 (上位切断時)                 │
│                                ▲                          │
│                                │ UDP 123                  │
│        ┌───────────────────────┼───────────────────────┐  │
│        │           │           │           │           │  │
│      [Web]       [DNS]      [AP1]        [AP2]  [MONITOR] │
│    AZ1 Pub      AZ2 Pub   AZ3 Priv     AZ4 Priv  AZ4 Priv │
│                       NTPクライアント × 5台                │
│                                                           │
└───────────────────────────────────────────────────────────┘
```

**対象サーバー一覧**

| サーバー名（例） | AZ | サブネット | NTPにおける役割 |
|-----------|-----|----------|--------------|
| `<NTPサーバーのFQDN>`（例：db.wp.local） | AZ3 | Private subnet | NTPサーバー |
| `<Webサーバーのホスト名>`（例：web.wp.local） | AZ1 | Public subnet | NTPクライアント |
| `<DNSサーバーのホスト名>`（例：dns.wp.local） | AZ2 | Public subnet | NTPクライアント |
| `<AP1サーバーのホスト名>`（例：ap1.wp.local） | AZ3 | Private subnet | NTPクライアント |
| `<AP2サーバーのホスト名>`（例：ap2.wp.local） | AZ4 | Private subnet | NTPクライアント |
| `<Zabbixサーバーのホスト名>`（例：MONITOR） | AZ4 | Private subnet | NTPクライアント |
| `<踏み台サーバーのホスト名>`（例：STEP） | AZ2 | Public subnet | 対象外 |

### 2-3. 完成イメージ（ゴール定義）

- [ ] NTPサーバーで`chronyd` が`active (running)`かつ自動起動有効である
- [ ] NTPサーバーで `169.254.169.123`（AWS NTPサーバー）と同期している
- [ ] NTPサーバーで `ss -ulnp | grep chronyd` にて `0.0.0.0:123` でLISTENしている
- [ ] NTPサーバーで `chronyc sources -v` の `169.254.169.123` 行頭に `*` マークが表示される
- [ ] クライアントEC2（5台）で `chronyc sources -v` にNTPサーバーのIPが表示される
- [ ] NTPサーバーで `chronyc clients` にてクライアントEC2（5台）からの接続が確認できる

------------------------------

## 3. 前提条件・準備

### 3-1. 環境要件

| 項目 | 要件 |
|------|------|
| OS | Amazon Linux 2023 |
| NTPサービス | chrony |
| 実行ユーザー | ec2-user（sudo権限あり） |

### 3-2. セキュリティグループ設定（事前確認）

NTPサーバーEC2に以下のSGルールが設定済みであることをAWSコンソールで確認すること．

#### 3-2-1. NTPサーバー（`<NTPサーバーのFQDN>`）のSG

| 方向 | タイプ | プロトコル | ポート | ソース／送信先 |
|------|-------|-----------|-------|-------|
| インバウンド | カスタムUDP | UDP | 123 | `<VPC CIDR>` |
| インバウンド | SSH | TCP | 22 | マイIP（踏み台経由） |
| アウトバウンド | カスタムUDP | UDP | 123 | 0.0.0.0/0 |
| アウトバウンド | HTTPS | TCP | 443 | 0.0.0.0/0 |

#### 3-2-2. NTPクライアントEC2（5台）のSG

| 方向 | タイプ | プロトコル | ポート | 送信先 |
|------|-------|-----------|-------|-------|
| アウトバウンド | カスタムUDP | UDP | 123 | NTPサーバーEC2のSG |

### 3-3. パラメータ定義表

> **注意：** 以下の値は作業前にAWSコンソールで確認し，記入してから作業を開始すること．

#### 共通

| パラメータ名 | 値 | 説明 |
|------------|---|------|
| `<NTPサーバーのプライベートIP>` | `<記入する>` | NTPサーバーのプライベートIP（AWSコンソールで確認） |
| `<NTPサーバーのFQDN>` | `<記入する>` | NTPサーバーのFQDN（例：`db.wp.local`） |
| `<VPC CIDR>` | `<記入する>` | VPC全体のCIDR範囲（例：`172.31.0.0/16`） |
| `<AWS NTPサーバーIP>` | `169.254.169.123` | AWS固定値．変更不要． |
| `<証跡保存先パス>` | `<記入する>` | 証跡ログの最終保存先（例：S3パス，共有ディレクトリ） |

#### クライアントEC2（5台分）

| パラメータ名 | 値 | 説明 |
|------------|---|------|
| `<WebサーバーのプライベートIP>` | `<記入する>` | クライアント①（Web） |
| `<DNSサーバーのプライベートIP>` | `<記入する>` | クライアント②（DNS） |
| `<AP1サーバーのプライベートIP>` | `<記入する>` | クライアント③（AP1） |
| `<AP2サーバーのプライベートIP>` | `<記入する>` | クライアント④（AP2） |
| `<ZabbixサーバーのプライベートIP>` | `<記入する>` | クライアント⑤（MONITOR） |

### 3-4. 作業情報・エスカレーション先

| 項目 | 内容 |
|------|------|
| 予定作業時間 | 約60分（サーバー1台＋クライアント5台） |
| サービスへの影響 | なし（`chronyd` 再起動は瞬時に完了） |
| 作業実施者 | `<記入する>` |
| 作業承認者 | `<記入する>` |

| 状況 | 連絡先 | 連絡方法 |
|------|-------|---------|
| 自力復旧不能なエラー発生時 | リーダー氏名：`<記入する>` | 電話・Slack |
| 作業時間が予定を30分超過した場合 | リーダー氏名：`<記入する>` | Slack |

### 3-5. 事前確認

> 以下をすべて確認してからStep 1に進むこと．

#### 事前確認①：ディスク容量確認

```bash
df -h
```

> **確認基準：** `/` パーティションの使用率が80%未満であること．

#### 事前確認②：メモリ確認

```bash
free -h
```

> **確認基準：** `available` が200MB以上あること．

#### 事前確認③：SGのインバウンドルール確認

AWSコンソールにてNTPサーバーEC2のSGに `UDP 123` のインバウンドルールが設定されていることを確認する．設定されていない場合は3-2を参照して追加すること．

#### 事前確認④：firewalldの状態確認（NTPサーバー・クライアント共通）

AL2023ではfirewalldはデフォルト無効だが，環境によって有効になっている場合があるため確認する．

```bash
systemctl status firewalld
```

- **`inactive (dead)` の場合** → 対応不要．次の事前確認へ進む．
- **`active (running)` の場合** → 以下を実行してUDP 123を許可すること：

```bash
firewall-cmd --add-service=ntp --permanent
firewall-cmd --reload
firewall-cmd --list-services
```

> **確認：** `ntp` が一覧に表示されること．

### 3-6. 証跡取得の開始（任意）

作業ログを記録するため，以下のコマンドを実行してから作業を開始することを推奨する．

```bash
script -a ~/ntp_setup_$(date +%Y%m%d_%H%M%S).log
```

> **補足：** 作業完了後は本手順書の **5-6 証跡取得の終了** で `exit` する．

### 3-7. リンク一覧

| 項目名 | 目的 |
|-------|------|
| https://chrony-project.org/documentation.html | chrony公式ドキュメント |
| https://docs.aws.amazon.com/ja_jp/AWSEC2/latest/UserGuide/set-time.html | AWS NTPサーバーの仕様 |
| https://docs.aws.amazon.com/ja_jp/linux/al2023/ug/ | Amazon Linux 2023ガイド |

------------------------------

## 4. 構築手順（詳細）

> **注意事項**
> - コマンド中の `<山カッコ>` は自分の環境の値（パラメータ定義表の値）に置き換えること
> - 各Stepの見出し末尾に **【実施対象：●●】** を明示しているので，対象のサーバーで実施すること
> - **必ず NTPサーバー → クライアント の順で実施する**こと（NTPサーバーが起動していない状態でクライアントを設定しても同期できない）
>
> 作業の流れ：
>
> ```
> ① NTPサーバー（<NTPサーバーのFQDN>）でStep 1〜10を実施
>        ↓
> ② クライアント5台それぞれでStep 11〜18を実施
>    - Web / DNS / AP1 / AP2 / MONITOR
>        ↓
> ③ 5章「動作確認・検証」に進み，最終確認を実施
> ```

------------------------------

### Step 1：接続確認【実施対象：NTPサーバー】

```bash
ip addr show | grep "inet "
```

> **確認：** `<NTPサーバーのプライベートIP>` が表示されること．

------------------------------

### Step 2：chronydのインストール確認【実施対象：NTPサーバー】

AL2023には`chrony` がデフォルトでインストールされているが，念のため確認する．

```bash
dnf list installed | grep chrony
```

- **`chrony` が表示された場合（インストール済み）** → Step 3へ進む
- **何も表示されない場合（未インストール）** → 以下を実行：

```bash
dnf install -y chrony
dnf list installed | grep chrony
```

> **確認：** `chrony` が表示されること．

------------------------------

### Step 3：chronydの自動起動設定と起動【実施対象：NTPサーバー】

```bash
systemctl enable --now chronyd
systemctl status chronyd --no-pager
```

> **確認：** `Active: active (running)` および `enabled` が表示されること．

------------------------------

### Step 4：設定ファイルのバックアップ【実施対象：NTPサーバー】

> **重要：** バックアップなしで次のStepに進んではならない．

```bash
cp -a /etc/chrony.conf /etc/chrony.conf.org
ls -la /etc/chrony.conf*
```

> **確認：** `.org` ファイルが作成されていること．

------------------------------

### Step 5：冪等性確認【実施対象：NTPサーバー】

再実行時も必ず実施すること．既に設定済みの行は追記しない．

```bash
grep -n "^allow\|^local\|^port" /etc/chrony.conf
```

> **確認：** 何も出力されないこと．すでに表示される行は追記不要．

------------------------------

### Step 6：設定ファイルの編集【実施対象：NTPサーバー】

```bash
vi /etc/chrony.conf
```

ファイル末尾に以下の3行を追記する．`<VPC CIDR>` はパラメータ定義表の値に置き換えること．

```
allow <VPC CIDR>
local stratum 10
port 123
```

各設定値の説明：

| 設定 | 説明 |
|------|------|
| `allow <VPC CIDR>` | VPC内のEC2からのNTP問い合わせを許可する． |
| `local stratum 10` | 上位NTPサーバーへの接続が切れた場合にシステムクロックをフォールバックとして提供．stratum値が大きいほど信頼性が低い． |
| `port 123` | NTPの標準ポートで外部からの接続を受け付ける．**この設定がないとchronydはローカルのみでLISTENし，クライアントから接続できない**． |

> **補足：** AL2023のデフォルト設定には `server` 行が存在せず，`sourcedir` でNTPソースを動的に読み込む仕組みになっている．上位NTPサーバー（`169.254.169.123`）は`sourcedir`の仕組みで自動的に設定されるため，`server` 行の追記は不要．

------------------------------

### Step 7：追記内容の確認【実施対象：NTPサーバー】

```bash
grep -n "^allow\|^local\|^port" /etc/chrony.conf
```

> **期待する結果：**
>
> ```
> xx: allow <VPC CIDR>
> xx: local stratum 10
> xx: port 123
> ```
>
> **確認：** 3行がそれぞれ1回ずつ表示されること（二重追記がないこと）．

------------------------------

### Step 8：chronydの再起動【実施対象：NTPサーバー】

```bash
systemctl restart chronyd
systemctl status chronyd --no-pager
```

> **確認：** `Active: active (running)` であること．

------------------------------

### Step 9：123番ポートでLISTENしているか確認【実施対象：NTPサーバー】

```bash
ss -ulnp | grep chronyd
```

> **期待する結果：**
>
> ```
> UNCONN 0  0  0.0.0.0:123    0.0.0.0:*  users:(("chronyd",pid=xxxx,fd=x))
> UNCONN 0  0  127.0.0.1:323  0.0.0.0:*  users:(("chronyd",pid=xxxx,fd=x))
> ```
>
> **確認：** `0.0.0.0:123` が表示されること．

> **ポイント：** `0.0.0.0:123` はすべてのIPからの接続を受け付けている状態．`127.0.0.1:123` のみの場合はローカルしか受け付けておらずクライアントから接続できない．その場合はStep 6の `port 123` が正しく追記されているか確認すること．

------------------------------

### Step 10：上位NTPサーバーとの同期確認【実施対象：NTPサーバー】

```bash
chronyc sources -v
```

> **確認：** `169.254.169.123` の行頭に `*` マークがついていること．

> **補足：** 起動直後は `*` マークが表示されるまで数秒〜数分かかる場合がある．すぐに表示されない場合は以下のコマンドで継続監視し，`*` がついたことを確認してから次のStepへ進むこと．
>
> ```bash
> watch -n 5 chronyc sources -v
> ```
>
> 確認後は `Ctrl + C` で終了する．

ここまで完了したらNTPサーバーEC2の作業は完了．クライアントEC2の作業に進む．

------------------------------

### Step 11：接続確認【実施対象：NTPクライアント】

以下の5台それぞれにSSHして実施する：

- `<Webサーバーのホスト名>`（AZ1 Public subnet）
- `<DNSサーバーのホスト名>`（AZ2 Public subnet）
- `<AP1サーバーのホスト名>`（AZ3 Private subnet）
- `<AP2サーバーのホスト名>`（AZ4 Private subnet）
- `<Zabbixサーバーのホスト名>`（AZ4 Private subnet）

```bash
ip addr show | grep "inet "
```

> **確認：** `<NTPサーバーのプライベートIP>` 以外のIP（クライアント自身のIP）が表示されること．

------------------------------

### Step 12：chronydのインストール確認【実施対象：NTPクライアント】

```bash
dnf list installed | grep chrony
```

- **`chrony` が表示された場合（インストール済み）** → Step 13へ進む
- **何も表示されない場合（未インストール）** → 以下を実行：

```bash
dnf install -y chrony
dnf list installed | grep chrony
```

> **確認：** `chrony` が表示されること．

------------------------------

### Step 13：chronydの自動起動設定と起動【実施対象：NTPクライアント】

```bash
systemctl enable --now chronyd
systemctl status chronyd --no-pager
```

> **確認：** `Active: active (running)` および `enabled` が表示されること．

------------------------------

### Step 14：設定ファイルのバックアップ【実施対象：NTPクライアント】

```bash
cp -a /etc/chrony.conf /etc/chrony.conf.org
ls -la /etc/chrony.conf*
```

> **確認：** `.org` ファイルが作成されていること．

------------------------------

### Step 15：冪等性確認【実施対象：NTPクライアント】

```bash
grep -n "^server" /etc/chrony.conf
```

> **確認：** 何も出力されないこと．すでに表示される場合は追記不要．

> **ポイント：** AL2023のデフォルト設定には `server` 行が存在しないため，通常は何も出力されない．

------------------------------

### Step 16：設定ファイルの編集【実施対象：NTPクライアント】

```bash
vi /etc/chrony.conf
```

ファイル末尾に以下の1行を追記する．`<NTPサーバーのプライベートIP>` はパラメータ定義表の値に置き換えること．

```
server <NTPサーバーのプライベートIP> iburst
```

> **補足：** `iburst` は起動直後に短時間で複数回問い合わせを行うオプション．初回同期を高速化する．

------------------------------

### Step 17：追記内容の確認【実施対象：NTPクライアント】

```bash
grep -n "^server" /etc/chrony.conf
```

> **期待する結果：**
>
> ```
> xx: server <NTPサーバーのプライベートIP> iburst
> ```
>
> **確認：** 1行だけ表示されること（二重追記がないこと）．

------------------------------

### Step 18：chronydの再起動と同期確認【実施対象：NTPクライアント】

```bash
systemctl restart chronyd
systemctl status chronyd --no-pager
```

> **確認：** `Active: active (running)` であること．

```bash
chronyc sources -v
```

> **確認：** `<NTPサーバーのプライベートIP>` がソース一覧に表示されていること．

> **補足：** クライアント側で `*` マークがNTPサーバーのIPではなく `169.254.169.123` についている場合がある．これはchronyが複数ソースを比較して信頼性の高い方を自動選択しているためで，正常な動作である．NTPサーバーのIPが一覧に表示されていれば問題ない．

------------------------------

## 5. 動作確認・検証

### 5-1. 確認チェックリスト

以下をすべて確認し，チェックを入れること．

- [ ] **確認①**：NTPサーバーで`chronyd` が `active (running)` かつ自動起動有効
- [ ] **確認②**：NTPサーバーで `ss -ulnp | grep chronyd` にて `0.0.0.0:123` が表示
- [ ] **確認③**：NTPサーバーで `chronyc sources -v` の `169.254.169.123` に `*` がある
- [ ] **確認④**：クライアント5台それぞれで `chronyc sources -v` に `<NTPサーバーのプライベートIP>` が表示
- [ ] **確認⑤**：NTPサーバーで `chronyc clients` にクライアントEC2（5台）が表示
- [ ] **確認⑥**：証跡ログファイル（`~/ntp_setup_*.log`）が `<証跡保存先パス>` に保存

------------------------------

### 確認①〜③：NTPサーバー側確認

NTPサーバーで以下を実行：

```bash
systemctl status chronyd --no-pager
systemctl is-enabled chronyd
ss -ulnp | grep chronyd
chronyc sources -v
chronyc tracking
```

> **期待する結果：**
>
> - `active (running)` および `enabled`
> - `0.0.0.0:123` がLISTEN
> - `169.254.169.123` の行頭に `*`
> - `chronyc tracking` で `Leap status : Normal`

------------------------------

### 確認④：クライアント側確認

各クライアントEC2で以下を実行：

```bash
chronyc sources -v
chronyc tracking
```

> **期待する結果：**
>
> - ソース一覧に `<NTPサーバーのプライベートIP>` が表示
> - `Leap status : Normal`

------------------------------

### 確認⑤：クライアント5台分の接続を一括確認

NTPサーバーで以下を実行：

```bash
chronyc clients
```

> **期待する結果：**
>
> ```
> Hostname                      NTP   Drop Int IntL Last     Cmd   Drop Int  Last
> ===============================================================================
> <Webサーバーのホスト名>         x      0   x    -     x       0      0   -     -
> <DNSサーバーのホスト名>         x      0   x    -     x       0      0   -     -
> <AP1サーバーのホスト名>         x      0   x    -     x       0      0   -     -
> <AP2サーバーのホスト名>         x      0   x    -     x       0      0   -     -
> <Zabbixサーバーのホスト名>      x      0   x    -     x       0      0   -     -
> ```
>
> **確認：** クライアントEC2（5台）のホスト名またはIPが表示され，NTP列の数値が1以上であること．

------------------------------

### 5-2. 時刻同期状態の最終確認

各サーバーで以下を実行し，システムクロックがNTPで同期されていることを確認：

```bash
timedatectl
```

> **期待する結果：** `System clock synchronized: yes` および `NTP service: active`

------------------------------

### 5-3. 証跡取得の終了

作業完了後，以下で証跡取得を終了する：

```bash
exit
ls -lh ~/ntp_setup_*.log
```

証跡ログファイルを `<証跡保存先パス>` に保存する：

```
<証跡保存先パス>/ntp_setup_YYYYMMDD_HHMMSS.log
```

------------------------------

## 6. トラブルシューティング

### よくあるエラーと対処法

------------------------------

#### エラー①：NTPサーバーで `chronyc sources -v` に `*` が表示されない

**原因：** 上位NTPサーバー（`169.254.169.123`）への到達不可，もしくは起動直後の同期処理中．

**対処法：**

1. アウトバウンドSGで `UDP 123` が `0.0.0.0/0` 宛に許可されているか確認．
2. 数分待ってから再確認．

```bash
watch -n 5 chronyc sources -v
```

------------------------------

#### エラー②：クライアントで `chronyc sources -v` にNTPサーバーIPが表示されない

**原因：** クライアント側設定ミス，もしくはSG／NTPサーバー側の `allow` 設定不足．

**対処法：**

1. `/etc/chrony.conf` に `server <NTPサーバーのプライベートIP> iburst` の行があるか確認．
2. NTPサーバー側 `/etc/chrony.conf` に `allow <VPC CIDR>` があるか確認．
3. NTPサーバー側SGで `UDP 123` のインバウンドが `<VPC CIDR>` から許可されているか確認．

------------------------------

#### エラー③：`ss -ulnp | grep chronyd` で `127.0.0.1:123` のみ表示される

**原因：** `/etc/chrony.conf` の `port 123` 追記漏れ．

**対処法：** Step 6 を再確認し，`port 123` を追記後 `systemctl restart chronyd`．

------------------------------

#### エラー④：`chronyc clients` でクライアントが表示されない

**原因：** クライアント側からの接続がまだ発生していない（NTPは比較的長い間隔で問い合わせ）．

**対処法：** クライアント側で `chronyc makestep` を実行して即時同期を試行．

```bash
chronyc makestep
chronyc -a makestep
```

その後しばらく待ってNTPサーバーで再度 `chronyc clients`．

------------------------------

#### エラー⑤：firewalldがNTP通信をブロックしている

**原因：** AL2023デフォルトでは無効だが，有効化されている環境ではブロックされる．

**対処法：**

```bash
firewall-cmd --add-service=ntp --permanent
firewall-cmd --reload
```

------------------------------

### ログの確認場所

| ログの種類 | 場所（パス） |
|-----------|------------|
| chrony ログ | `journalctl -u chronyd` |
| chrony 統計 | `chronyc tracking` / `chronyc sources -v` |
| クライアント情報 | `chronyc clients` |

------------------------------

## 7. 参考リソース・関連資料

| 資料名 | URL / 場所 | 補足 |
|-------|-----------|------|
| chrony公式 | https://chrony-project.org/ | プロジェクトトップ |
| chrony公式ドキュメント | https://chrony-project.org/documentation.html | 設定リファレンス |
| AWS NTPサーバー仕様 | https://docs.aws.amazon.com/ja_jp/AWSEC2/latest/UserGuide/set-time.html | `169.254.169.123` 等 |
| Amazon Linux 2023ガイド | https://docs.aws.amazon.com/ja_jp/linux/al2023/ug/ | OS全般 |
| 別手順書：内部DNS構築 | `nsd-private-redundancy.md` | FQDN解決の構築 |

------------------------------

## 8. ロールバック手順（切り戻し）

作業を中断し元の状態に戻す場合は以下を実施する（NTPサーバー・クライアント共通）．

### 8-1. 設定ファイルの復元【実施対象：NTPサーバー／NTPクライアント】

```bash
cp -a /etc/chrony.conf.org /etc/chrony.conf
systemctl restart chronyd
systemctl status chronyd --no-pager
```

> **確認：** `Active: active (running)` であること．

### 8-2. 同期状態の確認【実施対象：NTPサーバー／NTPクライアント】

```bash
chronyc sources -v
```

> **NTPサーバーの確認：** `169.254.169.123` に `*` マークが表示されること．
> **NTPクライアントの確認：** ソース一覧が元の状態（`server` 行追記前）に戻っていること．

### 8-3. 完了確認【実施対象：NTPサーバー／NTPクライアント】

```bash
grep -n "^allow\|^local\|^port\|^server" /etc/chrony.conf
```

> **期待する結果：** 追記した行が消えていること（AL2023デフォルト状態では何も表示されない）．

> **注意：**
> - `dnf update` で適用したパッケージ更新は取り消さない（依存破壊リスク回避）．
> - firewalld設定を変更した場合は，必要に応じて元に戻す（`firewall-cmd --remove-service=ntp --permanent` 等）．

------------------------------

## 付録

### A. コマンド解説

| コマンド | 説明 |
|---------|------|
| `dnf install -y chrony` | chronyパッケージを非対話インストール． |
| `dnf list installed \| grep chrony` | chronyのインストール状態確認． |
| `systemctl enable --now chronyd` | chronydを起動し，自動起動を有効化． |
| `systemctl status chronyd --no-pager` | サービスの稼働状態を確認． |
| `systemctl restart chronyd` | サービスを再起動（設定変更を反映）． |
| `chronyc sources -v` | 同期ソース一覧を詳細表示．`*` は現在の同期元． |
| `chronyc tracking` | 現在の同期状態（オフセット，遅延等）を表示． |
| `chronyc clients` | 自NTPサーバーに接続中のクライアント一覧（要sudo）． |
| `chronyc makestep` | 大きな時刻ズレを即時補正． |
| `chronyc -a makestep` | 認証付きで即時補正（管理者操作）． |
| `ss -ulnp \| grep chronyd` | UDPでLISTEN中のchronydプロセスを表示． |
| `timedatectl` | システムクロックとNTP同期状態を表示． |
| `script -a <ファイル>` | ターミナル操作のログ取得開始．`exit` で終了． |
| `watch -n 5 <コマンド>` | 5秒ごとにコマンドを再実行（継続監視）． |
| `firewall-cmd --add-service=ntp --permanent` | firewalldでNTPサービスを永続許可． |

------------------------------

### B. 設定ファイル解説

**`/etc/chrony.conf`（NTPサーバー側）**

AL2023のデフォルト設定には主要なディレクティブが既に含まれており，本手順書では末尾に3行追記するのみ．

```
# デフォルト記載（抜粋）
sourcedir /run/chrony-dhcp
sourcedir /etc/chrony.d
driftfile /var/lib/chrony/drift
makestep 1.0 3
rtcsync
keyfile /etc/chrony.keys
ntsdumpdir /var/lib/chrony
leapsectz right/UTC
logdir /var/log/chrony

# 本手順書での追記
allow <VPC CIDR>
local stratum 10
port 123
```

- `sourcedir`：複数のNTPソース定義ファイルを動的に読み込む．`/run/chrony-dhcp` ではDHCP経由のNTPサーバー（AWSの`169.254.169.123`等）が自動配置される．
- `driftfile`：システムクロックのドリフト値（時刻が進む／遅れる速さ）を記録するファイル．
- `makestep 1.0 3`：起動後3回までは時刻差が1秒以上あれば即時補正（ステップ補正）．以降はslew（徐々に補正）．
- `rtcsync`：ハードウェアクロック（RTC）も同期．
- `allow <VPC CIDR>`：VPC内のクライアントからのNTP問い合わせを許可．
- `local stratum 10`：上位NTP切断時のフォールバック設定．stratum=10で「信頼性低めだが提供する」状態．
- `port 123`：明示的に標準NTPポートでLISTEN．デフォルトではcmdポート323のみLISTENする場合があるため必須．

**`/etc/chrony.conf`（NTPクライアント側）**

```
# 本手順書での追記
server <NTPサーバーのプライベートIP> iburst
```

- `server`：問い合わせ先のNTPサーバーを指定．
- `iburst`：起動直後に4回連続で問い合わせを行うオプション．初回同期を高速化．通常設定では推奨．

------------------------------

### C. 用語解説

| 用語 | 説明 |
|------|------|
| NTP | Network Time Protocol．ネットワーク経由で時刻同期するプロトコル．標準ポートUDP/123． |
| chrony | NTPの実装の一つ．軽量・高速で，断続的なネットワーク環境にも強い．AL2023の標準． |
| chronyd | chronyのデーモン．時刻同期サービスのプロセス本体． |
| chronyc | chronydの操作・状態確認用コマンド． |
| stratum | NTPサーバーの階層レベル．stratum 0が原子時計などの基準源．stratumが大きいほど精度が下がる． |
| sourcedir | 複数のNTPソース設定ファイルを動的に読み込む仕組み．AL2023のデフォルト設定で使用． |
| iburst | 起動直後に短時間で4回問い合わせを行うオプション．初回同期を高速化． |
| drift | システムクロックの進み／遅れの速さ．chronyが学習してdriftfileに記録． |
| makestep | 大きな時刻差を瞬間的に補正する動作（時刻が飛ぶ）．通常は徐々に補正（slew）する． |
| stratum 10 (local) | 上位NTP切断時に自サーバーをstratum 10として時刻提供するフォールバック設定． |
| AWS NTPサーバー | `169.254.169.123`．AWSが提供する各リージョン共通のNTPサーバー（リンクローカル）． |
| ハードウェアクロック (RTC) | サーバーのマザーボードに搭載された時計．OS停止中も時刻を保持． |

------------------------------

### D. 補足解説

- **なぜAWS NTPサーバー（`169.254.169.123`）を直接使わず内部NTPサーバーを立てるか？**
  - 各EC2が直接AWS NTPに問い合わせると，問い合わせ回数が分散して管理が複雑になる．
  - 内部NTPサーバー1台に集約することで，時刻同期の状態を一元監視できる．
  - 内部システム全体で「同じ時刻源」を参照することで，ログの突合が容易になる．
  - 仮にAWS NTPに到達できなくなった場合でも，内部NTPサーバーが `local stratum 10` のフォールバックで時刻提供を継続できる．

- **stratum値の意味**
  - stratum 0：原子時計，GPS等の基準源．
  - stratum 1：stratum 0に直結したサーバー（一次NTPサーバー）．
  - stratum 2：stratum 1から時刻を取得するサーバー（二次NTPサーバー）．
  - stratumが大きいほど精度が下がる（許容範囲）．stratum 16は「未同期」を意味する特別な値．
  - 本構成では：AWS NTP（stratum 3〜4）→ 内部NTPサーバー（stratum 4〜5）→ クライアント（stratum 5〜6）．

- **`port 123` 追記の必要性**
  - chronyのデフォルトでは，コマンドポート（323）はLISTENするが，NTPポート（123）はLISTENしない場合がある．
  - クライアントから問い合わせを受けるためには明示的に `port 123` の指定が必要．

- **`iburst` オプション**
  - NTPのデフォルトでは時刻同期に数分〜数十分かかる場合がある．
  - `iburst` を付けると起動直後に短時間で4回問い合わせを行い，秒単位で同期完了する．
  - 本番／検証環境を問わず推奨されるオプション．

- **chrony vs ntpdの違い**
  - chronyは断続的なネットワーク（モバイル，仮想化環境）に強い．
  - ntpdは伝統的な実装で，安定接続が前提．
  - AL2023標準はchrony．本手順書もchrony前提．

- **時刻補正の方式（slew vs step）**
  - slew：徐々に時刻を補正．アプリケーションへの影響が少ない．
  - step：時刻を瞬間的に飛ばす．大きなズレ補正に必要だがログの順序が乱れる可能性．
  - `makestep 1.0 3` は起動後3回までは1秒以上のズレで step補正，以降は slew．

- **`dnf update` と `dnf upgrade` の違い**
  - DNFベースのAmazon Linux 2023では両者は同義．本手順書では `dnf update -y` に統一．
