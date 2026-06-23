# 【SMTP2層化 + DNS view + NFS を用いたメールサーバ構築(5台構成)】環境構築手順書

---

## 1. ドキュメント情報

| 項目 | 内容 |
|------|------|
| 手順書名 | SMTP2層化 + DNS view + NFS を用いたメールサーバ構築(5台構成) |
| 作成日 | 2026-06-22 |
| バージョン | v1.0 |
| 対象環境 | AWS |
| 元手順書 | 「Postfix + Dovecot + BIND + NFS を用いたメールサーバ構築(4台構成)」 v1.2 |

> **改訂履歴**
>
> | バージョン | 日付 | 変更内容 |
> |-----------|------|---------|
> | v1.0 | 2026-06-22 | 初版作成(発展課題用) |

---

## 2. 目的・概要

### 2-1. 目的

> 本手順書では、**DNSサーバ(兼NFS)1台 + 受信SMTPサーバ1台 + 配送SMTPサーバ3台**の合計5台構成で、以下の特徴を持つメールシステムを構築する。
>
> - **DNS view機能** によって、内部(VPC内)と外部(VPC外)で異なるレコードを返す
> - **SMTPサーバを「受信用」と「配送用」の2層に分離** し、責務を明確にする
> - 受信SMTPはメールを受け取って配送SMTPに振り分けるリレー専用、配送SMTPは特定ユーザーの最終配送専用とする

> **本手順書のスコープについて(重要)**
>
> 本手順書ではDNSサーバとして独自のBINDを構築するが、外部(Outlook等)からの名前解決を成立させるためには、**Route 53等の上位DNSでのサブドメイン権限委譲(NSレコード設定)** が本来必要となる。
> 本手順書ではRoute 53での権限委譲手順自体は省略しているが、`ex.entrycl.net` のように既に権限委譲済みのドメイン配下を利用する前提で記述している。

### 2-2. 構成概要(アーキテクチャ)

```
                  【外部(Outlook 等)】
                          ↓
              宛先: userX@ex.entrycl.net
                          ↓
              [外部からのDNS問い合わせ]
              → external view: グローバルIPを応答
                          ↓
              [受信SMTP(フロント)]
              mx.ex.entrycl.net
               ・Postfix のみ(Dovecot・NFS・ユーザーなし)
               ・transport_maps で配送先を振り分け
                          ↓
              [内部DNS問い合わせ: userN.tr.local]
              → internal view: プライベートIPを応答
                          ↓
          ┌───────────────┼───────────────┐
          ↓               ↓               ↓
      [配送SMTP1]      [配送SMTP2]      [配送SMTP3]
       user1.tr.local   user2.tr.local   user3.tr.local
       Postfix          Postfix          Postfix
       Dovecot          Dovecot          Dovecot
       /var/spool/mail/ ← /share をNFSマウント
          └───────────────┼───────────────┘
                          ↓
                    [NFS /share]
                          ↑
              [DNS Primary(兼NFS)]
              ns.ex.entrycl.net
              ├─ BIND(view対応)
              │   ├─ external view → ex.entrycl.net(グローバルIP)
              │   └─ internal view → ex.entrycl.net(プライベートIP)
              │                    + tr.local(プライベートIP)
              └─ NFS共有 (/share)
```

- **DNSサーバ(兼NFSサーバ)**: BIND(view対応の名前解決)+ NFSサーバ(`/share` を共有)
- **受信SMTPサーバ × 1台**: Postfix(外部からのメール受信、内部リレー専用)
- **配送SMTPサーバ × 3台**: Postfix(SMTP)+ Dovecot(POP3)+ NFSクライアント(`/var/spool/mail/` にマウント)

### 2-3. 完成イメージ(ゴール定義)

- [ ] 外部から `userX@ex.entrycl.net` 宛にメールを送信すると、受信SMTP → 対応する配送SMTP → NFS共有ディレクトリ の経路で配送される
- [ ] 各配送SMTPで `/var/spool/mail/<ユーザー名>` 内にメールが届いている
- [ ] 各配送SMTPから telnet でPOP3接続し、対象ユーザーでログインしてメールを取得できる
- [ ] VPC内から `dig ex.entrycl.net` するとプライベートIP、VPC外から `dig ex.entrycl.net @<DNS_PUB>` するとグローバルIPが返る
- [ ] VPC外から `dig user1.tr.local @<DNS_PUB>` しても解決できない(internal-onlyゾーン)

---

## 3. 前提条件・準備

### 3-1. AWS環境(起動済み前提)

以下が完了している前提とする:

- AWSアカウントを保有していること
- VPCが作成されており、CIDRは `172.31.0.0/16` であること(異なる場合は手順中の該当箇所を読み替え)
- EC2インスタンスが **5台起動済み** であること(全台 Amazon Linux 2023)
- 全EC2にSSHログインできること
- 各EC2には **パブリックIPが付与されている** こと

### 3-2. 環境要件

#### 3-2-1. DNSサーバ(兼NFSサーバ)

| 項目 | 要件 |
|------|------|
| OS | Amazon Linux 2023 |
| DNSサーバ | BIND |
| ファイル共有 | NFS |
| ツール | telnet |

#### 3-2-2. 受信SMTPサーバ(フロント)

| 項目 | 要件 |
|------|------|
| OS | Amazon Linux 2023 |
| SMTPサーバ | Postfix |
| ソフトウェア | Mailx, Rsyslog |
| ツール | telnet |
| 備考 | **Dovecot不要、メールユーザー不要、NFSマウント不要** |

> **🤔 考えるポイント:なぜ受信SMTPには Dovecot を入れないのか**
>
> Dovecotはユーザーのメールボックスにアクセスして配信する役割を持つ。受信SMTPはメールを受け取って即座に内部リレーするだけで、自分ではメールを保存しない。保存しないものに対してDovecotを動かしても意味がない。
>
> 「使わないものを入れない」のは設計の基本。インストールしないことで、攻撃面が減り(POP3ポートを晒さない)、リソース消費も減り、設定ミスの可能性も減る。

#### 3-2-3. 配送SMTPサーバ(3台共通)

| 項目 | 要件 |
|------|------|
| OS | Amazon Linux 2023 |
| SMTPサーバ | Postfix |
| POPサーバ | Dovecot |
| ソフトウェア | Mailx, Rsyslog |
| ツール | telnet |

### 3-3. セキュリティグループ設定

#### 3-3-1. DNSサーバ(兼NFSサーバ)

