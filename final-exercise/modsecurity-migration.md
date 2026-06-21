# 手順書_ModSecurity_移行

## 1. ドキュメント情報

| 項目        | 内容                                                                 |
| --------- | ------------------------------------------------------------------ |
| 対象システム    | nginx + ModSecurity                                                |
| 目的        | 既存環境の nginx 1.16.1 + ModSecurity 設定を，新環境の nginx 1.30.0 へ移行する       |
| 対象環境      | Amazon Linux 2023                                                  |
| 移行元       | nginx 1.16.1                                                       |
| 移行先       | nginx 1.30.0                                                       |
| 所要時間（初心者） | 2〜3時間                                                              |
| 所要時間（経験者） | 30分〜1時間                                                            |
| ダウンタイム    | `reload` の場合は基本的に短時間．`restart` の場合は一時的な通信断が発生する可能性あり                |
| 前提手順書     | `nginx-reverse-proxy.md`（新環境の nginx リバースプロキシ構築が完了していること）          |

> **改訂履歴**
>
> | バージョン | 日付         | 内容                                                                                          |
> | ----- | ---------- | ------------------------------------------------------------------------------------------- |
> | 1.0   | 2026-06-20 | 初版作成．`modsecurity構築手順書.md` を移行手順書として再編．ファイル名を `modsecurity-migration.md` に変更．テンプレート形式に統一． |

------------------------------

## 2. 目的・概要

### 2.1 目的

本手順書は，既存環境で稼働している nginx 1.16.1 + ModSecurity の設定を，新環境の nginx 1.30.0 へ移行するための手順をまとめたものです．

ModSecurity は，Webアプリケーションへの攻撃を検知・防御する WAF（Web Application Firewall）です．

本手順では，以下を実施します．

* ModSecurity モジュールロード設定の確認・修正
* ModSecurity 設定ファイルの移行
* nginx 設定への ModSecurity 適用
* 動作確認
* ロールバック手順の整理

### 2.2 構成図

```
┌──────────────────────────────────────────────────────────┐
│                    [移行元環境]                           │
│  ┌──────────────────────────────────────────────────┐    │
│  │  移行元サーバー（nginx 1.16.1 + ModSecurity）      │    │
│  │  /usr/local/nginx-1.16.1/conf/nginx.conf         │    │
│  │  /usr/local/nginx/conf/modsec_includes.conf      │    │
│  │  /usr/local/nginx/conf/modsecurity.conf          │    │
│  └────────────────────┬─────────────────────────────┘    │
└───────────────────────┼──────────────────────────────────┘
                        │ scp で設定ファイル転送
                        ▼
┌──────────────────────────────────────────────────────────┐
│                    [移行先環境]                           │
│  ┌──────────────────────────────────────────────────┐    │
│  │  移行先サーバー（nginx 1.30.0 + ModSecurity）      │    │
│  │  /etc/nginx/nginx.conf                           │    │
│  │  /etc/nginx/conf.d/proxy.conf                    │    │
│  │  /usr/local/nginx/conf/modsec_includes.conf      │    │
│  │  /usr/local/nginx/conf/modsecurity.conf          │    │
│  └──────────────────────────────────────────────────┘    │
└──────────────────────────────────────────────────────────┘
```

### 2.3 移行元・移行先

| 項目                   | 移行元                                          | 移行先                                          |
| -------------------- | -------------------------------------------- | -------------------------------------------- |
| nginx バージョン          | nginx 1.16.1                                 | nginx 1.30.0                                 |
| nginx 設定ファイル         | `/usr/local/nginx-1.16.1/conf/nginx.conf`    | `/etc/nginx/nginx.conf`                      |
| アプリ用設定ファイル           | 旧 nginx.conf 内に記載                            | `/etc/nginx/conf.d/proxy.conf`               |
| ModSecurity Include設定 | `/usr/local/nginx/conf/modsec_includes.conf` | `/usr/local/nginx/conf/modsec_includes.conf` |
| ModSecurity 本体設定     | `/usr/local/nginx/conf/modsecurity.conf`     | `/usr/local/nginx/conf/modsecurity.conf`     |

