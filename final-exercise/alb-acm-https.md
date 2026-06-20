# ACMとALBを用いたHTTPS化構築

------------------------------

## 1. ドキュメント情報

| 項目 | 内容 |
|------|------|
| 手順書名 | ACMとALBを用いたHTTPS化構築 |
| 作成日 | 2026-06-18 |
| 最終更新日 | 2026-06-18 |
| バージョン | v1.0 |
| 対象環境 | AWS（Amazon Linux 2023） |

> **改訂履歴**
>
> | バージョン | 日付 | 変更内容 |
> |-----------|------|---------|
> | v1.0 | 2026-06-18 | 初版作成（元`ACM-ALB構築手順書.md`を機能分割して再構成．本手順書はACMインポート以降のAWSコンソール／CLI操作を範囲とする．証明書取得までは別手順書`nsd-public-letsencrypt.md`を参照．構成図追加．プレースホルダーを意味ベース日本語に統一．パラメータ定義表を整理．各Stepに【実施対象】明示．句読点を「，．」に統一．サーバー表記を「サーバー」に統一．付録A〜D追加．） |

------------------------------

## 2. 目的・概要

### 2-1. 目的

> 本手順書では，別手順書（`nsd-public-letsencrypt.md`）で取得済みのLet's Encrypt証明書をAWS Certificate Manager（ACM）にインポートし，Application Load Balancer（ALB）を構築してWebサーバーへのHTTPS通信を実現する手順について説明する．
> ALBにはターゲットグループを設定し，HTTP（80）はHTTPSへリダイレクトし，HTTPS（443）はバックエンドのWebサーバーへ転送する．
>
> **本手順書の前提：** 証明書ファイル（`cert.pem` / `privkey.pem` / `chain.pem`）が `/etc/letsencrypt/live/<取得するサブドメイン>/` に取得済みであること．
> **本手順書の範囲外：** 証明書取得（`nsd-public-letsencrypt.md`を参照），Webサーバー自体の構築（`nginx-reverse-proxy.md`等を参照）．

### 2-2. 構成概要（アーキテクチャ）

```
[インターネット（ユーザー）]
       │
       │ HTTP(80) / HTTPS(443)
       │ FQDN：<取得するサブドメイン>
       │
       ▼
┌───────────────────────── VPC ──────────────────────────────┐
│                                                            │
│  [ALB（Public subnet）]                                     │
│    ├─ リスナー HTTP:80  ─→ HTTPS:443 リダイレクト (301)      │
│    └─ リスナー HTTPS:443                                    │
│         ├─ ACM証明書（インポート済み）                        │
│         └─ ターゲットグループ                                │
│                │                                          │
│                │ HTTP:80                                   │
│                ▼                                           │
│  [EC2: Webサーバー]                                         │
│    ├─ Nginx等（80番）                                       │
│    └─ /healthcheck （ALBのヘルスチェック用）                  │
│                                                            │
│  [ACM]                                                     │
│    └─ <取得するサブドメイン> 用証明書（インポート済み）          │
│         ↑                                                  │
│         │ インポート                                         │
│         │                                                  │
│   別手順書 `nsd-public-letsencrypt.md` で取得                │
│   /etc/letsencrypt/live/<取得するサブドメイン>/             │
│        ├─ cert.pem    ─→ ACM「証明書本文」                  │
│        ├─ privkey.pem ─→ ACM「プライベートキー」              │
│        └─ chain.pem   ─→ ACM「証明書チェーン」                │
│                                                            │
└────────────────────────────────────────────────────────────┘
```

### 2-3. 完成イメージ（ゴール定義）

- [ ] ACMに `<取得するサブドメイン>` 用証明書がインポートされ「使用中」状態である
- [ ] ターゲットグループが作成され，対象Webサーバーが「Healthy」状態である
- [ ] ALBが「Active」状態で，HTTPリスナーとHTTPSリスナーが両方設定されている
- [ ] HTTPリスナーがHTTPSへの301リダイレクトを実行する
- [ ] HTTPSリスナーがACM証明書を使用しターゲットグループへ転送する
- [ ] WebサーバーのSGがALBのSGからの80番接続を許可している
- [ ] ブラウザで `https://<取得するサブドメイン>` にアクセスし，Webサーバーのコンテンツが正常表示される
- [ ] `https://<取得するサブドメイン>` でブラウザの鍵マークが緑になり証明書エラーが出ない

------------------------------

## 3. 前提条件・準備

### 3-1. 環境要件

| 項目 | 要件 |
|------|------|
| Webサーバー | EC2インスタンスで起動済み（例：`nginx-reverse-proxy.md`で構築） |
| 証明書 | Let's Encryptで取得済み（`nsd-public-letsencrypt.md`完了） |
| AWS IAM | ACM／EC2／ELB操作権限 |
| AWS CLI | ローカルPCもしくは作業EC2にインストール済みで認証情報設定済み |
| Webサーバーの`/healthcheck` | ヘルスチェック用エンドポイントが200を返す状態 |

