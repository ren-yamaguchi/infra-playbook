# 【認証統合基盤(Keycloak + OpenLDAP + FreeRADIUS + Nginx)構築】環境構築手順書

---

## 1. ドキュメント情報

| 項目 | 内容 |
|------|------|
| 手順書名 | 認証統合基盤(Keycloak + OpenLDAP + FreeRADIUS + Nginx)構築 |
| 作成日 | 2026-06-25 |
| バージョン | v1.0 |
| 対象環境 | AWS |

> **改訂履歴**
>
> | バージョン | 日付 | 変更内容 |
> |-----------|------|---------|
> | v1.0 | 2026-06-25 | 初版作成 |
> | v2.0 | 2026-07-06 | OpenLDAPのSymasリポジトリ定義を現行の SOLDAP(2.6 LTS)構成に修正し、パッケージ名(`symas-openldap-servers`)・サービス名(`slapd`)の記載を実態に合わせて修正。旧`sofl.repo`の削除、`slappasswd`等の実際の配置先が`/opt/symas/bin/`ではなく`/opt/symas/sbin/`である点の修正、`slapd.conf`はテンプレート(`slapd.conf.default`)からのコピーが必要である点を追加。DBの初期設定手順(旧1-4節)はmdbバックエンドでは`DB_CONFIG`が不要かつ`ldap`ユーザーも存在しない(rootで動作)ことが判明したため、データディレクトリ(`/var/symas/openldap-data`)確認の手順に置き換え。環境変数ファイルのパスを`/etc/sysconfig/symas-openldap`から実際の`/etc/default/symas-openldap`に修正。Symasパッケージは`/opt/symas/bin`・`/opt/symas/sbin`を`$PATH`に追加する設定を用意していないため、`/etc/profile.d/`にPATH設定スクリプトを作成する手順(1-2-2節)を追加。Keycloakサーバの `c7i-flex.large` は無料利用枠対象だが、対象となるのは2025-07-15以降に作成したAWSアカウントのみである旨を注記として追加。操作端末から管理コンソールに外部アクセスした際に発生する「HTTPS required」エラー(master realmの`sslRequired=EXTERNAL`が原因)と、`kcadm.sh`による緩和手順を2-5節として追加。操作端末のhostsファイル編集を避けたい場合の代替手段(Chrome/Edgeの`--host-resolver-rules`起動オプション)を3-5-1節に追加。2-6節のKeycloak管理コンソールアクセス手順をhostsファイル方式から3-5-1節の方式に統一。3-2節にLDAP User Federationの設定が`auth-local` Realm上での操作である旨を明記。パスワードハッシュ生成(1-3, 1-9, 確認⑤)を`slappasswd -s`による非対話生成+`sed`/ヒアドキュメントでのファイル書き込みに変更し、`vi`への手貼り付けによるハッシュ破損(`Invalid credentials (49)`エラーの原因)を回避。`slapd.conf.default`に`core.schema`しかincludeされておらず`inetOrgPerson`/`posixAccount`/`shadowAccount`が未定義で`ldapadd`が`Invalid syntax (21)`になる問題を修正し、1-5節にcosine/inetorgperson/nis schemaのinclude追加手順を追加。1-8, 1-9, 確認⑤, エラー②の`-w AdminPass123`を`<ADMIN_PASS>`プレースホルダーに統一し(3-2節のBind credentials欄、Step 4のFreeRADIUS ldapモジュール設定も同様)、例示値のまま実行してしまう事故を防止。FreeRADIUS起動時に`mods-enabled/eap`のTLS証明書未生成で`radiusd`が起動しない問題に対し、4-5-1節として証明書生成(`make`)手順と、生成ファイルのグループ所有者(`root`のままだと`radiusd`ユーザーから`Permission denied`になる)を`radiusd`へ揃える`chgrp`手順を追加。Keycloakの起動(2-4節)を`&`単体から`nohup`+`disown`に変更し、SSHセッション切断によるプロセス停止・ブートストラップ管理者パスワードの消失を防止。ブートストラップ環境変数は最初の1回しか効かない仕様である旨を2-3節に注記。Step 3の最後に3-5節として`auth-local` realmの`sslRequired=NONE`設定を追加(masterだけでなくauth-localにも同じ緩和が必要なため)。oauth2-proxyのKeycloak Client(`oauth2-proxy`)にAudienceマッパーを追加する手順を6-1-1節として追加し、IDトークンの`aud`クレームに`account`しか入らず`audience`不一致エラーになる問題に対応。oauth2-proxy.cfgに`insecure_oidc_allow_unverified_email = true`を追加し、LDAP由来ユーザーの`emailVerified=false`によるログイン失敗を解消。Nginxの`/oauth2/`・`/oauth2/auth`ロケーションに`proxy_buffer_size`等を追加し、oauth2-proxyの大きな`Set-Cookie`ヘッダによる`upstream sent too big header`エラー(502)を解消 |

---

## 2. 目的・概要

### 2-1. 目的

本手順書では、**OpenLDAPを唯一のユーザー情報源(Single Source of Truth)** とし、**Web系認証(Keycloak)** と **ネットワーク系認証(FreeRADIUS)** の両方が同じLDAPを参照する、認証統合基盤を構築する。

学習ポイント:

- LDAPのDIT(Directory Information Tree)設計とエントリ操作
- KeycloakのUser Federation機能でLDAPを取り込む流れ
- OIDC(OpenID Connect)の Authorization Code Flow を Nginx + oauth2-proxy で体感
- FreeRADIUSをLDAPバックエンドで動かす
- 「同じユーザーがWebとRADIUSの両方で認証できる」状態の構築

### 2-2. 構成概要(アーキテクチャ)

```
                  [クライアント(ブラウザ)]
                          | HTTPS
                          v
              +---------------------------+
              |  nginx.auth.local         |
              |  Nginx + oauth2-proxy     |
              |  - 保護ページ /private    |
              |  - auth_request で保護    |
              +-----------+---------------+
                          | OIDC (HTTP)
                          v
              +---------------------------+
              |  kc.auth.local            |
              |  Keycloak (OIDC Provider) |
              |  - User Federation: LDAP  |
              +-----------+---------------+
                          | LDAP
                          v
              +---------------------------+
              |  ldap.auth.local          |<------ FreeRADIUS が参照
              |  OpenLDAP                 |
              |  (ユーザー情報の一元管理)  |
              +---------------------------+
                          ^ LDAP
                          |
              +---------------------------+
              |  radius.auth.local        |
              |  FreeRADIUS               |
              |  - LDAPバックエンド認証   |
              +---------------------------+
                          ^ radtest コマンド
              [テストクライアント(自分のPC等)]
```

- **OpenLDAPサーバ**: ユーザー情報の集中管理(`dc=auth,dc=local`)
- **Keycloakサーバ**: OIDC Provider、User FederationでOpenLDAPを取り込む
- **FreeRADIUSサーバ**: OpenLDAPをバックエンドにしたRADIUS認証
- **Nginxサーバ**: 自己署名HTTPSで保護ページを公開、oauth2-proxyでOIDC認証

### 2-3. 完成イメージ(ゴール定義)

- [ ] OpenLDAPに `taro` ユーザーが作成され、`ldapsearch` で取得できる
- [ ] Keycloak管理画面で LDAP User Federation を設定し、`taro` がKeycloakユーザーとして同期される
- [ ] ブラウザで `https://nginx.auth.local/private` にアクセスすると Keycloak ログイン画面にリダイレクトされ、`taro` でログインすると保護ページが表示される
- [ ] テスト端末から `radtest taro <password> <RADIUS_PUB> 0 testing123` を実行すると `Access-Accept` が返る
- [ ] OpenLDAP の `taro` のパスワードを変更すると、Webログインと radtest の両方の動作に即時反映される

---

### 2-4. 使用ミドルウェア解説

本構成で登場する主要ミドルウェアの概要を整理する。各ステップに入る前に全体像を把握しておくと、設定の意図が理解しやすくなる。

---

#### 2-4-1. OpenLDAP

**ジャンル:** ディレクトリサービス

**役割**

ユーザー情報を集中管理するサーバ。「誰が存在するか」「パスワードは何か」「どのグループに属するか」といった情報をツリー構造(DIT)で保持する。

**仕組みのイメージ**

LDAP(Lightweight Directory Access Protocol)は住民台帳に近いイメージ。組織の全ユーザー情報が1か所に集まっており、他のシステムが「このユーザーは存在しますか？」「パスワードは合っていますか？」と問い合わせに来る。問い合わせには `ldapsearch`、登録には `ldapadd` といった専用コマンドを使う。

**この構成での役割**

KeycloakとFreeRADIUSの両方が参照する「唯一の真実(Single Source of Truth)」。OpenLDAPのユーザー情報を変更すれば、Web認証とRADIUS認証の両方に即時反映される。

**学習ポイント**

- DIT(Directory Information Tree)のツリー構造と DN(Distinguished Name)の読み方
- `objectClass` の継承による属性の組み合わせ方
- `ldapadd` / `ldapsearch` / `ldapmodify` の基本操作

---

#### 2-4-2. Keycloak

**ジャンル:** IDプロバイダ(IdP) / 認証基盤

**役割**

OIDC(OpenID Connect)やSAMLに対応したオープンソースの認証・認可サーバ。ログイン画面の提供、トークンの発行、ユーザー管理などを一手に引き受ける。

**仕組みのイメージ**

