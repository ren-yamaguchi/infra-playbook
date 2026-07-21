# 【ファイルサーバ + バックアップ基盤(Samba + vsftpd + rsyncd + Chrony)】環境構築手順書

---

## 1. ドキュメント情報

| 項目 | 内容 |
|------|------|
| 手順書名 | ファイルサーバ + バックアップ基盤(Samba + vsftpd + rsyncd + Chrony) |
| 作成日 | 2026-06-25 |
| バージョン | v1.0 |
| 対象環境 | AWS(EC2 4台、全台パブリックサブネット) |

> **改訂履歴**
>
> | バージョン | 日付 | 変更内容 |
> |-----------|------|---------|
> | v1.0 | 2026-06-25 | 初版作成 |
> | v2.0 | 2026-07-07 | 実機検証に基づき記述を修正。主な変更点:①Amazon Linux 2023特有のパッケージ差異へ対応(vsftpd確認用に`ftp`→`lftp`、rsyncd起動に`rsync-daemon`、cron利用に`cronie`を追加インストール) ②clientへの`samba-client`/`lftp`導入手順の追加漏れを修正 ③ホスト名`client.local`→`cl.local`、プレースホルダの`01`表記を整理 ④NTPのStratum値、vsftpdのchroot動作に関する解説の誤りを修正 ⑤確認⑤の日付を実行日ベースのプレースホルダ形式に変更 |

---

## 2. 目的・概要

### 2-1. 目的

本手順書では、**社内ファイル共有 + 差分バックアップ + 時刻同期** という、どんなインフラにも必ず存在する「縁の下のレイヤー」を一通り構築する。

- **Samba** によるWindows互換のSMBファイル共有
- **vsftpd** によるFTPファイル受け渡し基盤(chrootで安全に運用)
- **rsyncd** による日次の差分バックアップ(`--link-dest`で世代管理)
- **Chrony** による社内NTPサーバの構築(階層型時刻同期)

### 2-2. 構成概要(アーキテクチャ)

```
        ┌─────────────────────────────┐
        │   [cl.local]                │
        │   検証用クライアント        │
        │   ・smbclient で Samba 接続 │
        │   ・lftp で vsftpd 接続     │
        │   ・chrony クライアント     │
        └─────────────────────────────┘
                       │
           ┌───────────┼───────────┐
           │ SMB(445)  │ FTP(21)
           ▼           ▼
        ┌─────────────────────────────┐
        │   [fs.local]                │
        │   ファイルサーバ            │
        │   ・Samba (smbd)            │
        │   ・vsftpd                  │
        │   ・/srv/data に蓄積        │
        │   ・chrony クライアント     │
        └─────────────────────────────┘
                    │
                    │ 日次 cron で rsync push(差分)
                    │ rsync://bk.local/backup
                    ▼
        ┌─────────────────────────────┐
        │   [bk.local]                │
        │   バックアップサーバ        │
        │   ・rsyncd                  │
        │   ・/backup/YYYY-MM-DD/     │
        │     に世代別保存            │
        │   ・chrony クライアント     │
        └─────────────────────────────┘

        ┌─────────────────────────────┐
        │   [ntp.local]               │
        │   社内NTPサーバ             │
        │   ・Chrony(サーバモード)    │
        │   ・上位: AWS NTP           │
        │     (169.254.169.123)       │
        └─────────────────────────────┘
                ▲
                │ NTP(123/UDP)
                │
        fs / bk / client が参照
```

### 2-3. 完成イメージ(ゴール定義)

- [ ] client から `smbclient` で fs の Samba 共有にアクセスし、ファイルを読み書きできる
- [ ] client から `lftp` で fs の vsftpd に接続し、ファイルをアップロード/ダウンロードできる
- [ ] vsftpd のローカルユーザーが chroot され、ホームディレクトリ外に出られない
- [ ] fs から bk へ cron で日次 rsync が走り、`/backup/YYYY-MM-DD/` に世代別ディレクトリができる
- [ ] 2日目以降のバックアップは `--link-dest` により差分のみ転送され、未変更ファイルはハードリンクで共有される
- [ ] fs / bk / client の3台が ntp を参照し、時刻が同期している
- [ ] bk を停止した状態で rsync を実行すると失敗し、ログに記録される

---

### 2-4. 使用ミドルウェア解説

本構成で登場するミドルウェアを4つ紹介する。それぞれの役割・ジャンル・仕組み・この構成での役割・学習ポイントを押さえておくことで、手順の「なぜ」が理解しやすくなる。

---

#### ① Samba

**役割**

WindowsのSMB(Server Message Block)プロトコルをLinux上で実装したソフトウェア。WindowsクライアントからLinuxサーバのディレクトリをネットワークドライブとしてマウントしたり、ファイルを読み書きしたりできる。

**ジャンル**

ファイル共有サーバ(NAS相当)。

**仕組みのイメージ**

Windowsの「ネットワークドライブの割り当て」が動く仕組みはSMBプロトコル。Sambaはそのサーバ側実装。クライアントは `\\サーバ名\共有名` でアクセスし、Sambaがファイルシステム操作をSMBの応答として返す。ユーザー認証はSamba独自のパスワードDB(tdbsam)を持ち、Linuxのパスワードとは別管理になっている。

```
クライアント ──SMB(445/TCP)──▶ smbd(Samba)
                                   │
                             /srv/data/public  ← Linuxのディレクトリ
```

**この構成での役割**

fs が Samba サーバとして動作し、client から `smbclient` を使ってファイルを読み書きする。共有は `public`(全メンバー)と `group01`(グループ限定)の2種類を定義し、ユーザー・グループベースのアクセス制御を実装する。

**学習ポイント**

- LinuxパスワードとSambaパスワードは別管理(`smbpasswd`)
- SGIDビット(`chmod 2775`)による共有ディレクトリのグループ継承
- SMB1を無効化する理由(WannaCry等の脆弱性対策)
- `hosts allow` / `hosts deny` によるSamba層のアクセス制御

---

#### ② vsftpd

**役割**

FTPサーバの実装の一つ。"Very Secure FTP Daemon" の略で、セキュリティを重視した設計が特徴。chroot機能でユーザーをホームディレクトリに閉じ込め、ホワイトリスト方式でアクセスユーザーを絞り込める。

**ジャンル**

ファイル転送サーバ(FTPサーバ)。

**仕組みのイメージ**

FTPは制御用コネクション(21/TCP)とデータ用コネクション(動的ポート)の2本を使う古典的なプロトコル。パッシブモードではサーバが待受ポートを開き、クライアントがそこへ接続することでNAT/FW環境でも動作させやすくする。

```
クライアント ──制御(21/TCP)──▶ vsftpd
            ──データ(30000-30100)──▶ vsftpd
                                       │
                               /home/ftpuser01/upload
```

**この構成での役割**

fs に vsftpd を立て、client からFTPでファイルを受け渡す。`chroot_local_user=YES` でユーザーをホームディレクトリに閉じ込め、ホワイトリスト(`userlist_deny=NO`)で許可ユーザーのみログイン可能にする。

**学習ポイント**

- chrootの仕組みと「ホームディレクトリ自体を書き込み不可にする」理由
- アクティブモードとパッシブモードの違いと、AWS環境でパッシブが必要な理由
- `userlist_deny=NO`(ホワイトリスト) vs `userlist_deny=YES`(ブラックリスト)の違い
- FTPがセキュリティ上の懸念を持つ理由(平文通信)と、VPC内限定運用の重要性

---

#### ③ rsyncd

**役割**

`rsync` をデーモンモードで動かし、ネットワーク越しにファイルを差分同期・転送するためのサーバ。`--link-dest` オプションと組み合わせることで、ディスク消費を抑えた世代管理バックアップを実現できる。

**ジャンル**

ファイル同期・バックアップサーバ。

**仕組みのイメージ**