### 3-2. セキュリティグループ設定

#### 3-2-1. ALBに割り当てるSG（新規作成）

| 方向 | タイプ | プロトコル | ポート | ソース／送信先 | 説明 |
|------|-------|-----------|-------|---------------|------|
| インバウンド | HTTP | TCP | 80 | 0.0.0.0/0 | インターネットからのHTTP受付（リダイレクト用） |
| インバウンド | HTTPS | TCP | 443 | 0.0.0.0/0 | インターネットからのHTTPS受付 |
| アウトバウンド | HTTP | TCP | 80 | WebサーバーのSG | バックエンドWebサーバーへの転送 |

#### 3-2-2. WebサーバーのSG（修正）

| 方向 | タイプ | プロトコル | ポート | ソース | 説明 |
|------|-------|-----------|-------|--------|------|
| インバウンド | HTTP | TCP | 80 | ALBのSG | **本手順書のStep 5で追加** |
| インバウンド | SSH | TCP | 22 | マイIP | 既存（変更不要） |

> **重要：** WebサーバーのSGインバウンドソースに **`0.0.0.0/0`** を設定しないこと．ALBを経由せず直接80番にアクセスされてしまう．

### 3-3. パラメータ定義表

> **注意：** 以下の値は作業前に環境に合わせて記入してから作業を開始すること．

#### 共通

| パラメータ名 | 値 | 説明 |
|------------|---|------|
| `<取得するサブドメイン>` | `<記入する>` | `nsd-public-letsencrypt.md`で証明書取得済みのFQDN |
| `<リージョン>` | 例：`us-west-2` | AWSリージョン |
| `<VPC ID>` | `<記入する>` | ALB／Webサーバーが配置されているVPC |
| `<AZ1>` | 例：`us-west-2a` | ALBを配置するAZ1 |
| `<AZ2>` | 例：`us-west-2b` | ALBを配置するAZ2 |
| `<Public subnet ID 1>` | `<記入する>` | AZ1のPublic subnet |
| `<Public subnet ID 2>` | `<記入する>` | AZ2のPublic subnet |

#### ALB／ターゲットグループ

| パラメータ名 | 値 | 説明 |
|------------|---|------|
| `<ALB名>` | 例：`alb-public-1` | ALBの名前（小文字英数字とハイフン） |
| `<ターゲットグループ名>` | 例：`web-tg-1` | ターゲットグループの名前 |
| `<ヘルスチェックパス>` | `/healthcheck` | ALBがWebサーバーに対して定期的にチェックするパス |

#### Webサーバー

| パラメータ名 | 値 | 説明 |
|------------|---|------|
| `<Webサーバーのインスタンス名>` | `<記入する>` | 対象EC2のNameタグ |
| `<WebサーバーのインスタンスID>` | `<記入する>` | 対象EC2のインスタンスID（`i-xxxxxxxx`） |
| `<WebサーバーのSG ID>` | `<記入する>` | 既存のWebサーバー側SG ID |

#### ロールバック用（任意）

| パラメータ名 | 値 | 説明 |
|------------|---|------|
| `<ALBのSG ID>` | `<Step 4で確定>` | Step 4で割り当てたALBのSG ID |
| `<ACM証明書ARN>` | `<Step 1で確定>` | Step 1でインポートした証明書のARN |

### 3-4. リンク一覧

| 項目名 | 目的 |
|-------|------|
| https://docs.aws.amazon.com/ja_jp/acm/latest/userguide/ | AWS Certificate Manager公式ガイド |
| https://docs.aws.amazon.com/ja_jp/elasticloadbalancing/latest/application/ | Application Load Balancer公式ガイド |
| https://docs.aws.amazon.com/ja_jp/cli/latest/reference/acm/ | AWS CLI acmコマンドリファレンス |
| https://docs.aws.amazon.com/ja_jp/cli/latest/reference/elbv2/ | AWS CLI elbv2コマンドリファレンス |

### 3-5. 事前確認

#### 3-5-1. AWS CLI接続確認【実施対象：ローカルPCまたは作業EC2】

```bash
aws sts get-caller-identity --region <リージョン>
```

> **期待する結果：** `UserId` / `Account` / `Arn` が表示される．

#### 3-5-2. 証明書ファイルの確認【実施対象：対外DNSサーバー】

```bash
ls -l /etc/letsencrypt/live/<取得するサブドメイン>/
```

> **期待する結果：** `cert.pem` / `privkey.pem` / `chain.pem` / `fullchain.pem` が存在．

#### 3-5-3. Webサーバーの動作確認【実施対象：Webサーバー】

```bash
# Webサーバーが起動していること
systemctl status nginx --no-pager

# /healthcheck が200を返すこと
curl -I http://localhost/healthcheck
```

> **期待する結果：** `HTTP/1.1 200 OK`（Nginxの場合．Webサーバーの種類に応じて変わる）．