「ログイン処理を外部委託できる窓口」に近いイメージ。アプリ側はKeycloakにログインを任せ、「この人は誰か」という情報をトークン(JWT)で受け取る。Keycloak自身はユーザーを内部に持つこともできるが、本構成では User Federation 機能でOpenLDAPを参照する。

**この構成での役割**

ブラウザからの認証リクエストを受け取り、OpenLDAPにユーザー情報を問い合わせて認証を行うOIDC Providerとして機能する。oauth2-proxyがKeycloakと通信し、認証結果をNginxに伝える。

**学習ポイント**

- Realm・Client・User Federation の概念と関係性
- OIDC の Authorization Code Flow の流れ(リダイレクト→コード取得→トークン交換)
- User Federation(LDAP連携)の設定と READ_ONLY モードの意味

---

#### 2-4-3. FreeRADIUS

**ジャンル:** RADIUSサーバ

**役割**

RADIUS(Remote Authentication Dial-In User Service)プロトコルに対応した認証サーバ。ネットワーク機器(VPN、Wi-Fiアクセスポイント、スイッチ等)からの認証要求を処理する用途で広く使われる。

**仕組みのイメージ**

ネットワーク機器は「このユーザーを通していいか？」という認証要求をRADIUSサーバに送る。RADIUSサーバはバックエンド(今回はOpenLDAP)に問い合わせて認証し、`Access-Accept` または `Access-Reject` で答える。通信にはUDP/1812を使う。

**この構成での役割**

OpenLDAPをバックエンドにした認証を提供する。`radtest` コマンドでユーザー名とパスワードを送ると、FreeRADIUSがOpenLDAPに bind して検証し、結果を返す。

**学習ポイント**

- RADIUS の認証フロー(authorize → authenticate フェーズの分離)
- `clients.conf` による送信元クライアントの管理と shared secret の役割
- LDAPモジュール(`rlm_ldap`)の有効化と設定方法

---

#### 2-4-4. oauth2-proxy

**ジャンル:** 認証プロキシ

**役割**

OIDC/OAuth2 プロバイダとのフローを代行するリバースプロキシ。アプリ自身にOIDCの実装を持たせる代わりに、oauth2-proxyが認証フロー全体を肩代わりする。

**仕組みのイメージ**

Nginx の `auth_request` から「このリクエストは認証済みか？」と問い合わせを受け、セッションクッキーを確認する。未認証であればKeycloakのログイン画面にリダイレクトし、認証後はセッションを確立して以降のリクエストを通す。アプリ側はJWTのパースやトークンリフレッシュを意識しなくてよい。

**この構成での役割**

NginxとKeycloakの仲介役。`/oauth2/auth` エンドポイントを提供し、Nginxの `auth_request` からの問い合わせに 200(認証済み) または 401(未認証) で応答する。未認証時はKeycloakのログイン画面へリダイレクトし、認証完了後のコールバック処理も担う。

**学習ポイント**

- `auth_request` ディレクティブを使ったNginxとの連携パターン
- `upstreams = "static://200"` による「認証専用ゲート」としての使い方
- クッキーによるセッション管理と `cookie_secret` の役割

---

## 3. 前提条件・準備

### 3-1. AWS環境(起動済み前提)

- AWSアカウントを保有していること
- VPCが作成されており、CIDRは `172.31.0.0/16` であること
- EC2インスタンスが **4台起動済み** であること(全台 Amazon Linux 2023)
- インスタンスタイプの推奨:
  - Keycloakサーバ: **c7i-flex.large**(メモリ4GB。無料利用枠対象)
  - その他3台: **t3.micro**(メモリ1GB。無料利用枠対象)
- 全EC2にSSHログインできること
- 各EC2にはパブリックIPが付与されていること

> **注意:パブリックIPの変動**
>
> EC2を停止/起動するとパブリックIPが変わる。再開時には3-4節のパラメータ表を更新し、自己署名証明書のCNや oauth2-proxy のリダイレクトURL等も合わせて見直す必要がある。

> **注意:c7i-flex.large の無料利用枠対象はアカウント作成日に依存する**
>
> AWS公式ドキュメント([Amazon EC2 User Guide](https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/ec2-free-tier-usage.html))によると、無料利用枠対象インスタンスタイプはAWSアカウントの作成日で異なる。
>
> - **2025年7月15日より前に作成したアカウント**: `t2.micro` / `t3.micro` のみが対象(12か月間、月750時間まで無料)
> - **2025年7月15日以降に作成したアカウント**: `t3.micro` / `t3.small` / `t4g.micro` / `t4g.small` / `c7i-flex.large` / `m7i-flex.large` が対象(ただし時間制の無料枠ではなく、サインアップ時に付与されるクレジットを6か月以内に使い切る方式)
>
> 自分のアカウントがどちらに該当するか不明な場合は、以下のCLIコマンドで無料利用枠対象インスタンスタイプを確認できる。
>
> ```bash
> aws ec2 describe-instance-types \
>     --filters Name=free-tier-eligible,Values=true \
>     --query "InstanceTypes[*].[InstanceType]" \
>     --output text | sort
> ```
>
> 2025年7月15日より前に作成したアカウントの場合、`c7i-flex.large` は無料利用枠の対象外(課金対象)になるため、その場合は `t3.micro` で代用し、Keycloakのメモリ不足に備えてスワップ領域の追加とJVMヒープの制限を行うこと。

### 3-2. 環境要件

#### 3-2-1. OpenLDAPサーバ

| 項目 | 要件 |
|------|------|
| インスタンスタイプ | t3.micro |
| OS | Amazon Linux 2023 |
| ミドルウェア | OpenLDAP (symas-openldap) |
| ツール | ldap-clients (ldapadd, ldapsearch) |

> **解説:Amazon Linux 2023 のOpenLDAP事情**
>
> Amazon Linux 2023 の標準リポジトリには `openldap-servers` パッケージが含まれていない(クライアントのみ)。本手順書では Symas が提供する RPM (`symas-openldap-servers`) を使う。RHEL系で広く使われている代替パッケージ。

#### 3-2-2. Keycloakサーバ

| 項目 | 要件 |
|------|------|
| インスタンスタイプ | c7i-flex.large(メモリ4GB。無料利用枠対象。対象条件は3-1節の注記参照) |
| OS | Amazon Linux 2023 |
| ミドルウェア | Keycloak 26.x (公式tarball) |
| 依存 | Java 21 (java-21-amazon-corretto) |

#### 3-2-3. FreeRADIUSサーバ

| 項目 | 要件 |
|------|------|
| インスタンスタイプ | t3.micro |
| OS | Amazon Linux 2023 |
| ミドルウェア | FreeRADIUS, freeradius-ldap |
| ツール | freeradius-utils (radtest, radclient) |

#### 3-2-4. Nginxサーバ

| 項目 | 要件 |
|------|------|
| インスタンスタイプ | t3.micro |
| OS | Amazon Linux 2023 |
| ミドルウェア | Nginx, oauth2-proxy (GitHub releases) |
| ツール | openssl(自己署名証明書生成) |

### 3-3. セキュリティグループ設定

#### 3-3-1. OpenLDAPサーバ

| タイプ | プロトコル | ポート | ソース | 目的 |
|---|---|---|---|---|
| SSH | TCP | 22 | マイIP | SSH接続 |
| LDAP | TCP | 389 | 172.31.0.0/16 | Keycloak/FreeRADIUSからのLDAP問い合わせ |

> **注意:本番ではLDAPS(636)必須**
>
> 学習用にLDAP(平文389)を使う。本番ではTLS化(LDAPS/StartTLS)し、認証情報が平文で流れない構成にすること。

#### 3-3-2. Keycloakサーバ

| タイプ | プロトコル | ポート | ソース | 目的 |
|---|---|---|---|---|
| SSH | TCP | 22 | マイIP | SSH接続 |
| Keycloak HTTP | TCP | 8080 | 172.31.0.0/16 | NginxからのOIDC通信(内部のみ) |
| Keycloak管理 | TCP | 8080 | マイIP | 管理コンソール初期設定用 |

> **解説:8080を「マイIP」にも開ける理由**
>
> Keycloakの管理コンソールに自分のブラウザから直接アクセスして初期設定(LDAPフェデレーション、Realm作成等)を行う必要があるため。本番ではNginxの背後に置き、管理画面も Nginx 経由で公開するのが一般的。

#### 3-3-3. FreeRADIUSサーバ

| タイプ | プロトコル | ポート | ソース | 目的 |
|---|---|---|---|---|
| SSH | TCP | 22 | マイIP | SSH接続 |
| RADIUS auth | UDP | 1812 | マイIP | radtestによる認証テスト |

#### 3-3-4. Nginxサーバ

| タイプ | プロトコル | ポート | ソース | 目的 |
|---|---|---|---|---|
| SSH | TCP | 22 | マイIP | SSH接続 |
| HTTPS | TCP | 443 | マイIP | ブラウザからの保護ページアクセス |
| HTTP | TCP | 80 | マイIP | HTTPS リダイレクト用 |

### 3-4. パラメータ整理表

| パラメータ | 意味 | 自環境の値 |
|---|---|---|
| `<LDAP_PUB>` | OpenLDAPサーバのグローバルIP | |
| `<LDAP_PRI>` | OpenLDAPサーバのプライベートIP | |
| `<KC_PUB>` | KeycloakサーバのグローバルパブリックIP | |
| `<KC_PRI>` | KeycloakサーバのプライベートIP | |
| `<RADIUS_PUB>` | FreeRADIUSサーバのグローバルIP | |
| `<RADIUS_PRI>` | FreeRADIUSサーバのプライベートIP | |
| `<NGINX_PUB>` | NginxサーバのグローバルIP | |
| `<NGINX_PRI>` | NginxサーバのプライベートIP | |
| `<MY_IP>` | 操作端末のグローバルIP | |