通常の `rsync` コマンドはSSH経由でリモートにファイルを送るが、rsyncd はデーモンとして常駐し、専用ポート(873/TCP)で待ち受ける。クライアントは `rsync://ホスト/モジュール名` という形式でアクセスし、モジュールごとに独立したパス・権限・認証を設定できる。

```
fs ──rsync(873/TCP)──▶ rsyncd(bk)
                           │
                     /backup/
                       2026-06-24/ ← 前日(ハードリンク中心)
                       2026-06-25/ ← 今日(差分のみ実ファイル)
```

**この構成での役割**

bk に rsyncd を構築し、fs から毎日 cron でバックアップを受け取る。`--link-dest` で昨日のスナップショットを参照し、変更のあったファイルのみ実体コピー・変更のないファイルはハードリンクで共有する世代管理を実現する。

**学習ポイント**

- `rsync` コマンド単体 vs rsyncd(デーモンモード)の使い分け
- `--link-dest` の動作とハードリンクの仕組み
- rsyncd独自の仮想ユーザー認証(`secrets file`)
- `use chroot = yes` を使う場合に `--link-dest` を相対パスで指定する理由

---

#### ④ Chrony

**役割**

NTP(Network Time Protocol)クライアント/サーバの実装。サーバ間の時刻を同期するために使う。古くからある `ntpd` の後継として開発され、起動直後の素早い同期や、仮想環境・クラウド環境への適性が高い。

**ジャンル**

時刻同期サービス(NTPサーバ/クライアント)。

**仕組みのイメージ**

NTPはStratum(階層)という概念を持つ。原子時計やGPSがStratum 0、それに直接つながるサーバがStratum 1、その参照先がStratum 2…と階層が深くなる。本構成では以下の3階層になる。

```
AWS Time Sync (169.254.169.123) ← Stratum 3相当
        │ NTP(123/UDP)
        ▼
   ntp(Chronyサーバ)            ← Stratum 4
        │ NTP(123/UDP)
        ▼
   fs / bk / client(Chronyクライアント) ← Stratum 5
```

**この構成での役割**

ntp をChronyサーバとして構築し、上位に AWS Time Sync Service(`169.254.169.123`)を参照させる。fs・bk・client の3台はChronyクライアントとして ntp を参照し、VPC内で統一された時刻を持つ。

**学習ポイント**

- `ntpd` と `chrony` の違い(特にクラウド・仮想環境での優位性)
- `allow` ディレクティブでクライアントからの問い合わせを許可する仕組み
- `chronyc sources -v` の `^*` / `^+` / `^?` の読み方
- フォールバック(ntp が落ちた場合にAWS NTPへ直接向く)を残す理由

---

## 3. 前提条件・準備

### 3-1. AWS環境(起動済み前提)

以下が完了している前提とする:

- AWSアカウントを保有していること
- VPCが作成されており、CIDRは `172.31.0.0/16` であること(異なる場合は手順中の該当箇所を読み替え)
- EC2インスタンスが **4台起動済み** であること(全台 Amazon Linux 2023、全台パブリックサブネット)
- 全EC2にSSHログインできること
- 各EC2には **パブリックIPが付与されている** こと

> **注意:パブリックIPの変動について**
>
> EIPではなく通常のパブリックIPを使う前提のため、EC2を停止/起動するとパブリックIPが変わる。**プライベートIPは変わらない**ため、本構成の内部通信(NTP・SMB・FTP・rsync)はいずれもプライベートIP経由で組むので影響は受けない。ただし、SSHログイン時のIP指定は毎回確認すること。

### 3-2. 環境要件

#### 3-2-1. fs(ファイルサーバ)

| 項目 | 要件 |
|------|------|
| インスタンスタイプ | t3.small |
| OS | Amazon Linux 2023 |
| ファイル共有 | Samba(smbd, nmbd) |
| FTPサーバ | vsftpd |
| 時刻同期 | Chrony(クライアント) |
| ツール | rsync, telnet |

> **インスタンスタイプ選定理由**
>
> Samba(smbd/nmbd)とvsftpdが同居し、ファイルI/Oと複数デーモンの常駐が発生する。t3.micro(1GB RAM)では複数デーモンの同時稼働でメモリが窮屈になる可能性があるため、t3.small(2GB RAM)を選定。

#### 3-2-2. bk(バックアップサーバ)

| 項目 | 要件 |
|------|------|
| インスタンスタイプ | t3.micro |
| OS | Amazon Linux 2023 |
| バックアップ受け | rsyncd |
| 時刻同期 | Chrony(クライアント) |
| ツール | rsync |

> **インスタンスタイプ選定理由**
>
> 日次深夜の rsync 受信のみで、常時負荷は低い。処理はストレージI/O中心でCPU・メモリをほぼ消費しないため、t3.micro で十分。

#### 3-2-3. ntp(NTPサーバ)

| 項目 | 要件 |
|------|------|
| インスタンスタイプ | t3.micro |
| OS | Amazon Linux 2023 |
| 時刻同期 | Chrony(サーバモード) |
| ツール | chrony 標準コマンド |

> **インスタンスタイプ選定理由**
>
> NTPパケットへの応答のみで、処理は非常に軽量。t3.micro でも過剰スペックなほどだが、AWS最小構成として選定。

#### 3-2-4. client(検証用クライアント)

| 項目 | 要件 |
|------|------|
| インスタンスタイプ | t3.micro |
| OS | Amazon Linux 2023 |
| ツール | samba-client(smbclient), ftp, rsync, chrony(クライアント) |

> **インスタンスタイプ選定理由**
>
> 検証用コマンドを実行するだけで、サービスは何も常駐しない。t3.micro で十分。

### 3-3. セキュリティグループ設定

#### 3-3-1. fs(ファイルサーバ)

| タイプ | プロトコル | ポート範囲 | ソース | 目的 |
|-------|-----------|-----------|--------|------|
| SSH | TCP | 22 | マイIP | ローカルからSSHログイン |
| SMB | TCP | 445 | 172.31.0.0/16 | Samba接続(VPC内のみ) |
| FTP制御 | TCP | 21 | 172.31.0.0/16 | FTP制御コネクション(VPC内のみ) |
| FTPパッシブ | TCP | 30000-30100 | 172.31.0.0/16 | FTPパッシブモードのデータ転送用 |

> **解説:なぜFTPに広いポート範囲を開けるのか**
>
> FTPは制御用コネクション(21番)とは別に、データ転送用のコネクションを動的に張る古典的なプロトコル。パッシブモードではサーバ側が「このポート番号で待ってます」とクライアントに伝え、クライアントがそこへ接続する。
>
> サーバ側でどのポート範囲を使うかを `pasv_min_port` / `pasv_max_port` で指定し、その範囲をSGで開ける必要がある。本手順書では `30000-30100` の101ポートを確保する。

> **注意:本番運用ではSMB/FTPを 0.0.0.0/0 で開けない**
>
> SMBもFTPも認証情報が平文または弱い暗号で流れることがあるプロトコル。インターネットに晒すと総当たり攻撃の対象になるため、必ずVPC内またはVPN内に閉じる。本構成も `172.31.0.0/16` 限定にしている。

#### 3-3-2. bk(バックアップサーバ)

| タイプ | プロトコル | ポート範囲 | ソース | 目的 |
|-------|-----------|-----------|--------|------|
| SSH | TCP | 22 | マイIP | ローカルからSSHログイン |
| rsync | TCP | 873 | 172.31.0.0/16 | rsyncデーモン(VPC内のみ) |

#### 3-3-3. ntp(NTPサーバ)

| タイプ | プロトコル | ポート範囲 | ソース | 目的 |
|-------|-----------|-----------|--------|------|
| SSH | TCP | 22 | マイIP | ローカルからSSHログイン |
| NTP | UDP | 123 | 172.31.0.0/16 | NTP問い合わせ受付(VPC内のみ) |