### 2.4 移行範囲

* nginx 1.16.1 から nginx 1.30.0 への ModSecurity 関連設定の移行
* ModSecurity モジュールロード設定の修正
* ModSecurity 設定ファイル（`modsec_includes.conf` / `modsecurity.conf`）の移行
* `proxy.conf` への ModSecurity 有効化設定追記
* 動作確認
* ロールバック手順の整理

### 2.5 注意点・コメント

ModSecurity を `DetectionOnly` から `On` に変更すると，正常なリクエストが誤検知により `403 Forbidden` でブロックされる可能性があります．

本番環境では，事前にログを確認し，問題がないことを確認してから `On` に変更してください．

------------------------------

## 3. 前提条件

### 3.1 前提手順書

本手順書は，以下の手順書が完了していることを前提とします．

| 手順書                       | 内容                                       |
| ------------------------- | ---------------------------------------- |
| `nginx-reverse-proxy.md`  | 新環境の nginx 1.30.0 リバースプロキシ構築（ModSecurity 未適用状態） |

### 3.2 想定される影響

* nginx 設定ミスにより，Webサイトへアクセスできなくなる可能性があります．
* ModSecurity の誤検知により，正常なリクエストが `403 Forbidden` でブロックされる可能性があります．
* ModSecurity モジュールのパス不一致により，nginx が起動しない可能性があります．
* 旧 nginx 用のモジュールを新 nginx で使うと，互換性問題が発生する可能性があります．

### 3.3 ロールバック可能性

ロールバックは可能です．

事前に以下のファイルをバックアップしておくことで，設定を元に戻せます．

* `/etc/nginx/nginx.conf`
* `/etc/nginx/conf.d/proxy.conf`
* `/usr/local/nginx/conf/modsec_includes.conf`
* `/usr/local/nginx/conf/modsecurity.conf`

### 3.4 バックアップ・復旧時間

| 作業              | 目安    |
| --------------- | ----- |
| 設定ファイルのバックアップ   | 5分    |
| 設定ファイルの復旧       | 5〜10分 |
| nginx 再起動・状態確認  | 1分以内  |

### 3.5 事前準備チェックリスト

* [ ] root 権限または sudo 権限を確認する
* [ ] 移行先サーバーの nginx バージョンを確認する
* [ ] 既存 nginx 設定ファイルのバックアップを取得する
* [ ] ModSecurity 設定ファイルのバックアップを取得する
* [ ] ModSecurity モジュールの存在を確認する

------------------------------

## 4. 移行手順

### 4.1 作業ユーザー確認【実施対象：移行先サーバー】

実施内容：root 権限または sudo 権限があるユーザーで作業できることを確認します．

```bash
whoami
sudo -v
```

期待される出力：

```text
root
```

または，`sudo -v` が正常に実行できること．

注意点・コメント：

nginx 設定ファイルの編集，ModSecurity 設定ファイルの編集，nginx の reload / restart には管理者権限が必要です．

------------------------------

### 4.2 移行先 nginx バージョンの確認【実施対象：移行先サーバー】

実施内容：移行先サーバーの nginx バージョンとビルドオプションを確認します．

```bash
nginx -v
nginx -V 2>&1 | tee /tmp/nginx-V.txt
```

期待される出力：

```text
nginx version: nginx/1.30.0
```

注意点・コメント：

`nginx -V` の出力は，ModSecurity モジュールをビルドする際に必要になる場合があります．

------------------------------

### 4.3 既存設定ファイルのバックアップ【実施対象：移行先サーバー】

実施内容：変更前に nginx 関連ファイルをバックアップします．

```bash
cp -a /etc/nginx/nginx.conf /etc/nginx/nginx.conf.bak.$(date +%Y%m%d_%H%M%S)

cp -a /etc/nginx/conf.d/proxy.conf /etc/nginx/conf.d/proxy.conf.bak.$(date +%Y%m%d_%H%M%S)

cp -a /usr/local/nginx/conf/modsec_includes.conf /usr/local/nginx/conf/modsec_includes.conf.bak.$(date +%Y%m%d_%H%M%S) 2>/dev/null || true

cp -a /usr/local/nginx/conf/modsecurity.conf /usr/local/nginx/conf/modsecurity.conf.bak.$(date +%Y%m%d_%H%M%S) 2>/dev/null || true
```