### 3-5. ホスト名・ドメイン設計

| サーバ | ホスト名 |
|---|---|
| OpenLDAPサーバ | `ldap.auth.local` |
| Keycloakサーバ | `kc.auth.local` |
| FreeRADIUSサーバ | `radius.auth.local` |
| Nginxサーバ | `nginx.auth.local` |

> **解説:今回はDNSサーバを立てない**
>
> 4台間の名前解決は各サーバの `/etc/hosts` に直接書き込む方式とする。学習スコープを認証系に絞るため、BIND等のDNSサーバ構築は省略。本来は内部DNSを立てる構成が望ましい。
>
> ブラウザからのアクセス時に `nginx.auth.local` を解決させるためには、**操作端末側の hosts ファイル**(Windowsなら `C:\Windows\System32\drivers\etc\hosts`、Macなら `/etc/hosts`)に `<NGINX_PUB> nginx.auth.local` を追記する。

#### 3-5-1. 操作端末のhostsファイルを変更したくない場合

会社支給PCなど、操作端末側の設定を変更したくない場合は、ブラウザ単位で名前解決を上書きする方法がある。Chrome/Edgeの `--host-resolver-rules` 起動オプションを使うと、システムの hosts ファイルには一切触れずに、そのブラウザプロセスの中だけ `kc.auth.local` / `nginx.auth.local` を任意のIPに解決させられる。

```powershell
& "C:\Program Files\Google\Chrome\Application\chrome.exe" `
  --host-resolver-rules="MAP kc.auth.local <KC_PUB>, MAP nginx.auth.local <NGINX_PUB>" `
  --user-data-dir="$env:TEMP\chrome-hostoverride-profile"
```

- `<KC_PUB>` / `<NGINX_PUB>` は実際のパブリックIPに置き換える
- `--user-data-dir` で普段使いのプロファイルと分離しているので、普段のブラウザ設定・履歴には影響しない
- 開いたウィンドウを閉じれば設定ごと消える(hostsファイルのように後片付けを忘れる心配がない)
- 3-3節のセキュリティグループで各サーバへの `マイIP` からの直接アクセスをすでに許可しているため、SSHトンネル等を別途張る必要はない

### 3-6. LDAP DIT 設計

```
dc=auth,dc=local           ... ルート
├── cn=admin,dc=auth,dc=local  ... 管理者DN
├── ou=People                  ... ユーザー格納OU
│   └── uid=taro               ... テストユーザー
└── ou=Groups                  ... グループ格納OU
    └── cn=users               ... 一般ユーザーグループ
```

---

## 4. 構築手順(詳細)

### 4-1. 環境構築の流れ

1. 全サーバ共通の初期設定(Step 0)
2. OpenLDAPサーバの構築(Step 1)
3. Keycloakサーバの構築(Step 2)
4. KeycloakのLDAPフェデレーション設定(Step 3)
5. FreeRADIUSサーバの構築(Step 4)
6. Nginxサーバの構築(自己署名証明書 + oauth2-proxy)(Step 5)
7. Keycloak側のクライアント設定(Step 6)

---

### Step 0: 全サーバ共通の初期設定

**目的:** 全4台のEC2で共通の初期化を行う。

#### 0-1. 【全サーバで実施】システム初期設定

各サーバのホスト名は3-5節を参照。

```bash
# 例: OpenLDAPサーバの場合
sudo su -
dnf update -y
timedatectl set-timezone Asia/Tokyo
hostnamectl set-hostname ldap.auth.local
```

他3台も同様に、それぞれ `kc.auth.local`、`radius.auth.local`、`nginx.auth.local` を設定する。

#### 0-2. 【全サーバで実施】/etc/hosts の設定

全4台で `/etc/hosts` に互いのプライベートIPを記載する。

```bash
vi /etc/hosts
```

末尾に追記:

```
<LDAP_PRI>    ldap.auth.local
<KC_PRI>      kc.auth.local
<RADIUS_PRI>  radius.auth.local
<NGINX_PRI>   nginx.auth.local
```

> **解説:なぜ全サーバに書くのか**
>
> Keycloakは LDAP に対して `ldap.auth.local` で問い合わせる。FreeRADIUSも同様。Nginxは oauth2-proxy 経由でKeycloak (`kc.auth.local`) と通信する。互いに名前で参照しあうため、全4台に同じ情報を入れておくのが確実。

---

### Step 1: OpenLDAPサーバの構築

**目的:** ユーザー情報の集中管理サーバを構築する。

#### 1-1. 【ldap.auth.localで実施】Symas OpenLDAP リポジトリの追加

```bash
rm -f /etc/yum.repos.d/sofl.repo
cat > /etc/yum.repos.d/soldap-release26.repo << 'EOF'
[soldap-release26]
name=Symas OpenLDAP 2.6 RPM release repository
baseurl=https://repo.symas.com/repo/rpm/SOLDAP/release26/rhel9
gpgkey=https://repo.symas.com/repo/gpg/RPM-GPG-KEY-symas-com-signing-key
gpgcheck=1
enabled=1
EOF
```

> **注意:古い `sofl.repo` が残っていると404エラーが出続ける**
>
> 冒頭の `rm -f /etc/yum.repos.d/sofl.repo` は、廃止された `SOFL` 版のリポジトリ定義ファイルが残っていないかの掃除。もし以前に旧バージョンの本手順(`sofl.repo` を作成する手順)を試したことがある場合、そのファイルが残ったままだと `dnf install` のたびに以下のような404エラーが出続ける(このリポジトリは無視されて処理自体は続行されるため実害はないが、紛らわしいので消しておく)。
>
> ```text
> Errors during downloading metadata for repository 'sofl':
>   - Status code: 404 for https://repo.symas.com/repo/rpm/SOFL/...
> Ignoring repositories: sofl
> ```

> **注意:`$releasever` をbaseurlに使わない**
>
> 以前は `baseurl=https://repo.symas.com/repo/rpm/SOFL/$releasever/RHEL9/` という書き方だったが、これは2点の理由で動かない。
>
> 1. `$releasever` はdnfがOSのリリースバージョンに自動置換する変数だが、Amazon Linux 2023はRHEL9ベースであってRHEL9そのものではないため、`9` ではなく独自の値(例: `2023.12.20260629`)に展開されてしまい、存在しないURLになる。
> 2. そもそも `SOFL`(Symas OpenLDAP for Linux、旧2.4系のブランド名)のリポジトリパスは廃止されており、現在RHEL9向けに提供されているのは後継の `SOLDAP`(2.6 LTS)という構成である。
>
> 上記のとおり `rhel9` を直接パスに埋め込む現行のリポジトリ定義を使う。

> **注意:gpgcheck=1 について**
>
> Symasの現行リポジトリ定義は `gpgcheck=1` かつ `gpgkey=` 指定がデフォルトになっている。署名検証を行うため、そのまま使う。

#### 1-2. 【ldap.auth.localで実施】OpenLDAPのインストール

```bash
dnf install -y symas-openldap-clients symas-openldap-servers
```

> **注意:パッケージ名は `servers`(複数形)**
>
> Symas公式の現行手順では `symas-openldap-servers`(複数形)が正しいパッケージ名になっている。`symas-openldap-server`(単数形)では見つからないので注意。

#### 1-2-1. 【ldap.auth.localで実施】インストール内容の確認

パッケージのバージョンアップ等で実際のファイルパスやサービス名が変わることがあるため、以降の手順に進む前に実機で確認しておく。

```bash
rpm -q symas-openldap-clients symas-openldap-servers
rpm -ql symas-openldap-clients | grep -i slap
rpm -ql symas-openldap-servers | grep -i slap
systemctl list-unit-files | grep -i -E 'ldap|slapd'
```

- `rpm -q` で2パッケージとも(バージョン文字列付きで)表示されることを確認する。片方だけしか入っていない場合はインストールが途中で終わっている。
- `slappasswd` は `symas-openldap-clients` に含まれるが、配置先は `/opt/symas/bin/` ではなく **`/opt/symas/sbin/`**(`slapadd`/`slapcat`/`slapindex` など他のslap*系メンテナンスツールと同じ場所)。1-3節ではこのパスを使う。
- サービス名が `slapd` として登録されていることを確認する(1-7節で使用)。もし別名しか見つからない場合は、以降のコマンド中の `slapd` をその名前に読み替える。

#### 1-2-2. 【ldap.auth.localで実施】PATHの設定

`ldapadd`/`ldapsearch`/`ldapmodify` 等のクライアントツールは `/opt/symas/bin/` にあるが、Symasのパッケージは `$PATH` にこのディレクトリを追加する設定(`/etc/profile.d/` 配下のスクリプト等)を用意していない。何もしないと以降の手順で `command not found` になるため、恒久的にPATHを通しておく。

```bash
cat > /etc/profile.d/symas-openldap.sh << 'EOF'
export PATH="/opt/symas/bin:/opt/symas/sbin:$PATH"
EOF
chmod 644 /etc/profile.d/symas-openldap.sh
source /etc/profile.d/symas-openldap.sh
which ldapadd
# /opt/symas/bin/ldapadd と表示されればOK
```