> **注意：** `/healthcheck` エンドポイントが用意されていない場合は，Webサーバー側で先に追加すること（`nginx-reverse-proxy.md`参照）．

------------------------------

## 4. 構築手順（詳細）

> **注意事項**
> - 本手順書は **AWSコンソール（GUI）操作と AWS CLI 操作の両方** を含む
> - 各Stepの見出し末尾に **【実施対象：●●】** を明示しているので，対象の場所で実施すること
> - 既存リソース（Webサーバー，VPC等）への影響を最小化するため，**新規構築のみ** を行う方針とする

------------------------------

### Step 1：ACMに証明書をインポート【実施対象：AWSコンソール（ACM）】

**目的：** Let's Encrypt証明書をAWS Certificate Managerに登録する

#### Step 1-1：証明書ファイル内容の準備【実施対象：対外DNSサーバー】

```bash
# 証明書本文
cat /etc/letsencrypt/live/<取得するサブドメイン>/cert.pem

# プライベートキー
cat /etc/letsencrypt/live/<取得するサブドメイン>/privkey.pem

# 中間CA証明書チェーン
cat /etc/letsencrypt/live/<取得するサブドメイン>/chain.pem
```

それぞれの出力内容をすべてコピー（`-----BEGIN ～ -----END～-----` まで含めて）して別ファイルに保存しておく．

#### Step 1-2：ACMコンソールで証明書をインポート【実施対象：AWSコンソール】

```
1. AWSコンソール → Certificate Manager → 対象のリージョン（<リージョン>）を選択
2. 左メニュー「証明書」をクリック
3. 右上「証明書をインポート」をクリック
4. 以下を入力：
     - 証明書本文       ：cert.pem の内容
     - 証明書のプライベートキー ：privkey.pem の内容
     - 証明書チェーン   ：chain.pem の内容
5. （任意）タグを追加
6. 「次へ」→「確認とリクエスト」→「インポート」
```

> **重要：** **`chain.pem` を必ず入力すること**．省略するとブラウザによって証明書検証エラーになる場合がある．

> **補足：** AWS CLIでもインポート可能：
>
> ```bash
> aws acm import-certificate \
>     --certificate fileb:///etc/letsencrypt/live/<取得するサブドメイン>/cert.pem \
>     --private-key fileb:///etc/letsencrypt/live/<取得するサブドメイン>/privkey.pem \
>     --certificate-chain fileb:///etc/letsencrypt/live/<取得するサブドメイン>/chain.pem \
>     --region <リージョン>
> ```

#### Step 1-3：証明書ARNの控え

ACMコンソールでインポートした証明書のARNを確認し，パラメータ定義表の `<ACM証明書ARN>` 欄に記入する．

```
例：arn:aws:acm:us-west-2:123456789012:certificate/abcd1234-...
```

------------------------------

### Step 2：ターゲットグループの作成【実施対象：AWSコンソール（EC2）】

**目的：** ALBがリクエストを送る先（Webサーバー）を登録するターゲットグループを作成する

#### 操作手順

```
1. EC2コンソール → 左メニュー「ターゲットグループ」をクリック
2. 「ターゲットグループの作成」をクリック
3. 以下を入力：
```

##### 基本設定

| 設定項目 | 設定値 |
|---------|--------|
| ターゲットタイプ | インスタンス |
| ターゲットグループ名 | `<ターゲットグループ名>` |
| プロトコル | HTTP |
| ポート | 80 |
| プロトコルバージョン | HTTP1 |
| VPC | `<VPC ID>` |

##### ヘルスチェック設定

| 設定項目 | 設定値 |
|---------|--------|
| プロトコル | HTTP |
| パス | `<ヘルスチェックパス>` |
| 正常のしきい値 | 5 |
| 非正常のしきい値 | 2 |
| タイムアウト | 5秒 |
| 間隔 | 30秒 |
| 成功コード | 200 |

##### ターゲット登録

| インスタンスID | ポート |
|--------------|--------|
| `<WebサーバーのインスタンスID>` | 80 |

```
4. 「ターゲットグループの作成」をクリック
```

> **注意：** この時点ではターゲットが「unused」または「initial」状態．ALB作成後に「healthy」に遷移する．

------------------------------

### Step 3：ALBを作成【実施対象：AWSコンソール（EC2）】

**目的：** Application Load Balancerを作成し，HTTP→HTTPSリダイレクトとHTTPS転送設定を行う

#### 操作手順

```
1. EC2コンソール → 左メニュー「ロードバランサー」をクリック
2. 「ロードバランサーの作成」をクリック
3. 「Application Load Balancer」の「作成」をクリック
```

##### 基本設定

| 設定項目 | 設定値 |
|---------|--------|
| ロードバランサー名 | `<ALB名>` |
| スキーム | インターネット向け |
| IPアドレスタイプ | IPv4 |