| タイプ | プロトコル | ポート範囲 | ソース | 目的 |
|-------|-----------|-----------|--------|------|
| SSH | TCP | 22 | マイIP | ローカルからSSHログイン |
| DNS (UDP) | UDP | 53 | 0.0.0.0/0 | 内部・外部の両方から名前解決を受け付けるため |
| DNS (TCP) | TCP | 53 | 0.0.0.0/0 | ゾーン応答が512バイトを超えた場合のTCPフォールバック対応 |
| NFS | TCP | 2049 | 172.31.0.0/16 | 配送SMTP3台とのファイル共有のため |

> **🔧 仕掛けの解説:DNSのTCP/53も開けておく理由**
>
> 元の4台手順書ではUDP/53のみだったが、view定義によってゾーン応答が大きくなる場合、UDPで返しきれずTCPフォールバックが起きる。「念のためTCPも開ける」のは運用上の保険。

#### 3-3-2. 受信SMTPサーバ(フロント)

| タイプ | プロトコル | ポート範囲 | ソース | 目的 |
|-------|-----------|-----------|--------|------|
| SSH | TCP | 22 | マイIP | ローカルからSSHログイン |
| SMTP | TCP | 25 | 0.0.0.0/0 | 外部からのメール受信のため |

> **🔧 仕掛けの解説:受信SMTPは「外向け25番」しか開けない**
>
> 受信SMTPは外部からメールを受け取るために25番を全開放するが、POP3(110番)もNFS(2049番)も開けない。これは「受信SMTPはユーザーアカウントもメールボックスも持たない」という設計の必然的な帰結。
>
> 「**役割が明確だと、開けるべきポートが自然に決まる**」。これは責務分離設計の副産物。

#### 3-3-3. 配送SMTPサーバ(3台共通)

| タイプ | プロトコル | ポート範囲 | ソース | 目的 |
|-------|-----------|-----------|--------|------|
| SSH | TCP | 22 | マイIP | ローカルからSSHログイン |
| SMTP | TCP | 25 | 172.31.0.0/16 | 受信SMTPからの内部リレー受信のみ(外部からは直接受け取らない) |
| POP3 | TCP | 110 | 172.31.0.0/16 | 内部からのPOP3取得のため |

> **🔧 仕掛けの解説:配送SMTPの25番は「内部のみ」**
>
> 元の4台構成では、各SMTPが外部から直接受信する設計だったため `0.0.0.0/0` で25番を開けていた。新構成では「外部からの受信は受信SMTPのみ」という責務分離をしたので、配送SMTPは外部に25番を晒す必要がなくなる。
>
> もし配送SMTPの25番を `0.0.0.0/0` のままにすると、「設定上は受信SMTP経由のはずなのに、外部から直接配送SMTPに送ってもメールが届いてしまう」という抜け道ができる。これは設計の意図と矛盾するので、SGで明示的に絞る。

### 3-4. パラメータ整理表

> 以下のプレースホルダを自分の環境の値に置き換えながら手順を進めること。

| パラメータ | 意味 | 自環境の値 |
|---|---|---|
| `<DNS_PUB>` | DNS兼NFSサーバのグローバルIP | |
| `<DNS_PRI>` | DNS兼NFSサーバのプライベートIP | |
| `<MX_PUB>` | 受信SMTPサーバのグローバルIP | |
| `<MX_PRI>` | 受信SMTPサーバのプライベートIP | |
| `<D1_PUB>` | 配送SMTP1のグローバルIP | |
| `<D1_PRI>` | 配送SMTP1のプライベートIP | |
| `<D2_PUB>` | 配送SMTP2のグローバルIP | |
| `<D2_PRI>` | 配送SMTP2のプライベートIP | |
| `<D3_PUB>` | 配送SMTP3のグローバルIP | |
| `<D3_PRI>` | 配送SMTP3のプライベートIP | |
| `<UID>` | メールユーザー共通UID(例: 2001) | |

### 3-5. ホスト名・ドメイン設計

| サーバ | 設定するホスト名 | 用途のドメイン |
|---|---|---|
| DNS兼NFSサーバ | `ns.ex.entrycl.net` | 外部にも見せる |
| 受信SMTPサーバ | `mx.ex.entrycl.net` | 外部にも見せる |
| 配送SMTP1 | `user1.tr.local` | 内部のみ |
| 配送SMTP2 | `user2.tr.local` | 内部のみ |
| 配送SMTP3 | `user3.tr.local` | 内部のみ |

> **🔧 仕掛けの解説:外部に見せるホスト名と、内部にしか見せないホスト名**
>
> 受信SMTPは `ex.entrycl.net`(外部公開ドメイン)のホスト名を持つ。配送SMTPは `tr.local`(内部専用ドメイン)のホスト名を持つ。
>
> これにより、「外部から見える存在は受信SMTPだけ」「配送SMTPは外部からは存在自体が知られない」という設計が、ホスト名レベルでも一貫する。
>
> もし配送SMTPに `user1.ex.entrycl.net` のような外部ドメインを使うと、「外部に公開しているドメインなのに、外からは解決できない」という違和感が生まれ、設計の意図が伝わりにくくなる。

---

## 4. 構築手順(詳細)

> **注意事項**
> - コマンド中の `<山カッコ>` は自分の環境の値に置き換えること
> - 環境依存のパラメータ(IPアドレス等)は3-4節を参照
> - エラーが出た場合は「6. トラブルシューティング」を参照

### 4-1. 環境構築の流れ

1. DNSサーバ(view対応)の構築 (Step 1)
2. NFSサーバの設定 (Step 2)
3. メールユーザーの作成 (Step 3)
4. 受信SMTPサーバの構築 (Step 4)
5. 配送SMTPサーバの構築 (Step 5)
6. 配送SMTPサーバのPOP3(Dovecot)設定 (Step 6)
7. 配送SMTPサーバのNFSクライアント設定 (Step 7)

---

### Step 1: DNSサーバ(view対応)の構築

**目的:** 内部と外部で異なるレコードを返すDNSサーバを構築する。**DNSサーバ上で実施**する。

#### 1-1. ホスト名の設定

```bash
sudo hostnamectl set-hostname ns.ex.entrycl.net
sudo su -
```

#### 1-2. BINDのインストール

```bash
dnf install -y bind
```

#### 1-3. named.conf の編集

```bash
vi /etc/named.conf
```

設定ファイルの編集内容:

```
// ---以下のように変更---
// listen-on port 53 { 127.0.0.1; };       ← コメントアウト
// listen-on-v6 port 53 { ::1; };          ← コメントアウト
allow-query { any; };

// ---ファイル末尾に追記---

// === ACL定義(view判定用) ===
acl "internal-net" {
    172.31.0.0/16;
    127.0.0.1;
};

// === internal view(VPC内からの問い合わせに応答) ===
view "internal" {
    match-clients { internal-net; };
    recursion yes;

    zone "ex.entrycl.net" IN {
        type master;
        file "/var/named/ex.entrycl.net.internal.zone";
    };

    zone "tr.local" IN {
        type master;
        file "/var/named/tr.local.internal.zone";
    };
};

// === external view(VPC外からの問い合わせに応答) ===
view "external" {
    match-clients { any; };
    recursion no;

    zone "ex.entrycl.net" IN {
        type master;
        file "/var/named/ex.entrycl.net.external.zone";
    };

    // tr.local は外部に公開しない(意図的に存在させない)
};
```

> **🔧 仕掛けの解説①:`acl` で「内部」を明確に定義する**
>
> `acl "internal-net"` で「VPC CIDR + 自分自身」を「内部とみなす範囲」として名前付けする。後で `match-clients { internal-net; }` のように使える。直接IPを書くこともできるが、ACLにすることで「定義箇所が1つに集約され、変更しやすい」設計になる。
>
> `127.0.0.1` を含めているのは、DNS Primary自身が自分のDNSを引きたい場合(`dig @127.0.0.1`)に internal view で応答してほしいから。

> **🔧 仕掛けの解説②:view は「上から順に判定」される**
>
> BINDのviewは記述順に `match-clients` を判定し、最初にマッチしたviewが使われる。internal view を先に書くことで、`172.31.0.0/16` からの問い合わせは internal に吸い込まれ、それ以外は external に流れる。
>
> もし external view を先に書いてしまうと、`match-clients { any; }` が最初にマッチしてしまい、internal view は永遠に使われない。**順序が意味を持つ**ことに注意。

> **🔧 仕掛けの解説③:なぜ internal は `recursion yes`、external は `recursion no` か**
>
> - internal: VPC内のサーバが、`ex.entrycl.net` 以外のドメイン(例: `amazonaws.com`)を引きたいときに、このDNSがフォワーダとして動けるよう再帰問い合わせを許可
> - external: 外部からの問い合わせに対しては、自分が権威を持つゾーン(`ex.entrycl.net`)以外には答えない。再帰許可しているDNSはオープンリゾルバ攻撃に悪用される危険がある
>
> 「外部にはオープンリゾルバとして振る舞わない」のはセキュリティの基本。

> **🔧 仕掛けの解説④:なぜ `tr.local` は external view に書かないのか**
>
> external view は「外部に見せる情報」を定義する場所。`tr.local` を書いてしまうと、外部から `dig tr.local` で応答が返ってしまい、内部構造が漏れる。書かないことで「**そもそも存在しないドメイン**」として振る舞わせる(外部からは NXDOMAIN または REFUSED が返る)。
>
> これは「内部リソース情報を外部に晒さない」という、よくある内部DNS設計のパターン。

> **🤔 考えるポイント:`ex.entrycl.net` は internal にも external にも書かれている**
>
> 同じドメイン名が両方のviewに登場するのは違和感があるかもしれない。しかしBIND の view は「**問い合わせ元が違えば、別世界**」として扱うので、これは正しい。同じFQDN(例: `mx.ex.entrycl.net`)でも、internal viewでは `<MX_PRI>`、external viewでは `<MX_PUB>` という違うIPを返せる。

#### 1-4. 構文チェック

```bash
named-checkconf
# 何も出なければOK
```

#### 1-5. 外部用ゾーンファイル作成

```bash
vi /var/named/ex.entrycl.net.external.zone
```

```
$TTL 3600
@ IN SOA ns.ex.entrycl.net. admin.ex.entrycl.net. (
    20260622 ; serial
    3600 ; refresh
    3600 ; retry
    3600 ; expire
    3600 ) ; minimum

    IN NS ns.ex.entrycl.net.
    IN MX 10 mx.ex.entrycl.net.

ns           IN A <DNS_PUB>
mx           IN A <MX_PUB>
```

> **🔧 仕掛けの解説:外部用ゾーンには MX が 1 つだけ**
>
> 元の4台構成では `user1.teama.entrycl.net` 〜 `user3.teama.entrycl.net` の3つのMXがあり、外部から見ても3台のSMTPが存在していた。新構成では「外部からは受信SMTPしか見えない」設計なので、MXは `mx.ex.entrycl.net` 1つに集約する。配送SMTPは外部にAレコードもMXも公開しない。

> **🤔 考えるポイント:なぜ MX の数を減らせるのか**
>
> MX は「このドメイン宛のメールを受け取るサーバ」を示すレコード。受信SMTPに集約したので、外部から見える「メール受信窓口」は1台だけ。よってMXは1つで足りる。
>
> 元の4台構成では「ユーザーごとにメールサーバが分かれている」という設計だったため、ユーザーごとにMXが必要だった。設計が変わればDNSの中身も変わる。

#### 1-6. 内部用ゾーンファイル作成(ex.entrycl.net)

```bash
vi /var/named/ex.entrycl.net.internal.zone
```

```
$TTL 3600
@ IN SOA ns.ex.entrycl.net. admin.ex.entrycl.net. (
    20260622 ; serial
    3600 ; refresh
    3600 ; retry
    3600 ; expire
    3600 ) ; minimum

    IN NS ns.ex.entrycl.net.
    IN MX 10 mx.ex.entrycl.net.

ns           IN A <DNS_PRI>
mx           IN A <MX_PRI>
```

> **🔧 仕掛けの解説:外部用と内部用の違いは「Aレコードの値だけ」**
>
> ホスト名・MX・NSレコードの構造はまったく同じ。違いはAレコードの値が「グローバルIP」か「プライベートIP」かだけ。
>
> これにより、内部にいるサーバは「外部と同じドメイン名で通信しているように見えるが、実はプライベートIP経由でVPC内ルーティングで完結する」という構造になる。
>
> 外部→外部、内部→内部、それぞれの世界の中では矛盾なく通信できる、というのが view の妙。

#### 1-7. 内部用ゾーンファイル作成(tr.local)

```bash
vi /var/named/tr.local.internal.zone
```

```
$TTL 3600
@ IN SOA ns.tr.local. admin.tr.local. (
    20260622 ; serial
    3600 ; refresh
    3600 ; retry
    3600 ; expire
    3600 ) ; minimum

    IN NS ns.tr.local.

ns           IN A <DNS_PRI>
user1        IN A <D1_PRI>
user2        IN A <D2_PRI>
user3        IN A <D3_PRI>
```