> **注意:`source` は今のシェルにのみ効く**
>
> `/etc/profile.d/` に置いたスクリプトは新しいログインシェルから自動で読み込まれるが、今操作中のシェルには反映されない。そのため `source` コマンドで今のシェルにも即座に反映させている。別のターミナルで新しくSSHログインした場合は `source` しなくても自動的にPATHが通る。

#### 1-3. 【ldap.auth.localで実施】管理者パスワードのハッシュ生成

```bash
ADMIN_HASH=$(/opt/symas/sbin/slappasswd -s 'AdminPass123')
echo "$ADMIN_HASH"
# 出力例: {SSHA}xxxxxxxxxxxxxxxxxxxxxxxxxx
```

`AdminPass123` の部分は実際に使うパスワードに書き換える。`-s` オプションでパスワードを引数指定して非対話で生成し、シェル変数 `$ADMIN_HASH` にそのまま保持しておく(1-5節で使う)。

> **注意:環境変数は同じシェルセッションでのみ有効**
>
> `$ADMIN_HASH` は**現在のシェルセッション内でのみ**有効。1-5節は必ず同じターミナルセッションで実行すること。セッションを切った場合はこのコマンドから再実行する。

> **注意:`slappasswd: No such file or directory` になる場合**
>
> `symas-openldap-clients` がインストール済みでも、`/opt/symas/bin/slappasswd` には存在しない。実体は `/opt/symas/sbin/slappasswd` にあるので、パスを間違えていないか確認する。
>
> ```bash
> find /opt/symas -iname 'slappasswd*'
> # /opt/symas/sbin/slappasswd と出ればそちらを使う
> ```

#### 1-4. 【ldap.auth.localで実施】データディレクトリの確認

`DB_CONFIG` はBerkeley DB系(bdb/hdb)バックエンド用のチューニングファイルで、このパッケージには存在しない。`slapd.conf.default` を見ると `database mdb` となっており、本パッケージはmdb(LMDB)バックエンドがデフォルトのため、`DB_CONFIG` 自体が不要。また `systemctl cat slapd` の内容(`symas-openldap-servers.service`)に `User=` の指定がなく、slapdはrootで動作する構成になっている。distro標準のOpenLDAPパッケージにあるような専用の `ldap` ユーザーはSymasパッケージには存在せず、作る必要もない。

代わりに、`slapd.conf.default` の `directory` で指定されているデータディレクトリが存在するかを確認しておく。

```bash
mkdir -p /var/symas/openldap-data
ls -ld /var/symas/openldap-data
```

> **注意:distro標準のOpenLDAPとディレクトリ・実行ユーザーが異なる**
>
> 一般的なOpenLDAP(Amazon Linux標準の`openldap-servers`等)は `/var/lib/ldap` を専用の `ldap` ユーザーで使う構成が多いが、Symasのパッケージは `/opt/symas` 配下に独自にインストールされ、データディレクトリも `/var/symas/openldap-data`、実行ユーザーもroot、という異なる構成になっている。他のOpenLDAP解説記事を参考にする際はこの違いに注意すること。

#### 1-5. 【ldap.auth.localで実施】slapd.conf の編集

パッケージが提供するのは `slapd.conf.default` というテンプレートのみで、`slapd.conf` 自体は存在しない。まずテンプレートをコピーしてから編集する。

```bash
cp /opt/symas/etc/openldap/slapd.conf.default /opt/symas/etc/openldap/slapd.conf
sed -i \
  -e 's|^suffix.*|suffix          "dc=auth,dc=local"|' \
  -e 's|^rootdn.*|rootdn          "cn=admin,dc=auth,dc=local"|' \
  -e "s|^rootpw.*|rootpw          $ADMIN_HASH|" \
  /opt/symas/etc/openldap/slapd.conf
sed -i '/^include.*core\.schema/a include         /opt/symas/etc/openldap/schema/cosine.schema' /opt/symas/etc/openldap/slapd.conf
sed -i '/^include.*cosine\.schema/a include         /opt/symas/etc/openldap/schema/inetorgperson.schema' /opt/symas/etc/openldap/slapd.conf
sed -i '/^include.*inetorgperson\.schema/a include         /opt/symas/etc/openldap/schema/nis.schema' /opt/symas/etc/openldap/slapd.conf
grep -E '^(include|suffix|rootdn|rootpw)' /opt/symas/etc/openldap/slapd.conf
```

> **注意:`vi`で直接貼り付けない**
>
> `{SSHA}...` のハッシュ文字列は改行やスペースが混入しやすく、`vi`へ手で貼り付けると一部が欠けたり改行が入ったりして、後で `ldapwhoami`/Keycloakの`Test authentication`が `Invalid credentials (49)` になる原因になる。`sed` でシェル変数 `$ADMIN_HASH` をそのまま書き込むことで、この種の貼り付けミスを避けられる。最後の`grep`で意図通りの行になっているか必ず確認すること。

> **注意:スキーマのincludeが `core.schema` しかない**
>
> `slapd.conf.default` には `core.schema` しか `include` されていない。1-9節で使う `inetOrgPerson`(cosine/inetorgperson schema)、`posixAccount`/`shadowAccount`(nis schema)を使うには、依存関係の順序(core → cosine → inetorgperson → nis)で追加が必要。これを怠ると、`ldapadd` 時に `ldap_add: Invalid syntax (21) additional info: objectClass: value #0 invalid per syntax` というエラーになる。スキーマは起動時に読み込まれるため、初めてslapdを起動する1-7節より前に済ませておくこと。すでにslapdを起動済みの場合は `systemctl restart slapd` で反映させる。

> **解説:slapd.conf 方式と cn=config 方式**
>
> OpenLDAPの設定方式には伝統的な `slapd.conf` 方式と、動的な `cn=config`(OLC)方式がある。Symas のデフォルトは `slapd.conf` 方式なので、本手順書もそれに従う。学習用には slapd.conf の方が直感的。

#### 1-6. 【ldap.auth.localで実施】listenアドレスの設定

```bash
vi /etc/default/symas-openldap
```

以下のように編集:

```
SLAPD_URLS="ldap:/// ldapi:///"
```

> **注意:環境変数ファイルは `/etc/default/` 配下**
>
> `systemctl cat slapd` で確認できる `EnvironmentFile=-/etc/default/symas-openldap` の記載どおり、RHEL系であってもSymasパッケージはDebian/Ubuntu風の `/etc/default/` にこのファイルを置く(`/etc/sysconfig/` ではない)。ファイルが存在しない場合は新規作成してよい(`EnvironmentFile=-`の`-`は「無くてもエラーにしない」という意味)。

> **解説:`ldap:///` は全インターフェースで待ち受け**
>
> `ldap:///` は「すべてのIPアドレスのポート389で待ち受け」を意味する。プライベートIPでもlocalhostでも受け付ける。

#### 1-7. 【ldap.auth.localで実施】slapdの起動

```bash
systemctl start slapd
systemctl enable slapd
systemctl status slapd
```

> **注意:サービス名は `slapd`**
>
> Symas公式の現行手順ではサービス名は `slapd` として案内されている。1-2-1節で確認した内容と食い違う場合は、そちらで確認した名前に読み替えること。

#### 1-8. 【ldap.auth.localで実施】ベースDN・OU・ユーザーの投入

LDIFファイルを作成:

```bash
vi /root/base.ldif
```

内容:

```
dn: dc=auth,dc=local
objectClass: top
objectClass: dcObject
objectClass: organization
o: Auth Local Org
dc: auth

dn: ou=People,dc=auth,dc=local
objectClass: organizationalUnit
ou: People

dn: ou=Groups,dc=auth,dc=local
objectClass: organizationalUnit
ou: Groups
```

投入:

```bash
ldapadd -x -D "cn=admin,dc=auth,dc=local" -w '<ADMIN_PASS>' -f /root/base.ldif
# <ADMIN_PASS> は1-3節で実際に設定した平文パスワードに置き換える
```

> **注意:`-w` フラグについて**
>
> `-w <ADMIN_PASS>` はパスワードをコマンドライン引数として渡すため、`history` や `ps` に平文で残る。本番では `-W` フラグ(プロンプト入力)を使うこと。

#### 1-9. 【ldap.auth.localで実施】テストユーザー taro の作成

```bash
# taro のパスワードハッシュを生成(1-3節と同様、非対話・変数に保持)
TARO_HASH=$(/opt/symas/sbin/slappasswd -s 'TaroPass123')
echo "$TARO_HASH"
```

```bash
cat > /root/taro.ldif << EOF
dn: uid=taro,ou=People,dc=auth,dc=local
objectClass: inetOrgPerson
objectClass: posixAccount
objectClass: shadowAccount
uid: taro
cn: Taro Yamada
sn: Yamada
givenName: Taro
mail: taro@auth.local
uidNumber: 10001
gidNumber: 10000
homeDirectory: /home/taro
loginShell: /bin/bash
userPassword: $TARO_HASH
EOF
cat /root/taro.ldif
```

> **注意:ここも`vi`で直接貼り付けない**
>
> 1-3/1-5節と同じ理由(ハッシュの貼り付けミス)を避けるため、`cat` のヒアドキュメントでシェル変数 `$TARO_HASH` をそのまま展開してファイルを作る。最後の `cat` で `userPassword:` の行が正しく展開されているか確認すること。