> **解説:NTPはUDP**
>
> NTPはTCPではなくUDPの123番を使う。SG設定時にプロトコル選択を間違えないよう注意。

#### 3-3-4. client(検証用クライアント)

| タイプ | プロトコル | ポート範囲 | ソース | 目的 |
|-------|-----------|-----------|--------|------|
| SSH | TCP | 22 | マイIP | ローカルからSSHログイン |

> **解説:クライアントは外向きの通信のみなのでインバウンドはSSHのみ**
>
> clientは自分から fs・bk・ntp へ接続する側なので、外部から受け付けるポートは不要。

### 3-4. パラメータ整理表

> 以下のプレースホルダを自分の環境の値に置き換えながら手順を進めること。

| パラメータ | 意味 | 自環境の値 |
|---|---|---|
| `<FS_PRI>` | fs のプライベートIP | |
| `<BK_PRI>` | bk のプライベートIP | |
| `<NTP_PRI>` | ntp のプライベートIP | |
| `<CLIENT_PRI>` | client のプライベートIP | |
| `<SMB_USER>` | Samba接続用ユーザー(例: smbuser01) | |
| `<FTP_USER>` | FTP接続用ユーザー(例: ftpuser01) | |

### 3-5. ホスト名設計

| サーバ | ホスト名 | 役割 |
|---|---|---|
| ファイルサーバ | `fs.local` | Samba + vsftpd |
| バックアップサーバ | `bk.local` | rsyncd |
| NTPサーバ | `ntp.local` | Chrony サーバ |
| クライアント | `cl.local` | 検証用 |

> **解説:`.local` ドメインの扱い**
>
> 本手順書ではDNSサーバを立てないため、名前解決は全台の `/etc/hosts` に固定エントリを書く方式で行う。`.local` は内部用ドメインとして使うが、外部公開はしないので問題ない。

---

## 4. 構築手順(詳細)

> **注意事項**
> - コマンド中の `<山カッコ>` は自分の環境の値に置き換えること
> - 環境依存のパラメータ(IPアドレス等)は3-4節を参照
> - エラーが出た場合は「6. トラブルシューティング」を参照

### 4-1. 環境構築の流れ

1. 全サーバの初期設定と /etc/hosts 設定 (Step 0)
2. ntp: Chrony サーバ構築 (Step 1)
3. fs/bk/client: Chrony クライアント設定 (Step 2)
4. fs: Samba 構築 (Step 3)
5. fs: vsftpd 構築 (Step 4)
6. bk: rsyncd 構築 (Step 5)
7. fs: 日次バックアップ(cron + rsync)設定 (Step 6)

---

### Step 0: 全サーバ共通の初期設定

**目的:** 全4台で共通の初期設定を行う。**fs / bk / ntp / client のすべてで実施**する。

#### 0-1. 【全サーバで実施】rootへ昇格・OS更新・タイムゾーン設定・ホスト名設定

各サーバごとに自分のホスト名を設定すること。

```bash
sudo su -
dnf update -y
timedatectl set-timezone Asia/Tokyo

# 各サーバでホスト名を変える
# fsの場合
hostnamectl set-hostname fs.local
# bkの場合
hostnamectl set-hostname bk.local
# ntpの場合
hostnamectl set-hostname ntp.local
# clientの場合
hostnamectl set-hostname cl.local
```

#### 0-2. 【全サーバで実施】/etc/hosts の編集

全サーバで同じ内容を書く。

```bash
vi /etc/hosts
```

ファイル末尾に追記:

```
<FS_PRI>      fs.local
<BK_PRI>      bk.local
<NTP_PRI>     ntp.local
<CLIENT_PRI>  cl.local
```

---

### Step 1: ntp に Chrony サーバを構築

**目的:** 社内NTPサーバを構築し、上位として AWS NTP を参照する。**ntpで実施**する。

#### 1-1. 【ntpで実施】chrony のインストール状況確認

Amazon Linux 2023 ではデフォルトで chrony がインストール・起動している。

```bash
rpm -q chrony
systemctl status chronyd
```

#### 1-2. 【ntpで実施】chrony.conf の編集

```bash
cp /etc/chrony.conf /etc/chrony.conf.bak
vi /etc/chrony.conf
```

既存の内容を以下に置き換える(または該当行を編集):

```
# 上位NTPサーバとして AWS のNTPを指定
server 169.254.169.123 prefer iburst minpoll 4 maxpoll 4

# 念のためフォールバックとしてpoolも残す
pool 2.amazon.pool.ntp.org iburst

# ドリフトファイル
driftfile /var/lib/chrony/drift

# システムクロックの段階的補正
makestep 1.0 3

# RTC同期(AWS仮想環境では効果薄いがデフォルト)
rtcsync

# 自分自身に時刻同期を要求してくるクライアントを許可
allow 172.31.0.0/16

# ログディレクトリ
logdir /var/log/chrony
```

> **解説①:`169.254.169.123` は何者か**
>
> これはAWSが各EC2に提供している **Amazon Time Sync Service** のNTPエンドポイント。リンクローカルアドレス(169.254.0.0/16)なので、AWS内部からのみアクセス可能で、インターネットを経由しない。
>
> 安定性・精度ともに高く、AWS環境では基本的にこれを上位に使うのが定石。

> **解説②:`allow 172.31.0.0/16` の意味**
>
> chrony をNTP**サーバ**として動かすには、「どのクライアントからの問い合わせに応答するか」を明示する必要がある。デフォルトはローカルホストのみ(=サーバとして機能しない)。`allow` ディレクティブで応答対象を広げる。
>
> ここでVPC CIDR全体を許可することで、VPC内の他サーバが ntp を参照できるようになる。

> **解説③:`prefer iburst minpoll 4 maxpoll 4`**
>
> - `prefer`: 複数のサーバ指定がある場合、これを優先する
> - `iburst`: 起動直後に短い間隔で複数回問い合わせて、すばやく同期する
> - `minpoll 4 maxpoll 4`: 問い合わせ間隔を2^4=16秒に固定(短めにして反応を早く)

#### 1-3. 【ntpで実施】chronyd の再起動

```bash
systemctl restart chronyd
systemctl enable chronyd
```

#### 1-4. 【ntpで実施】同期状態の確認

```bash
chronyc sources -v
chronyc tracking
```

`chronyc sources -v` の出力で、`169.254.169.123` の行の先頭に `^*` (アスタリスク)が付いていれば、上位NTPと同期成功。

> **考えるポイント:`^*` `^+` `^-` `^?` の意味**
>
> chrony の sources 表示の先頭記号には意味がある:
> - `^*`: 現在同期に使っているソース
> - `^+`: 同期候補として有効
> - `^-`: 統計的に外れ値として除外中
> - `^?`: まだ評価中、または到達不能
>
> 安定運用時は1つだけ `*` が付き、他は `+` か空白になる。すべて `?` のままなら通信が成立していない。

---

### Step 2: fs / bk / client に Chrony クライアント設定

**目的:** ntp を参照する Chrony クライアントとして設定する。**fs / bk / client の3台で実施**する。

#### 2-1. 【fs・bk・clientで実施】chrony.conf の編集

```bash
cp /etc/chrony.conf /etc/chrony.conf.bak
vi /etc/chrony.conf
```

既存の内容を以下に置き換える:

```
# 社内NTPサーバ(ntp)を参照
server ntp.local prefer iburst minpoll 4 maxpoll 4

# フォールバック(ntpが落ちたとき用)
server 169.254.169.123 iburst

driftfile /var/lib/chrony/drift
makestep 1.0 3
rtcsync
logdir /var/log/chrony
```

> **解説:なぜフォールバックを残すのか**
>
> 社内NTP(ntp)に集約する設計だが、ntp自体が停止すると全サーバの時刻同期が止まる。学習用途の単純構成では問題が顕在化しにくいが、本番ではNTPサーバ自体を冗長化するか、上位ソースを直接参照できるフォールバックを残すのが定石。
>
> 本手順書ではフォールバックとして AWS NTP を残し、ntp が落ちても時刻同期が完全には止まらないようにしている。

