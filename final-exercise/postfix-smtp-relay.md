# Postfixを用いたSMTPリレーサーバー構築

------------------------------

## 1. ドキュメント情報

| 項目 | 内容 |
|------|------|
| 手順書名 | Postfixを用いたSMTPリレーサーバー構築 |
| 作成日 | 2026-06-18 |
| 最終更新日 | 2026-06-18 |
| バージョン | v1.0 |
| 対象環境 | AWS（Amazon Linux 2023） |

> **改訂履歴**
>
> | バージョン | 日付 | 変更内容 |
> |-----------|------|---------|
> | v1.0 | 2026-06-18 | 初版作成（テンプレートに沿って再構成．構成図追加．プレースホルダーを意味ベースに統一．パラメータ定義表を統合．SG設定セクションを強化．各Stepに【実施対象】明示．句読点を「，．」に統一．サーバー表記を「サーバー」に統一．メール送信テスト追加．付録A〜D追加．） |

------------------------------

## 2. 目的・概要

### 2-1. 目的

> 本手順書では，AWSのEC2インスタンス上に「Postfix」をインストールし，VPC内の各サーバー（特にAPサーバー）から発信されるメールを外部メールサーバーへリレー（中継）するSMTPリレーサーバーを構築する手順について説明する．
> 構成上はAZ1とAZ3の2台に同手順を適用し，アプリケーション側の設定によって冗長化する想定．
> 本手順書では「SMTPリレーサーバー1台分」の構築までを範囲とする．

### 2-2. 構成概要（アーキテクチャ）

```
[外部メールサーバー]
       ▲
       │ SMTP（25 / 587）
       │
┌──────┴───────────────── VPC ─────────────────────────────┐
│                                                          │
│  [EC2: SMTPリレーサーバー（AZ1）]   [EC2: SMTPリレーサーバー（AZ3）]│
│    └─ Postfix（25番）              └─ Postfix（25番）       │
│         ▲                                ▲                │
│         │ SMTP（25）                      │ SMTP（25）      │
│         │                                │                │
│  [EC2: APサーバー]──────────────────────┘                  │
│    （Tomcat等のアプリ）                                     │
│                                                          │
│  [systemd-resolved → 内部DNS（Primary/Secondary）]         │
│                                                          │
└──────────────────────────────────────────────────────────┘
```

### 2-3. 完成イメージ（ゴール定義）

- [ ] `postfix.service` が `active (running)` かつ自動起動有効である
- [ ] localhost（127.0.0.1）および `<SMTPリレーサーバーのプライベートIP>` の25番ポートでLISTENしている
- [ ] `/var/log/maillog` に `fatal` / `error` レベルのログが出ていない
- [ ] APサーバーから `nc -zv <SMTPリレーサーバーのプライベートIP> 25` が成功する
- [ ] APサーバーから本サーバー経由でメール送信テストが成功する

------------------------------

## 3. 前提条件・準備

### 3-1. 環境要件

| 項目 | 要件 |
|------|------|
| OS | Amazon Linux 2023 |
| CPU | 1コア以上 |
| メモリ | 1GB以上 |
| ストレージ | 8GB以上 |
| 配置サブネット | SMTPリレー用サブネット（AZ1またはAZ3） |
| 依存パッケージ | `postfix`，`nmap-ncat` |

> **補足：** 本サーバーは「SMTPリレー専用」として設計されたAZに配置する．AP／DNSサーバーとは別インスタンスを推奨．

### 3-2. セキュリティグループ設定

#### 3-2-1. SMTPリレーサーバーのインバウンドルール

| タイプ | プロトコル | ポート範囲 | ソース | 説明 |
|-------|------------|----------|--------|------|
| SSH | TCP | 22 | マイIP | ローカルPCからSSHで接続（踏み台経由） |
| カスタムTCP | TCP | 25 | VPC CIDR | VPC内部のAPサーバー等からのSMTP接続 |

#### 3-2-2. SMTPリレーサーバーのアウトバウンドルール