```bash
ldapadd -x -D "cn=admin,dc=auth,dc=local" -w '<ADMIN_PASS>' -f /root/taro.ldif
# <ADMIN_PASS> は1-3節で実際に設定した平文パスワードに置き換える(例の "AdminPass123" のままでは動かない)
```

> **解説:複数のobjectClassを継承する理由**
>
> - `inetOrgPerson`: メールアドレスや姓名など一般的なユーザー属性を提供。Keycloakが期待する標準属性が含まれる
> - `posixAccount`: uidNumber/gidNumber/homeDirectory/loginShell など、Unixユーザー的な属性を追加。FreeRADIUS から使う場面で役立つ
> - `shadowAccount`: パスワード期限などのshadow関連属性
>
> Keycloak と FreeRADIUS の両方から参照するため、両者が必要とする属性を網羅できるよう複数継承する。

#### 1-10. 【ldap.auth.localで実施】動作確認

```bash
ldapsearch -x -b "dc=auth,dc=local" "(uid=taro)"
# taro のエントリが返ればOK
```

---

### Step 2: Keycloakサーバの構築

**目的:** OIDC Providerとなる Keycloak を起動する。

#### 2-1. 【kc.auth.localで実施】Javaのインストール

```bash
dnf install -y java-21-amazon-corretto-headless
java -version
# openjdk version "21.x.x" と表示されればOK
```

#### 2-2. 【kc.auth.localで実施】Keycloakのダウンロードと展開

```bash
cd /opt
curl -L -O https://github.com/keycloak/keycloak/releases/download/26.0.5/keycloak-26.0.5.tar.gz
tar xzf keycloak-26.0.5.tar.gz
mv keycloak-26.0.5 keycloak
```

> **注意:Keycloakのバージョンについて**
>
> 26.0.5 は2025年時点の安定版例。最新の安定版を https://www.keycloak.org/downloads で確認して使うのが望ましい。

#### 2-3. 【kc.auth.localで実施】初期管理者アカウントの設定

Keycloak 26.x では `KC_BOOTSTRAP_ADMIN_USERNAME` / `KC_BOOTSTRAP_ADMIN_PASSWORD` 環境変数で初期管理者を作成する。

```bash
export KC_BOOTSTRAP_ADMIN_USERNAME=admin
export KC_BOOTSTRAP_ADMIN_PASSWORD=KcAdminPass123
```

> **注意:環境変数は同じシェルセッションで引き継がれる**
>
> `export` した変数は **現在のシェルセッション内でのみ** 有効。次のステップの `kc.sh start-dev` は必ず同じターミナルセッションで実行すること。`sudo su -` 等でユーザーを切り替えた場合は再度 `export` が必要。

> **注意:このブートストラップは最初の1回しか効かない**
>
> `KC_BOOTSTRAP_ADMIN_USERNAME`/`KC_BOOTSTRAP_ADMIN_PASSWORD` は、**master realmにまだ管理者が1人も存在しない場合にのみ**使われる。一度adminユーザーが作成された後は、この環境変数を変えて再度exportしても無視され、パスワードは変わらない。プロセスが落ちて再起動した際に「前と違うパスワードをexportしてしまい、ログインできなくなる」という事故が起きやすいので、ここで設定したパスワードは忘れないよう控えておくこと。

#### 2-4. 【kc.auth.localで実施】Keycloakの起動(開発モード)

```bash
cd /opt/keycloak
nohup ./bin/kc.sh start-dev --http-host=0.0.0.0 --http-port=8080 --hostname=kc.auth.local --hostname-strict=false > /var/log/keycloak-start.log 2>&1 &
disown
```

起動には少し時間がかかる。ログに `Listening on: http://0.0.0.0:8080` が出れば成功。

```bash
tail -f /var/log/keycloak-start.log
# 確認できたら Ctrl+C でtailを抜けてよい(プロセス自体は動き続ける)
```

> **解説:start-dev モードと本番モードの違い**
>
> - `start-dev`: HTTP有効、開発用。TLSなしで起動できる
> - `start`: 本番モード。TLS必須(無効化するには `--http-enabled=true` 等のフラグが必要)
>
> 学習用なので start-dev を使う。本番では `start` モードで TLS終端する。

> **注意:`&` 単体ではなく `nohup` + `disown` を使う理由**
>
> `&` だけでバックグラウンドに回すと、SSHセッションが切れた(意図的な切断だけでなく、通信の瞬断や端末アプリの再起動なども含む)瞬間にプロセスがSIGHUPを受けて終了してしまうことがある。学習中に何度もこれで気づかないうちにKeycloakが落ち、後から再起動すると「別のセッションで環境変数を再exportし忘れる」→ 上記の注意にある通り管理者パスワードが分からなくなる、という事故につながりやすい。`nohup` でSIGHUPを無視し、`disown` でシェルのジョブ管理からも切り離すことで、SSHセッションを閉じてもプロセスが生き続けるようにする。もちろん、本来は systemd ユニット化するのが望ましい。

#### 2-5. 【kc.auth.localで実施】SSL要件の緩和(外部からのHTTPアクセスを許可)

Keycloakのrealmには `sslRequired` という設定があり、`master` realmはデフォルトで `EXTERNAL`(プライベートIP/ループバック以外からのアクセスにはHTTPSを要求する)になっている。操作端末(自宅PCなど)からパブリックIP経由でHTTPアクセスすると、この判定に引っかかり「We are sorry ... HTTPS required」という画面が出て管理コンソールにすら入れない。

管理コンソールのログイン画面自体がこのチェックでブロックされるため、GUIでは直せない。サーバー上で `localhost` 経由の場合はこの制限にかからないことを利用し、CLIツール `kcadm.sh` で緩和する。

```bash
cd /opt/keycloak/bin
./kcadm.sh config credentials --server http://localhost:8080 --realm master --user admin --password KcAdminPass123
./kcadm.sh update realms/master -s sslRequired=NONE
```

> **注意:学習用の設定であることを忘れない**
>
> `sslRequired=NONE` は「常にHTTP可」を意味する。本番でこの設定はしないこと。本手順書では学習目的で外部から素のHTTPでアクセスするために緩和している。

#### 2-6. 【操作端末で実施】Keycloak管理コンソールにアクセス

3-5-1節の方法(Chrome/Edgeの `--host-resolver-rules` 起動オプション)で `kc.auth.local` / `nginx.auth.local` を名前解決できるようにする。

```powershell
& "C:\Program Files\Google\Chrome\Application\chrome.exe" `
  --host-resolver-rules="MAP kc.auth.local <KC_PUB>, MAP nginx.auth.local <NGINX_PUB>" `
  --user-data-dir="$env:TEMP\chrome-hostoverride-profile"
```

開いたウィンドウで `http://kc.auth.local:8080/` を開き、`Administration Console` をクリック。

- Username: `admin`
- Password: `KcAdminPass123`

でログイン。

---

### Step 3: KeycloakのLDAPフェデレーション設定

**目的:** Keycloak管理画面から、OpenLDAP をユーザーソースとして登録する。

#### 3-1. 【Keycloak管理画面で実施】Realmの作成

1. 左上のドロップダウン(`Keycloak master`)→ `Create Realm`
2. Realm name: `auth-local`
3. `Create` をクリック

> **解説:Realmとは**
>
> Keycloak のテナント単位。1つのRealmは独立したユーザー集合・クライアント・設定を持つ。`master` は管理用Realmなので、業務用は別Realmを作るのがベストプラクティス。

#### 3-2. 【Keycloak管理画面で実施】LDAP User Federation の追加

`auth-local` Realmに切り替えた状態で(3-1でRealmを作成すると、通常はそのまま`auth-local`に切り替わっている。左上のドロップダウンが`auth-local`になっているか確認する):

1. 左メニュー `User federation` をクリック
2. `Add Ldap providers` をクリック
3. 以下のように設定:

| 項目 | 値 |
|---|---|
| UI display name | `openldap-auth-local` |
| Vendor | `Other` |
| Connection URL | `ldap://ldap.auth.local:389` |
| Bind type | `simple` |
| Bind DN | `cn=admin,dc=auth,dc=local` |
| Bind credentials | `<ADMIN_PASS>`(1-3節で実際に設定した平文パスワード) |
| Edit mode | `READ_ONLY` |
| Users DN | `ou=People,dc=auth,dc=local` |
| Username LDAP attribute | `uid` |
| RDN LDAP attribute | `uid` |
| UUID LDAP attribute | `entryUUID` |
| User object classes | `inetOrgPerson, organizationalPerson` |

4. `Test connection` で成功表示を確認
5. `Test authentication` で成功表示を確認
6. `Save` をクリック

> **解説:READ_ONLYモードの意味**
>
> Keycloakから LDAPへの書き込みを禁止する。ユーザー管理はLDAP側で行い、Keycloakは「参照するだけ」とする。これにより「LDAPが唯一の真実」というポリシーを徹底できる。

#### 3-3. 【Keycloak管理画面で実施】ユーザー同期の実行

1. 作成したフェデレーション `openldap-auth-local` を開く
2. 画面上部の `Action` → `Sync all users` をクリック
3. 「1 user(s) imported」のような成功メッセージを確認

#### 3-4. 【Keycloak管理画面で実施】同期されたユーザーの確認

1. 左メニュー `Users` をクリック
2. `taro` が表示されることを確認
3. クリックして属性(Email: `taro@auth.local` 等)が取り込まれていることを確認

