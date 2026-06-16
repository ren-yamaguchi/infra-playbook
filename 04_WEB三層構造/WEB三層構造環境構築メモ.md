#### apacheとphpの連携方式は2種類
1. モジュール方式
    apacheのモジュールとして組み込む方法
2. PHP-FPM方式 (FastCGI)
    PHPを独立したプロセスとして実行し、Apacheと通信（プロキシ）させる方法

#### phpが「systemtl start php」できないわけ
apacheはwebサーバソフトウェア
phpはスクリプト言語であるため、apacheからのリクエストを受けて動く仕組み

#### sudoの位置に注意
```bash
$ sudo echo "<?php phpinfo(); ?>" > /var/www/html/phpinfo.php
-bash: /var/www/html/phpinfo.php: Permission denied
```

上記を実行すると以下のようなエラー文が表示されます

**理由：** 上記のコマンドの実行順番はリダイレクト（`>`）が先に実行されます。つまり、
1. /var/www/html/phpinfo.php ファイルが開く
2. phpinfo.phpファイルの中に`<?php phpinfo(); ?>` が書き込まれる  

この順番で実行されます。ここで重要なのが`sudo` の存在です。上記の場合、`sudo` は`echo ...` にしか反映されず、phpinfo.phpファイルを開くことには反映されません。よって、上記のようなエラー文（権限がありません）と表示されてしまいます。

したがって、このような場合には違う書き方で実行を行いましょう。

#### WordPressのAllowOverride設定まとめ（初心者向け）

- WordPressの「パーマリンク」は、見やすいURLを作る機能  
- 例：`?p=123` → `/post/sample-article` のように変わる  
- ただし、このURLは実際のファイルではない  

- 実際には、ApacheがURLを書き換えている（mod_rewrite）  
- 書き換えルールは `.htaccess` に記述される  

- `.htaccess` はディレクトリごとの設定ファイル  
- WordPressはこのファイルを使って動作する  

- しかし初期設定では `.htaccess` は無効（AllowOverride None）  
- → 書き換えルールが無視される  

- その結果、パーマリンクが動かず404エラーになる  

- `AllowOverride All` に変更すると `.htaccess` が有効になる  
- → URL書き換えが動作する  

- 最終的に、すべてのリクエストは `index.php` に渡される  
- → WordPressが中身を判断してページを表示する  