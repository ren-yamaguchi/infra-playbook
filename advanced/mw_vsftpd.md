# vsftpd / ProFTPD 基本・発展課題集

> FTP サーバー。古い現場では今も使われる。SFTP / SCP との比較で使い分けを理解します  
> 前提：AWS 無料利用枠の範囲内で実施可能な課題を基本とする  
> 作成日：2026年6月

---

## 目次

1. [基本課題 A：vsftpd のインストールと基本設定](#基本課題-avsftpd-のインストールと基本設定)
2. [基本課題 B：ユーザー管理とアクセス制御](#基本課題-bユーザー管理とアクセス制御)
3. [基本課題 C：パッシブモードの設定](#基本課題-cパッシブモードの設定)
4. [発展課題 D：FTPS（FTP over TLS）の設定](#発展課題-dftpsftp-over-tls-の設定)
5. [発展課題 E：chroot によるディレクトリ制限](#発展課題-echroot-によるディレクトリ制限)
6. [発展課題 F：ProFTPD の設定と比較](#発展課題-fproftpd-の設定と比較)
7. [発展課題 G：監視とログ管理](#発展課題-g監視とログ管理)
8. [発展課題 H：SFTP / SCP との比較と移行](#発展課題-hsftp--scp-との比較と移行)

---

## 基本課題 A：vsftpd のインストールと基本設定

**A-1. EC2 への vsftpd インストール**
- AL2023 の EC2 に `vsftpd` をインストールし、`systemd` でサービス登録・自動起動を設定する
- Security Group で FTP ポート（21）とパッシブモード用ポート範囲（例：60000-65535）を開放する
- `vsftpd -v` でバージョンを確認し、FTP クライアントから接続テストを行う

**A-2. vsftpd.conf の基本設定**
- `/etc/vsftpd/vsftpd.conf` で基本設定を行う

```ini
# 匿名アクセスを禁止
anonymous_enable=NO

# ローカルユーザーのアクセスを許可
local_enable=YES

# アップロードを許可
write_enable=YES

# ローカルユーザーのデフォルト umask
local_umask=022

# アクセスログ
xferlog_enable=YES
xferlog_file=/var/log/vsftpd.log

# タイムアウト設定
idle_session_timeout=300
data_connection_timeout=120
```

**A-3. 動作確認**
- `ftp <EC2 IP>` または `lftp` で接続し、ファイルのアップロード・ダウンロード・ディレクトリ一覧表示が動作することを確認する

---

## 基本課題 B：ユーザー管理とアクセス制御

**B-1. FTP ユーザーの作成**
- FTP 専用のシステムユーザーを作成し（シェルを `/sbin/nologin` に設定して SSH ログインを禁止）、FTP のみアクセスできる設定にする
- `userlist_enable=YES` と `userlist_file=/etc/vsftpd/user_list` を設定し、許可するユーザーを明示的に管理する

**B-2. IP ベースのアクセス制御**
- `/etc/hosts.allow` と `/etc/hosts.deny` で接続を許可する IP アドレスを制限する
- Security Group の制限と合わせて二重にアクセス制御する設定の意義をまとめる

---

## 基本課題 C：パッシブモードの設定

**C-1. パッシブモードの理解**
- FTP のアクティブモードとパッシブモードの違い（データ接続の方向・NAT/ファイアウォール環境での問題）を図で整理する
- EC2（NAT 環境）では必ずパッシブモードが必要な理由をまとめる

**C-2. パッシブモードのポート設定**
- `pasv_enable=YES`・`pasv_min_port=60000`・`pasv_max_port=65535`・`pasv_address=<EC2 パブリック IP>` を設定する
- Security Group でパッシブポート範囲を開放し、FTP クライアントから接続・ファイル転送ができることを確認する

---

## 発展課題 D：FTPS（FTP over TLS）の設定

**D-1. 自己署名証明書の生成と FTPS 設定**
- OpenSSL で自己署名証明書を生成し、vsftpd の TLS 設定を行う

```ini
ssl_enable=YES
allow_anon_ssl=NO
force_local_data_ssl=YES
force_local_logins_ssl=YES
ssl_tlsv1=YES
ssl_sslv2=NO
ssl_sslv3=NO
rsa_cert_file=/etc/vsftpd/vsftpd.pem
rsa_private_key_file=/etc/vsftpd/vsftpd.pem
```

**D-2. FTPS 接続の確認**
- `lftp -u user,password ftps://<IP>` または FileZilla で FTPS 接続し、通信が暗号化されていることをパケットキャプチャで確認する
- Let's Encrypt 証明書を vsftpd に適用し、自己署名証明書との信頼性の違いを確認する

---

## 発展課題 E：chroot によるディレクトリ制限

**E-1. chroot_local_user の設定**
- `chroot_local_user=YES` で FTP ユーザーをホームディレクトリに閉じ込め、サーバーの他のディレクトリにアクセスできないようにする
- chroot 環境でのディレクトリパーミッション（ホームディレクトリの書き込み権限を root にする必要がある）の設定を確認する

**E-2. 仮想ユーザーの設定**
- `pam_service_name` と DB ファイルを使った仮想ユーザー（OS のユーザーアカウントを持たない FTP ユーザー）を設定し、セキュリティを向上させる

---

## 発展課題 F：ProFTPD の設定と比較

**F-1. ProFTPD のインストールと基本設定**
- AL2023 に ProFTPD をインストールし、vsftpd と同等の設定（ローカルユーザー認証・パッシブモード・TLS）を行う
- 設定ファイル（`/etc/proftpd.conf`）の構文が Apache の `httpd.conf` に似ていることを確認する

**F-2. vsftpd vs ProFTPD の比較**

| 観点 | vsftpd | ProFTPD |
|------|--------|---------|
| セキュリティ | 高（シンプルな設計） | 中（機能が多い分設定ミスのリスクあり） |
| 設定の柔軟性 | 低 | 高（Apache 風のディレクティブ） |
| 仮想ユーザー | 対応（pam） | 対応（SQL バックエンドも可） |
| 帯域制限 | 限定的 | 詳細な設定が可能 |
| モジュール拡張 | なし | mod_sftp 等で SFTP 対応も可能 |

---

## 発展課題 G：監視とログ管理

**G-1. アクセスログの分析**
- `/var/log/vsftpd.log` を解析し、ユーザー別の転送量・アクセス頻度を集計するスクリプトを作成する
- ブルートフォースログイン試行を `fail2ban` で検知し、該当 IP を自動ブロックする設定を行う

**G-2. CloudWatch Logs への転送**
- vsftpd のアクセスログを CloudWatch Logs に転送し、ログイン失敗が急増した場合のアラームを設定する

---

## 発展課題 H：SFTP / SCP との比較と移行

**H-1. プロトコル比較**

| 観点 | FTP | FTPS | SFTP | SCP |
|------|-----|------|------|-----|
| 暗号化 | なし | TLS | SSH | SSH |
| ポート | 21（+データ用） | 21（+データ用） | 22 のみ | 22 のみ |
| NAT 越え | 困難 | 困難 | 容易 | 容易 |
| 認証方式 | ユーザー/パスワード | ユーザー/パスワード | SSH 鍵 / パスワード | SSH 鍵 / パスワード |
| 現場での推奨度 | 低（レガシー） | 中 | 高 | 高 |

**H-2. OpenSSH による SFTP サーバーの設定**
- OpenSSH の `Subsystem sftp internal-sftp` 設定を使い、FTP の代替として SFTP サーバーを設定する
- `ChrootDirectory` で SFTP ユーザーを特定ディレクトリに閉じ込め、vsftpd の chroot 設定と比較する
- FTP からSFTP への移行手順と、クライアント側の設定変更箇所をまとめる

---

*以上（vsftpd / ProFTPD 基本・発展課題）*