注意点・コメント：

`2>/dev/null || true` は，対象ファイルが存在しない場合でも処理を止めないための記述です．

------------------------------

### 4.4 ModSecurity モジュールの存在確認【実施対象：移行先サーバー】

実施内容：新環境に ModSecurity の nginx 用モジュールが存在するか確認します．

```bash
find / -name "ngx_http_modsecurity_module.so" 2>/dev/null
```

期待される出力例：

```text
/usr/lib64/nginx/modules/ngx_http_modsecurity_module.so
```

注意点・コメント：

nginx 1.30.0 で使用する場合は，nginx 1.30.0 に対応した `ngx_http_modsecurity_module.so` が必要です．

旧 nginx 1.16.1 用のモジュールをそのまま流用するのは避けます．

------------------------------

### 4.5 ModSecurity ロード設定の確認・修正【実施対象：移行先サーバー】

実施内容：nginx が ModSecurity モジュールを読み込む設定を確認し，実際のモジュールパスに合わせて修正します．

現在の設定確認：

```bash
grep -Rni "ngx_http_modsecurity_module.so\|load_module" /etc/nginx /usr/share/nginx/modules 2>/dev/null
```

ファイル編集：`/usr/share/nginx/modules/modsecurity.conf`

【変更前】

```nginx
load_module modules/ngx_http_modsecurity_module.so;
```

【変更後】

```nginx
load_module /usr/lib64/nginx/modules/ngx_http_modsecurity_module.so;
```

【理由】

実際に存在する ModSecurity モジュールのパスを指定するためです．

`/usr/share/nginx/modules/ngx_http_modsecurity_module.so` が存在しない場合，nginx 起動時に `dlopen()` エラーになります．

注意点・コメント：

実際のパスは環境によって異なるため，必ず `find` コマンドで確認したパスを指定してください．

------------------------------

### 4.6 ModSecurity 設定ファイルの移行【実施対象：移行元サーバー → 移行先サーバー】

実施内容：移行元から ModSecurity 設定ファイルを移行先へコピーします．

移行先で現在の状態を確認：

```bash
ls -l /usr/local/nginx/conf/modsec_includes.conf
ls -l /usr/local/nginx/conf/modsecurity.conf
```

存在しない場合，移行元からコピーします．

```bash
scp <移行元サーバーのIP>:/usr/local/nginx/conf/modsec_includes.conf /usr/local/nginx/conf/

scp <移行元サーバーのIP>:/usr/local/nginx/conf/modsecurity.conf /usr/local/nginx/conf/
```

参照パスの確認：

```bash
cat /usr/local/nginx/conf/modsec_includes.conf
```

期待される出力例：

```text
Include /usr/local/nginx/conf/modsecurity.conf
```

参照先ファイルの存在確認：

```bash
ls -l /usr/local/nginx/conf/modsecurity.conf
```

注意点・コメント：

`<移行元サーバーのIP>` は，実際の移行元サーバーの IP アドレスに置き換えてください．

`Include` 先のファイルが存在しないと，ModSecurity が正しく動作しません．

------------------------------

### 4.7 ModSecurity 動作モードの変更【実施対象：移行先サーバー】

実施内容：ModSecurity が検知のみか，ブロックする設定か確認し，必要に応じて変更します．

現在の設定確認：

```bash
grep -Rni "^\s*SecRuleEngine" /usr/local/nginx/conf /etc/nginx 2>/dev/null
```

期待される出力例：

```text
/usr/local/nginx/conf/modsecurity.conf:7:SecRuleEngine DetectionOnly
```

| 設定値           | 意味               |
| ------------- | ---------------- |
| DetectionOnly | 検知のみ．ブロックしない     |
| On            | 検知してブロックする       |
| Off           | ModSecurity を無効化 |