> **考えるポイント:同期 vs オンデマンドフェッチ**
>
> Keycloak の LDAP連携は「初回ログイン時にオンデマンドでフェッチ」も可能で、`Sync all users` は事前一括取り込みするだけ。本手順書では学習目的で事前同期を行うが、大規模環境では「ログイン時にだけ取り込む」設計の方が初期負荷が低い。

#### 3-5. 【kc.auth.localで実施】auth-local realmのSSL要件緩和

2-5節で `master` realmの `sslRequired` を `NONE` にしたが、この設定はrealmごとの設定であり、今作成した `auth-local` realmには適用されない。Step 6でoauth2-proxy経由のログインを試すと、ブラウザが `http://kc.auth.local:8080/realms/auth-local/...` へ直接(HTTPで)リダイレクトされる場面があり、そこで同じ「HTTPS required」エラーになる。今のうちに緩和しておく。

```bash
cd /opt/keycloak/bin
./kcadm.sh config credentials --server http://localhost:8080 --realm master --user admin --password KcAdminPass123
./kcadm.sh update realms/auth-local -s sslRequired=NONE
```

---

### Step 4: FreeRADIUSサーバの構築

**目的:** OpenLDAPをバックエンドにしたRADIUS認証を構築する。

#### 4-1. 【radius.auth.localで実施】パッケージのインストール

```bash
dnf install -y freeradius freeradius-ldap freeradius-utils
```

#### 4-2. 【radius.auth.localで実施】LDAPモジュールの有効化

```bash
ln -s /etc/raddb/mods-available/ldap /etc/raddb/mods-enabled/ldap
```

#### 4-3. 【radius.auth.localで実施】LDAPモジュールの設定

```bash
vi /etc/raddb/mods-available/ldap
```

`server`、`identity`、`password`、`base_dn` を以下のように編集:

```
ldap {
    server = 'ldap.auth.local'
    port = 389
    identity = 'cn=admin,dc=auth,dc=local'
    password = <ADMIN_PASS>
    base_dn = 'ou=People,dc=auth,dc=local'

    user {
        base_dn = "${..base_dn}"
        filter = "(uid=%{%{Stripped-User-Name}:-%{User-Name}})"
    }
}
```

> **注意:`identity` 行はデフォルトでコメントアウトされている**
>
> デフォルトの `mods-available/ldap` では `identity` の行が `#identity = 'cn=admin,dc=example,dc=org'` のようにコメントアウトされた例として入っている。値を書き換えるだけでなく、**先頭の `#` を外して有効化する**のを忘れないこと。コメントアウトされたままだと `identity` が未設定(空)になり、LDAPへのbindが `Invalid credentials` で失敗する。

`<ADMIN_PASS>` は1-3節で実際に設定した平文パスワードに置き換える。上記以外の設定項目(tls、pool 等)はデフォルトのままにしておく。

> **解説:filter の意味**
>
> RADIUSクライアントから送られてくる `User-Name` をLDAPの `uid` 属性で検索する。`taro` というユーザー名で認証要求が来たら、`uid=taro` のエントリを探しに行く。

#### 4-4. 【radius.auth.localで実施】default サイトでLDAPを使う設定

```bash
vi /etc/raddb/sites-available/default
```

`authorize { ... }` セクション内の `-ldap` のコメントを外す:

```
authorize {
    ...
    -ldap
    ...
}
```

さらに `authenticate { ... }` セクション内の以下のコメントを外す:

```
authenticate {
    ...
    Auth-Type LDAP {
        ldap
    }
    ...
}
```

> **解説:authorize と authenticate の役割分担**
>
> - `authorize`: ユーザーが存在するか、どの認証方式を使うかを決定するフェーズ
> - `authenticate`: 実際にパスワード検証を行うフェーズ
>
> `authorize` でLDAPを呼び出すと、ユーザーが見つかり次第 `Auth-Type` が `LDAP` に設定される。続く `authenticate` フェーズで `Auth-Type LDAP` 配下の `ldap` モジュールが呼ばれ、LDAP bind による検証が行われる。

#### 4-5. 【radius.auth.localで実施】クライアント設定

`radtest` を実行する端末(本手順書では操作端末)をRADIUSクライアントとして登録する。

```bash
vi /etc/raddb/clients.conf
```

末尾に追記:

```
client mytestclient {
    ipaddr = <MY_IP>
    secret = testing123
    require_message_authenticator = no
}
```

> **解説:secret はクライアントとサーバの共有秘密**
>
> RADIUSプロトコルでは、クライアントとサーバ間で共有秘密(shared secret)を持ち、これでパケットを検証する。`testing123` は学習用の慣例的な値。本番では強力なランダム値を使う。

#### 4-5-1. 【radius.auth.localで実施】EAPモジュール用証明書の生成

`mods-enabled/eap` はデフォルトで有効になっているが、EAP-TLS用の証明書(`/etc/raddb/certs/server.pem`等)が未生成のままだと、本手順書では使わない`eap`モジュールの初期化に失敗し、`radiusd`自体が起動できない(`Failed reading certificate file "/etc/raddb/certs/server.pem"`等のエラーになる)。

```bash
which make || dnf install -y make
cd /etc/raddb/certs
make
```

`make`で新しく生成されたファイルは所有グループが`root`のままになり、`radiusd`ユーザー(グループ`radiusd`)から読めず`Permission denied`になることがある。生成後は必ずグループを揃える。

```bash
chgrp -R radiusd /etc/raddb/certs
```

> **注意:`eap`モジュールを削除して回避しない**
>
> `mods-enabled/eap` のシンボリックリンクを削除して回避しようとすると、`sites-enabled/default` の `authenticate` セクションが `eap` モジュールを名前で参照しているため、`Failed to find "eap" as a module or policy` というパースエラーで起動できなくなる。本手順書ではEAP/802.1X認証自体は使わないが、証明書を生成してモジュールを正常に初期化させる方法で対処する。

#### 4-6. 【radius.auth.localで実施】FreeRADIUSの起動

まずデバッグモードで起動し、設定エラーがないか確認:

```bash
radiusd -X
# 起動ログが流れ、最後に「Ready to process requests」と出ればOK
# Ctrl+C で停止
```

問題なければ通常起動:

```bash
systemctl start radiusd
systemctl enable radiusd
systemctl status radiusd
```

---

### Step 5: Nginxサーバの構築(自己署名証明書 + oauth2-proxy)

**目的:** 自己署名HTTPS でアクセスできる Nginx を構築し、oauth2-proxy 経由で Keycloak OIDC を使った保護を実現する。

#### 5-1. 【nginx.auth.localで実施】Nginxのインストール

```bash
dnf install -y nginx openssl
systemctl start nginx
systemctl enable nginx
```

#### 5-2. 【nginx.auth.localで実施】自己署名証明書の作成

```bash
mkdir -p /etc/nginx/ssl
cd /etc/nginx/ssl

openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
  -keyout nginx.key -out nginx.crt \
  -subj "/CN=nginx.auth.local" \
  -addext "subjectAltName=DNS:nginx.auth.local"

chmod 600 nginx.key
```

> **注意:本番ではLet's Encrypt等の正規証明書を使う**
>
> 自己署名証明書はブラウザで警告が出る。学習用なので「詳細設定 → 移動」で許可する想定。本番では Let's Encrypt や 公的CAの証明書を使うこと。

#### 5-3. 【nginx.auth.localで実施】oauth2-proxy のダウンロード

```bash
cd /opt
curl -L -O https://github.com/oauth2-proxy/oauth2-proxy/releases/download/v7.7.1/oauth2-proxy-v7.7.1.linux-amd64.tar.gz
tar xzf oauth2-proxy-v7.7.1.linux-amd64.tar.gz
mv oauth2-proxy-v7.7.1.linux-amd64 oauth2-proxy
ln -s /opt/oauth2-proxy/oauth2-proxy /usr/local/bin/oauth2-proxy
oauth2-proxy --version
```

> **解説:oauth2-proxy の役割**
>
> oauth2-proxy は OIDC/OAuth2 プロバイダ(今回はKeycloak)とのフローを代行する逆プロキシ。Nginxの `auth_request` ディレクティブから呼び出される `/oauth2/auth` エンドポイントを提供し、未認証ならログイン画面へリダイレクトする。
>
> Nginx単体でOIDCを扱うのは煩雑(JWTパース、トークン交換、リフレッシュ等)なので、oauth2-proxy に任せるのが定石。

#### 5-4. 【nginx.auth.localで実施】保護対象ページの作成

```bash
mkdir -p /usr/share/nginx/html/private
cat > /usr/share/nginx/html/private/index.html << 'EOF'
<!DOCTYPE html>
<html>
<head><title>Private Area</title></head>
<body>
<h1>Welcome to Private Area</h1>
<p>You are authenticated via Keycloak + OpenLDAP.</p>
</body>
</html>
EOF
```

公開ページも作っておく(認証不要):

```bash
cat > /usr/share/nginx/html/index.html << 'EOF'
<!DOCTYPE html>
<html>
<head><title>Public Page</title></head>
<body>
<h1>Public Page</h1>
<p><a href="/private/">Go to Private Area</a></p>
</body>
</html>
EOF
```

#### 5-5. 【nginx.auth.localで実施】Nginx 設定

```bash
vi /etc/nginx/conf.d/auth.conf
```