##### ネットワーク設定

| 設定項目 | 設定値 |
|---------|--------|
| VPC | `<VPC ID>` |
| AZ1 | `<AZ1>`：`<Public subnet ID 1>` |
| AZ2 | `<AZ2>`：`<Public subnet ID 2>` |

> **重要：** **Public subnetを必ず選択する**．Private subnetでは外部からアクセス不可．

##### セキュリティグループ設定

3-2-1で設計した新規SGを作成して割り当てる：

| インバウンド/アウトバウンド | タイプ | ポート | ソース／送信先 |
|------|--------|--------|--------|
| インバウンド | HTTP | 80 | 0.0.0.0/0 |
| インバウンド | HTTPS | 443 | 0.0.0.0/0 |
| アウトバウンド | HTTP | 80 | `<WebサーバーのSG ID>` |

SG作成後，**作成されたSG IDをパラメータ定義表の `<ALBのSG ID>` に記入** すること（Step 5で使用）．

##### リスナー設定

**リスナー1（HTTP）**

| 設定項目 | 設定値 |
|---------|--------|
| プロトコル：ポート | HTTP：80 |
| デフォルトアクション | 「URLにリダイレクト」を選択 |
| リダイレクト先プロトコル | HTTPS |
| リダイレクト先ポート | 443 |
| ステータスコード | 301 |

**リスナー2（HTTPS）**

| 設定項目 | 設定値 |
|---------|--------|
| プロトコル：ポート | HTTPS：443 |
| デフォルトアクション | ターゲットグループ `<ターゲットグループ名>` に転送 |
| SSL証明書 | Step 1でインポートしたACM証明書（`<ACM証明書ARN>`） |
| セキュリティポリシー | ELBSecurityPolicy-TLS13-1-2-2021-06（推奨） |

```
4. 「ロードバランサーの作成」をクリック
```

> **補足：** ALBが「Active」状態になるまで数分かかる．

------------------------------

### Step 4：ALB DNS名の確認【実施対象：AWSコンソール（EC2）】

**目的：** ALBのDNS名を確認し，後続の確認作業で使用する

#### 操作手順

```
1. EC2コンソール → ロードバランサー → <ALB名> をクリック
2. 「詳細」タブの「DNS名」を確認・記録
```

> **例：** `alb-public-1-XXXXXXXXX.us-west-2.elb.amazonaws.com`

#### 次の作業の選択肢

- **DNSレコードでこのALBに名前を当てる場合：** Route53または `nsd-public-letsencrypt.md` で設定したNSDサーバーで，`<取得するサブドメイン>` のAレコードをALBの DNS名のCNAMEとして登録．
- **ALBのDNS名で直接アクセスする場合：** 証明書とFQDNが一致しないため証明書エラーになる（`curl -k` で動作確認可能）．

> **重要：** 本手順書の完成イメージでは「`<取得するサブドメイン>` でアクセスして緑の鍵マーク」を目指しているため，DNS設定が必要．

#### CNAMEレコードの追加（NSDサーバー側で実施する場合）

`nsd-public-letsencrypt.md` で構築したNSDサーバー上で：

```bash
sudo su -
vi /etc/nsd/<取得するサブドメイン>.zone
```

以下を追記（serialインクリメント）：

```
@ IN CNAME alb-public-1-XXXXXXXXX.us-west-2.elb.amazonaws.com.
```

> **注意：** ゾーンのapex（`@`）にCNAMEは厳密にはRFC違反．Aレコード（ALBのIPは時間で変わるため非推奨）かALIASレコード（Route53専用）の選択肢もある．DNS設計についてはチームの設計方針に従うこと．

```bash
nsd-checkzone <取得するサブドメイン> /etc/nsd/<取得するサブドメイン>.zone
systemctl restart nsd
```

------------------------------

### Step 5：Webサーバー側SGの修正【実施対象：AWSコンソール（EC2）】

**目的：** Webサーバー側SGに，ALBのSGからの80番接続を許可するルールを追加する

#### 操作手順

```
1. EC2コンソール → インスタンス → <Webサーバーのインスタンス名> をクリック
2. 「セキュリティ」タブ → セキュリティグループ（<WebサーバーのSG ID>）をクリック
3. 「インバウンドルールを編集」をクリック
4. 「ルールを追加」をクリック
5. 以下を入力：
     - タイプ      ：HTTP
     - プロトコル  ：TCP
     - ポート範囲  ：80
     - ソース      ：<ALBのSG ID>（カスタム → SGを検索）
6. 「ルールを保存」をクリック
```

> **重要：** ソースは必ず **ALBのSG ID** を指定すること．`0.0.0.0/0` を指定するとALBを経由せず直接アクセスが可能になり，HTTPS化の意味が失われる．

> **補足：** AWS CLIでも追加可能：
>
> ```bash
> aws ec2 authorize-security-group-ingress \
>     --group-id <WebサーバーのSG ID> \
>     --protocol tcp \
>     --port 80 \
>     --source-group <ALBのSG ID> \
>     --region <リージョン>
> ```