ファイル編集：`/usr/local/nginx/conf/modsecurity.conf`

【変更前】

```nginx
SecRuleEngine DetectionOnly
```

【変更後】

```nginx
SecRuleEngine On
```

【理由】

検知のみでは攻撃をブロックしないため，WAF として防御するには `On` に変更します．

注意点・コメント：

本番環境では，いきなり `On` にすると正常な通信が誤検知でブロックされる可能性があります．

事前にログを確認し，問題ないことを確認してから変更してください．

------------------------------

### 4.8 nginx 設定への ModSecurity 適用【実施対象：移行先サーバー】

実施内容：アプリケーション用の `server` ブロックで ModSecurity を有効化します．

ファイル編集：`/etc/nginx/conf.d/proxy.conf`

【変更前】

```nginx
server {
    listen       80;
    server_name  _;

    location <アプリケーションパス> {
        proxy_pass http://<upstream名><アプリケーションパス>;
    }
}
```

【変更後】

```nginx
server {
    listen       80;
    server_name  _;

    modsecurity on;
    modsecurity_rules_file /usr/local/nginx/conf/modsec_includes.conf;

    location <アプリケーションパス> {
        proxy_pass http://<upstream名><アプリケーションパス>;
    }
}
```

【理由】

対象の Web アクセスに対して ModSecurity の検査を有効にするためです．

注意点・コメント：

`modsecurity_rules_file` のパスは，実際に存在する `modsec_includes.conf` を指定してください．

------------------------------

### 4.9 server_name 重複の確認・解消【実施対象：移行先サーバー】

実施内容：nginx 設定の中で `server_name _;` が重複していないか確認します．

```bash
grep -Rni "server_name\s\+_;" /etc/nginx /usr/local/nginx/conf 2>/dev/null
```

重複している場合，`nginx -t` で以下のような警告が出ます．

```text
nginx: [warn] conflicting server name "_" on 0.0.0.0:80, ignored
```

ファイル編集：`/etc/nginx/conf.d/proxy.conf`

【変更前】

```nginx
server {
    listen 80;
    server_name _;
}
```

【変更後】

```nginx
server {
    listen 80;
    server_name <対象FQDN>;
}
```

【理由】

同じ IP アドレス・同じポート番号で `server_name _;` が複数あると，どちらか一方が無視されるためです．

注意点・コメント：

`server_name _;` はデフォルト用の設定として使われます．

複数の `server` ブロックで重複している場合は，不要な `server` ブロックを削除するか，正式なドメイン名に変更してください．

------------------------------

### 4.10 nginx 設定の構文チェック【実施対象：移行先サーバー】

実施内容：nginx 設定に文法エラーがないか確認します．

```bash
nginx -t
```

期待される出力：

```text
nginx: the configuration file /etc/nginx/nginx.conf syntax is ok
nginx: configuration file /etc/nginx/nginx.conf test is successful
```

注意点・コメント：

`unknown directive "modsecurity"` が出る場合は，ModSecurity モジュールが読み込まれていません．

`dlopen()` エラーが出る場合は，`load_module` のパスが間違っている可能性があります．

------------------------------

### 4.11 nginx 設定の反映【実施対象：移行先サーバー】

実施内容：nginx 設定を反映します．

無停止に近い反映：

```bash
systemctl reload nginx
```

再起動する場合：

```bash
systemctl restart nginx
```

状態確認：

```bash
systemctl status nginx
```

注意点・コメント：

本番環境では，まず `reload` を使用することを推奨します．

`restart` は一時的に通信断が発生する可能性があります．

------------------------------

## 5. 動作確認

### 5.1 動作確認チェックリスト

* [ ] `SecRuleEngine On` になっている
* [ ] テストリクエストで ModSecurity の動作を確認した
* [ ] nginx エラーログに異常がない
* [ ] ModSecurity 監査ログを確認した
* [ ] アプリケーションが正常に表示される
* [ ] 正常な操作が `403 Forbidden` でブロックされない

------------------------------

### 5.2 ModSecurity 設定の確認【実施対象：移行先サーバー】