> **🔧 仕掛けの解説①:`tr.local` は internal view 専用**
>
> このドメインは internal view にしか定義されていない。外部から `dig user1.tr.local @<DNS_PUB>` しても、external view にこのゾーンがないため応答できない(REFUSEDまたは空応答)。これにより、配送SMTPのプライベートIPやサーバ名を外部に漏らさない設計になる。

> **🤔 考えるポイント:なぜ `.local` を選んだのか**
>
> `.local` は伝統的に内部ネットワーク用ドメインとして広く使われてきた。本手順書では「**内部専用であることを名前で明示する慣習**」として `.local` を採用している。
>
> 厳密にはRFC的には議論がある名前空間だが、学習目的では「見た目で内部用とわかる」ことを優先している。

> **🔧 仕掛けの解説②:MXレコードが `tr.local` にはない**
>
> `tr.local` はサーバ間通信用のドメインであり、メールの宛先ドメインとして使うわけではないので、MXは不要。`user1.tr.local` はあくまで「配送SMTP1サーバのホスト名」であり、メールアドレスのドメインではない。
>
> メールアドレスは `user1@ex.entrycl.net` のまま。**サーバ名とメールアドレスのドメインを切り離せる**のが、この構成の特徴の一つ。

#### 1-8. ゾーン構文チェック

```bash
named-checkzone ex.entrycl.net /var/named/ex.entrycl.net.external.zone
named-checkzone ex.entrycl.net /var/named/ex.entrycl.net.internal.zone
named-checkzone tr.local /var/named/tr.local.internal.zone
# 全て「OK」と出ればOK
```

#### 1-9. BINDの起動と自動起動設定

```bash
systemctl start named
systemctl status named
systemctl enable named
```

#### 1-10. 自身でDNS動作確認

```bash
# 127.0.0.1 は internal-net に含まれるので internal view で応答するはず
dig @127.0.0.1 ex.entrycl.net mx +short
# 期待: 10 mx.ex.entrycl.net.

dig @127.0.0.1 mx.ex.entrycl.net +short
# 期待: <MX_PRI>(プライベートIP)

dig @127.0.0.1 user1.tr.local +short
# 期待: <D1_PRI>
```

---

### Step 2: NFSサーバの設定(DNSサーバ上)

**目的:** メールスプールを配送SMTP3台で共有するためのNFS共有設定を行う。**DNSサーバ上で実施**する。

#### 2-1. 共有ディレクトリの作成

```bash
mkdir /share
```

#### 2-2. exports設定

```bash
vi /etc/exports
```

設定ファイルの編集内容:

```
# ---以下を追記---
/share 172.31.0.0/16(rw,no_root_squash)
# ----------------
```

> **🔧 仕掛けの解説:`172.31.0.0/16` 全体に公開している意味**
>
> 配送SMTP3台だけでなく、受信SMTPも含めてVPC内すべてに公開しているように見えるが、実際には**受信SMTPはNFSをマウントしない**ので問題にならない。
>
> もし受信SMTPがNFSマウントしていたら、それは「受信SMTPがメールを直接保存できる」状態になり、責務分離が崩れる。「マウントしない」ことが設計上の境界線。

#### 2-3. NFSサーバの起動・自動起動設定

```bash
systemctl start nfs-server
systemctl enable nfs-server
```

#### 2-4. /share の所有グループ・権限変更

```bash
chown -R root:mail /share
chmod 770 /share
```

> **🔧 仕掛けの解説:なぜ `mail` グループに 770 か**
>
> このあと作成する全メールユーザーは `mail` グループ所属。`/share` を `mail` グループ書き込み可能にすることで、各ユーザーが自分のメールボックス(`/share/<ユーザー名>/`)を作成・更新できる。
>
> `770` のうち、「その他」(7→0)を 0 にしているのは、`mail` グループ以外のユーザーが `/share` に入れないようにする防御策。

---

### Step 3: メールユーザーの作成

**目的:** メールサーバ専用のユーザーを **配送SMTP 3台 + DNSサーバ** で作成する。

> **重要:** 受信SMTPサーバには **メールユーザーを作成しない**。これが新構成の核心。

#### 3-1. 全対象サーバ(DNS + 配送SMTP×3)で実行

各サーバで、`user1` `user2` `user3` の3ユーザーを **同じUID/GID** で作成する。

```bash
# 例: user1 をUID 2001で作成
useradd user1 -u 2001 -g mail -M -K MAIL_DIR=/dev/null -s /sbin/nologin
# 「Creating mailbox file: Not a directory」と表示されれば成功

useradd user2 -u 2002 -g mail -M -K MAIL_DIR=/dev/null -s /sbin/nologin
useradd user3 -u 2003 -g mail -M -K MAIL_DIR=/dev/null -s /sbin/nologin

# パスワード設定(検証用にシンプルなものでよい)
passwd user1
passwd user2
passwd user3
```

> **🔧 仕掛けの解説①:なぜ受信SMTPには user1〜3 を作らないか**
>
> 受信SMTPで `user1` を作ってしまうと、Postfixは「自分のサーバに `user1` というローカルユーザーがいる」と認識する。後に `main.cf` で `mydestination = ex.entrycl.net` のように設定してしまった場合、受信SMTPが「自分でローカル配送できる」と勘違いし、メールが受信SMTPのローカル領域に保存されてしまう。
>
> ユーザーを作らないことで、「うっかり設定ミスをしても、受信SMTPはローカル配送できない」という二重の防御になる。

> **🤔 考えるポイント①:UID統一の重要性(NFS の本質)**
>
> NFSは「ファイル所有権をUID/GIDで管理する」プロトコル。配送SMTP1で作成したファイル(UID=2001の所有)は、配送SMTP2で見ると「UID=2001を持つユーザー」のものとして認識される。もし配送SMTP2の `user1` のUIDが2001でなかったら、別人扱いになりメールが見えなくなる。
>
> よって**全サーバでUIDを揃える**ことが絶対条件。

> **🤔 考えるポイント②:DNSサーバにも user1〜3 を作る理由**
>
> DNSサーバ自身はメール処理しないが、NFSサーバとして `/share` 上に各ユーザーのディレクトリを作る場面で、所有者UIDが一致している必要がある。後でメンテナンス時に DNSサーバ上で `ls -l /share` してファイル所有者を確認するときも、UIDではなくユーザー名で表示されると見やすい。