------------------------------

### Step 6：動作確認【実施対象：ローカルPC】

**目的：** ALB経由でHTTPSアクセスが可能であることを確認する

#### Step 6-1：HTTP→HTTPSリダイレクト確認

```bash
curl -I http://<取得するサブドメイン>
```

> **期待する結果：**
>
> ```
> HTTP/1.1 301 Moved Permanently
> Location: https://<取得するサブドメイン>:443/
> ```

#### Step 6-2：HTTPSアクセス確認

```bash
curl -I https://<取得するサブドメイン>
```

> **期待する結果：** `HTTP/1.1 200 OK` 等，Webサーバーのレスポンスが返る．

#### Step 6-3：ブラウザでの確認

ブラウザで `https://<取得するサブドメイン>` にアクセスし，以下を確認：

- 鍵マークが表示される（証明書エラーなし）
- Webサーバーのコンテンツが表示される

------------------------------

## 5. 動作確認・検証

### 5-1. 確認チェックリスト

- [ ] **確認①**：ACMに証明書がインポートされ「使用中」になっている
- [ ] **確認②**：ターゲットグループ内のターゲットが「Healthy」状態
- [ ] **確認③**：ALBが「Active」状態
- [ ] **確認④**：HTTP→HTTPSリダイレクト確認（301）
- [ ] **確認⑤**：HTTPSアクセス確認（200）
- [ ] **確認⑥**：証明書チェーン検証成功

------------------------------

### 確認①：ACM証明書の状態確認【実施対象：AWSコンソール（ACM）】

```
ACM → 証明書 → 対象証明書
→ ステータス：「使用中」
→ 使用中のリソース：作成したALBのリスナー
```

------------------------------

### 確認②：ターゲットグループのヘルスチェック【実施対象：AWSコンソール（EC2）】

```
EC2 → ターゲットグループ → <ターゲットグループ名>
→ 「ターゲット」タブ
→ ステータス：「Healthy」
```

> **注意：** 「Unhealthy」の場合：
>
> - WebサーバーのSGでALBのSGからの80番が許可されているか（Step 5確認）
> - Webサーバーが起動しているか
> - `<ヘルスチェックパス>` が200を返すか

------------------------------

### 確認③：ALB状態確認【実施対象：AWSコンソール（EC2）】

```
EC2 → ロードバランサー → <ALB名>
→ 状態：「Active」
```

------------------------------

### 確認④：HTTP→HTTPSリダイレクト【実施対象：ローカルPC】

```bash
curl -I http://<取得するサブドメイン>
```

> **期待する結果：** `HTTP/1.1 301 Moved Permanently` および `Location: https://<取得するサブドメイン>:443/`．

------------------------------

### 確認⑤：HTTPSアクセス【実施対象：ローカルPC】

```bash
curl https://<取得するサブドメイン>
```

> **期待する結果：** Webサーバーのコンテンツが返る．

------------------------------

### 確認⑥：証明書チェーン検証【実施対象：ローカルPC】

```bash
openssl s_client -connect <取得するサブドメイン>:443 -servername <取得するサブドメイン> < /dev/null 2>&1 | grep -E "Verify return code|subject="
```

> **期待する結果：**
>
> ```
> Verify return code: 0 (ok)
> subject=CN = <取得するサブドメイン>
> ```

------------------------------

### 5-2. 運用上の作業（構築後）

#### 5-2-1. 証明書更新運用の設計

Let's Encrypt証明書は90日で失効するため，更新運用が必要：

1. `certbot renew` のcron／systemd timer化
2. 更新成功後にAWS CLI（`aws acm import-certificate --certificate-arn <既存ARN>`）でACM上の証明書を上書き
3. 更新失敗の監視

詳細は `nsd-public-letsencrypt.md` 付録D-4を参照．

#### 5-2-2. ALBアクセスログの有効化（推奨）

```
EC2 → ロードバランサー → <ALB名>
→ 「属性」タブ → 「編集」
→ アクセスログ：「有効」
→ S3バケット：ログ保存先を指定
```

#### 5-2-3. ALBのモニタリング

- CloudWatchメトリクスでRequestCount／TargetResponseTime／HTTPCode_Target_5XX_Count等を監視
- アラーム設定（4XX・5XX急増，TargetResponseTime長期化など）

------------------------------

## 6. トラブルシューティング

### よくあるエラーと対処法

------------------------------

#### エラー①：ターゲットグループが「Unhealthy」になる

**原因：**

- WebサーバーのSGがALBからの80番を許可していない
- Webサーバー（Nginx等）が起動していない
- ヘルスチェックパスが200を返さない

**対処法：**