実施内容：`SecRuleEngine` の設定を確認します．

```bash
grep -Rni "^\s*SecRuleEngine" /usr/local/nginx/conf /etc/nginx 2>/dev/null
```

期待される出力：

```text
SecRuleEngine On
```

注意点・コメント：

`DetectionOnly` の場合は検知のみで，ブロックは行われません．

------------------------------

### 5.3 テストリクエストによる確認【実施対象：移行先サーバー】

実施内容：攻撃に見えるリクエストを送信し，ModSecurity が反応するか確認します．

```bash
curl -I "http://localhost/?id=1 UNION SELECT 1,2,3--"
```

ブロックされる場合の例：

```text
HTTP/1.1 403 Forbidden
```

注意点・コメント：

`SecRuleEngine DetectionOnly` の場合，`403 Forbidden` にはならず，ログ出力のみになる可能性があります．

------------------------------

### 5.4 nginx ログの確認【実施対象：移行先サーバー】

実施内容：nginx のエラーログとアクセスログを確認します．

```bash
tail -n 100 /var/log/nginx/error.log
tail -n 100 /var/log/nginx/access.log
```

ModSecurity 監査ログのパス確認：

```bash
grep -Rni "SecAuditLog" /usr/local/nginx/conf /etc/nginx 2>/dev/null
```

監査ログ確認例：

```bash
tail -n 100 /var/log/modsec_audit.log
```

注意点・コメント：

`error`，`emerg`，`crit` が出ている場合は，設定ファイルの記述ミスやモジュール不足の可能性があります．

------------------------------

### 5.5 アプリケーション動作確認【実施対象：移行先サーバー】

実施内容：ブラウザで以下にアクセスし，アプリケーションが正常に動作することを確認します．

```text
http://<対象FQDN><アプリケーションパス>
```

確認項目：

* [ ] トップページが表示される
* [ ] ログインできる
* [ ] 画面遷移できる
* [ ] ファイルアップロードができる
* [ ] 正常な操作が `403 Forbidden` でブロックされない

------------------------------

### 5.6 移行後の継続監視【実施対象：移行先サーバー】

実施内容：移行後は，一定時間ログを監視します．

```bash
tail -f /var/log/nginx/error.log
```

```bash
tail -f /var/log/nginx/access.log
```

ModSecurity 監査ログ：

```bash
tail -f /var/log/modsec_audit.log
```

監視設定の確認項目：

* [ ] nginx プロセス監視を確認した
* [ ] HTTP ステータス監視を確認した
* [ ] 403 エラー増加の監視を確認した
* [ ] nginx error.log の監視を確認した

注意点・コメント：

`403 Forbidden` が急増している場合は，ModSecurity の誤検知が発生している可能性があります．

------------------------------

## 6. トラブルシューティング

### エラー1：unknown directive "modsecurity"

原因：

ModSecurity モジュールが読み込まれていない可能性があります．

解決方法：

ModSecurity モジュールのロード設定を確認します．

```bash
grep -Rni "ngx_http_modsecurity_module.so\|load_module" /etc/nginx /usr/share/nginx/modules 2>/dev/null
```

`.so` ファイルが存在するか確認します．

```bash
find / -name "ngx_http_modsecurity_module.so" 2>/dev/null
```

注意点・コメント：

`load_module` のパスが実際の `.so` ファイルと一致しているか確認してください．

------------------------------

### エラー2：dlopen() エラー

原因：

`load_module` のパスが間違っている可能性があります．

解決方法：

正しいモジュールパスを確認します．

```bash
find / -name "ngx_http_modsecurity_module.so" 2>/dev/null
```

確認したパスを `/usr/share/nginx/modules/modsecurity.conf` に設定します．

注意点・コメント：

存在しないパスを指定すると，nginx は起動できません．

------------------------------

### エラー3：nginx が起動しない

原因：

nginx 設定ファイルの文法ミス，または ModSecurity 設定ファイルの読み込みエラーの可能性があります．

解決方法：

```bash
nginx -t
```

出力されたエラー内容のファイル名と行番号を確認して修正します．

