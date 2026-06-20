# SpamAssassin 基本・発展課題集

> スパムフィルタリングエンジン。Postfix・Dovecot とセットで使われる  
> 前提：AWS 無料利用枠の範囲内で実施可能な課題を基本とする  
> 作成日：2026年6月

---

## 目次

1. [基本課題 A：インストールと基本設定](#基本課題-aインストールと基本設定)
2. [基本課題 B：ルールとスコアリングの理解](#基本課題-bルールとスコアリングの理解)
3. [基本課題 C：Postfix との連携](#基本課題-cpostfix-との連携)
4. [発展課題 D：Bayes フィルターの学習](#発展課題-dbayes-フィルターの学習)
5. [発展課題 E：カスタムルールの作成](#発展課題-eカスタムルールの作成)
6. [発展課題 F：ClamAV との組み合わせ](#発展課題-fclamav-との組み合わせ)
7. [発展課題 G：監視と運用](#発展課題-g監視と運用)

---

## 基本課題 A：インストールと基本設定

**A-1. EC2 への SpamAssassin インストール**
- AL2023 の EC2 に SpamAssassin（`spamassassin`・`spamd`）をインストールし、`systemd` でサービス登録・自動起動を設定する
- `sa-update` でスパムルールデータベースを最新化し、cron で日次自動更新を設定する
- `spamassassin -V` でバージョンを確認し、`spamc -R < /path/to/test.eml` でテストメールを解析する

**A-2. 設定ファイルの基本設定**
- `/etc/mail/spamassassin/local.cf` で以下の基本設定を行う

```perl
# スパム判定スコアの閾値（デフォルト5.0）
required_score  5.0

# スパムメールの件名にタグを付ける
rewrite_header  Subject [SPAM]

# スパムと判定されたメールにヘッダーを追加
add_header all Status _YESNO_, score=_SCORE_ required=_REQD_

# Bayes フィルターを有効化
use_bayes  1
bayes_auto_learn  1
```

**A-3. テストメールによる動作確認**
- GTUBE（Generic Test for Unsolicited Bulk Email）文字列を含むテストメールを `spamassassin -t` で解析し、スパムとして検出されることを確認する
- 解析結果のスコアと各ルールのヒット状況を読み取り、スコアリングの仕組みを理解する

---

## 基本課題 B：ルールとスコアリングの理解

**B-1. スコアリングの仕組み**
- SpamAssassin のルール（`RCVD_IN_DNSWL_NONE`・`SPF_PASS`・`DKIM_VALID` 等）が各メールに適用され、スコアが加算・減算される仕組みを理解する
- `spamassassin -D -t < test.eml 2>&1 | less` でデバッグモードの詳細出力を確認し、どのルールが発火したかを特定する

**B-2. ホワイトリスト・ブラックリスト**
- `whitelist_from` で特定の送信者を常にスパム判定から除外する設定を行う
- `blacklist_from` で特定の送信者を常にスパムと判定する設定を行う

---

## 基本課題 C：Postfix との連携

**C-1. spamd デーモン経由の連携**
- `spamd` をデーモンとして起動し、Postfix の `master.cf` にコンテンツフィルターとして設定する
- メールの送受信テストで、スパムメールのヘッダーに `X-Spam-Status: Yes` が追加されることを確認する

**C-2. amavisd-new との組み合わせ**
- `amavisd-new` を Postfix とSpamAssassin の仲介として設定し、スパムと判定されたメールを隔離フォルダに移動する設定を行う

---

## 発展課題 D：Bayes フィルターの学習

**D-1. 学習データの投入**
- `sa-learn --spam /path/to/spam/` でスパムメールを学習させる
- `sa-learn --ham /path/to/ham/` で正常メールを学習させる
- `sa-learn --dump magic` で学習データの状態（スパム/ハム件数・トークン数）を確認する

**D-2. 自動学習の設定**
- Dovecot の Sieve スクリプトと連携し、ユーザーが「迷惑メール」フォルダに移動したメールを自動的に SpamAssassin に学習させる仕組みを構築する

---

## 発展課題 E：カスタムルールの作成

**E-1. 独自ルールの作成**
- 特定の件名パターン・本文キーワードにスコアを付与するカスタムルールを作成する

```perl
# local.cf にカスタムルールを追加
header LOCAL_SUBJECT_MATCH  Subject =~ /無料|当選|プレゼント/
score  LOCAL_SUBJECT_MATCH  3.0
describe LOCAL_SUBJECT_MATCH 日本語スパムキーワードを検出
```

**E-2. DNS ブラックリスト（DNSBL）の追加**
- `URIBL_BLACK`・`SORBS_SPAM` 等の DNS ベースブラックリストを有効化し、既知のスパム発信元からのメールのスコアを上げる設定を行う

---

## 発展課題 F：ClamAV との組み合わせ

**F-1. ClamAV インストールと連携**
- ClamAV をインストールし、`amavisd-new` 経由でウイルスチェックと SpamAssassin のスパムチェックを同時に実行する設定を行う
- ウイルス添付メールが到着した場合に管理者にアラートメールが届くことを確認する

---

## 発展課題 G：監視と運用

**G-1. ログ分析**
- Postfix のログから SpamAssassin によってスパム判定されたメールの件数を集計するスクリプトを作成する
- 1 日のスパム率・誤検知率を集計してレポートを生成し、閾値を超えた場合にアラートを送る仕組みを構築する

**G-2. ルールの定期更新**
- `sa-update` を cron で日次実行し、SpamAssassin のルールを常に最新化する
- 更新後に `spamd` を自動でリロードし、新しいルールが即座に有効になる設定を行う

---

*以上（SpamAssassin 基本・発展課題）*