```bash
# WebサーバーでNginx起動確認
sudo systemctl status nginx

# ヘルスチェックパス確認
curl -I http://localhost/healthcheck
# → 200 OK

# SG確認（CLI例）
aws ec2 describe-security-groups \
    --group-ids <WebサーバーのSG ID> \
    --query 'SecurityGroups[0].IpPermissions' \
    --region <リージョン>
```

------------------------------

#### エラー②：ACM証明書がインポートできない

**原因：**

- `cert.pem` / `privkey.pem` / `chain.pem` の内容に余分なスペースや改行が混在
- 証明書の有効期限切れ
- 公開鍵と秘密鍵の不一致

**対処法：**

```bash
# 証明書先頭・末尾の BEGIN/END 行確認
head -1 /etc/letsencrypt/live/<取得するサブドメイン>/cert.pem
tail -1 /etc/letsencrypt/live/<取得するサブドメイン>/cert.pem

# 有効期限確認
openssl x509 -in /etc/letsencrypt/live/<取得するサブドメイン>/cert.pem -noout -dates

# 公開鍵と秘密鍵が一致するか確認
openssl x509 -in cert.pem -noout -modulus | openssl md5
openssl rsa  -in privkey.pem -noout -modulus | openssl md5
# → 両方の md5 値が一致すること
```

------------------------------

#### エラー③：ALB DNS名にアクセスしても証明書エラー

**原因：** ALBのDNS名（`*.elb.amazonaws.com`）は証明書のSubject（`<取得するサブドメイン>`）と一致しない．

**対処法：**

- `<取得するサブドメイン>` 経由でアクセスする（DNS設定済みであること）
- もしくは `curl -k` で証明書検証をスキップしてテスト

------------------------------

#### エラー④：HTTPSアクセスで504 Gateway Timeout

**原因：**

- WebサーバーのSGがALBから80番を拒否している
- Webサーバーがダウンしている
- バックエンドの応答が遅い（タイムアウト）

**対処法：**

```bash
# Webサーバー側でポート80のリッスン確認
sudo ss -tlnp | grep :80

# ALBのターゲットグループ ヘルスチェックタイムアウトを調整（必要なら）
```

------------------------------

#### エラー⑤：`<取得するサブドメイン>` の名前解決ができない

**原因：** DNSにALBに対するレコードが設定されていない．

**対処法：** Step 4-5を参照してNSDまたはRoute53でCNAME（またはAレコード）を設定．

------------------------------

### ログの確認場所

| ログの種類 | 場所 |
|-----------|------|
| ALBアクセスログ | S3バケット（5-2-2で有効化した場合） |
| ALBメトリクス | CloudWatch / EC2 → ロードバランサー → 「モニタリング」タブ |
| ターゲットヘルスチェック履歴 | EC2 → ターゲットグループ → 「モニタリング」タブ |
| Webサーバーログ | `/var/log/nginx/access.log` 等 |

------------------------------

## 7. 参考リソース・関連資料

| 資料名 | URL / 場所 | 補足 |
|-------|-----------|------|
| ACM公式ガイド | https://docs.aws.amazon.com/ja_jp/acm/latest/userguide/ | 証明書管理全般 |
| ALB公式ガイド | https://docs.aws.amazon.com/ja_jp/elasticloadbalancing/latest/application/ | ALB全般 |
| ALB セキュリティポリシー | https://docs.aws.amazon.com/ja_jp/elasticloadbalancing/latest/application/create-https-listener.html#describe-ssl-policies | TLSバージョン／暗号スイート |
| 別手順書：対外DNS構築とLet's Encrypt | `nsd-public-letsencrypt.md` | 本手順書の前提作業 |
| 別手順書：Nginxリバースプロキシ構築 | `nginx-reverse-proxy.md` | バックエンドWebサーバー側 |

------------------------------

## 8. ロールバック手順

### 8-1. ロールバック判定基準

以下の場合，直ちにロールバックを実施する：

- ターゲットグループが「Unhealthy」のまま10分以上改善しない
- HTTPS アクセスで証明書エラーが継続し原因特定が困難
- ALB構築後にWebサーバーへ直接アクセスできなくなった
- ALBに想定外の課金が発生している

> **補足：** ALB・ACMは設定削除だけで元に戻せる（既存のWebサーバー設定には影響しない）．

------------------------------

### 8-2. WebサーバーSGの設定戻し【実施対象：AWSコンソール（EC2）】

```
EC2 → セキュリティグループ → <WebサーバーのSG ID>
→ インバウンドルール → Step 5で追加したルール（ALBのSGからのHTTP）を削除
```

または AWS CLI：

```bash
aws ec2 revoke-security-group-ingress \
    --group-id <WebサーバーのSG ID> \
    --protocol tcp \
    --port 80 \
    --source-group <ALBのSG ID> \
    --region <リージョン>
```

### 8-3. DNS CNAMEレコードの削除（NSDで設定した場合）【実施対象：対外DNSサーバー】