| タイプ | プロトコル | ポート範囲 | 送信先 | 説明 |
|-------|------------|----------|--------|------|
| HTTPS | TCP | 443 | 0.0.0.0/0 | dnf／パッケージダウンロード |
| HTTP | TCP | 80 | 0.0.0.0/0 | dnfミラー |
| SMTP | TCP | 25 | 0.0.0.0/0 | 外部メールサーバーへのリレー |
| SMTP Submission | TCP | 587 | 0.0.0.0/0 | サブミッションポート利用時 |
| DNS | UDP | 53 | 内部DNSサーバーのSG | 内部名前解決 |

> **注意：** AWSのデフォルトでは新規アカウントのEC2からのポート25アウトバウンドが制限されている場合がある．制限解除はAWSサポートに申請する必要がある（参考リソース参照）．

### 3-3. パラメータ定義表

> **注意：** 以下の値は作業前に環境に合わせて記入してから作業を開始すること．

#### system-setup用

| パラメータ名 | 値 | 説明 |
|------------|---|------|
| `<SMTPリレーサーバーのホスト名>` | `<記入する>` | このサーバーのホスト名（例：`<任意の名前>-smtp`） |
| `<プライマリDNSのIP>` | `<記入する>` | 内部DNSプライマリ（AZ2のAPサーバー）のIP |
| `<セカンダリDNSのIP>` | `<記入する>` | 内部DNSセカンダリ（AZ4のAPサーバー）のIP |

#### Postfix設定用

| パラメータ名 | 値 | 説明 |
|------------|---|------|
| `<SMTPリレーサーバーのプライベートIP>` | `<記入する>` | このサーバーのプライベートIP（`ip addr show` で確認） |
| `<許可するネットワーク>` | 例：`10.0.0.0/16` | リレーを許可するネットワーク（VPC CIDR） |
| `<Postfix myhostname>` | 例：`hr-dash.tech` | Postfixの`myhostname`値（自分の名乗るホスト名） |
| `<Postfix mydomain>` | 例：`hr-dash.tech` | Postfixの`mydomain`値 |

#### ロールバック用（任意）

| パラメータ名 | 値 | 説明 |
|------------|---|------|
| `<元のホスト名>` | `<記入する>` | 構築前のホスト名（戻す場合のみ記入） |
| `<元のタイムゾーン>` | `<記入する>` | 構築前のタイムゾーン（戻す場合のみ記入） |

### 3-4. リンク一覧

| 項目名 | 目的 |
|-------|------|
| https://www.postfix.org/documentation.html | Postfix公式ドキュメント |
| https://www.postfix.org/postconf.5.html | `main.cf`のディレクティブ一覧 |
| https://repost.aws/ja/knowledge-center/ec2-port-25-throttle | AWS EC2のポート25制限解除申請 |
| https://docs.aws.amazon.com/ja_jp/linux/al2023/ug/ | Amazon Linux 2023ガイド |

------------------------------

## 4. 構築手順（詳細）

> **注意事項**
> - コマンド中の `<山カッコ>` は自分の環境の値（パラメータ定義表の値）に置き換えること
> - 各Stepの見出し末尾に **【実施対象：SMTPリレーサーバー】** を明示しているので，対象のサーバーで実施すること
> - 本手順書の作業対象はすべて **SMTPリレーサーバー** である
> - 同居サーバー等で `system-setup` を既に実施済みの場合，Step 1はスキップ可能

------------------------------

### Step 1：system-setup（共通システム設定）【実施対象：SMTPリレーサーバー】

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
hostnamectl set-hostname <SMTPリレーサーバーのホスト名>

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

> **注意：** ホスト名をシェルのプロンプトに反映させるため，一度SSHを切断して再接続すること．
> **注意：** カーネル更新で再起動した場合は，再度SSH接続してからStep 2以降に進むこと．

------------------------------

### Step 2：Postfixのインストール【実施対象：SMTPリレーサーバー】

**目的：** dnfからPostfixをインストールする

#### 操作手順

```bash
# Postfixをインストール
dnf install -y postfix

# バージョン確認
postconf mail_version
```