> **🔧 仕掛けの解説②:`-M` と `-K MAIL_DIR=/dev/null` の意味**
>
> - `-M`: ホームディレクトリを作らない(メール専用ユーザーなのでログイン用ホームは不要)
> - `-K MAIL_DIR=/dev/null`: useraddが自動的に `/var/spool/mail/<ユーザー名>` を作るのを抑止する。NFS共有先に作るので、ローカルに作られると混乱するため
> - `-s /sbin/nologin`: シェルログイン不可(POPプロトコルからのみアクセス)

---

### Step 4: 受信SMTPサーバの構築

**目的:** 外部からのメールを受け取り、配送SMTPへリレーする「フロントサーバ」を構築する。**受信SMTPサーバ上で実施**する。

#### 4-1. ホスト名の設定

```bash
sudo hostnamectl set-hostname mx.ex.entrycl.net
sudo su -
```

#### 4-2. 必要なパッケージのインストール

```bash
dnf install -y postfix mailx rsyslog telnet

systemctl start rsyslog
systemctl enable rsyslog
systemctl start postfix
```

#### 4-3. /etc/resolv.conf の設定

受信SMTPは内部DNSを優先して引くようにする。

```bash
vi /etc/resolv.conf
```

```
nameserver <DNS_PRI>
```

> **🔧 仕掛けの解説:なぜ内部DNSを優先して引くのか**
>
> 受信SMTPが `transport_maps` で「`user1@ex.entrycl.net` は `user1.tr.local` に渡せ」と判定したあと、`user1.tr.local` を実際にIPに解決する必要がある。`tr.local` ドメインは internal view にしか存在しないので、internal viewを返してくれるDNS(=自分の構築したDNS Primary)に問い合わせる必要がある。
>
> AWSのデフォルトDNS(VPC リゾルバ)に問い合わせても `tr.local` は解けない。

> **🤔 考えるポイント:resolv.conf は再起動で上書きされることがある**
>
> Amazon Linux 2023 では `cloud-init` や `NetworkManager` が起動時に `/etc/resolv.conf` を書き換えることがある。本格運用するなら永続化対策が必要だが、本手順書ではスコープ外とする。検証中に設定が消えていたら再度書き直す。

#### 4-4. main.cf の事前整理

```bash
grep -v ^# /etc/postfix/main.cf | cat -s > /tmp/main.cf
cp /tmp/main.cf /etc/postfix/main.cf
# 「cp: overwrite '/etc/postfix/main.cf'?」と表示されるので「yes」と入力し、Enter
```

#### 4-5. main.cf の編集

```bash
vi /etc/postfix/main.cf
```

末尾に追記:

```
# === 受信SMTP用設定 ===
myhostname = mx.ex.entrycl.net
mydomain = ex.entrycl.net
myorigin = $myhostname

inet_interfaces = all

# 自分でローカル配送するドメインは「自分のホスト名」のみ
# ex.entrycl.net は意図的に含めない
mydestination = $myhostname, localhost

# 信頼するネットワーク(リレー許可するソース)
mynetworks = 172.31.0.0/16, 127.0.0.1

# 外部からのメールでも、このドメイン宛なら受け取ってリレーしてよい
relay_domains = ex.entrycl.net

# 宛先ごとの転送ルール
transport_maps = hash:/etc/postfix/transport
```

> **🔧 仕掛けの解説①:`mydestination` に `ex.entrycl.net` を含めない**
>
> もし含めると、Postfixは「`user1@ex.entrycl.net` 宛のメールは自分が最終配送する」と判断し、ローカルユーザー `user1` を探そうとする。しかし受信SMTPには `user1` が存在しないので、`User unknown in local recipient table` で配送失敗する。
>
> `mydestination` に含めないことで、Postfixに「自分はこのドメインの最終配送先ではない」と伝えることになり、`transport_maps` の判定に処理が回ってくる。

> **🔧 仕掛けの解説②:`relay_domains` の意味**
>
> Postfixはデフォルトで「自分宛(=`mydestination`)でも、信頼ネットワーク(=`mynetworks`)でもない宛先」へのメールはリレー拒否する(オープンリレー防止)。
>
> 外部から来たメール `user1@ex.entrycl.net` は、`mydestination` に入っていないし、外部からの接続はmynetworksにも入っていない。**そこで `relay_domains` に `ex.entrycl.net` を入れることで、「このドメイン宛は外部からの接続でもリレーしてよい」と例外宣言する**。
>
> `relay_domains` がなければ、外部からのメールは "Relay access denied" で全部弾かれる。

> **🔧 仕掛けの解説③:`mydestination` vs `relay_domains`**
>
> 似て見えるが役割が違う:
> - `mydestination`: 「**自分が最終配送する**」ドメイン
> - `relay_domains`: 「**他のサーバへリレーする**」ドメイン
>
> 受信SMTPは `ex.entrycl.net` 宛のメールを「自分では配送せず、リレーで渡す」役割なので、`relay_domains` に入れる。配送SMTPは「自分が最終配送する」役割なので、`mydestination` に入れる(Step 5で設定)。

> **🔧 仕掛けの解説④:`mynetworks` に `172.31.0.0/16` を入れる理由**
>
> 内部のサーバ(配送SMTP等)から、この受信SMTPを経由して外部にメールを送るような構成にも対応できるようにしておく。本手順書のスコープでは「外部→受信→配送」だけだが、内部→外部の経路も将来的に通せるようにするための備え。

#### 4-6. transport ファイル作成

```bash
vi /etc/postfix/transport
```

```
user1@ex.entrycl.net    smtp:[user1.tr.local]
user2@ex.entrycl.net    smtp:[user2.tr.local]
user3@ex.entrycl.net    smtp:[user3.tr.local]
```

> **🔧 仕掛けの解説①:`[ ]` の意味**
>
> `[user1.tr.local]` の角括弧は「MXレコードを引かずに、このホストのAレコードに直接SMTP接続せよ」という指示。
>
> 括弧がないと、Postfixは `user1.tr.local` のMXレコードを引きにいく。`tr.local` ゾーンにはMXを定義していないので、見つからないかフォールバックの挙動になる。配送SMTPはMXを持たないAレコードのみの存在なので、`[ ]` で「Aレコード直接指定」を明示する。

> **🔧 仕掛けの解説②:`transport_maps` は「宛先書き換え」ではない**
>
> このマップは「宛先 `user1@ex.entrycl.net` のメールを、`user1.tr.local` というサーバにSMTPで渡せ」という**ルーティング指示**。メールヘッダの `To:` は書き換わらない。
>
> 配送SMTP1に渡されたメールも、宛先は `user1@ex.entrycl.net` のまま。だから配送SMTP1側で `ex.entrycl.net` を `mydestination` に含めて「受け入れ準備」をしておく必要がある(Step 5)。