注意点・コメント：

`nginx -t` が成功するまでは，`systemctl reload nginx` や `systemctl restart nginx` を実行しないでください．

------------------------------

### エラー4：正常アクセスが 403 Forbidden になる

原因：

ModSecurity の誤検知により，正常なリクエストがブロックされている可能性があります．

解決方法：

一時的に `SecRuleEngine` を `DetectionOnly` に戻します．

ファイル編集：`/usr/local/nginx/conf/modsecurity.conf`

【変更前】

```nginx
SecRuleEngine On
```

【変更後】

```nginx
SecRuleEngine DetectionOnly
```

【理由】

一時的にブロックを停止し，ログ確認を優先するためです．

設定確認と反映：

```bash
nginx -t
systemctl reload nginx
```

注意点・コメント：

恒久対応としては，監査ログを確認し，誤検知しているルールの調整を行います．

------------------------------

### エラー5：監査ログが出力されない

原因：

`SecAuditLog` 設定がない，またはログ出力先の権限が不足している可能性があります．

解決方法：

`SecAuditLog` の設定を確認します．

```bash
grep -Rni "SecAuditLog" /usr/local/nginx/conf /etc/nginx 2>/dev/null
```

ログファイルの存在を確認します．

```bash
ls -l /var/log/modsec_audit.log
```

注意点・コメント：

ログファイルまたは出力先ディレクトリに nginx 実行ユーザーが書き込める必要があります．

------------------------------

### エラー6：conflicting server name "_" 警告

原因：

`server_name _;` を持つ `server` ブロックが複数存在しています．

解決方法：

該当箇所を検索します．

```bash
grep -Rni "server_name  _\|server_name _" /etc/nginx
```

不要な `server` ブロックをコメントアウトするか，正式なドメイン名に変更します．

注意点・コメント：

警告だけで nginx 自体は起動する場合があります．

ただし，意図しない `server` ブロックが無視される可能性があるため修正してください．

------------------------------

## 7. 参考リソース

* nginx 公式ドキュメント：https://nginx.org/en/docs/
* ModSecurity 公式ドキュメント：https://github.com/owasp-modsecurity/ModSecurity/wiki
* ModSecurity-nginx Connector：https://github.com/owasp-modsecurity/ModSecurity-nginx
* OWASP Core Rule Set 公式ドキュメント：https://coreruleset.org/
* 前提手順書：`nginx-reverse-proxy.md`
* チーム間統一：手順書作成ガイドライン

------------------------------

## 8. ロールバック手順

### 8.1 ロールバック判定基準

以下のいずれかが発生した場合は，ロールバックを検討します．

* nginx が起動しない
* `nginx -t` が失敗する
* 正常なアクセスが大量に `403 Forbidden` でブロックされる
* アプリケーションにアクセスできない
* ModSecurity 設定後に重大なエラーが継続する

------------------------------

### 8.2 設定ファイルをバックアップから戻す【実施対象：移行先サーバー】

実施内容：事前に取得したバックアップを戻します．

```bash
cp -a /etc/nginx/nginx.conf.bak.<日時> /etc/nginx/nginx.conf

cp -a /etc/nginx/conf.d/proxy.conf.bak.<日時> /etc/nginx/conf.d/proxy.conf
```

ModSecurity 設定も戻す場合：

```bash
cp -a /usr/local/nginx/conf/modsec_includes.conf.bak.<日時> /usr/local/nginx/conf/modsec_includes.conf

cp -a /usr/local/nginx/conf/modsecurity.conf.bak.<日時> /usr/local/nginx/conf/modsecurity.conf
```

注意点・コメント：

`<日時>` は実際のバックアップファイル名のタイムスタンプに置き換えてください．

------------------------------

### 8.3 nginx 設定確認と反映【実施対象：移行先サーバー】

実施内容：ロールバック後の設定に問題がないか確認し，nginx に反映します．

```bash
nginx -t
systemctl reload nginx
systemctl status nginx
```

確認項目：