#### 2-2. 【fs・bk・clientで実施】chronyd の再起動

```bash
systemctl restart chronyd
systemctl enable chronyd
```

#### 2-3. 【fs・bk・clientで実施】同期状態の確認

```bash
chronyc sources -v
```

`ntp.local` の行に `^*` が付いていれば、ntp 経由での同期成功。

```bash
chronyc tracking
# Reference ID: が ntp のIPになっていればOK
```

---

### Step 3: fs に Samba を構築

**目的:** SMB共有を提供するファイルサーバを構築する。**fsで実施**する。

#### 3-1. 【fsで実施】Samba のインストール

```bash
dnf install -y samba samba-client
```

#### 3-2. 【fsで実施】共有用ディレクトリとグループ・ユーザーの作成

```bash
# 共有用のシステムグループを作る
groupadd smbgroup

# Samba接続用ユーザー(例として smbuser01 を1名作成)
useradd -M -s /sbin/nologin -G smbgroup smbuser01
# アカウントがロック状態になることを避けるため、Linuxパスワードも設定しておく
passwd smbuser01

# 共有ディレクトリ(全員用 + グループ別)
mkdir -p /srv/data/public
mkdir -p /srv/data/group01

# 権限設定
chown -R root:smbgroup /srv/data/public
chmod 2775 /srv/data/public

chown -R root:smbgroup /srv/data/group01
chmod 2770 /srv/data/group01
```

> **解説①:`-M -s /sbin/nologin` の意味**
>
> Sambaユーザーは「SMBプロトコル経由でアクセスするためだけのユーザー」であり、SSHログインしたりホームディレクトリで作業したりしない。よって:
> - `-M`: ホームディレクトリを作らない
> - `-s /sbin/nologin`: 対話シェル禁止
>
> これにより万一パスワードが漏れても、SSH等での悪用ができない最小権限ユーザーになる。

> **解説②:`chmod 2775` の `2` の意味(SGIDビット)**
>
> 通常のパーミッションは3桁(例: 775)だが、先頭に `2` を付けると **SGIDビット** が立つ。
>
> 効果:そのディレクトリ内で新規作成されたファイル・ディレクトリは、自動的にディレクトリの所有グループ(ここでは `smbgroup`)を引き継ぐ。
>
> これがないと、ユーザーAが作ったファイルはAのプライマリグループになり、ユーザーBから書き込めない事態が起きる。共有ディレクトリでは SGID を立てるのが定石。

#### 3-3. 【fsで実施】Sambaパスワードの設定

LinuxユーザーのパスワードとSambaパスワードは**別管理**。Samba用パスワードを設定する。

```bash
smbpasswd -a smbuser01
# New SMB password: と聞かれるので、入力(Linuxパスワードと別でよい)
# Retype new SMB password: 確認入力
```

> **解説:Samba独自のパスワードDB**
>
> Sambaは内部に独自のユーザーDB(`/var/lib/samba/private/passdb.tdb`)を持ち、ここで認証する。`smbpasswd -a` で「Linuxユーザーをこの内部DBに登録」する操作になる。
>
> Linuxユーザーが存在しないユーザー名で `smbpasswd -a` するとエラーになるため、`useradd` が前提。

#### 3-4. 【fsで実施】smb.conf の編集

```bash
cp /etc/samba/smb.conf /etc/samba/smb.conf.bak
vi /etc/samba/smb.conf
```

ファイル全体を以下に置き換える:

```
[global]
   workgroup = WORKGROUP
   server string = fs Samba Server
   netbios name = FS
   security = user
   passdb backend = tdbsam
   map to guest = Bad User

   # ログ
   log file = /var/log/samba/log.%m
   max log size = 50

   # SMBプロトコルバージョン(SMB1は無効化、SMB2以降のみ)
   server min protocol = SMB2

   # 接続制限(VPC内のみ)
   hosts allow = 172.31. 127.
   hosts deny = 0.0.0.0/0

[public]
   comment = Public Share for all smbgroup members
   path = /srv/data/public
   browseable = yes
   writable = yes
   valid users = @smbgroup
   create mask = 0664
   directory mask = 2775

[group01]
   comment = Group01 Private Share
   path = /srv/data/group01
   browseable = yes
   writable = yes
   valid users = @smbgroup
   create mask = 0660
   directory mask = 2770
```

> **解説①:`security = user` と `passdb backend = tdbsam`**
>
> - `security = user`: 接続時にユーザー名+パスワードでの認証を要求する(共有レベル認証ではなくユーザーレベル認証)
> - `passdb backend = tdbsam`: ユーザーDB形式として TDB Sam(`tdbsam`)を使う。Samba 4 系の標準

> **解説②:`server min protocol = SMB2` の重要性**
>
> SMB1(CIFS)は WannaCry ランサムウェア等で悪用された深刻な脆弱性を持つ、現在は使用非推奨のプロトコル。新しいクライアントはSMB2以降で問題なく動くため、サーバ側でSMB1を無効化しておく。

> **解説③:`hosts allow` / `hosts deny`**
>
> Samba層でもアクセス制御を二重化する。SGはAWSレイヤー、`hosts allow` はSambaアプリケーションレイヤー。多層防御の考え方。
>
> 書き方が独特で、`172.31.` のように末尾ドットでネットワーク前方一致を表す(これはSamba独自の記法)。

> **解説④:`create mask` / `directory mask`**
>
> SMB経由で新規作成されたファイル/ディレクトリのパーミッションを、ここで指定した値で**マスク(AND演算)**する。
> - `create mask = 0660`: グループまで読み書き、その他はアクセス不可
> - `directory mask = 2770`: SGIDを立てつつ、グループまで読み書き、その他は不可
>
> group01共有のほうは「グループメンバーだけが見える」状態にしている。

#### 3-5. 【fsで実施】設定ファイルの構文チェック

```bash
testparm
# 「Loaded services file OK.」と出ればOK
# Enterを押すと詳細表示
```

#### 3-6. 【fsで実施】Samba の起動

```bash
systemctl start smb nmb
systemctl enable smb nmb
systemctl status smb
```

> **解説:smb と nmb の役割分担**
>
> - `smbd`: ファイル共有本体(SMBプロトコル処理)
> - `nmbd`: NetBIOS名前解決サービス(古いWindowsクライアント向け)
>
> SMB2以降のモダンなクライアントだけ相手にするなら nmbd は厳密には不要だが、起動しておいて困ることはないので両方有効にする。

---

### Step 4: fs に vsftpd を構築

**目的:** ローカルユーザーFTP(chroot有効)を構築する。**fsで実施**する。

#### 4-1. 【fsで実施】vsftpd と FTPクライアントのインストール

```bash
dnf install -y vsftpd lftp
```

> **注意:`ftp` パッケージは存在しない**
>
> Amazon Linux 2023 のリポジトリには、伝統的な `ftp` コマンド(netkit-ftp系)のパッケージが存在しない。上流のFedora/RHEL9系でも同様の理由でセキュリティ上の懸念からリポジトリ提供が終了しているため、`dnf install -y ftp` は `No match for argument: ftp` エラーで失敗する。
>
> 代わりに、同等の対話コマンド(`ls` / `get` / `put` / `cd` / `bye` など)を持つ後継クライアント `lftp` を動作確認用にインストールする。`lftp` はデフォルトでパッシブモード接続を行うため、後述の動作確認手順もシンプルになる。

#### 4-2. 【fsで実施】FTP用ユーザーの作成

```bash
useradd ftpuser01
passwd ftpuser01
# パスワードを設定

# ホームディレクトリ配下にアップロード用ディレクトリを作る
mkdir -p /home/ftpuser01/upload
chown ftpuser01:ftpuser01 /home/ftpuser01/upload
chmod 700 /home/ftpuser01/upload

# chrootの仕様上、ホームディレクトリ自体は書き込み不可にする必要がある
chmod 555 /home/ftpuser01
```