```
# HTTP → HTTPS リダイレクト
server {
    listen 80;
    server_name nginx.auth.local;
    return 301 https://$host$request_uri;
}

server {
    listen 443 ssl;
    server_name nginx.auth.local;

    ssl_certificate     /etc/nginx/ssl/nginx.crt;
    ssl_certificate_key /etc/nginx/ssl/nginx.key;

    # oauth2-proxy のエンドポイント
    location /oauth2/ {
        proxy_pass       http://127.0.0.1:4180;
        proxy_set_header Host                    $host;
        proxy_set_header X-Real-IP               $remote_addr;
        proxy_set_header X-Scheme                $scheme;
        proxy_set_header X-Auth-Request-Redirect $request_uri;
        proxy_buffer_size          16k;
        proxy_buffers              4 16k;
        proxy_busy_buffers_size    32k;
    }

    # 認証チェック用の内部location
    location = /oauth2/auth {
        internal;
        proxy_pass       http://127.0.0.1:4180;
        proxy_set_header Host             $host;
        proxy_set_header X-Real-IP        $remote_addr;
        proxy_set_header X-Scheme         $scheme;
        proxy_set_header Content-Length   "";
        proxy_pass_request_body           off;
        proxy_buffer_size          16k;
        proxy_buffers              4 16k;
        proxy_busy_buffers_size    32k;
    }

    # 公開ページ
    location / {
        root /usr/share/nginx/html;
        index index.html;
    }

    # 保護ページ
    location /private/ {
        auth_request /oauth2/auth;
        error_page 401 = /oauth2/sign_in;

        root /usr/share/nginx/html;
        index index.html;
    }
}
```

> **注意:`proxy_buffer_size` 等を大きくする理由**
>
> oauth2-proxyはセッション情報(アクセストークン等)を暗号化してCookie(`Set-Cookie`ヘッダ)に格納するため、レスポンスヘッダがNginxのデフォルトのプロキシバッファ(4〜8KB程度)を超えることがある。これを設定しないと `upstream sent too big header while reading response header from upstream` というエラーでコールバック処理が502になる。

デフォルトの `/etc/nginx/nginx.conf` 内のデフォルトserverブロックは削除する。

```bash
vi /etc/nginx/nginx.conf
```

ファイル内を確認し、`include /etc/nginx/conf.d/*.conf;` の行があることを確認したうえで、その後ろに続く `server { ... }` ブロック全体(行ごと)を削除する。`include` の行は残すこと。

```bash
# 編集後、構文確認
nginx -t
```

`nginx: configuration file /etc/nginx/nginx.conf test is successful` と表示されればOK。

設定テストとリロード:

```bash
systemctl reload nginx
```

> **解説:auth_request の仕組み**
>
> 1. クライアントが `/private/` にアクセス
> 2. Nginx は `auth_request /oauth2/auth` により内部で oauth2-proxy に問い合わせ
> 3. oauth2-proxy がセッションクッキーを検証
> 4. 認証済みなら 200 を返す → クライアントに `/private/` を返す
> 5. 未認証なら 401 を返す → `error_page 401` で `/oauth2/sign_in` にリダイレクト → Keycloakログイン画面へ

---

### Step 6: Keycloak側のクライアント設定 + oauth2-proxy起動

**目的:** Keycloak側に oauth2-proxy 用の OIDC クライアントを登録し、oauth2-proxy を起動する。

#### 6-1. 【Keycloak管理画面で実施】Clientの作成

`auth-local` Realmに切り替えた状態で:

1. 左メニュー `Clients` → `Create client`
2. General settings:
   - Client type: `OpenID Connect`
   - Client ID: `oauth2-proxy`
   - `Next`
3. Capability config:
   - Client authentication: `On`
   - Authentication flow: `Standard flow` のみチェック
   - `Next`
4. Login settings:
   - Valid redirect URIs: `https://nginx.auth.local/oauth2/callback`
   - `Save`

#### 6-1-1. 【Keycloak管理画面で実施】Audienceマッパーの追加

KeycloakのIDトークンは、デフォルトでは `aud`(audience)クレームに `account` しか含まれず、`oauth2-proxy` クライアント自身は含まれない。これを緩和しないと、oauth2-proxyがトークンを受け取った際に `audience from claim aud with value [account] does not match with any of allowed audiences map[oauth2-proxy:{}]` というエラーでコールバックが失敗する。

1. `Clients` → `oauth2-proxy` を開く
2. `Client scopes` タブ → `oauth2-proxy-dedicated` をクリック
3. マッパーがまだ無い状態だと `Add predefined mapper` と `Configure a new mapper` の2つのボタンが表示される。**`Configure a new mapper`** をクリックし、一覧から `Audience`(`Add specified audience to the audience (aud) field of token`)を選択する
4. 設定:
   - Name: `aud-oauth2-proxy`
   - Included Client Audience: `oauth2-proxy`
   - Add to ID token: `On`
5. `Save`

> **注意:`Audience Resolve` ではなく `Audience` を選ぶこと**
>
> `Add predefined mapper` 側の一覧にも `audience resolve` という項目があるが、これは別の用途(あるクライアントに対してロールを持つ「他の」クライアントのIDを自動的にaudienceへ加える)のマッパーで、今回のケース(oauth2-proxy自身を自分のトークンのaudienceに含めたい)では効かないことがある。必ず `Configure a new mapper` 側の `Audience` を使い、`Included Client Audience` に `oauth2-proxy` を明示的に指定すること。

#### 6-2. 【Keycloak管理画面で実施】Client Secret の取得

1. 作成した `oauth2-proxy` クライアントを開く
2. `Credentials` タブをクリック
3. `Client Secret` の値をコピーしてメモ(以降 `<KC_CLIENT_SECRET>` と表記)

#### 6-3. 【nginx.auth.localで実施】oauth2-proxy のクッキー署名秘密生成

```bash
openssl rand -base64 32 | tr '+/' '-_'
# 出力例: xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx
# この値をメモ(<COOKIE_SECRET>)
```

#### 6-4. 【nginx.auth.localで実施】oauth2-proxy の設定ファイル作成

```bash
mkdir -p /etc/oauth2-proxy
vi /etc/oauth2-proxy/oauth2-proxy.cfg
```

```
http_address = "127.0.0.1:4180"
reverse_proxy = true

provider = "keycloak-oidc"
oidc_issuer_url = "http://kc.auth.local:8080/realms/auth-local"
client_id = "oauth2-proxy"
client_secret = "<KC_CLIENT_SECRET>"

redirect_url = "https://nginx.auth.local/oauth2/callback"

cookie_secret = "<COOKIE_SECRET>"
cookie_secure = true
cookie_domains = ["nginx.auth.local"]

email_domains = ["*"]

# LDAPからインポートしたユーザーは emailVerified=false になるため、これがないと
# "email in id_token isn't verified" エラーでコールバックが失敗する
insecure_oidc_allow_unverified_email = true

# oauth2-proxy 自身が直接外向きには受けないため
upstreams = ["static://200"]

skip_provider_button = true
```

> **解説:upstreams = "static://200" の意味**
>
> oauth2-proxy を「認証専用ゲート」として使うときの設定。実際のページ配信は Nginx が行い、oauth2-proxy は `/oauth2/auth` の問い合わせに対して 200/401 を返すだけ。`static://200` は upstream を持たない動作を明示する。

> **解説:`insecure_oidc_allow_unverified_email` が必要な理由**
>
> KeycloakにLDAP User Federation経由でインポートされたユーザー(taro等)は、デフォルトで `emailVerified = false` になる。oauth2-proxyは既定で「`email_verified` が false のIDトークンは拒否する」という安全側の挙動になっており、これがないと `taro@auth.local` のようなLDAP由来のメールアドレスでログインしようとするたびに500エラーになる。

#### 6-5. 【nginx.auth.localで実施】oauth2-proxy の systemd ユニット作成

```bash
vi /etc/systemd/system/oauth2-proxy.service
```

```
[Unit]
Description=oauth2-proxy
After=network.target

[Service]
ExecStart=/usr/local/bin/oauth2-proxy --config=/etc/oauth2-proxy/oauth2-proxy.cfg
Restart=on-failure
User=nobody

[Install]
WantedBy=multi-user.target
```

```bash
systemctl daemon-reload
systemctl start oauth2-proxy
systemctl enable oauth2-proxy
systemctl status oauth2-proxy
```

---

## 5. 動作確認・検証

### 5-1. 確認チェックリスト

- [ ] 確認①: OpenLDAPから taro が取得できる
- [ ] 確認②: Keycloak管理画面で taro が同期されている
- [ ] 確認③: ブラウザでNginx保護ページにアクセス → Keycloakログイン → 保護ページ閲覧成功
- [ ] 確認④: radtest で taro が認証成功
- [ ] 確認⑤: LDAP側でパスワード変更すると、Webログインと radtest の両方に反映される

---

### 確認①: OpenLDAP からの取得

【ldap.auth.localで実施】

```bash
ldapsearch -x -b "dc=auth,dc=local" "(uid=taro)" uid cn mail
# taro のエントリが返ればOK
```

---

### 確認②: Keycloakでの同期状態

Keycloak管理コンソール → `Users` → `taro` が表示されていることを確認。

---

### 確認③: Webログインフロー

【操作端末で実施】

1. ブラウザで `https://nginx.auth.local/private/` にアクセス
2. 自己署名証明書の警告 → 詳細設定 → 移動
3. Keycloakのログイン画面にリダイレクトされる
4. Username: `taro`, Password: `TaroPass123` を入力
5. 保護ページ `Welcome to Private Area` が表示されればOK