> **期待する結果：** `mail_version = 3.x.x` のように表示される．

------------------------------

### Step 3：main.cfのバックアップ【実施対象：SMTPリレーサーバー】

**目的：** オリジナルの `main.cf` を `.org` 拡張子で退避する（ロールバック時に使用）

#### 操作手順

```bash
# 既にバックアップ済みかチェック，無ければ取得
ls /etc/postfix/main.cf.org 2>/dev/null && echo "既にバックアップ済み" || cp -p /etc/postfix/main.cf /etc/postfix/main.cf.org

# バックアップ確認
ls -l /etc/postfix/main.cf.org
```

> **重要：** ロールバック時に本バックアップから復元する．**絶対に上書きしないこと**．

------------------------------

### Step 4：main.cfの生成【実施対象：SMTPリレーサーバー】

**目的：** SMTPリレー用に `main.cf` を作成する

#### 操作手順

```bash
# main.cf を編集
vi /etc/postfix/main.cf
```

設定ファイルの記述内容（vi上で `:1,$d` で全行削除した後，以下を貼り付け）：

```
compatibility_level = 3.7

queue_directory = /var/spool/postfix
command_directory = /usr/sbin
daemon_directory = /usr/libexec/postfix
data_directory = /var/lib/postfix
mail_owner = postfix

inet_interfaces = localhost, <SMTPリレーサーバーのプライベートIP>
inet_protocols = ipv4

mydestination = $myhostname, localhost.$mydomain, localhost
unknown_local_recipient_reject_code = 550

alias_maps = hash:/etc/aliases
alias_database = hash:/etc/aliases

debug_peer_level = 2
debugger_command =
         PATH=/bin:/usr/bin:/usr/local/bin:/usr/X11R6/bin
         ddd $daemon_directory/$process_name $process_id & sleep 5

sendmail_path = /usr/sbin/sendmail.postfix
newaliases_path = /usr/bin/newaliases.postfix
mailq_path = /usr/bin/mailq.postfix

setgid_group = postdrop

html_directory = no
manpage_directory = /usr/share/man
sample_directory = /usr/share/doc/postfix/samples
readme_directory = /usr/share/doc/postfix/README_FILES

smtpd_tls_cert_file = /etc/pki/tls/certs/postfix.pem
smtpd_tls_key_file = /etc/pki/tls/private/postfix.key
smtpd_tls_security_level = may

smtp_tls_CApath = /etc/pki/tls/certs
smtp_tls_CAfile = /etc/pki/tls/certs/ca-bundle.crt
smtp_tls_security_level = may

meta_directory = /etc/postfix
shlib_directory = /usr/lib64/postfix

mynetworks = <許可するネットワーク>
myhostname = <Postfix myhostname>
mydomain = <Postfix mydomain>
myorigin = $mydomain
```

> **重要：**
> - `$` 記号は Postfix の変数展開のため，そのまま記述する（シェル変数ではない）．
> - `inet_interfaces` の `<SMTPリレーサーバーのプライベートIP>` を間違えるとPostfixが`bind`できず起動失敗する．

> **補足：** 各ディレクティブの意味は付録Bを参照．

------------------------------

### Step 5：設定構文チェック【実施対象：SMTPリレーサーバー】

**目的：** Postfix構文チェッカーで設定ファイルの妥当性を確認する

#### 操作手順

```bash
postfix check
```

> **期待する結果：** 何も表示されない（エラーなし）．

> **注意：** エラーが出た場合は `/etc/postfix/main.cf` の記述を見直すこと．

------------------------------

### Step 6：Postfixの起動【実施対象：SMTPリレーサーバー】

**目的：** Postfixを起動し，自動起動を有効化する

#### 操作手順

```bash
# 起動 + 自動起動有効化
systemctl enable --now postfix.service

# 起動確認
systemctl status postfix.service --no-pager

# 自動起動確認
systemctl is-enabled postfix.service
```

> **期待する結果：** `active (running)` および `enabled` が表示される．

------------------------------

