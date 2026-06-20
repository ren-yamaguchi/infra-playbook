# Unbound 基本・発展課題集

> キャッシュ専用 DNS リゾルバー。BIND との役割分担が現場で頻出のミドルウェア  
> 前提：AWS 無料利用枠の範囲内で実施可能な課題を基本とする  
> 作成日：2026年6月

---

## 目次

1. [基本課題 A：インストールと基本設定](#基本課題-aインストールと基本設定)
2. [基本課題 B：フォワーダーとキャッシュの設定](#基本課題-bフォワーダーとキャッシュの設定)
3. [基本課題 C：アクセス制御とセキュリティ基礎](#基本課題-cアクセス制御とセキュリティ基礎)
4. [発展課題 D：BIND との役割分担構成](#発展課題-dbind-との役割分担構成)
5. [発展課題 E：DNSSEC の検証](#発展課題-ednssec-の検証)
6. [発展課題 F：DNS over TLS / DNS over HTTPS](#発展課題-fdns-over-tls--dns-over-https)
7. [発展課題 G：パフォーマンスチューニング](#発展課題-gパフォーマンスチューニング)
8. [発展課題 H：監視と運用](#発展課題-h監視と運用)
9. [発展課題 I：Route 53 / BIND との比較と使い分け](#発展課題-iroute-53--bind-との比較と使い分け)

---

## 基本課題 A：インストールと基本設定

**A-1. EC2 への Unbound インストール**
- AL2023 の EC2 に Unbound をインストールし、`systemd` でサービス登録・自動起動を設定する
- `unbound -V` でバージョンとコンパイルオプションを確認する
- `unbound-checkconf` で設定ファイルの文法チェックを行い、正常終了することを確認する

**A-2. 基本設定ファイルの理解**
- `/etc/unbound/unbound.conf` の主要ディレクティブを設定する

```yaml
server:
    interface: 0.0.0.0
    port: 53
    do-ip4: yes
    do-ip6: no
    do-udp: yes
    do-tcp: yes
    access-control: 127.0.0.1/32 allow
    access-control: 10.0.0.0/16 allow   # VPC CIDR
    access-control: 0.0.0.0/0 refuse
    verbosity: 1
    logfile: /var/log/unbound/unbound.log
    cache-max-ttl: 86400
    cache-min-ttl: 0
```

**A-3. 名前解決の動作確認**
- `dig @localhost google.com` で Unbound 経由の名前解決が成功することを確認する
- 2 回目以降の問い合わせでキャッシュから返ることを `dig` の `Query time` が短縮されることで確認する
- `unbound-control stats` でキャッシュヒット数・クエリ数を確認する

---

## 基本課題 B：フォワーダーとキャッシュの設定

**B-1. フォワーダーの設定**
- 特定ドメインの問い合わせを指定 DNS サーバーに転送する設定を行う

```yaml
forward-zone:
    name: "."
    forward-addr: 8.8.8.8        # Google Public DNS
    forward-addr: 1.1.1.1        # Cloudflare DNS
```

**B-2. スタブゾーンによる内部ドメインの設定**
- 内部ドメイン（例：`internal.example.local`）の問い合わせを内部 BIND サーバーに転送するスタブゾーンを設定する

```yaml
stub-zone:
    name: "internal.example.local"
    stub-addr: 10.0.1.100        # BIND サーバーの IP
```

**B-3. ローカルレコードの設定**
- `local-data` でホスト名と IP のマッピングをローカルに定義し、外部 DNS に問い合わせずに名前解決できることを確認する

```yaml
server:
    local-data: "web.internal. A 10.0.1.10"
    local-data-ptr: "10.0.1.10 web.internal."
```

---

## 基本課題 C：アクセス制御とセキュリティ基礎

**C-1. アクセス制御の設定**
- `access-control` で許可する IP レンジを最小化し、VPC CIDR 以外からの問い合わせを `refuse` する設定を行う
- `refuse`（エラー応答）と `deny`（無応答）の違いを確認し、セキュリティ観点での使い分けをまとめる

**C-2. DNS キャッシュポイズニング対策**
- `use-caps-for-id: yes`（0x20 エンコーディング）を設定し、キャッシュポイズニング耐性を高める
- `harden-glue: yes`・`harden-dnssec-stripped: yes` を設定し、不正なグルーレコードや DNSSEC 情報の剥奪攻撃に対する防御を有効化する

---

## 発展課題 D：BIND との役割分担構成

**D-1. BIND（権威 DNS）+ Unbound（キャッシュ DNS）の分離構成**
- EC2-a に BIND（権威 DNS・内部ゾーン管理）、EC2-b に Unbound（キャッシュ DNS・クライアント向け）を配置する
- Unbound のスタブゾーンで内部ドメインを BIND に転送し、外部ドメインはパブリック DNS（8.8.8.8 等）に転送する構成を実装する
- クライアントの DNS 設定を Unbound の IP に向け、内部・外部どちらの名前解決も Unbound 経由で完結する構成を確認する

**D-2. キャッシュの分離による効果**
- BIND にキャッシュ機能を持たせず権威応答のみに専念させ、Unbound がキャッシュを担当することで BIND の負荷が削減されることを `unbound-control stats` と BIND の `rndc stats` で比較する

---

## 発展課題 E：DNSSEC の検証

**E-1. DNSSEC 検証の有効化**
- `auto-trust-anchor-file` でトラストアンカーを設定し、DNSSEC の署名検証を有効化する
- `dig @localhost +dnssec google.com` で DNSSEC 対応ドメインの応答に `ad`（Authentic Data）フラグが立つことを確認する
- DNSSEC 署名のないドメインと署名のあるドメインで応答の違いを確認する

**E-2. DNSSEC 検証失敗のシミュレーション**
- 意図的に不正なドメインへの問い合わせを行い、Unbound が `SERVFAIL` を返してクライアントを保護することを確認する

---

## 発展課題 F：DNS over TLS / DNS over HTTPS

**F-1. DNS over TLS（DoT）の設定**
- Unbound で TLS（853 番ポート）による暗号化 DNS クエリを受け付ける設定を行う
- `kdig @localhost +tls google.com` で TLS 接続による名前解決が成功することを確認する
- 平文 DNS（53 番）と DoT（853 番）の通信をパケットキャプチャで比較し、暗号化の効果を確認する

**F-2. フォワード先への DoT 設定**
- アップストリームへの転送を DoT で暗号化し、ISP によるクエリの盗聴・改ざんを防ぐ設定を行う

```yaml
forward-zone:
    name: "."
    forward-tls-upstream: yes
    forward-addr: 1.1.1.1@853#cloudflare-dns.com
    forward-addr: 8.8.8.8@853#dns.google
```

---

## 発展課題 G：パフォーマンスチューニング

**G-1. キャッシュサイズの最適化**
- `msg-cache-size`（DNS メッセージキャッシュ）と `rrset-cache-size`（リソースレコードキャッシュ）を EC2 の RAM に合わせて調整する
- `prefetch: yes` を設定し、TTL 期限切れ前にキャッシュをプリフェッチして遅延を削減する

**G-2. スレッド数の最適化**
- `num-threads` を CPU コア数に合わせて設定し、マルチスレッドによる並列クエリ処理を有効化する
- `so-reuseport: yes` を設定してポートの再利用を許可し、スレッド間の競合を削減する

**G-3. ベンチマーク**
- `dnsperf` で Unbound・BIND・Route 53 Resolver のクエリ応答速度とスループットを比較する

---

## 発展課題 H：監視と運用

**H-1. unbound-control による管理**
- `unbound-control stats_noreset` で統計情報を取得し、以下のメトリクスを定期収集するスクリプトを作成する

| メトリクス | 確認内容 |
|-----------|---------|
| `total.num.queries` | 総クエリ数 |
| `total.num.cachehits` | キャッシュヒット数 |
| `total.num.cachemiss` | キャッシュミス数 |
| `total.num.recursivereplies` | 再帰問い合わせ数 |
| `mem.cache.rrset` | rrset キャッシュのメモリ使用量 |

**H-2. Zabbix による監視**
- Zabbix のユーザーパラメーターで `unbound-control stats` の値を取得し、キャッシュヒット率の低下・応答時間の増加でアラートを発火させる

---

## 発展課題 I：Route 53 / BIND との比較と使い分け

**I-1. 三者比較表の作成**

| 観点 | Unbound | BIND | Route 53 Resolver |
|------|---------|------|------------------|
| 主な用途 | キャッシュ DNS | 権威 DNS・キャッシュ DNS | VPC 内の名前解決 |
| 権威 DNS 機能 | なし | あり | なし（委任先） |
| DNSSEC 検証 | ◎ | ○ | ○（自動） |
| DoT / DoH | ◎ | 限定的 | なし |
| 管理コスト | 低 | 高 | 最低（マネージド） |
| カスタマイズ性 | 高 | 最高 | 低 |

**I-2. 推奨構成パターン**
- 小規模（EC2 数台）：Route 53 Resolver（デフォルト）のみで十分
- 中規模（内部ドメイン管理が必要）：BIND（権威）+ Unbound（キャッシュ）の分離構成
- キャッシュ特化・DNSSEC 検証強化：Unbound をキャッシュ DNS として前段に配置

---

*以上（Unbound 基本・発展課題）*