> **解説:このフローでの通信経路**
>
> ブラウザ → Nginx(HTTPS) → auth_request → oauth2-proxy → 401 → リダイレクト → Keycloak(HTTP) → ログイン → LDAP問い合わせ → 認証成功 → コールバックURL → oauth2-proxy がセッション確立 → ブラウザに保護ページが返る、という流れ。
>
> 1ユーザーアクションの裏で4台のサーバが連携する。

---

### 確認④: RADIUS認証

【操作端末で実施】(`radtest` が使える環境 / 必要ならFreeRADIUSサーバ自身でローカルテスト)

サーバ自身でテストする場合、`clients.conf` に `client localhost` の定義があるはずなので、まずローカルから:

```bash
# radius.auth.local 上で
radtest taro TaroPass123 127.0.0.1 0 testing123
```

期待出力:

```
Received Access-Accept Id ... from 127.0.0.1:1812 ...
```

外部端末からテストする場合は、3-3-3節のSGで `<MY_IP>` から1812/UDPを許可し、4-5節で `client mytestclient` を `<MY_IP>` で登録した状態で:

```bash
radtest taro TaroPass123 <RADIUS_PUB> 0 testing123
```

---

### 確認⑤: パスワード変更の即時反映

【ldap.auth.localで実施】

```bash
# 新パスワードのハッシュ生成(非対話・変数に保持)
NEW_HASH=$(/opt/symas/sbin/slappasswd -s 'NewPass456')
echo "$NEW_HASH"
```

LDIFファイルもヒアドキュメントで作成し、`vi`での手貼り付けによるハッシュの破損を避ける:

```bash
cat > /root/modify_taro.ldif << EOF
dn: uid=taro,ou=People,dc=auth,dc=local
changetype: modify
replace: userPassword
userPassword: $NEW_HASH
EOF
cat /root/modify_taro.ldif
ldapmodify -x -D "cn=admin,dc=auth,dc=local" -w '<ADMIN_PASS>' -f /root/modify_taro.ldif
# <ADMIN_PASS> は1-3節で実際に設定した平文パスワードに置き換える
```

【操作端末で確認】

- ブラウザで再度 `/private/` にアクセス → ログアウト後、`NewPass456` でログインできる
- `radtest taro NewPass456 ... ` → Access-Accept
- `radtest taro TaroPass123 ... ` → Access-Reject

> **考えるポイント:なぜ即時反映されるのか**
>
> Keycloak はパスワード検証時に毎回LDAPに bind しに行く(`READ_ONLY` モードのとき)。FreeRADIUS も同様にbind検証する。よってLDAP側でパスワードを変えれば、両者から即時参照される。
>
> 「**真実はLDAPにしかない**」状態を保つことが、認証統合基盤の本質。

---

## 6. トラブルシューティング

### エラー①: ldapsearchで「Can't contact LDAP server」

**原因:** slapdが起動していない、または listenが正しくない。

**対処:**

```bash
systemctl status slapd
ss -tlnp | grep 389
# 0.0.0.0:389 で待ち受けていればOK
```

---

### エラー②: Keycloak の Test connection で失敗

**原因:** SG、`/etc/hosts`、Connection URL の指定ミス。

**対処:**

```bash
# kc.auth.local 上で
ldapsearch -x -H ldap://ldap.auth.local -D "cn=admin,dc=auth,dc=local" -w '<ADMIN_PASS>' -b "dc=auth,dc=local"
# <ADMIN_PASS> は1-3節で実際に設定した平文パスワードに置き換える
# 成功すれば、KeycloakのConnection URL設定を見直し
```

---

### エラー③: oauth2-proxy が「invalid_redirect_uri」エラー

**原因:** Keycloak の Client の Valid redirect URIs と、oauth2-proxy の redirect_url が一致していない。

**対処:** Keycloak側の Valid redirect URIs に `https://nginx.auth.local/oauth2/callback` が **正確に** 入っているか確認。末尾スラッシュ・スキーム・ポート番号まで一致が必要。

---

### エラー④: 自己署名証明書でブラウザがアクセス拒否

**原因:** 厳格ブラウザは自己署名証明書を強く拒否する設定がある。

**対処:** Chrome なら「詳細設定 → 〜にアクセスする(安全ではありません)」をクリック。Firefoxは「例外として追加」。

---

### エラー⑤: radtest が「No reply from server」

**原因:** SG(UDP/1812)の設定漏れ、または FreeRADIUS のclients.conf に送信元IPが登録されていない。

**対処:**

```bash
# radius.auth.local 上で
radiusd -X
# 別端末から radtest 実行し、ログに何か出るか確認
# 「Ignoring request from unknown client」と出れば clients.conf 不備
```

---

### エラー⑥: Keycloak起動時に Out of Memory

**原因:** インスタンスタイプのメモリが足りない(t3.microで起動した場合など)。

**対処:** c7i-flex.large等のメモリ4GBのインスタンスにスケールアップ。または `KC_JAVA_OPTS` で JVM ヒープを抑える:

```bash
export JAVA_OPTS_KC_HEAP="-Xms256m -Xmx512m"
./bin/kc.sh start-dev ...
```

---

### ログの確認場所

| ログ | 場所 | コマンド |
|---|---|---|
| OpenLDAP | `journalctl -u slapd` | `journalctl -u slapd -f` |
| Keycloak | コンソール出力 | 起動端末で確認 |
| FreeRADIUS | `/var/log/radius/radius.log` または `journalctl -u radiusd` | `radiusd -X` で詳細デバッグ |
| Nginx | `/var/log/nginx/error.log` | `tail -f /var/log/nginx/error.log` |
| oauth2-proxy | `journalctl -u oauth2-proxy` | `journalctl -u oauth2-proxy -f` |

---

## 7. 参考リソース・関連資料

| 資料名 | URL |
|---|---|
| Keycloak Server Administration | https://www.keycloak.org/docs/latest/server_admin/ |
| Keycloak User Federation (LDAP) | https://www.keycloak.org/docs/latest/server_admin/#_user-storage-federation |
| Symas OpenLDAP Documentation | https://repo.symas.com/ |
| OpenLDAP Admin Guide | https://www.openldap.org/doc/admin26/ |
| FreeRADIUS LDAP Module | https://wiki.freeradius.org/modules/Rlm_ldap |
| oauth2-proxy Documentation | https://oauth2-proxy.github.io/oauth2-proxy/ |
| Nginx auth_request module | https://nginx.org/en/docs/http/ngx_http_auth_request_module.html |

---

## 付録

### A. 環境変数・パラメータまとめ

| パラメータ | 自環境の値 | 説明 |
|---|---|---|
| `<LDAP_PUB>` | | OpenLDAPサーバ グローバルIP |
| `<LDAP_PRI>` | | OpenLDAPサーバ プライベートIP |
| `<KC_PUB>` | | Keycloakサーバ グローバルIP |
| `<KC_PRI>` | | Keycloakサーバ プライベートIP |
| `<RADIUS_PUB>` | | FreeRADIUSサーバ グローバルIP |
| `<RADIUS_PRI>` | | FreeRADIUSサーバ プライベートIP |
| `<NGINX_PUB>` | | Nginxサーバ グローバルIP |
| `<NGINX_PRI>` | | Nginxサーバ プライベートIP |
| `<MY_IP>` | | 操作端末のグローバルIP |
| `<ADMIN_HASH>` | | OpenLDAP admin のSSHAパスワード |
| `<TARO_HASH>` | | taro のSSHAパスワード |
| `<KC_CLIENT_SECRET>` | | Keycloak側 oauth2-proxy クライアントの Secret |
| `<COOKIE_SECRET>` | | oauth2-proxy のクッキー署名秘密(base64) |
| LDAPベースDN | `dc=auth,dc=local` | |
| Keycloak Realm | `auth-local` | |
| Keycloak Client ID | `oauth2-proxy` | |
| RADIUS shared secret | `testing123` | |

### B. 用語解説

| 用語 | 説明 |
|---|---|
| DIT | Directory Information Tree。LDAPのツリー構造 |
| DN | Distinguished Name。LDAPエントリの完全な識別名 |
| RDN | Relative DN。親に対する相対識別名(例: `uid=taro`) |
| User Federation | Keycloakが外部ユーザーストア(LDAP等)を取り込む機能 |
| Realm | Keycloakのテナント単位。独立したユーザー集合・設定を持つ |
| OIDC | OpenID Connect。OAuth2 をベースにした認証プロトコル |
| Authorization Code Flow | OIDCの代表的なフロー。ブラウザリダイレクトで認証コードを取得し、トークンと交換 |
| auth_request | Nginxの内部ディレクティブ。リクエストごとに別エンドポイントへ認証問い合わせ |
| RADIUS | Remote Authentication Dial-In User Service。ネットワーク機器でよく使われる認証プロトコル |
| Access-Accept / Reject | RADIUSサーバが返す応答パケットの種別 |
| shared secret | RADIUSクライアントとサーバ間で共有する秘密鍵 |

### C. クリーンアップ手順

1. 各サーバで関連サービスを停止
   - OpenLDAP: `systemctl stop slapd`
   - Keycloak: プロセスを `kill`
   - FreeRADIUS: `systemctl stop radiusd`
   - Nginx: `systemctl stop nginx`, oauth2-proxy: `systemctl stop oauth2-proxy`
2. 操作端末の hosts ファイルから `nginx.auth.local`、`kc.auth.local` の行を削除
3. EC2インスタンス4台を終了
4. セキュリティグループを削除
5. キーペアを削除(必要に応じて)