### Step 7：設定再読込（既に起動済みの場合）【実施対象：SMTPリレーサーバー】

**目的：** Step 6で起動済みだった場合に備えて，設定を再読込する

#### 操作手順

```bash
systemctl reload postfix.service
```

> **補足：** 初回起動時にエラーになる場合があるが無視して構わない．Step 6で正常起動していれば本Stepは省略可能．

------------------------------

## 5. 動作確認・検証

> 構築完了後，以下の確認をすべてパスしたら構築成功とみなす．

### 5-1. 確認チェックリスト

- [ ] **確認①**：Postfixサービスが `active (running)` かつ自動起動有効
- [ ] **確認②**：25番ポートがLISTEN状態（localhost と プライベートIP の2つ）
- [ ] **確認③**：`/var/log/maillog` にエラーが出ていない
- [ ] **確認④**：VPC内のAPサーバーから25番への接続が可能
- [ ] **確認⑤**：APサーバーから本サーバー経由でメール送信テストが成功

------------------------------

### 確認①：サービス状態確認

```bash
systemctl status postfix.service --no-pager
systemctl is-enabled postfix.service
```

**期待する結果：** `active (running)` および `enabled`．

------------------------------

### 確認②：リッスンポート確認

```bash
ss -ltnp | grep :25
```

**期待する結果：** localhost（127.0.0.1:25）と `<SMTPリレーサーバーのプライベートIP>:25` の両方でmasterプロセスがLISTENしている．

```
LISTEN 0  100  127.0.0.1:25   0.0.0.0:*  users:(("master",pid=...))
LISTEN 0  100  <SMTPリレーサーバーのプライベートIP>:25   0.0.0.0:*  users:(("master",pid=...))
```

------------------------------

### 確認③：ログ確認

```bash
tail -n 50 /var/log/maillog
```

> **注意：** `fatal` や `error` レベルのログが出ていないことを目視確認する．

------------------------------

### 確認④：APサーバーからのポート疎通確認

APサーバー側で以下を実行：

```bash
nc -zv <SMTPリレーサーバーのプライベートIP> 25
```

> **期待する結果：** `Ncat: Connected to <IP>:25.` が表示される．

------------------------------

### 確認⑤：メール送信テスト（任意）

APサーバー側で以下のいずれかを実行：

```bash
# 方法1：sendmail を使う（mailx パッケージが必要な場合あり）
echo "Subject: SMTP relay test
This is a test message from AP server." | sendmail -S <SMTPリレーサーバーのプライベートIP>:25 <宛先メールアドレス>

# 方法2：swaks を使う（より詳細なログ）
# 事前に：dnf install -y swaks
swaks --to <宛先メールアドレス> --server <SMTPリレーサーバーのプライベートIP>:25
```

その後，SMTPリレーサーバー側でログ確認：

```bash
tail -n 30 /var/log/maillog
```

> **期待する結果：** `status=sent` または `relay=` の行が出力されている．

> **注意：** メール送信テストはチームに事前周知すること．本番宛先には送らずテスト用アドレスを使う．

------------------------------

## 6. トラブルシューティング

### よくあるエラーと対処法

------------------------------

#### エラー①：`postfix/master[xxx]: fatal: bind ... Cannot assign requested address`

**原因：** `inet_interfaces` で指定したIPがこのサーバーに割り当てられていない．

**対処法：**

```bash
# 現在のIP確認
ip -4 addr show | grep inet

# main.cf を修正
vi /etc/postfix/main.cf
# → inet_interfaces 行の IP を正しい値に修正

# 再起動
systemctl restart postfix.service
```

------------------------------

#### エラー②：他サーバーから25/tcpに接続できない

**原因：** セキュリティグループの設定不足，もしくは `mynetworks` の設定ミス．

**対処法：**

1. AWSコンソールで対象EC2のSGに，ソースSGからの25/tcpを追加．
2. `mynetworks` の確認：

   ```bash
   postconf mynetworks
   ```

3. パラメータシートの「許可するネットワーク」を確認し，必要に応じて修正．