> **🤔 考えるポイント:なぜわざわざユーザーごとに別サーバに振るのか**
>
> 元の4台構成と同じ「ユーザー1人につき1サーバ」のポリシーを踏襲しているため。実運用では1つの配送SMTPで全員を扱う集約構成のほうが一般的だが、本手順書では「責務分離」の学習のため意図的にユーザーごとにサーバを分けている。
>
> `transport_maps` を使えば「ユーザーごと」だけでなく「ドメインごと」「特定アドレスだけ別経路」など柔軟な振り分けが可能であることを体感してほしい。

#### 4-7. transport ファイルをハッシュ化

```bash
postmap /etc/postfix/transport
# /etc/postfix/transport.db が生成される

ls -l /etc/postfix/transport.db
```

> **🔧 仕掛けの解説:なぜ `postmap` が必要か**
>
> Postfixは高速ルックアップのため、テキストファイル(`transport`)を直接読まずハッシュDB(`transport.db`)を参照する。`transport` を編集したら必ず `postmap` を実行する必要がある。
>
> 編集後に `postmap` を忘れると、テキストは新しいのにDBは古いまま、という不整合が起きる。

> **🤔 考えるポイント:`/etc/aliases` も同じ仕組み**
>
> `/etc/aliases` を編集した後に `newaliases` を実行するのと同じ構造。Postfixの「マップファイル」と呼ばれるものは、ほぼすべて「テキスト編集 → ハッシュ化コマンド実行」のセット。

#### 4-8. Postfixの再起動

```bash
systemctl restart postfix
systemctl status postfix
systemctl enable postfix
```

---

### Step 5: 配送SMTPサーバの構築

**目的:** 受信SMTPから渡されたメールを最終配送する、ユーザー専用のSMTPサーバを構築する。**3台の配送SMTPサーバそれぞれで実施**する。

> **対応関係:**
> - 配送SMTP1 → ホスト名 `user1.tr.local` → ユーザー `user1` のメール最終配送
> - 配送SMTP2 → ホスト名 `user2.tr.local` → ユーザー `user2` のメール最終配送
> - 配送SMTP3 → ホスト名 `user3.tr.local` → ユーザー `user3` のメール最終配送

#### 5-1. ホスト名の設定(各サーバで異なる)

```bash
# 配送SMTP1 の場合
sudo hostnamectl set-hostname user1.tr.local
# 配送SMTP2 → user2.tr.local
# 配送SMTP3 → user3.tr.local

sudo su -
```

#### 5-2. 必要なパッケージのインストール

```bash
dnf install -y postfix mailx rsyslog telnet

systemctl start rsyslog
systemctl enable rsyslog
systemctl start postfix
```

#### 5-3. /etc/resolv.conf の設定

```bash
vi /etc/resolv.conf
```

```
nameserver <DNS_PRI>
```

#### 5-4. main.cf の事前整理

```bash
grep -v ^# /etc/postfix/main.cf | cat -s > /tmp/main.cf
cp /tmp/main.cf /etc/postfix/main.cf
# 「yes」と入力
```

#### 5-5. main.cf の編集(配送SMTP1の例)

```bash
vi /etc/postfix/main.cf
```

末尾に追記(`myhostname` は各サーバで異なる):

```
# === 配送SMTP用設定(配送SMTP1の例) ===
myhostname = user1.tr.local
mydomain = tr.local
myorigin = $myhostname

inet_interfaces = all

# ex.entrycl.net 宛のメールは自分が最終配送する
mydestination = ex.entrycl.net, $myhostname, localhost

mynetworks = 172.31.0.0/16, 127.0.0.1

mail_spool_directory = /var/spool/mail/
```

> 配送SMTP2では `myhostname = user2.tr.local`
> 配送SMTP3では `myhostname = user3.tr.local`

> **🔧 仕掛けの解説①:`mydomain` と `mydestination` の役割の違い**
>
> - `mydomain` = 自分が「名乗る」ドメイン。`myhostname` のドメイン部や、`myorigin` のデフォルト値に使われる
> - `mydestination` = 自分が「受け持つ」ドメインのリスト
>
> 配送SMTPでは、`mydomain = tr.local`(自分は `tr.local` ドメインのサーバ)だが、`mydestination` に `ex.entrycl.net` を入れる(`ex.entrycl.net` 宛のメールも自分が配送する)。
>
> 「**名乗るドメインと、受け持つドメインは違ってよい**」。これが理解の鍵。

> **🔧 仕掛けの解説②:なぜ `ex.entrycl.net` を `mydestination` に入れる必要があるか**
>
> 受信SMTPから渡されてくるメールの宛先は `user1@ex.entrycl.net` のまま(`transport_maps` はアドレスを書き換えない)。配送SMTPが「自分はこのドメイン宛を受け取る」と宣言していないと、「他のサーバに渡してください」と Relay access denied で弾いてしまう。
>
> `mydestination` に `ex.entrycl.net` を入れることで、「自分は `ex.entrycl.net` ドメインの `user1` の最終配送先である」と認識し、ローカルの `/var/spool/mail/user1/` に書き込む。

> **🤔 考えるポイント:配送SMTP1が user2 宛のメールを受けたらどうなるか**
>
> 設計上、受信SMTPは `transport_maps` で `user2` 宛は `user2.tr.local` に振り分けるので、配送SMTP1には届かない。
>
> しかし、もし手動で配送SMTP1に `user2` 宛のメールを送り込むとどうなるか?
> - 配送SMTP1は `mydestination` に `ex.entrycl.net` を含めているので「受け取る」
> - ローカルユーザー `user2` を探す → 存在する(Step 3で全配送SMTPに `user1〜3` を作っているため)
> - `/var/spool/mail/user2/` に書き込む(NFS共有なので他サーバとも共有される)
>
> よって最終的にメールは届くが、想定外の経路。`transport_maps` は「正しい経路に流すための交通整理」であり、間違って届いても破綻はしない、という安全マージン。

> **🔧 仕掛けの解説③:なぜ受信SMTPと違って `relay_domains` がないのか**
>
> 配送SMTPの役割は「最終配送のみ」。リレーしない。`mynetworks = 172.31.0.0/16` で内部からの送信を信頼するので、もし内部から外部宛のメールが来てもリレーは可能になるが、`relay_domains` を明示的に空にしておく方が責務が明確。

#### 5-6. Postfixの再起動

```bash
systemctl restart postfix
systemctl status postfix
systemctl enable postfix
```

---

### Step 6: 配送SMTPサーバのPOP3(Dovecot)設定

