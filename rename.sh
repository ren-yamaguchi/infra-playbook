#!/bin/bash
# infra-playbook: 日本語ファイル/ディレクトリの英語化 + 振り分けスクリプト
#
# 使い方:
#   1. リポジトリルートで dry-run(動作確認): bash rename.sh --dry-run
#   2. 本番実行: bash rename.sh
#   3. 終わったら: git status で確認 → git add -A && git commit

set -e

DRY_RUN=0
if [ "$1" = "--dry-run" ]; then
  DRY_RUN=1
  echo "=== DRY RUN モード(実際には移動しません) ==="
fi

# 実行関数: dry-run なら echo するだけ、本番なら実行
run() {
  if [ $DRY_RUN -eq 1 ]; then
    echo "  $*"
  else
    echo "  $*"
    eval "$@"
  fi
}

# リポジトリルートか確認
if [ ! -d ".git" ]; then
  echo "エラー: リポジトリルートで実行してください(.git が見つかりません)"
  exit 1
fi

echo ""
echo "=== ステップ1: 移動先ディレクトリを作成 ==="

run 'mkdir -p docs/self-study'
run 'mkdir -p projects/nginx-tomcat-pg-nfs-redundancy/procedure'
run 'mkdir -p topics/aws/alb topics/aws/ebs-volume-expansion topics/aws/vpc'
run 'mkdir -p topics/iac/ansible/zabbix'
run 'mkdir -p topics/mail'
run 'mkdir -p topics/monitoring/zabbix'
run 'mkdir -p topics/network/dns-bind topics/network/dns-nsd topics/network/diagrams topics/network/https-letsencrypt'
run 'mkdir -p topics/storage/nfs/diagrams'
run 'mkdir -p topics/web-ap/apache topics/web-ap/nginx topics/web-ap/tomcat topics/web-ap/php-fpm'
run 'mkdir -p topics/web-ap/lamp/diagrams topics/web-ap/lntp'

echo ""
echo "=== ステップ2: projects/ 配下のファイル振り分け ==="

run 'mv "projects/手順書_Nginx_Tomcat_Postgresql_1台基本構築.md" "topics/web-ap/lntp/1-server.md"'
run 'mv "projects/手順書_Nginx_Tomcat_Postgresql_3台基本構築.md" "topics/web-ap/lntp/3-server.md"'
run 'mv "projects/手順書_Nginx_Tomcat_Postgresql_NFS_3台構築.md" "topics/web-ap/lntp/3-server-nfs.md"'
run 'mv "projects/手順書_Nginx_Tomcat_Postgresql_NFS_5台_WEB-AP冗長構築.md" "projects/nginx-tomcat-pg-nfs-redundancy/procedure/procedure.md"'
run 'mv "projects/手順書_Certbot_LetsEncrypt_HTTPS化.md" "topics/network/https-letsencrypt/procedure.md"'
run 'mv "projects/自己学習_基本課題.md" "docs/self-study/basic.md"'
run 'mv "projects/自己学習_発展課題.md" "docs/self-study/advanced.md"'

echo ""
echo "=== ステップ3: topics/web-ap/ 配下のファイル振り分け+英語化 ==="

run 'mv "topics/web-ap/手順書_Apache_基本構築.md" "topics/web-ap/apache/basic-setup.md"'
run 'mv "topics/web-ap/手順書_Apache_ベーシック認証構築.md" "topics/web-ap/apache/basic-auth.md"'
run 'mv "topics/web-ap/手順書_Nginx_基本構築.md" "topics/web-ap/nginx/basic-setup.md"'
run 'mv "topics/web-ap/手順書_Apache_Tomcat_基本構築.md" "topics/web-ap/tomcat/apache-tomcat-basic.md"'
run 'mv "topics/web-ap/手順書_Apache_Tomcat_2台構成構築.md" "topics/web-ap/tomcat/apache-tomcat-2server.md"'
run 'mv "topics/web-ap/手順書_Apache_Tomcat_AJP連携構築.md" "topics/web-ap/tomcat/apache-tomcat-ajp.md"'
run 'mv "topics/web-ap/手順書_Apache_Tomcat_Proxy_2台構成構築.md" "topics/web-ap/tomcat/apache-tomcat-proxy-2server.md"'
run 'mv "topics/web-ap/手順書_Nginx_Tomcat_基本構築.md" "topics/web-ap/tomcat/nginx-tomcat-basic.md"'
run 'mv "topics/web-ap/手順書_Apache_php-fpm_基本構築.md" "topics/web-ap/php-fpm/apache-php-fpm-basic.md"'
run 'mv "topics/web-ap/手順書_Apache_PHP_MariaDB_1台基本構築.md" "topics/web-ap/lamp/1-server.md"'
run 'mv "topics/web-ap/手順書_Apache_PHP_MariaDB_2台基本構築.md" "topics/web-ap/lamp/2-server.md"'
run 'mv "topics/web-ap/手順書_Apache_PHP_MariaDB_3台基本構築.md" "topics/web-ap/lamp/3-server.md"'
run 'mv "topics/web-ap/AWS_WEB三層構造環境構築.png" "topics/web-ap/lamp/diagrams/aws-architecture.png"'
run 'mv "topics/web-ap/WEB三層構造環境構築メモ.md" "topics/web-ap/lamp/notes.md"'

echo ""
echo "=== ステップ4: その他(英語化のみ) ==="

run 'mv "topics/aws/alb/手順書_Apache_ALB_2台基本構築.md" "topics/aws/alb/apache-alb-2server.md"'
run 'mv "topics/aws/ebs-volume-expansion/手順書_EBSボリューム拡張.md" "topics/aws/ebs-volume-expansion/procedure.md"'
run 'mv "topics/aws/vpc/手順書_VPC環境構築.md" "topics/aws/vpc/procedure.md"'
run 'mv "topics/iac/ansible/zabbix/手順書_Ansible_Zabbix_PostgreSQL_構築.md" "topics/iac/ansible/zabbix/ansible-zabbix-pg.md"'
run 'mv "topics/mail/手順書_Postfix_Dovecot_BIND_基本構築.md" "topics/mail/postfix-dovecot-bind-basic.md"'
run 'mv "topics/monitoring/zabbix/手順書_Zabbix_基本構築.md" "topics/monitoring/zabbix/basic-setup.md"'
run 'mv "topics/network/名前解決データフロー.png" "topics/network/diagrams/dns-resolution-flow.png"'
run 'mv "topics/network/手順書_BIND_Nginx_基本構築.md" "topics/network/dns-bind/bind-nginx-basic.md"'
run 'mv "topics/network/手順書_NSD_Nginx_基本構築.md" "topics/network/dns-nsd/nsd-nginx-basic.md"'
run 'mv "topics/storage/nfs/NFSサーバ環境構築.png" "topics/storage/nfs/diagrams/nfs-architecture.png"'
run 'mv "topics/storage/nfs/手順書_Postfix_Dovecot_BIND_NFS_4台基本構築.md" "topics/storage/nfs/postfix-dovecot-bind-nfs-4server.md"'

echo ""
echo "=== 完了 ==="
if [ $DRY_RUN -eq 1 ]; then
  echo "DRY RUN でした。実際の移動は行われていません。"
  echo "問題なければ引数なしで再実行してください: bash rename.sh"
else
  echo "次のステップ:"
  echo "  1. git status で結果確認"
  echo "  2. find . -path ./.git -prune -o -print | grep -P '[\\x{3000}-\\x{9fff}]' で残った日本語パスを確認"
  echo "  3. git add -A && git commit -m 'ファイル名・ディレクトリ名を英語化'"
fi