------------------------------

#### エラー③：`postfix check` でエラー

**原因：** `main.cf` の記述ミス．

**対処法：** エラーメッセージに表示された行番号を確認し，修正．

```bash
vi /etc/postfix/main.cf
postfix check
```

------------------------------

#### エラー④：外部メールサーバーへ届かない（25番が外部にアウトバウンドできない）

**原因：** AWSのデフォルトでは新規アカウントのEC2からのポート25アウトバウンドが制限されている．

**対処法：**

1. 外部宛のSMTP通信ログを確認：

   ```bash
   grep "to=<外部宛先>" /var/log/maillog
   ```

2. `Connection timed out` が出る場合は，AWSサポートに「Easy DKIM／ポート25解除」を申請（参考リソース参照）．
3. 暫定的にはサブミッションポート587経由のリレーサービス利用を検討．

------------------------------

#### エラー⑤：`/var/log/maillog` が存在しない

**原因：** `rsyslog` パッケージがインストールされていない．

**対処法：**

```bash
dnf install -y rsyslog
systemctl enable --now rsyslog
systemctl restart postfix.service
```

------------------------------

### ログの確認場所

| ログの種類 | 場所（パス） |
|-----------|------------|
| Postfix ログ | `/var/log/maillog` |
| systemd ログ | `journalctl -u postfix.service` |
| キュー状況 | `mailq` または `postqueue -p` |

------------------------------

## 7. 参考リソース・関連資料

| 資料名 | URL / 場所 | 補足 |
|-------|-----------|------|
| Postfix 公式 | https://www.postfix.org/ | プロジェクトトップ |
| Postfix `main.cf` リファレンス | https://www.postfix.org/postconf.5.html | ディレクティブ一覧 |
| AWS EC2 ポート25解除 | https://repost.aws/ja/knowledge-center/ec2-port-25-throttle | アウトバウンド制限解除 |
| Amazon Linux 2023 ガイド | https://docs.aws.amazon.com/ja_jp/linux/al2023/ug/ | OS全般 |
| 別手順書：内部DNS構築 | `nsd-private-redundancy.md` | 内部名前解決 |
| 別手順書：Tomcat構築 | `tomcat-basic.md` | メール送信元のAPサーバー |

------------------------------

## 8. ロールバック手順

### 8-1. Postfixサービスの停止と無効化【実施対象：SMTPリレーサーバー】

```bash
systemctl disable --now postfix.service
```

### 8-2. main.cfの復元【実施対象：SMTPリレーサーバー】

```bash
# バックアップ存在確認
ls /etc/postfix/main.cf.org

# 存在する場合のみ復元
cp -f /etc/postfix/main.cf.org /etc/postfix/main.cf
```

### 8-3. Postfixパッケージのアンインストール【実施対象：SMTPリレーサーバー】

```bash
# 存在確認
rpm -q postfix

# インストールされている場合
dnf remove -y postfix
```

### 8-4. 残存ディレクトリの確認（任意で削除）【実施対象：SMTPリレーサーバー】

```bash
ls -ld /etc/postfix /var/spool/postfix 2>/dev/null
```

完全に消す場合のみ（他システムへの影響がないことを確認後）：

```bash
rm -rf /etc/postfix /var/spool/postfix
```

### 8-5. systemd-resolvedのDNS設定削除【実施対象：SMTPリレーサーバー】

```bash
rm -f /etc/systemd/resolved.conf.d/wp-local.conf
systemctl restart systemd-resolved
```

### 8-6. ホスト名・タイムゾーンの復元（任意）【実施対象：SMTPリレーサーバー】

```bash
hostnamectl set-hostname <元のホスト名>
timedatectl set-timezone <元のタイムゾーン>
```

### 8-7. 完了確認【実施対象：SMTPリレーサーバー】

```bash
systemctl status postfix.service 2>&1 | head -3
```

> **期待する結果：** `Unit postfix.service could not be found.`（パッケージ削除済みのため）