```bash
sudo su -
vi /etc/nsd/<取得するサブドメイン>.zone
# → Step 4-5で追加したCNAMEレコードを削除，serialインクリメント

nsd-checkzone <取得するサブドメイン> /etc/nsd/<取得するサブドメイン>.zone
systemctl restart nsd
```

### 8-4. ALBの削除【実施対象：AWSコンソール（EC2）】

```
EC2 → ロードバランサー → <ALB名> を選択
→ アクション → 「ロードバランサーの削除」
```

または：

```bash
# ALB ARNを取得
ALB_ARN=$(aws elbv2 describe-load-balancers \
    --names <ALB名> \
    --query 'LoadBalancers[0].LoadBalancerArn' \
    --output text --region <リージョン>)

# ALB削除
aws elbv2 delete-load-balancer \
    --load-balancer-arn ${ALB_ARN} \
    --region <リージョン>
```

### 8-5. ターゲットグループの削除【実施対象：AWSコンソール（EC2）】

```
EC2 → ターゲットグループ → <ターゲットグループ名> を選択
→ アクション → 「ターゲットグループの削除」
```

> **注意：** ALBから参照されている間は削除できない．Step 8-4を先に実施．

### 8-6. ALB用SGの削除【実施対象：AWSコンソール（EC2）】

```
EC2 → セキュリティグループ → ALB用SGを選択
→ アクション → 「セキュリティグループの削除」
```

> **注意：** 他のリソースから参照されている間は削除できない．

### 8-7. ACM証明書の削除【実施対象：AWSコンソール（ACM）】

```
ACM → 証明書 → 対象証明書を選択
→ アクション → 「削除」
```

> **注意：** 「使用中」状態では削除できない．先にALBから外しておく必要がある（ALB削除済みなら自動的に「使用中」状態が解除される）．

### 8-8. 完了確認【実施対象：ローカルPC】

```bash
# ALB DNS名が解決されないこと
dig <ALB名>-XXXXXXXXX.us-west-2.elb.amazonaws.com +short
# → 何も返らない or NXDOMAIN

# 元のWebサーバー直接アクセスが復元できているか（必要なら）
curl -I http://<Webサーバーのパブリック/プライベートIP>:80
```

> **注意：** Let's Encrypt証明書ファイル自体は `/etc/letsencrypt/live/` に残る．削除する場合は `nsd-public-letsencrypt.md` 8-3を参照．

------------------------------

## 付録

### A. コマンド解説

| コマンド | 説明 |
|---------|------|
| `aws sts get-caller-identity` | 現在のAWS認証情報を確認． |
| `aws acm import-certificate` | 外部証明書をACMにインポート． |
| `aws acm list-certificates` | ACMの証明書一覧を表示． |
| `aws elbv2 describe-load-balancers` | ALB一覧を表示． |
| `aws elbv2 describe-target-groups` | ターゲットグループ一覧を表示． |
| `aws elbv2 describe-target-health` | ターゲットの健全性を表示． |
| `aws ec2 describe-security-groups` | SGの設定を表示． |
| `aws ec2 authorize-security-group-ingress` | SGにインバウンドルールを追加． |
| `aws ec2 revoke-security-group-ingress` | SGからインバウンドルールを削除． |
| `curl -I <URL>` | HTTPヘッダのみ取得．リダイレクトの確認に使う． |
| `curl -k <URL>` | TLS証明書検証をスキップ． |
| `openssl s_client -connect <host>:443 -servername <host>` | TLSハンドシェイクを試行し，証明書チェーンを表示． |
| `openssl x509 -in <cert.pem> -noout -dates` | 証明書の有効期限を表示． |
| `dig <FQDN> +short` | DNS問い合わせ結果のみ表示． |

------------------------------

### B. 設定ファイル解説

**ACM登録時の3ファイル**

| ACM入力欄 | 対応ファイル | 内容 |
|-----------|------------|------|
| 証明書本文 | `cert.pem` | サーバー証明書 |
| プライベートキー | `privkey.pem` | 秘密鍵 |
| 証明書チェーン | `chain.pem` | 中間CA証明書 |

> **注意：** `fullchain.pem` は `cert.pem` + `chain.pem` の連結．ACMでは個別に入力するため使わない．

**ALBリスナー設定**

| リスナー | ポート | デフォルトアクション |
|---------|-------|---------------------|
| HTTP | 80 | HTTPS:443 へリダイレクト（301） |
| HTTPS | 443 | ACM証明書を使ってターゲットグループへ転送 |

**ターゲットグループ設定**

| 項目 | 値 | 説明 |
|------|-----|------|
| プロトコル | HTTP | バックエンド（Webサーバー）はHTTPで受ける |
| ポート | 80 | Webサーバーが LISTEN するポート |
| ヘルスチェックパス | `/healthcheck` | 200を返すパスを指定．無いと「Unhealthy」になる |

------------------------------

### C. 用語解説