> **解説:なぜホームディレクトリを書き込み不可にするか**
>
> vsftpd の chroot 機能は、セキュリティ強化のため「**chroot対象のディレクトリ自体は書き込み不可でなければ起動を拒否する**」という仕様がある(`500 OOPS: vsftpd: refusing to run with writable root inside chroot()` というエラー)。
>
> 対策として:
> - ホームディレクトリ(`/home/ftpuser01`)は読み込み専用(`555`)にする
> - その配下に書き込み可能な `upload/` ディレクトリを作る
>
> ユーザーはログイン直後は読み専用領域に居て、`cd upload` した先で書き込みできる構造になる。

#### 4-3. 【fsで実施】vsftpd.conf の編集

```bash
cp /etc/vsftpd/vsftpd.conf /etc/vsftpd/vsftpd.conf.bak
vi /etc/vsftpd/vsftpd.conf
```

主な変更点(該当行を以下のように編集):

```
# 匿名FTPは無効化
anonymous_enable=NO

# ローカルユーザーのログインを許可
local_enable=YES

# 書き込み許可
write_enable=YES

# 新規ファイル作成時のumask
local_umask=022

# ログ
xferlog_enable=YES
xferlog_file=/var/log/xferlog
xferlog_std_format=YES

# PASVモード(パッシブ)を有効化
pasv_enable=YES
pasv_min_port=30000
pasv_max_port=30100

# chroot 設定:ローカルユーザーをホームディレクトリに閉じ込める
chroot_local_user=YES
allow_writeable_chroot=NO

# リスナーモード(systemd管理)
listen=YES
listen_ipv6=NO

# ユーザーごとの設定ディレクトリ(必要時用)
userlist_enable=YES
userlist_deny=NO
userlist_file=/etc/vsftpd/user_list
```

> **解説①:`chroot_local_user=YES` + `allow_writeable_chroot=NO`**
>
> この2つの組み合わせが「ホームディレクトリ外に出られない、かつchrootディレクトリ自体は書き込み不可」というセキュアな構成。前述の通り、ホームディレクトリは `555` にしておく必要がある。

> **解説②:`userlist_enable=YES` + `userlist_deny=NO`**
>
> `userlist_deny=NO` の場合、`userlist_file` に書かれたユーザーだけがログインを許可される(ホワイトリスト方式)。
>
> 逆に `userlist_deny=YES`(デフォルト)だと、`userlist_file` に書かれたユーザーは拒否される(ブラックリスト方式)。
>
> 本構成ではホワイトリスト方式にして、明示的に許可したユーザーのみFTPを使えるようにする。

#### 4-4. 【fsで実施】user_list の編集

```bash
vi /etc/vsftpd/user_list
```

ファイルを全削除し、許可ユーザーのみ書く:

```
ftpuser01
```

> **注意:既存のuser_listを上書きする**
>
> デフォルトの `user_list` には `root` などの危険ユーザーが列挙されている(ブラックリスト用途のため)。ホワイトリスト方式に切り替えたので、許可したいユーザーだけを書く。

#### 4-5. 【fsで実施】vsftpd の起動

```bash
systemctl start vsftpd
systemctl enable vsftpd
systemctl status vsftpd
```

---

### Step 5: bk に rsyncd を構築

**目的:** rsyncデーモンモードでバックアップ受け口を構築する。**bkで実施**する。

#### 5-1. 【bkで実施】rsync のインストール状況確認

Amazon Linux 2023 では rsync(クライアント機能)は標準で入っている。

```bash
rpm -q rsync
```

入っていなければ `dnf install -y rsync`。

> **注意:`rsync-daemon` パッケージも別途必要**
>
> `rsync` パッケージには `rsync` コマンド本体(クライアント機能)のみが含まれ、デーモンモードで起動するための systemd ユニットファイル `rsyncd.service` は別パッケージ `rsync-daemon` に分離されている。これは RHEL8/9系(Amazon Linux 2023 もこの系統)で行われたパッケージ分割で、rsyncをSSH経由のクライアントとしてのみ使う場合はデーモン機能が不要なため、最小構成にする目的がある。
>
> 本手順書では bk を rsyncd(デーモンモード)として構築するため、以下を必ず実施する。

```bash
rpm -q rsync-daemon
# 入っていなければ
dnf install -y rsync-daemon
```

#### 5-2. 【bkで実施】バックアップ格納用ディレクトリの作成

```bash
mkdir -p /backup
chown root:root /backup
chmod 755 /backup
```

#### 5-3. 【bkで実施】rsyncd.conf の作成

```bash
vi /etc/rsyncd.conf
```

以下の内容を記述:

```
# 全体設定
uid = root
gid = root
use chroot = yes
max connections = 4
pid file = /var/run/rsyncd.pid
log file = /var/log/rsyncd.log

# モジュール定義: バックアップ受け口
[backup]
    path = /backup
    comment = Backup repository from fs
    read only = no
    list = yes
    hosts allow = 172.31.0.0/16
    hosts deny = *
    auth users = rsyncuser
    secrets file = /etc/rsyncd.secrets
```

> **解説①:rsyncd の「モジュール」とは**
>
> `[backup]` のような角括弧で囲まれたセクションが「モジュール」。クライアントから `rsync://bk.local/backup` のようなURL形式でアクセスされる際の `backup` 部分がこれにあたる。
>
> 1つの rsyncd で複数モジュールを定義でき、それぞれに別パス・別権限を割り当てられる。

> **解説②:`use chroot = yes` の意味**
>
> rsyncデーモンが受信時に、モジュールの `path` に chroot する。これにより、シンボリックリンク等を悪用したパス外アクセスを防ぐ。

> **解説③:`auth users` + `secrets file`**
>
> rsyncdは独自のユーザー認証機構を持つ(Linuxユーザーとは別)。
> - `auth users`: モジュールへのアクセスを許可するユーザー名(rsyncd内部の仮想ユーザー)
> - `secrets file`: そのユーザーのパスワードを `ユーザー名:パスワード` 形式で書いたファイル
>
> SSH経由の rsync ではなく rsyncデーモンモードを使う場合、この認証が標準的。

#### 5-4. 【bkで実施】認証ファイルの作成

```bash
vi /etc/rsyncd.secrets
```

```
rsyncuser:RsyncP@ss1234
```

```bash
# パーミッションは必ず600(他人に読まれるとパスワードが漏れる)
chmod 600 /etc/rsyncd.secrets
chown root:root /etc/rsyncd.secrets
```

> **注意:`secrets file` のパーミッションは600必須**
>
> rsyncdはパーミッションが緩い(他ユーザーから読める)secretsファイルを検出すると、起動を拒否するか警告を出す。必ず `600` にする。

#### 5-5. 【bkで実施】rsyncd の起動

Amazon Linux 2023 では systemd ユニットファイルが提供されている。

```bash
systemctl start rsyncd
systemctl enable rsyncd
systemctl status rsyncd
```

ポート確認:

```bash
ss -lntp | grep 873
# *:873 で LISTEN していればOK
```

---

### Step 6: fs に日次バックアップ(cron + rsync)を設定

**目的:** fs の `/srv/data` を毎日 bk に rsync で送る。`--link-dest` で世代管理する。**fsで実施**する。

#### 6-1. 【fsで実施】rsyncパスワードファイルの作成

クライアント側でも認証パスワードを書いたファイルが必要(対話入力を避けるため)。

```bash
echo 'RsyncP@ss1234' > /root/.rsync.pass
chmod 600 /root/.rsync.pass
```

#### 6-2. 【fsで実施】バックアップスクリプトの作成

```bash
vi /usr/local/bin/daily_backup.sh
```

以下を記述:

```bash
#!/bin/bash
# 日次バックアップスクリプト(--link-dest で世代管理)

set -u

# 設定
SRC=/srv/data/
DEST_HOST=bk.local
DEST_MODULE=backup
RSYNC_USER=rsyncuser
PASS_FILE=/root/.rsync.pass
LOG_FILE=/var/log/daily_backup.log

# 日付
TODAY=$(date +%Y-%m-%d)
YESTERDAY=$(date -d 'yesterday' +%Y-%m-%d)

# 転送先パス(rsyncd URL形式)
DEST_TODAY="rsync://${RSYNC_USER}@${DEST_HOST}/${DEST_MODULE}/${TODAY}/"
LINK_DEST_PATH="../${YESTERDAY}"

echo "[$(date '+%Y-%m-%d %H:%M:%S')] Backup start: ${TODAY}" >> "${LOG_FILE}"

# rsync 実行
rsync -av --delete \
    --link-dest="${LINK_DEST_PATH}" \
    --password-file="${PASS_FILE}" \
    "${SRC}" "${DEST_TODAY}" \
    >> "${LOG_FILE}" 2>&1

RC=$?
if [ ${RC} -eq 0 ]; then
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] Backup success: ${TODAY}" >> "${LOG_FILE}"
else
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] Backup FAILED: ${TODAY} (rc=${RC})" >> "${LOG_FILE}"
fi

exit ${RC}
```

実行権限を付与:

```bash
chmod 755 /usr/local/bin/daily_backup.sh
```

> **解説①:`--link-dest` の動作**
>
> rsyncに `--link-dest=PATH` を指定すると、転送先で「PATHに既に同じ内容のファイルがあれば、コピーせずハードリンクで参照する」という挙動になる。
>
> 例: 昨日のバックアップが `/backup/2026-06-24/` にあるとき、今日 `/backup/2026-06-25/` に取る際に `--link-dest=../2026-06-24` を指定すると:
> - 昨日から変わっていないファイル → 昨日のファイルへのハードリンクとして格納(ディスク消費ほぼゼロ)
> - 変わったファイル → 通常コピー(新しい内容で別ファイルとして格納)
>
> 結果:**毎日完全な世代スナップショットがあるのに、ディスク消費は差分相当だけ**という、商用バックアップツールでもお馴染みの仕組みが実現する。

> **解説②:なぜ `LINK_DEST_PATH` は相対パスか**
>
> rsyncデーモンは `use chroot = yes` でモジュールパス(`/backup`)に chroot している。chroot内では `/backup` は見えず、ルートが `/` になっている。よって絶対パスで `/backup/2026-06-24` と書くと「chroot内のルート直下にそんなパスはない」と言われる。
>
> 相対パス `../2026-06-24` にすると、転送先(`/backup/2026-06-25/`)の親(`/backup/`)を起点として正しく解決される。これは rsyncd の `--link-dest` 利用時の定番ハマりどころ。

> **解説③:`--delete` の意味**
>
> 転送元から消えたファイルを、転送先からも削除する。これがないと「過去に存在したが削除されたファイル」がバックアップに残り続け、本物のミラーにならない。
>
> ただし `--link-dest` と組み合わせているので、削除されたファイルは「過去日のスナップショット」には残る。「最新スナップショットでは消えているが、昨日のスナップショットには残っている」という、まさにバックアップらしい挙動になる。

#### 6-3. 【fsで実施】テストデータの準備

```bash
# Sambaの共有用ディレクトリにテストファイルを置く
echo "Hello from fs at $(date)" > /srv/data/public/hello.txt
mkdir -p /srv/data/public/docs
echo "Sample document" > /srv/data/public/docs/sample.txt
```

#### 6-4. 【fsで実施】手動でバックアップ実行・確認

cron に登録する前に、スクリプトが正しく動くかを確認する。

```bash
/usr/local/bin/daily_backup.sh
echo "Exit code: $?"
cat /var/log/daily_backup.log
```

#### 6-5. 【fsで実施】cron への登録

Amazon Linux 2023 ではcron機能を提供する `cronie` パッケージがデフォルトでインストールされていない(Amazon Linux 2ではプリインストール・起動済みだったが、AL2023はより最小構成のベースイメージになっている)。まずインストールと起動を行う。

```bash
dnf install -y cronie
systemctl enable --now crond
```

```bash
crontab -e
```

以下を追記:

```
# 毎日 02:00 に日次バックアップ
0 2 * * * /usr/local/bin/daily_backup.sh
```

> **考えるポイント:なぜ深夜2時か**
>
> バックアップは「利用が少ない時間帯」に走らせるのが定石。日付が変わって日次集計バッチが走り終わった後、業務開始前、という時間帯として深夜2〜4時が選ばれることが多い。
>
> 学習用途では時間帯は何でもよいが、`date +%Y-%m-%d` を使う以上、**日付境界をまたぐタイミングを避ける**配慮はしておくとよい(0時直前に始めて0時直後に終わると、開始時と終了時で日付が変わってログが分かりにくくなる)。

---

## 5. 動作確認・検証

> 構築完了後、以下の確認をすべてパスしたら構築成功とみなす。

### 5-1. 確認チェックリスト

- [ ] **確認①**: ntp が AWS NTP と同期し、他3台が ntp と同期している
- [ ] **確認②**: client から Samba 共有にアクセスし、ファイルを読み書きできる
- [ ] **確認③**: client から FTP で fs にログイン、ファイル送受信できる
- [ ] **確認④**: fs から bk へ rsync が成功し、世代別ディレクトリができている
- [ ] **確認⑤**: 2日目のバックアップで `--link-dest` によりハードリンクが作られている
- [ ] **確認⑥**: bk を停止すると rsync が失敗する(障害シミュレーション)

---

### 確認①: 時刻同期の確認

```bash
# ntpで
chronyc sources -v
# 169.254.169.123 の先頭に ^* が付いていればOK

chronyc tracking
# ntp自身のStratumは4程度で表示されればOK(AWS Time Sync=Stratum3相当 → ntp=Stratum4)
```

```bash
# fs・bk・clientで
chronyc sources -v
# ntp.local の先頭に ^* が付いていればOK
```

> **考えるポイント:Stratum(階層)とは**
>
> NTPには「Stratum」という時刻精度の階層概念がある:
> - Stratum 0: 原子時計やGPS(物理的な時刻源)
> - Stratum 1: Stratum 0 に直接つながるNTPサーバ
> - Stratum 2: Stratum 1 を参照するNTPサーバ
> - ...
>
> 階層が深くなるほど精度が下がる(理論上)。AWS NTP は Stratum 3 程度で、それを参照する ntp は Stratum 4、ntpを参照する fs 等は Stratum 5 になる。一般的に Stratum 15 を超えると無効扱い。

---

### 確認②: Samba接続テスト

```bash
# clで(smbclientが未導入の場合)
dnf install -y samba-client
```

```bash
# client から
smbclient -L //fs.local/ -U smbuser01
# Samba のパスワードを入力
# 共有一覧(public, group01)が表示されればOK
```

具体的なファイル操作:

```bash
# client から public 共有に接続
smbclient //fs.local/public -U smbuser01
# プロンプトが smb: \> になる

# 以下、smbプロンプト内で
ls
# Step 6-3 で作った hello.txt が見えるはず

# ファイルをローカルにダウンロード
get hello.txt /tmp/hello.txt

# ローカルのファイルをアップロード
!echo "uploaded from client" > /tmp/upload_test.txt
put /tmp/upload_test.txt upload_test.txt

# 確認
ls

exit
```

fs側で確認:

```bash
# fsで
ls -l /srv/data/public/
# upload_test.txt が増えていればOK
# 所有グループが smbgroup になっていることも確認(SGIDの効果)
```

---

### 確認③: FTP接続テスト

```bash
# clで(lftpが未導入の場合)
dnf install -y lftp
```