> **注意：**
> - `dnf update` で適用したパッケージ更新は取り消さない（依存破壊リスク回避）．
> - ホスト名を変更した場合はSSHを一度切断して再ログインすること．

------------------------------

## 付録

### A. コマンド解説

| コマンド | 説明 |
|---------|------|
| `dnf install -y <パッケージ>` | dnfからパッケージを非対話インストール． |
| `postconf <パラメータ名>` | Postfixの設定値を表示．パラメータ省略時は全表示． |
| `postconf -e "<パラメータ>=<値>"` | `main.cf` のパラメータを直接編集（コマンド経由）． |
| `postfix check` | `main.cf` の構文チェック．エラー時のみ出力． |
| `postfix start \| stop \| reload` | Postfixの起動／停止／設定再読込（systemd経由を推奨）． |
| `sendmail -S <SMTP:port> <宛先>` | コマンドラインからメール送信．`-S` でSMTP宛先指定． |
| `mailq` | キュー内のメール一覧を表示．エイリアス：`postqueue -p`． |
| `postqueue -f` | キューを即時フラッシュ（再送試行）． |
| `postsuper -d <queue_id>` | 指定キューIDのメールを削除． |
| `systemctl enable --now <サービス>` | サービスを起動し，自動起動を有効化． |
| `systemctl reload <サービス>` | サービスを停止せず設定再読込． |
| `ss -ltnp` | TCPでLISTEN中のポートとプロセスを一覧表示． |
| `nc -zv <IP> <ポート>` | ポートへの疎通確認． |
| `tail -n <数> <ファイル>` | ファイルの末尾N行を表示． |
| `journalctl -u <サービス>` | 指定サービスのsystemdログを表示． |

------------------------------

### B. 設定ファイル解説

**`/etc/postfix/main.cf`（SMTPリレーサーバー）**

```
compatibility_level = 3.7
```

- Postfixの互換性レベル．新バージョンへ移行時のディレクティブ解釈ルールを指定．

```
queue_directory = /var/spool/postfix
command_directory = /usr/sbin
daemon_directory = /usr/libexec/postfix
data_directory = /var/lib/postfix
mail_owner = postfix
```

- Postfixのファイル配置ディレクトリ群．通常変更不要．
- `mail_owner`：Postfixプロセスの実行ユーザー．

```
inet_interfaces = localhost, <SMTPリレーサーバーのプライベートIP>
inet_protocols = ipv4
```

- `inet_interfaces`：LISTENするインターフェース／IP．localhost（127.0.0.1）と自分のプライベートIPを指定．
- `inet_protocols = ipv4`：IPv4のみ使用．

```
mydestination = $myhostname, localhost.$mydomain, localhost
```

- 自サーバー宛として扱うドメイン．ここに該当する宛先はローカル配送される．
- 本構成（リレー専用）では最小限のみ指定．

```
unknown_local_recipient_reject_code = 550
```

- 未知のローカル宛先への応答コード．550で永続エラーを返す．

```
alias_maps = hash:/etc/aliases
alias_database = hash:/etc/aliases
```

- ローカルエイリアス（`/etc/aliases`）の設定．

```
smtpd_tls_security_level = may
smtp_tls_security_level = may
```

- TLS設定．`may` は「対応していれば使う，未対応でも継続」．本構成では緩めの設定．
- 本番環境ではより厳格な設定（`encrypt` 等）を検討すべき．

```
mynetworks = <許可するネットワーク>
```

- **リレー（中継送信）を許可するネットワーク**．**ここに含まれるIPからは認証なしで外部へリレー可能**．
- セキュリティ上重要．VPC CIDR以外を含めない．

```
myhostname = <Postfix myhostname>
mydomain = <Postfix mydomain>
myorigin = $mydomain
```

- `myhostname`：Postfixが自分を名乗るホスト名（FQDN）．
- `mydomain`：所属ドメイン．
- `myorigin`：送信時にFromに付加されるドメイン．`$mydomain` で `mydomain` の値を参照．

------------------------------

### C. 用語解説

