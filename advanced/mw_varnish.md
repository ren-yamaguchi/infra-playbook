# Varnish Cache 基本・発展課題集

> 前提：AWS 無料利用枠の範囲内で実施可能な課題を基本とする  
> CloudFront・Redis との比較視点を随所に盛り込み、使い分けの判断力を養う構成にしています  
> 作成日：2026年5月

---

## 目次

1. [基本課題 A：インストールと基本設定](#基本課題-aインストールと基本設定)
2. [基本課題 B：VCL による基本的なキャッシュ制御](#基本課題-bvcl-による基本的なキャッシュ制御)
3. [基本課題 C：キャッシュの動作確認と検証](#基本課題-cキャッシュの動作確認と検証)
4. [発展課題 D：VCL の高度な制御](#発展課題-dvcl-の高度な制御)
5. [発展課題 E：WordPress との連携](#発展課題-ewordpress-との連携)
6. [発展課題 F：パフォーマンスチューニング](#発展課題-fパフォーマンスチューニング)
7. [発展課題 G：監視と運用](#発展課題-g監視と運用)
8. [発展課題 H：セキュリティと高可用性](#発展課題-hセキュリティと高可用性)
9. [発展課題 I：CloudFront / Redis との比較と使い分け](#発展課題-icloudfront--redis-との比較と使い分け)

---

## 基本課題 A：インストールと基本設定

**A-1. EC2 への Varnish インストール**
- AL2023 の EC2 に Varnish をインストールし、`systemd` でサービスとして登録・自動起動を設定する
- Varnish をポート 80 で待ち受け、バックエンドの Apache / Nginx をポート 8080 で動作させる構成に変更する
- `varnishd -V` でバージョンを確認し、`varnishadm ping` で管理インターフェースへの接続を確認する

```bash
# Varnish のリスニングポートを 80 に変更（/etc/varnish/varnish.params）
VARNISH_LISTEN_PORT=80
VARNISH_BACKEND_PORT=8080

# Apache のポートを 8080 に変更（/etc/httpd/conf/httpd.conf）
Listen 8080
```

**A-2. 基本的な VCL 設定**
- `/etc/varnish/default.vcl` でバックエンドを定義し、Varnish 経由でバックエンドのコンテンツが返ることを確認する

```vcl
vcl 4.1;

backend default {
    .host = "127.0.0.1";
    .port = "8080";
}
```

**A-3. Varnish のアーキテクチャ理解**
- Varnish の処理フロー（`vcl_recv` → `vcl_hash` → `vcl_hit` / `vcl_miss` → `vcl_backend_fetch` → `vcl_deliver`）を図に整理する
- 各サブルーチン（`vcl_recv`・`vcl_backend_response`・`vcl_deliver`）でどのような制御を行うべきかをまとめる
- `pass`・`hash`（lookup）・`pipe`・`synth` アクションの違いと使い所を理解する

---

## 基本課題 B：VCL による基本的なキャッシュ制御

**B-1. キャッシュの有効化と除外**
- デフォルトでは Cookie を含むリクエストはキャッシュされないことを確認し、静的ファイル（画像・CSS・JS）の Cookie を除去してキャッシュを有効化する

```vcl
sub vcl_recv {
    # 静的ファイルは Cookie を除去してキャッシュ対象にする
    if (req.url ~ "\.(png|jpg|jpeg|gif|css|js|ico|woff2)$") {
        unset req.http.Cookie;
    }
}
```

**B-2. TTL の設定**
- `vcl_backend_response` でバックエンドのレスポンスに対してキャッシュ TTL を設定する
- 静的ファイルは TTL を長く（1 日）、HTML は短く（60 秒）設定し、コンテンツ種別ごとの TTL を管理する
- `beresp.ttl`・`beresp.grace`・`beresp.keep` の違いを理解し、バックエンド障害時の Grace モードの動作を確認する

**B-3. キャッシュキーのカスタマイズ**
- `vcl_hash` でキャッシュキーに含める要素を制御し、URL とクエリパラメーターのみをキャッシュキーとして使う設定を行う
- `X-Forwarded-Proto` をキャッシュキーに含め、HTTP と HTTPS のキャッシュを分離する設定を行う

---

## 基本課題 C：キャッシュの動作確認と検証

**C-1. キャッシュヒットの確認**
- `varnishlog -i RespHeader -q "RespHeader:X-Cache"` でキャッシュヒット・ミスのログをリアルタイムで確認する
- `vcl_deliver` でレスポンスヘッダーに `X-Cache: HIT` または `X-Cache: MISS` を付与し、`curl -I` で確認できるようにする

```vcl
sub vcl_deliver {
    if (obj.hits > 0) {
        set resp.http.X-Cache = "HIT";
        set resp.http.X-Cache-Hits = obj.hits;
    } else {
        set resp.http.X-Cache = "MISS";
    }
}
```

**C-2. キャッシュヒット率の計測**
- `varnishstat -1 -f MAIN.cache_hit -f MAIN.cache_miss` でキャッシュヒット数・ミス数を取得する
- `ab` で 1000 件のリクエストを送り、キャッシュ有効・無効でバックエンドへのリクエスト数の違いを比較する

**C-3. キャッシュの手動パージ**
- `BAN` コマンドで特定の URL パターンにマッチするキャッシュを一括削除する
- `PURGE` リクエストで特定 URL のキャッシュを即時削除する設定を VCL に追加し、動作を確認する

```vcl
sub vcl_recv {
    if (req.method == "PURGE") {
        if (req.http.X-Real-IP != "10.0.1.0/24") {
            return (synth(403, "Forbidden"));
        }
        return (purge);
    }
}
```

---

## 発展課題 D：VCL の高度な制御

**D-1. デバイス別キャッシュ**
- `User-Agent` を解析してデバイス種別（PC / Mobile / Tablet）を判定し、デバイスごとに異なるキャッシュを保持する設定を実装する
- `vcl_hash` でデバイス種別をキャッシュキーに含め、モバイル向けとデスクトップ向けで別のコンテンツを返す構成を実現する

**D-2. 地域・言語別キャッシュ**
- `Accept-Language` ヘッダーを解析し、言語別に異なるキャッシュエントリを保持する設定を行う
- `Vary` ヘッダーへの対応（バックエンドが `Vary: Accept-Language` を返す場合の動作）を確認する

**D-3. 動的コンテンツの部分キャッシュ（ESI）**
- ESI（Edge Side Includes）を有効化し、ページの一部（ヘッダー・フッターなど共通部分）はキャッシュし、個人化部分はキャッシュしない構成を実装する
- `<esi:include src="/header" />` タグをバックエンドのレスポンスに追加し、Varnish が ESI を処理することを確認する

**D-4. リクエストのリライトとリダイレクト**
- `vcl_recv` でリクエスト URL を書き換え（例：`/old-path` → `/new-path`）、バックエンドへのリクエストを変換する
- `synth(301, ...)` で Varnish からリダイレクトレスポンスを直接返し、バックエンドにリクエストを転送せずにリダイレクトを処理する

---

## 発展課題 E：WordPress との連携

**E-1. WordPress + Varnish の基本設定**
- WordPress の前段に Varnish を配置し、匿名ユーザーのページビューをキャッシュする設定を実装する
- ログイン済みユーザー（`wordpress_logged_in_*` Cookie を持つリクエスト）はキャッシュをバイパスし、常にバックエンドに転送する設定を行う

```vcl
sub vcl_recv {
    # ログイン済みユーザーはキャッシュをバイパス
    if (req.http.Cookie ~ "wordpress_logged_in") {
        return (pass);
    }
    # 管理画面へのアクセスはキャッシュしない
    if (req.url ~ "^/wp-admin") {
        return (pass);
    }
}
```

**E-2. WordPress のキャッシュパージ連携**
- WordPress のコンテンツ更新時（投稿・更新・コメント）に、対象ページのキャッシュを自動でパージするプラグイン（`Varnish HTTP Purge`）を導入する
- 記事を更新した際に Varnish のキャッシュが自動でパージされ、次のアクセスで最新コンテンツが返ることを確認する

**E-3. パフォーマンス効果の計測**
- `ab` で Varnish あり・なしで WordPress のレスポンスタイムとスループットを比較し、キャッシュ効果を数値で示す
- `varnishstat` でキャッシュヒット率を計算し、設定改善によるヒット率の向上を確認する

---

## 発展課題 F：パフォーマンスチューニング

**F-1. メモリ設定の最適化**
- Varnish のキャッシュストレージサイズ（`-s malloc,256m` など）を EC2 の RAM に合わせて調整する
- `varnishstat -1 -f MAIN.n_object` でキャッシュオブジェクト数を確認し、メモリ使用量とのバランスを取る

**F-2. スレッドプールの調整**
- `thread_pools`・`thread_pool_min`・`thread_pool_max` を調整し、同時リクエスト処理能力を最適化する
- `varnishstat -1 -f MAIN.threads` でスレッド数をリアルタイム監視し、スレッド不足が発生していないか確認する

**F-3. 圧縮の設定**
- `http_gzip_support on` を有効化し、Varnish が gzip 圧縮されたコンテンツをキャッシュする設定を行う
- クライアントが gzip を要求している場合のみ圧縮済みコンテンツを返し、非対応クライアントには非圧縮で返す動作を確認する

---

## 発展課題 G：監視と運用

**G-1. varnishstat による統計モニタリング**
- `varnishstat` でリアルタイムに以下のメトリクスを監視するダッシュボードスクリプトを作成する

| メトリクス | 確認内容 |
|-----------|---------|
| `MAIN.cache_hit` / `MAIN.cache_miss` | キャッシュヒット率 |
| `MAIN.n_object` | キャッシュオブジェクト数 |
| `MAIN.threads` | アクティブスレッド数 |
| `MAIN.backend_fail` | バックエンド接続失敗数 |
| `MAIN.sess_dropped` | 廃棄されたセッション数 |

**G-2. varnishlog による詳細ログ分析**
- `varnishlog` でリアルタイムにリクエストの詳細ログを確認する
- `varnishncsa` で Apache 形式のアクセスログを出力し、`GoAccess` で可視化する
- CloudWatch Logs にログを転送し、キャッシュミス率が急増した場合のアラームを設定する

**G-3. Zabbix による監視**
- Zabbix のユーザーパラメーターで `varnishstat` の値を定期取得し、以下のトリガーを設定する
  - キャッシュヒット率が 50% を下回った場合
  - バックエンド接続失敗が発生した場合
  - キャッシュオブジェクト数が急減した場合（大量パージ検知）

---

## 発展課題 H：セキュリティと高可用性

**H-1. 管理インターフェースの保護**
- `varnishadm` の管理ポート（6082）を `127.0.0.1` のみにバインドし、外部からアクセスできないようにする
- `PURGE` リクエストを受け付ける IP アドレスを VCL で制限し、不正なキャッシュパージを防ぐ

**H-2. バックエンドの障害対応**
- `beresp.grace` を設定し、バックエンドが停止した場合でも古いキャッシュを一定時間提供する Grace モードを有効化する
- バックエンドのヘルスチェック（`.probe`）を設定し、バックエンドが回復した場合に自動で通常のキャッシュ動作に戻ることを確認する

```vcl
backend default {
    .host = "127.0.0.1";
    .port = "8080";
    .probe = {
        .url = "/health";
        .timeout = 2s;
        .interval = 5s;
        .window = 5;
        .threshold = 3;
    }
}
```

**H-3. 複数バックエンドへの対応**
- `directors`（`random`・`round_robin`・`fallback`）を使って複数バックエンドへの振り分けを設定する
- `fallback` ディレクターでプライマリバックエンドが停止した場合にセカンダリに自動切り替えされる設定を行い、高可用性を実現する

---

## 発展課題 I：CloudFront / Redis との比較と使い分け

**I-1. 比較表の作成**
- 以下の観点で Varnish・CloudFront・Redis の比較表を作成する

| 観点 | Varnish | CloudFront | Redis |
|------|---------|-----------|-------|
| キャッシュ対象 | HTTP レスポンス | HTTP レスポンス | アプリデータ |
| 設置場所 | オリジン近傍 | エッジ（世界中） | アプリ近傍 |
| 管理コスト | 高（自己管理） | 低（マネージド） | 中（自己管理） |
| 細かな制御 | 最高（VCL） | 中 | 高（TTL・型） |
| 動的コンテンツ | ESI で部分対応 | Lambda@Edge | 完全対応 |
| コスト | EC2 料金のみ | 従量課金 | EC2 料金のみ |
| SSL 対応 | 要別途設定 | ◎（ACM 連携） | 対応あり |

**I-2. 用途別の選択基準**
- 以下のシナリオでどのキャッシュを選択すべきか、理由とともに整理する
  - グローバルユーザー向けに静的ファイルを高速配信したい場合 → CloudFront
  - オリジンサーバーへの負荷を削減し、きめ細かなキャッシュ制御を行いたい場合 → Varnish
  - セッション・DBクエリ結果・計算結果をアプリ内でキャッシュしたい場合 → Redis
  - 上記すべてを組み合わせた多層キャッシュ構成を設計する場合

---

*以上（Varnish Cache 基本・発展課題）*