```bash
# client から
lftp ftpuser01@fs.local
# Password: 設定したパスワード
# ログインに成功するとプロンプトが lftp ftpuser01@fs.local:~> になる
```

> **注意:プロンプトが表示されても、認証に成功したとは限らない**
>
> `lftp` は接続を遅延評価するため、`lftp ftpuser01@fs.local` を実行した直後は実際にはまだ認証(ログイン)を行っていない。パスワードを間違えていても、この時点ではエラーにならず `lftp ftpuser01@fs.local:~>` のプロンプトが表示されてしまう。
>
> 実際の認証は `cd` や `ls` など、サーバへの通信が必要な最初のコマンドを入力したタイミングで行われる。そのため、パスワードが間違っている場合は `cd upload` 等の実行時に初めて `Login failed: 530 Login incorrect.` として失敗が表面化する。プロンプトが出た=ログイン成功、と誤解しないこと。

lftpプロンプト内で:

```bash
# 現在のディレクトリ確認
pwd
# /home/ftpuser01 と表示されるが、chrootされているので実際のパスは隠蔽されている

# uploadディレクトリへ移動
cd upload

# ローカルでテストファイルを準備し、転送
!echo "ftp test" > /tmp/ftp_test.txt
put /tmp/ftp_test.txt

# 一覧表示
ls

# chroot確認:親ディレクトリに出られないことを確認
cd /
ls
# / でも chroot 内のルートに居続けることを確認

bye
```

> **解説:ここでの `/` はLinux実機のルートではない**
>
> `cd /` で移動しているのは、Linux実機の本当の `/`(ルートファイルシステム)ではなく、**chroot内での仮想的なトップディレクトリ**である。vsftpdが `chroot_local_user=YES` によって、ログイン時に `ftpuser01` から見える世界を `/home/ftpuser01` に閉じ込めているため、FTPセッションの中で `/` と表示されているのは実際には `/home/ftpuser01` を指している。
>
> そのため `ls` の結果が `upload` ディレクトリのみで、`bin` / `etc` / `var` など本来のLinuxルート直下のディレクトリが一切見えていなければ、chrootが正しく機能している証拠になる。逆にこれらの実ディレクトリが見えてしまう場合は、`chroot_local_user=YES` が(コメントアウトされたまま等で)有効になっていない可能性が高い。

fs側で確認:

```bash
# fsで
ls -l /home/ftpuser01/upload/
# ftp_test.txt が転送されていればOK
```

> **解説:パッシブモードについて**
>
> 古典的FTPには「アクティブモード」と「パッシブモード」がある。AWS環境のように間にNAT/SGがある場合、サーバから逆方向にコネクションを張るアクティブモードは破綻しやすい。パッシブモード(サーバが待ち受け、クライアントがそこに接続)が現代では標準。
>
> `lftp` はデフォルトでパッシブモードを使用するため、明示的な切り替え操作は不要。(旧来の `ftp` コマンドはデフォルトでアクティブモードになることが多く、`passive` コマンドで切り替える必要があった。)

---

### 確認④: rsync バックアップの動作確認

Step 6-4 を既に実施していれば、bkに1世代目が出来ている。bkで確認:

```bash
# bkで
ls -l /backup/
# 2026-06-25 のような日付ディレクトリができていればOK

ls -l /backup/$(date +%Y-%m-%d)/public/
# hello.txt や docs/ がコピーされていればOK

cat /backup/$(date +%Y-%m-%d)/public/hello.txt
```

---

### 確認⑤: `--link-dest` によるハードリンク確認

2日目のバックアップを擬似的に実行する。日付を変えて検証するため、スクリプトを少しいじってもよいが、ここでは**日付ディレクトリを手動で作って疑似的に検証**する。

> **プレースホルダについて**
>
> 以下の `<DAY1>` は「Step 6-4で実際にバックアップを実行した日付」、`<TOMORROW>` は「その翌日相当として検証に使う任意の日付」を表すプレースホルダ。まず bk で実際の日付ディレクトリ名を確認してから、下記コマンド中の `<DAY1>` `<TOMORROW>` を**すべて**その値に置き換えて実行すること(1箇所でも置き換え忘れると正しく動作しない)。
>
> ```bash
> # bkで、Step 6-4で実際に作成された日付ディレクトリ名を確認
> ls /backup/
> # 例: 2026-07-07 のようなディレクトリが表示される → これが <DAY1>
> ```

簡単な方法として、**日を改めて翌日に実行**するのが最もリアル。学習中にすぐ試したい場合は以下の手順で確認できる:

```bash
# fsで(daily_backup.shのTODAY/YESTERDAYをテスト用に書き換えて再実行する例)
# /usr/local/bin/daily_backup.sh を一時的にコピーして
cp /usr/local/bin/daily_backup.sh /tmp/daily_backup_test.sh
sed -i 's|TODAY=$(date +%Y-%m-%d)|TODAY=<TOMORROW>|' /tmp/daily_backup_test.sh
sed -i 's|YESTERDAY=$(date -d .yesterday. +%Y-%m-%d)|YESTERDAY=<DAY1>|' /tmp/daily_backup_test.sh
bash /tmp/daily_backup_test.sh

# bkで確認
ls -l /backup/
# <DAY1> と <TOMORROW> の両方があるはず

# ハードリンク確認:同じiノードを共有しているか
ls -i /backup/<DAY1>/public/hello.txt
ls -i /backup/<TOMORROW>/public/hello.txt
# 先頭の数字(iノード番号)が同じならハードリンク成功

# リンク数も確認
stat /backup/<TOMORROW>/public/hello.txt
# Links: 2 と表示されていればハードリンクされている証拠
```

> **考えるポイント:同じファイルなのに2世代分?**
>
> ハードリンクは「同じiノード(=同じファイル実体)に複数の名前を付ける」仕組み。`/backup/<DAY1>/public/hello.txt` と `/backup/<TOMORROW>/public/hello.txt` の両方は同じ実体を指していて、ディスクは1ファイル分しか消費しない。
>
> しかし、見た目上は両日付のディレクトリに独立してファイルが存在するので、「2世代分のスナップショット」として運用できる。これが `--link-dest` 方式バックアップの妙味。

---

### 確認⑥: 障害シミュレーション(bk停止時)

```bash
# AWSコンソールから bk を「停止」する
# (削除ではなく停止。後で再開する)
```

数分待ってから:

```bash
# fsで
/usr/local/bin/daily_backup.sh
echo "Exit code: $?"
# 非ゼロが返るはず

tail /var/log/daily_backup.log
# FAILED の行が記録されているはず
```

bk を再起動して復旧確認:

```bash
# AWSコンソールから bk を「開始」
# 数分待つ

# fsで再実行
/usr/local/bin/daily_backup.sh
echo "Exit code: $?"
# 0 で成功するはず
```

> **考えるポイント:バックアップ失敗を「検知」する仕組み**
>
> 本構成ではログを残すだけで、失敗時の通知は実装していない。実運用では:
> - rsync の終了コードを監視して、非ゼロなら管理者にメール通知
> - Zabbix等の監視で `/var/log/daily_backup.log` の最終行を監視
> - cron MAILTO 設定で標準エラー出力をメール送信
>
> といった「失敗を黙らせない」仕組みが必須。「**バックアップは取れているだけではダメで、取れていることを確認できる仕組みまでがバックアップ**」というのは現場の格言。

---

## 6. トラブルシューティング

### よくあるエラーと対処法

---

#### エラー①: Samba接続時に `NT_STATUS_LOGON_FAILURE`

**原因:** Sambaパスワードが未設定、または Linuxユーザー側のロックなど。

**対処法:**

```bash
# fsで
pdbedit -L
# 登録済みSambaユーザー一覧に対象ユーザーがいるか確認

# 再設定する場合
smbpasswd smbuser01
```

---

#### エラー②: `dnf install -y vsftpd ftp` で `No match for argument: ftp`