| 用語 | 説明 |
|------|------|
| SMTP | Simple Mail Transfer Protocol．メール送信プロトコル．標準ポートは25． |
| MTA | Mail Transfer Agent．メール転送エージェント．Postfix／Sendmail／Exim等． |
| MUA | Mail User Agent．メールクライアント（Thunderbird等）． |
| SMTPリレー | あるMTAから別のMTAへメールを中継すること．本構成のPostfixはリレー専用． |
| Postfix | Wietse Venemaが開発した高速・セキュアなMTA実装． |
| サブミッションポート | TCP/587．認証付きSMTP（クライアント→MTA）に使う． |
| `mynetworks` | Postfixがリレーを許可するネットワーク範囲．設定を誤ると不正中継（オープンリレー）になる． |
| `myhostname` | PostfixがHELO/EHLOで名乗るホスト名（FQDN）． |
| `myorigin` | 送信時にFromアドレスへ付加されるドメイン名． |
| `mydestination` | 自分宛（ローカル配送）として扱うドメイン． |
| TLS | Transport Layer Security．通信暗号化． |
| `compatibility_level` | Postfixの互換性レベル．新旧バージョンの振る舞い差を制御． |
| `master` | Postfixのメインプロセス（`/usr/libexec/postfix/master`）．`postfix.service` で起動される． |
| キュー | 配送待ち／再送待ちのメール一時保管領域．`mailq` で確認． |

------------------------------

### D. 補足解説

- **なぜSMTPリレー専用サーバーが必要か？**
  - 各APサーバーから直接外部メールを送ると，送信元IPがバラつき，スパムフィルタに引っかかりやすい．
  - リレーサーバーに集約することで，送信元IPを一本化でき，逆引きDNS／SPF／DKIM設定の管理も容易になる．
  - 外部メールサービスとの接続管理（認証情報，証明書，TLS設定）を一箇所に集約できる．

- **`inet_interfaces` で localhost とプライベートIP の2つを指定する理由**
  - `localhost` だけだと外部（同VPC内のAPサーバー等）からの25番接続を受けられない．
  - プライベートIPだけだとPostfix自身がローカルメール送信（cron通知等）するときにループバック経路で接続できない．
  - 両方指定することで「ローカル送信」と「VPC内からの受信」の両方をカバーする．

- **`mynetworks` の重要性（セキュリティ）**
  - `mynetworks` に含まれる接続元からは **認証なしでリレー可能** になる．
  - ここに `0.0.0.0/0` のような広範囲を指定すると **オープンリレー** となり，スパム踏み台にされる．
  - 必ずVPC CIDR等の信頼できる範囲のみを指定する．

- **TLSの `security_level = may` の意味**
  - `may`：相手がTLSに対応していれば暗号化通信，対応していなければ平文で継続．
  - `encrypt`：必ず暗号化．対応していなければ送信失敗．
  - `verify`：暗号化＋証明書検証必須．
  - 本構成は検証環境のため `may` だが，本番では受信側／送信側それぞれに応じた強化を検討すること．

- **AWS EC2のポート25制限について**
  - 新規AWSアカウントでは，EC2インスタンスからのアウトバウンド25番が制限されている（スパム対策）．
  - 外部メールサーバーへリレーする場合，AWSサポートへ「ポート25制限解除」の申請が必要．
  - 申請が通らない場合は，サブミッションポート587経由でリレーサービス（Amazon SES等）を利用する選択肢もある．

- **同居構成と分離構成の比較**

  | 観点 | 同居構成 | 分離構成（推奨） |
  |------|---------|----------------|
  | コスト | 安い（EC2台数少） | やや高い |
  | 障害影響 | 同居サービスに波及 | SMTPの障害が他に影響しない |
  | リソース競合 | 起こりうる | 起こらない |
  | 運用性 | ログ調査時に切り分け難 | 切り分けが容易 |

  - 本手順書は分離構成（SMTPリレー専用サーバー）を前提とする．

- **`dnf update` と `dnf upgrade` の違い**
  - DNFベースのAmazon Linux 2023では両者は同義．本手順書では `dnf update -y` に統一．