**目的:** メールをダウンロードして閲覧するためのPOP3サーバを構築する。**3台の配送SMTPサーバそれぞれで実施**する。

#### 6-1. Dovecotのインストール

```bash
dnf install -y dovecot
```

#### 6-2. dovecot.conf の編集

```bash
vi /etc/dovecot/dovecot.conf
```

```
# ---以下を追記/変更---
protocols = pop3

# Maildir形式の設定。%uにはユーザ名が入る
mail_location = maildir:/var/spool/mail/%u/
# ---------------------
```

> **🤔 考えるポイント:Maildir 形式が NFS と相性が良い理由**
>
> Maildir は「1メール=1ファイル」の方式。`new/`, `cur/`, `tmp/` のサブディレクトリを使い、ファイル単位でアトミックに移動することで状態管理する。
>
> 一方、mbox 形式は「1ユーザーのメールを1ファイルに連結」する。ファイルロックが必要になるが、NFS環境ではロックの扱いが複雑で問題が起きやすい。Maildirならファイル単位の操作なのでロック競合が起きにくい。
>
> NFS環境では Maildir を選ぶのが定石。

#### 6-3. SSL設定の無効化

```bash
vi /etc/dovecot/conf.d/10-ssl.conf
# 「ssl = required」を「#ssl = required」のようにコメントアウト
```

> **🔧 仕掛けの解説:本来はTLS化すべきだが学習用には省略**
>
> 本番運用では SSL/TLS は必須だが、本手順書では証明書取得を含めると複雑になるので無効化している。ネットワーク上をパスワードが平文で流れるので、本構成は閉域学習用に限定すること。

#### 6-4. 認証設定

```bash
vi /etc/dovecot/conf.d/10-auth.conf
# 「disable_plaintext_auth = no」に変更
```

#### 6-5. Dovecot起動

```bash
systemctl start dovecot
systemctl enable dovecot
```

---

### Step 7: 配送SMTPサーバのNFSクライアント設定

**目的:** DNSサーバの共有ディレクトリ `/share` を配送SMTPの `/var/spool/mail/` にマウントする。**3台の配送SMTPサーバそれぞれで実施**する。

#### 7-1. /etc/fstab の編集

```bash
vi /etc/fstab
```

```
# ---以下を追記---
<DNS_PRI>:/share /var/spool/mail/ nfs4 defaults 0 0
# ----------------
```

#### 7-2. マウント実施

```bash
mount /var/spool/mail/
df -h
```

**期待する結果:** `df -h` の出力に `<DNS_PRI>:/share` が `/var/spool/mail` にマウントされていることが表示される。

> **🤔 考えるポイント:なぜ受信SMTPはNFSマウントしないのか**
>
> 受信SMTPはメールを保存しない。受け取ったらすぐ配送SMTPに渡す。よってメールスプール用のNFS共有は不要。
>
> もし受信SMTPにもNFSマウントしてしまうと、「受信SMTPが直接ローカル配送できる」状態になってしまい、設計の責務分離が崩れる可能性がある。「**マウントしないこと**」も意図的な設計判断。

> **🔧 仕掛けの解説:配送SMTP間でメールが見える仕組み**
>
> 配送SMTP1〜3はすべて同じNFS共有 `/share` を `/var/spool/mail/` にマウントしている。よって配送SMTP1の `/var/spool/mail/user1/` も、配送SMTP2から見れば同じ内容に見える。
>
> これにより、「user1のメールは配送SMTP1に届くが、配送SMTP2から telnet POP3 でも取得できる」という挙動が成り立つ(動作確認②で検証)。

---

## 5. 動作確認・検証

> 構築完了後、以下の確認をすべてパスしたら構築成功とみなす。

### 5-1. 確認チェックリスト

- [ ] **確認①**: DNS view が正しく動作する
- [ ] **確認②**: メールが受信SMTP経由で配送SMTPに届く
- [ ] **確認③**: telnet で POP3 接続してメール取得できる

---

### 確認①: DNS view の動作確認

#### 内部から(配送SMTP1 などで実施)

```bash
dig ex.entrycl.net mx +short
# 期待: 10 mx.ex.entrycl.net.

dig mx.ex.entrycl.net +short
# 期待: <MX_PRI>(プライベートIP)

dig user1.tr.local +short
# 期待: <D1_PRI>
```

#### 外部から(自分のPC等で実施)

```bash
dig @<DNS_PUB> mx.ex.entrycl.net +short
# 期待: <MX_PUB>(グローバルIP)

dig @<DNS_PUB> user1.tr.local
# 期待: 応答セクションが空、または REFUSED
# (tr.local は external view に存在しないため)
```

---

### 確認②: メール送信と配送

受信SMTPで telnet を使って、外部からのメール送信をシミュレートする。

```bash
# 受信SMTP上で
telnet <MX_PRI> 25
```

接続後、以下を対話形式で入力:

```
EHLO test.example.com
MAIL FROM:<sender@example.com>
RCPT TO:<user1@ex.entrycl.net>
DATA
Subject: Test mail to user1
From: sender@example.com
To: user1@ex.entrycl.net

This is a test message for user1.
.
QUIT
```

配送SMTP1で確認:

```bash
ls /var/spool/mail/user1/new/
# メールファイルが届いていればOK

# 中身を確認
cat /var/spool/mail/user1/new/*
```

ログ確認:

```bash
# 受信SMTPで
tail -f /var/log/maillog
# → smtp ... to=<user1@ex.entrycl.net>, relay=user1.tr.local[<D1_PRI>]:25, ... status=sent

# 配送SMTP1で
tail -f /var/log/maillog
# → local ... to=<user1@ex.entrycl.net>, relay=local, ... status=sent (delivered to maildir)
```

---

### 確認③: POP3でのメール取得

#### 自サーバから取得

```bash
# 配送SMTP1 で
telnet localhost 110
```

```
user user1
pass <user1のパスワード>
list
retr 1
quit
```

#### 別の配送SMTPから取得(NFS共有確認)

```bash
# 配送SMTP2 で
telnet <D1_PRI> 110
```

```
user user1
pass <user1のパスワード>
list
retr 1
quit
```

> **🤔 考えるポイント:なぜ配送SMTP2 から配送SMTP1 のメールが取れる?**
>
> 配送SMTP2 にも `user1` がUID統一で作成されており、`/var/spool/mail/user1/` は NFS 共有上にある。よって配送SMTP1上のメールも、配送SMTP2 から POP3 でアクセス可能。
>
> 本構成は「**配送先のサーバ名は固定だが、取得先はどこからでもよい**」という柔軟性を持つ。

---

## 6. トラブルシューティング