* [ ] バックアップから設定を戻した
* [ ] `nginx -t` が成功した
* [ ] nginx を再読み込みした
* [ ] アプリケーションへアクセスできることを確認した

------------------------------

## 付録A：コマンドリファレンス

### A.1 nginx 関連コマンド

| コマンド                       | 内容                       |
| -------------------------- | ------------------------ |
| `nginx -v`                 | nginx バージョン表示            |
| `nginx -V`                 | nginx バージョン＋ビルドオプション表示   |
| `nginx -t`                 | nginx 設定ファイルの構文チェック      |
| `systemctl reload nginx`   | nginx の無停止リロード（推奨）       |
| `systemctl restart nginx`  | nginx の再起動（一時的に通信断あり）    |
| `systemctl status nginx`   | nginx サービスの状態確認          |
| `systemctl enable --now nginx` | nginx の起動・自動起動有効化（初回時のみ） |

### A.2 ModSecurity 関連コマンド

| コマンド                                                                            | 内容                       |
| ------------------------------------------------------------------------------- | ------------------------ |
| `grep -Rni "^\s*SecRuleEngine" /usr/local/nginx/conf /etc/nginx 2>/dev/null`    | `SecRuleEngine` の現在値確認   |
| `grep -Rni "SecAuditLog" /usr/local/nginx/conf /etc/nginx 2>/dev/null`          | 監査ログ出力先の設定確認             |
| `find / -name "ngx_http_modsecurity_module.so" 2>/dev/null`                     | ModSecurity モジュールのパス検索   |
| `tail -f /var/log/modsec_audit.log`                                             | ModSecurity 監査ログのリアルタイム監視 |

### A.3 ログ確認コマンド

| コマンド                                  | 内容                       |
| ------------------------------------- | ------------------------ |
| `tail -n 100 /var/log/nginx/error.log` | nginx エラーログの直近100行確認     |
| `tail -n 100 /var/log/nginx/access.log` | nginx アクセスログの直近100行確認    |
| `tail -f /var/log/nginx/error.log`    | nginx エラーログのリアルタイム監視     |
| `tail -f /var/log/modsec_audit.log`   | ModSecurity 監査ログのリアルタイム監視 |

------------------------------

## 付録B：設定ファイル解説

### B.1 `/usr/share/nginx/modules/modsecurity.conf`

ModSecurity モジュールを nginx に読み込ませる `load_module` ディレクティブを記述するファイルです．

```nginx
load_module /usr/lib64/nginx/modules/ngx_http_modsecurity_module.so;
```

| 項目          | 説明                                                          |
| ----------- | ----------------------------------------------------------- |
| `load_module` | nginx に動的モジュールを読み込ませるディレクティブ．`http` ブロックより前で記述する必要がある |
| パス指定         | 実際に `.so` ファイルが配置されているパスと完全一致している必要がある               |

### B.2 `/usr/local/nginx/conf/modsec_includes.conf`

ModSecurity のメイン設定ファイルを `Include` するためのエントリーポイントです．

```text
Include /usr/local/nginx/conf/modsecurity.conf
```

複数のルールセットを段階的に読み込ませたい場合，このファイルに追加 `Include` 行を記述します．

### B.3 `/usr/local/nginx/conf/modsecurity.conf`

ModSecurity 本体の動作設定ファイルです．主要なディレクティブは以下のとおりです．

| ディレクティブ        | 内容                                                          |
| -------------- | ----------------------------------------------------------- |
| `SecRuleEngine` | 検知エンジンの動作モード（`On` / `DetectionOnly` / `Off`） |
| `SecAuditLog`  | 監査ログの出力先ファイルパス                                              |
| `SecAuditEngine` | 監査ログの記録モード（`On` / `RelevantOnly` / `Off`）                   |
| `SecRule`      | 個別の検知ルール定義                                                  |

### B.4 `/etc/nginx/conf.d/proxy.conf`

リバースプロキシ用の `server` ブロックを定義するファイルです．本手順書では，このファイルに ModSecurity 有効化ディレクティブを追記します．