**原因:** Amazon Linux 2023 のリポジトリには伝統的な `ftp` コマンド(netkit-ftp系)のパッケージが存在しない。上流のFedora/RHEL9系でも同様にリポジトリから外れているため発生する。

**対処法:**

```bash
# fsで(動作確認用クライアントとして lftp を使う)
dnf install -y vsftpd lftp
```

> `lftp` は `ftp` とほぼ同じ対話コマンド(`ls` / `get` / `put` / `cd` / `bye` 等)が使え、かつデフォルトでパッシブモード接続を行う。本手順書の動作確認(確認③)は `lftp` を前提に記載している。

---

#### エラー③: vsftpd で `500 OOPS: vsftpd: refusing to run with writable root inside chroot()`

**原因:** chroot対象のホームディレクトリが書き込み可能になっている。

**対処法:**

```bash
# fsで
chmod 555 /home/ftpuser01
# 書き込みは /home/ftpuser01/upload/ で行わせる
```

---

#### エラー④: FTPで `ls` が固まる、データ転送に失敗する

**原因:** パッシブモードのポート範囲がSGで開いていない。

**対処法:**

```bash
# fs側のSGで TCP 30000-30100 が 172.31.0.0/16 に開いているか再確認
```

> `lftp` はデフォルトでパッシブモードを使うため、クライアント側の設定切り替えは基本的に不要。それでも固まる場合はSG側のポート開放漏れを疑う。

---

#### エラー⑤: rsyncで `@ERROR: auth failed on module backup`

**原因:** secretsファイルのパスワード不一致、またはパーミッション問題。

**対処法:**

```bash
# bkで
cat /etc/rsyncd.secrets
ls -l /etc/rsyncd.secrets
# 600 になっているか

# fsで
cat /root/.rsync.pass
ls -l /root/.rsync.pass
# 600 になっているか、パスワードが一致しているか
```

---

#### エラー⑥: rsyncで `--link-dest arg does not exist` 警告

**原因:** 1日目のバックアップ時には「昨日」のディレクトリがまだ存在しない。

**対処法:**

初日は警告が出るが処理は続行され、フルコピーで成功する。2日目以降は昨日分が存在するので警告は消える。**初日のみの正常な挙動**。

---

#### エラー⑦: `chronyc sources` で全部 `^?` のまま

**原因:** SGでNTP(UDP 123)が開いていない、または ntp の `allow` 設定が不足。

**対処法:**

```bash
# ntp側
grep ^allow /etc/chrony.conf
# allow 172.31.0.0/16 があるか確認

# クライアント側から疎通テスト
chronyc -h ntp.local activity
```

---

#### エラー⑧: `systemctl start rsyncd` で `Unit rsyncd.service not found`

**原因:** `rsyncd.service` の systemdユニットファイルは `rsync` パッケージではなく、別パッケージ `rsync-daemon` に含まれている。`rsync` コマンドが使える状態でも、`rsync-daemon` が未インストールだとデーモンとして起動できない。

**対処法:**

```bash
# bkで
dnf install -y rsync-daemon
systemctl start rsyncd
systemctl enable rsyncd
systemctl status rsyncd
```

---

#### エラー⑨: `crontab -e` で `command not found`

**原因:** Amazon Linux 2023 ではcron機能を提供する `cronie` パッケージがデフォルトでインストールされていない。Amazon Linux 2ではプリインストール・起動済みだったが、AL2023はより最小構成のベースイメージになっているため発生する。

**対処法:**

```bash
# fsで
dnf install -y cronie
systemctl enable --now crond
crontab -e
```

---

### ログの確認場所

| ログの種類 | 場所(パス) | 確認コマンド |
|-----------|------------|------------|
| OSシステムログ | `/var/log/messages` | `sudo tail -f /var/log/messages` |
| Sambaログ | `/var/log/samba/log.<クライアント名(NetBIOS名)>` | `sudo tail -f /var/log/samba/log.*` |
| vsftpdログ | `/var/log/xferlog` | `sudo tail -f /var/log/xferlog` |
| rsyncdログ | `/var/log/rsyncd.log` | `sudo tail -f /var/log/rsyncd.log` |
| バックアップログ | `/var/log/daily_backup.log` | `sudo tail -f /var/log/daily_backup.log` |
| Chronyログ | `/var/log/chrony/` | `sudo tail -f /var/log/chrony/*` |
| cronログ | `/var/log/cron` | `sudo tail -f /var/log/cron` |

---

## 7. 参考リソース・関連資料

| 資料名 | URL | 補足 |
|-------|-----|------|
| Samba 公式ドキュメント | https://www.samba.org/samba/docs/ | smb.conf リファレンス |
| smb.conf(5) man | https://www.samba.org/samba/docs/current/man-html/smb.conf.5.html | 各パラメータ詳細 |
| vsftpd 公式 | https://security.appspot.com/vsftpd.html | 設定例集 |
| rsync 公式 | https://rsync.samba.org/ | rsync全般 |
| rsyncd.conf(5) | https://download.samba.org/pub/rsync/rsyncd.conf.5 | rsyncd 設定リファレンス |
| Chrony 公式 | https://chrony-project.org/documentation.html | chrony.conf リファレンス |
| Amazon Time Sync Service | https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/set-time.html | AWS NTP 利用ガイド |

---

## 付録

### A. 環境変数・パラメータまとめ

| パラメータ名 | 自分の環境の値 | 説明 |
|------------|-------------|------|
| fs プライベートIP `<FS_PRI>` | `xx.xx.xx.xx` | Samba・FTP・rsync送信元 |
| bk プライベートIP `<BK_PRI>` | `xx.xx.xx.xx` | rsync受信先 |
| ntp プライベートIP `<NTP_PRI>` | `xx.xx.xx.xx` | 社内NTPサーバ |
| client プライベートIP `<CLIENT_PRI>` | `xx.xx.xx.xx` | 検証用クライアント |
| Sambaユーザー `<SMB_USER>` | `smbuser01` | グループ `smbgroup` 所属 |
| FTPユーザー `<FTP_USER>` | `ftpuser01` | chroot対象 |
| rsync仮想ユーザー | `rsyncuser` | rsyncd内部認証用 |
| rsyncパスワード | `RsyncP@ss1234` | 学習用・本番では強固なものに |

### B. 用語解説

| 用語 | 説明 |
|------|------|
| SMB/CIFS | Windows由来のファイル共有プロトコル。Sambaはそのオープン実装 |
| NetBIOS | 古いWindowsで使われた名前解決プロトコル。nmbdが対応 |
| SGIDビット | ディレクトリに付けると配下のファイルが親ディレクトリのグループを継承 |
| passdb backend | Sambaのユーザー認証DB形式。`tdbsam` が標準 |
| chroot | プロセスから見えるファイルシステムのルートを切り替える仕組み |
| パッシブモード(FTP) | サーバが待受ポートを開き、クライアントが接続する方式 |
| rsyncモジュール | rsyncdの設定単位。URL形式 `rsync://host/module` でアクセス |
| `--link-dest` | 既存ディレクトリと同一ファイルはハードリンクで参照する rsync オプション |
| ハードリンク | 同一iノードに複数の名前を付ける仕組み。ディスク消費なしの「コピー」 |
| Stratum(NTP) | 時刻源からの階層深さ。小さいほど精度が高い |
| Amazon Time Sync Service | AWSが提供する内部NTPサービス。エンドポイント 169.254.169.123 |

### C. 削除・クリーンアップ手順

1. fsの crontab から日次バックアップ行を削除(`crontab -e`)
2. 各サーバで作成したサービスを停止(`systemctl stop smb nmb vsftpd rsyncd chronyd`)
3. EC2インスタンスを4台とも終了する
4. セキュリティグループを削除する
5. キーペアを削除する(必要に応じて)

> **注意:** バックアップサーバ(bk)の `/backup` には機密ファイルが残っている可能性があるため、削除前に必要に応じて取り出しておくこと。