| 用語 | 説明 |
|------|------|
| ACM | AWS Certificate Manager．AWSが提供する証明書管理サービス．無料証明書発行と外部証明書インポートの両方をサポート． |
| ALB | Application Load Balancer．L7ロードバランサー．HTTPSの終端，パスベースのルーティング等が可能． |
| ターゲットグループ | ALBがリクエストを転送する先のEC2やIPの集合． |
| リスナー | ALBがクライアントからの接続を受け付ける設定（プロトコル＋ポート）． |
| ヘルスチェック | ターゲットが正常応答するかをALBが定期的に確認する仕組み． |
| 301リダイレクト | HTTPの永続的リダイレクト．ブラウザ・検索エンジン共にURL変更を記憶する． |
| SSL終端 | HTTPSをロードバランサーで復号し，バックエンドへはHTTPで送る方式．バックエンド負荷軽減に有効． |
| セキュリティポリシー | ALBで使用するTLSバージョンと暗号スイートの組合せ．新しい程セキュア． |
| AWS CLI | AWSのコマンドラインインターフェース．コンソール操作と同等の操作が可能． |
| ARN | Amazon Resource Name．AWSリソースの一意識別子． |
| EIP | Elastic IP．静的なパブリックIP． |

------------------------------

### D. 補足解説

#### D-1. ALBによるSSL終端のメリット

- 証明書管理を1箇所（ALB+ACM）に集中させられる
- バックエンドのWebサーバーで複雑なTLS設定が不要
- セキュリティポリシー（TLS1.3対応等）を一括変更可能
- バックエンドはHTTPで負荷が軽い

**注意点：** ALB→バックエンドの通信はVPC内のHTTPなので，VPC内部からの盗聴に対しては無防備．要件次第ではバックエンドもHTTPS化（mTLS等）を検討．

#### D-2. ヘルスチェックパスの設計

- 単純な静的ファイル（`/healthcheck`）が無難
- DBや他サービスの応答に依存させると，連鎖障害でWebサーバーが「Unhealthy」扱いになる
- DB接続も確認するパスは「ディープヘルスチェック」と呼び，別途設定するのが一般的

#### D-3. ALBのコスト構造

- 時間あたりの基本料金
- LCU（Load Balancer Capacity Unit）課金（接続数／リクエスト数など）
- アクセスログ保存先のS3コスト

検証環境で長期間放置するとそれなりに課金が発生するので，使わない時は削除を推奨．

#### D-4. 証明書更新時のACM再インポート

Let's Encrypt証明書を更新後，ACM側にも反映する必要がある：

```bash
# 更新（90日に1回）
certbot renew

# 既存のACM証明書のARNを指定してインポート（上書き）
aws acm import-certificate \
    --certificate-arn <ACM証明書ARN> \
    --certificate fileb:///etc/letsencrypt/live/<取得するサブドメイン>/cert.pem \
    --private-key fileb:///etc/letsencrypt/live/<取得するサブドメイン>/privkey.pem \
    --certificate-chain fileb:///etc/letsencrypt/live/<取得するサブドメイン>/chain.pem \
    --region <リージョン>
```

> **重要：** `--certificate-arn` を指定すると上書きとなり，ALBのリスナー設定変更は不要．新規ARNにすると手動でALBリスナーの設定変更が必要．

certbotの `--deploy-hook` でACMインポートを自動化することを推奨：

```
/etc/letsencrypt/renewal-hooks/deploy/acm-reimport.sh
```

#### D-5. CNAMEとALIASとAレコードの違い（DNS設計）

| レコード | 用途 | 注意点 |
|---------|------|--------|
| CNAME | 別名→正式名のマッピング | apex（`@`）には使えない（RFC違反）．サブドメインのみOK |
| ALIAS（Route53専用） | ALB等のAWSリソースに直接マッピング | apexにも使える．Route53でのみ利用可 |
| A | FQDN→IPv4 | ALBのIPは変動するので非推奨 |

本手順書のNSDでは `CNAME` を採用しているが，apex（`<取得するサブドメイン>` 自体）に当てる場合はRFC違反となる．サブのサブドメイン（`www.<取得するサブドメイン>`）にすると問題ない．

#### D-6. HTTP→HTTPSリダイレクトの SEO/UX 観点

- 301（Permanent Redirect）：恒久的．検索エンジンがURL変更を反映．
- 302（Temporary）：一時的．SEO観点ではURL変更とみなされない．
- HTTPS化を恒久的に維持するなら **301推奨**．

#### D-7. 本手順書を実施する際の追加考慮点

- ALBの「削除保護」を有効化しておくと誤削除を防げる
- アクセスログを最初から有効化しておくと障害調査が早い
- WebサーバーのSGに「ALBのSG」を指定する方法（Step 5）は推奨．IP指定だとALBスケール時に追従できない

#### D-8. `dnf update` と `dnf upgrade` の違い

- DNFベースのAmazon Linux 2023では両者は同義．本手順書ではOSパッケージ操作は含まないため使用しない．