### よくあるエラーと対処法

---

#### エラー①: SSH接続がタイムアウトする

**原因:** セキュリティグループのインバウンドルールでSSH(ポート22)が許可されていない可能性がある

**対処法:**
1. AWSコンソール → EC2 → セキュリティグループを開く
2. 対象のセキュリティグループのインバウンドルールを確認する
3. SSH(TCP/22)が自分のIPから許可されているか確認する

---

#### エラー②: `dig` で内部用IPが返ってこない

**原因:** view の `match-clients` がクライアントIPにマッチしていない、またはACL定義が間違っている。

**対処法:**

```bash
# DNS Primary で query log を有効化
rndc querylog
# /var/log/messages を見て、どのviewが選ばれているか確認
tail -f /var/log/messages | grep "view "
```

---

#### エラー③: 受信SMTPから配送SMTPに接続できない

**原因:** 配送SMTPのSGで受信SMTPからの25番が許可されていない、または `user1.tr.local` が解決できない。

**対処法:**

```bash
# 受信SMTPで
dig user1.tr.local
# プライベートIPが返ってこなければ、/etc/resolv.conf を確認

nc -zv user1.tr.local 25
# 接続できなければ、配送SMTPのSGを確認
```

---

#### エラー④: 受信SMTPで `Relay access denied` が出る

**原因:** `relay_domains` に `ex.entrycl.net` が含まれていない、または `postmap` 実行忘れ。

**対処法:**

```bash
# 受信SMTPで設定確認
postconf relay_domains
# ex.entrycl.net が表示されればOK

postmap /etc/postfix/transport
systemctl restart postfix
```

---

#### エラー⑤: 配送SMTPで `User unknown in local recipient table`

**原因:** 配送SMTPに対象ユーザーが作成されていない、またはUIDがずれている。

**対処法:**

```bash
# 各配送SMTPで
id user1
# UIDが2001(統一値)であることを確認
```

---

#### エラー⑥: メールが届くが Maildir に保存されない

**原因:** NFSマウントが外れている、UID/GIDがずれている。

**対処法:**

```bash
# 配送SMTPで
df -h | grep share
# マウントされているか確認

ls -ln /var/spool/mail/
# 所有UIDが正しいか確認(数値で表示)
```

---

### ログの確認場所

| ログの種類 | 場所(パス) | 確認コマンド |
|-----------|------------|------------|
| OSシステムログ | `/var/log/messages` | `sudo tail -f /var/log/messages` |
| メールログ | `/var/log/maillog` | `sudo tail -f /var/log/maillog` |
| BINDログ | `journalctl -u named` | `sudo journalctl -u named -f` |
| Dovecotログ | `journalctl -u dovecot` | `sudo journalctl -u dovecot -f` |
| NFSサーバログ | `journalctl -u nfs-server` | `sudo journalctl -u nfs-server -f` |

---

## 7. 参考リソース・関連資料

| 資料名 | URL | 補足 |
|-------|-----|------|
| Postfix 公式ドキュメント | https://www.postfix.org/documentation.html | Postfix設定リファレンス |
| Postfix transport(5) | https://www.postfix.org/transport.5.html | transport_maps の仕様 |
| Postfix BASIC_CONFIGURATION_README | https://www.postfix.org/BASIC_CONFIGURATION_README.html | mydestination, relay_domains 解説 |
| Dovecot 公式ドキュメント | https://doc.dovecot.org/ | Dovecot設定リファレンス |
| BIND 公式ドキュメント (ISC) | https://www.isc.org/bind/ | BIND設定リファレンス |
| BIND view ドキュメント | https://bind9.readthedocs.io/ | view機能リファレンス |
| NFS 公式ドキュメント | https://linux-nfs.org/ | NFS設定リファレンス |

---

## 付録

### A. 環境変数・パラメータまとめ

| パラメータ名 | 自分の環境の値 | 説明 |
|------------|-------------|------|
| DNSサーバ プライベートIP `<DNS_PRI>` | `xx.xx.xx.xx` | NFSマウント先・内部DNS問い合わせ先 |
| DNSサーバ グローバルIP `<DNS_PUB>` | `xx.xx.xx.xx` | 外部DNS問い合わせ先・external view |
| 受信SMTP プライベートIP `<MX_PRI>` | `xx.xx.xx.xx` | internal view の `mx` Aレコード |
| 受信SMTP グローバルIP `<MX_PUB>` | `xx.xx.xx.xx` | external view の `mx` Aレコード |
| 配送SMTP1 プライベートIP `<D1_PRI>` | `xx.xx.xx.xx` | internal view の `user1.tr.local` Aレコード |
| 配送SMTP2 プライベートIP `<D2_PRI>` | `xx.xx.xx.xx` | internal view の `user2.tr.local` Aレコード |
| 配送SMTP3 プライベートIP `<D3_PRI>` | `xx.xx.xx.xx` | internal view の `user3.tr.local` Aレコード |
| 外部ドメイン | `ex.entrycl.net` | 公開メールアドレスのドメイン |
| 内部ドメイン | `tr.local` | サーバ間通信用ドメイン |
| メールユーザー | `user1, user2, user3` | UID = 2001, 2002, 2003 で統一 |

### B. 用語解説

| 用語 | 説明 |
|------|------|
| view(BIND) | 問い合わせ元IPによって異なるゾーン定義を返すBINDの機能 |
| `match-clients` | view がどのクライアントに応答するかを定義するBIND設定 |
| ACL(BIND) | クライアントIP範囲に名前を付ける仕組み |
| `transport_maps`(Postfix) | 宛先アドレスごとの転送先サーバを定義するマップ |
| `relay_domains`(Postfix) | リレーを許可するドメインのリスト |
| `mydestination`(Postfix) | 自分が最終配送するドメインのリスト |
| `mydomain`(Postfix) | 自分が「名乗る」ドメイン |
| ハッシュマップ(`.db`) | `postmap` で生成されるPostfix用の高速ルックアップDB |
| Maildir | 1メール1ファイルでメールを保存する形式。NFS環境で推奨 |
| internal-only zone | 内部からのみ解決可能なDNSゾーン。external view に含めないことで実現 |

### C. 削除・クリーンアップ手順

1. 配送SMTPサーバ側で `/etc/fstab` の追記行を削除し、`umount /var/spool/mail/` を実行
2. EC2インスタンスを5台とも終了する
3. セキュリティグループを削除する
4. キーペアを削除する(必要に応じて)

> **注意:** NFSマウント中のままEC2を終了するとマウントが残った状態になる可能性があるため、先にアンマウントすることを推奨。