| ディレクティブ                | 内容                                                |
| ---------------------- | ------------------------------------------------- |
| `modsecurity on;`      | この `server` ブロックで ModSecurity を有効化               |
| `modsecurity_rules_file` | ModSecurity の設定ファイル（通常は `modsec_includes.conf`）のパス指定 |

------------------------------

## 付録C：用語集

| 用語              | 説明                                                                                |
| --------------- | --------------------------------------------------------------------------------- |
| WAF             | Web Application Firewall．Webアプリケーションへの攻撃を検知・防御するファイアウォール                       |
| ModSecurity     | オープンソースの WAF．nginx / Apache / IIS で利用可能                                            |
| OWASP CRS       | OWASP Core Rule Set．ModSecurity 用の汎用攻撃検知ルールセット                                    |
| `SecRuleEngine` | ModSecurity の検知エンジン動作モード．`On`（ブロック），`DetectionOnly`（検知のみ），`Off`（無効） |
| `load_module`   | nginx に動的モジュールを読み込ませるディレクティブ．`http` ブロックより前に記述する必要がある                       |
| `dlopen()`      | Linux における動的ライブラリ読み込み用システムコール．`.so` ファイルが存在しない場合などにエラーとなる                 |
| 監査ログ            | ModSecurity による検知・ブロック記録のログ．通常は `/var/log/modsec_audit.log` に出力             |
| 誤検知             | 正常なリクエストを攻撃と誤って判定してしまう状態．False Positive とも呼ぶ                                     |
| 移行元             | 旧環境．本手順書では nginx 1.16.1 が稼働するサーバー                                                |
| 移行先             | 新環境．本手順書では nginx 1.30.0 が稼働するサーバー                                                |

------------------------------

## 付録D：補足情報

### D.1 ModSecurity を `DetectionOnly` で運用するメリット

本番環境への投入直後は，`SecRuleEngine DetectionOnly` で一定期間運用し，監査ログを確認することを推奨します．

| 観点      | 内容                                                          |
| ------- | ----------------------------------------------------------- |
| 誤検知の洗い出し | 本番トラフィックでどのリクエストが検知対象になるかを実害なく確認できる            |
| ルールチューニング | 業務影響のあるルールを特定し，例外設定や除外ルールを追加できる                          |
| 段階的移行    | 安定性を確認しながら `On` への切り替えタイミングを判断できる                          |

### D.2 旧環境の扱い

移行完了後，旧環境はすぐに削除せず一定期間保持します．

| 項目    | 内容          |
| ----- | ----------- |
| 保持期間  | 未定          |
| 削除予定日 | 未定          |
| 削除判断  | 新環境が安定稼働した後 |

注意点・コメント：

移行後すぐに旧環境を削除すると，障害発生時に切り戻しができなくなる可能性があります．

### D.3 関連手順書

| 手順書                       | 関係                                       |
| ------------------------- | ---------------------------------------- |
| `nginx-reverse-proxy.md`  | 前提手順書．新環境の nginx リバースプロキシ構築（ModSecurity 未適用） |

### D.4 作業全体チェックリスト

* [ ] 作業ユーザーの権限を確認した
* [ ] 移行先 nginx バージョンを確認した
* [ ] 既存設定ファイルをバックアップした
* [ ] ModSecurity モジュールの場所を確認した
* [ ] ModSecurity ロード設定を確認・修正した
* [ ] `modsec_includes.conf` を配置した
* [ ] `modsecurity.conf` を配置した
* [ ] `SecRuleEngine` の設定を確認した
* [ ] 必要に応じて `SecRuleEngine On` に変更した
* [ ] `proxy.conf` に `modsecurity on;` を設定した
* [ ] `modsecurity_rules_file` のパスを確認した
* [ ] `server_name _;` の重複を確認した
* [ ] `nginx -t` が成功した
* [ ] nginx 設定を反映した
* [ ] ModSecurity のテストリクエストを実施した
* [ ] アプリケーションの正常動作を確認した
* [ ] nginx ログを確認した
* [ ] ModSecurity 監査ログを確認した
* [ ] 監視設定を確認した
* [ ] ロールバック手順を確認した
