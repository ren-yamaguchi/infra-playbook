# CI/CD ツール 基本・発展課題集

> 継続的インテグレーション / 継続的デリバリーのツール群  
> 現場での採用率が高い GitHub Actions・AWS CodeDeploy・Jenkins・AWS CodePipeline を対象とします  
> 前提：AWS 無料利用枠の範囲内で実施可能な課題を基本とする  
> 作成日：2026年6月

---

## 目次

1. [基本課題 A：CI/CD の概念理解](#基本課題-acicd-の概念理解)
2. [基本課題 B：GitHub Actions の基本](#基本課題-bgithub-actions-の基本)
3. [基本課題 C：AWS CodeDeploy の基本](#基本課題-caws-codedeploy-の基本)
4. [発展課題 D：GitHub Actions による EC2 自動デプロイ](#発展課題-dgithub-actions-による-ec2-自動デプロイ)
5. [発展課題 E：AWS CodePipeline による完全自動化](#発展課題-eaws-codepipeline-による完全自動化)
6. [発展課題 F：Jenkins のインストールと基本設定](#発展課題-fjenkins-のインストールと基本設定)
7. [発展課題 G：デプロイ戦略の実装](#発展課題-gデプロイ戦略の実装)
8. [発展課題 H：Ansible / Terraform との統合](#発展課題-hansible--terraform-との統合)
9. [発展課題 I：セキュリティとシークレット管理](#発展課題-iセキュリティとシークレット管理)
10. [発展課題 J：各ツールの比較と使い分け](#発展課題-j各ツールの比較と使い分け)

---

## 基本課題 A：CI/CD の概念理解

**A-1. CI/CD パイプラインの構成要素の整理**
- 以下の用語を定義し、それぞれの役割と実行タイミングをまとめる

| 用語 | 意味 | 実行タイミング |
|------|------|--------------|
| CI（継続的インテグレーション） | コードのビルド・テストの自動化 | プッシュ・プルリクエスト時 |
| CD（継続的デリバリー） | デプロイ可能な状態を常に維持 | CI 成功後（手動承認あり） |
| CD（継続的デプロイ） | 本番環境への自動デプロイ | CI 成功後（自動） |
| パイプライン | 一連の自動化ステップ | イベントトリガー |
| アーティファクト | ビルド成果物 | CI 完了後に保存 |

**A-2. デプロイ戦略の種類と特性**
- 以下のデプロイ戦略を比較し、リスク・ダウンタイム・ロールバック容易さの観点でまとめる

| 戦略 | 概要 | ダウンタイム | ロールバック |
|------|------|------------|------------|
| In-Place | 稼働中のサーバーを直接更新 | あり | 手動 |
| Blue/Green | 新環境を用意して切り替え | なし | 即時（切り戻し） |
| Canary | 一部のトラフィックのみ新バージョンへ | なし | 段階的縮小 |
| Rolling | サーバーを順次更新 | 最小 | 段階的縮小 |

---

## 基本課題 B：GitHub Actions の基本

**B-1. ワークフローファイルの構造理解**
- `.github/workflows/` ディレクトリにワークフローファイルを作成し、以下の構成要素を理解する

```yaml
name: CI Pipeline
on:
  push:
    branches: [main]
  pull_request:
    branches: [main]

jobs:
  build-and-test:
    runs-on: ubuntu-latest

    steps:
      - name: Checkout code
        uses: actions/checkout@v4

      - name: Set up PHP
        uses: shivammathur/setup-php@v2
        with:
          php-version: '8.2'

      - name: Install dependencies
        run: composer install --no-dev

      - name: Run tests
        run: php artisan test
```

**B-2. 基本的なワークフローの作成**
- Python / PHP / Node.js のいずれかでシンプルなテストコードを作成し、GitHub Actions でテストが自動実行されることを確認する
- ブランチへのプッシュと PR 作成でそれぞれワークフローが発火することを確認する

**B-3. Actions のマーケットプレイスの活用**
- `actions/checkout`・`actions/setup-python`・`actions/upload-artifact`・`appleboy/ssh-action` など代表的な公式 / サードパーティ Actions の使い方を確認する

---

## 基本課題 C：AWS CodeDeploy の基本

**C-1. CodeDeploy の構成要素の理解**
- アプリケーション・デプロイグループ・デプロイ設定・改訂（リビジョン）の関係を図で整理する
- EC2 に CodeDeploy エージェントをインストールし、IAM ロール（`AmazonEC2RoleforAWSCodeDeploy`）をアタッチする

**C-2. appspec.yml の作成**
- デプロイの各フェーズ（`BeforeInstall`・`AfterInstall`・`ApplicationStart`・`ValidateService`）でスクリプトを実行する `appspec.yml` を作成する

```yaml
version: 0.0
os: linux

files:
  - source: /
    destination: /var/www/html

hooks:
  BeforeInstall:
    - location: scripts/before_install.sh
      timeout: 60
      runas: root
  AfterInstall:
    - location: scripts/after_install.sh
      timeout: 60
      runas: root
  ApplicationStart:
    - location: scripts/start_server.sh
      timeout: 30
  ValidateService:
    - location: scripts/validate_service.sh
      timeout: 30
```

---

## 発展課題 D：GitHub Actions による EC2 自動デプロイ

**D-1. SSH を使った直接デプロイ**
- GitHub リポジトリへのプッシュをトリガーに、`appleboy/ssh-action` で EC2 に SSH 接続してデプロイするワークフローを構築する

```yaml
- name: Deploy to EC2
  uses: appleboy/ssh-action@v1
  with:
    host: ${{ secrets.EC2_HOST }}
    username: ec2-user
    key: ${{ secrets.EC2_SSH_KEY }}
    script: |
      cd /var/www/html
      git pull origin main
      composer install --no-dev
      sudo systemctl reload httpd
```

**D-2. Secrets の管理**
- GitHub Secrets に `EC2_HOST`・`EC2_SSH_KEY` を登録し、ワークフロー内で環境変数として安全に利用する
- SSH 鍵はデプロイ専用の鍵ペアを生成し、EC2 の `authorized_keys` に公開鍵のみを追加する

**D-3. デプロイの安全性向上**
- デプロイ前にテストが成功した場合のみデプロイが実行される `needs` 依存関係を設定する
- デプロイ後に `/health` エンドポイントへの HTTP チェックで成功した場合のみジョブを正常終了させるステップを追加する

---

## 発展課題 E：AWS CodePipeline による完全自動化

**E-1. CodePipeline の構築**
- 以下の 3 ステージで構成される CodePipeline を構築する
  1. **Source**：GitHub リポジトリへのプッシュを検知（CodeStar Connections を使用）
  2. **Build**：CodeBuild でビルド・テストを実行
  3. **Deploy**：CodeDeploy で EC2 にデプロイ

**E-2. CodeBuild の buildspec.yml 作成**
- テスト実行・アーティファクトのパッケージングを行う `buildspec.yml` を作成する

```yaml
version: 0.2

phases:
  install:
    runtime-versions:
      php: 8.2
    commands:
      - composer install --no-dev

  build:
    commands:
      - echo "Running tests..."
      - php artisan test

  post_build:
    commands:
      - echo "Build completed"

artifacts:
  files:
    - '**/*'
  exclude-paths:
    - tests/**
    - .git/**
```

**E-3. 手動承認ステージの追加**
- `Build` と `Deploy` の間に手動承認ステージを追加し、SNS で担当者にメール通知 → 承認後にデプロイが開始される設定を行う

---

## 発展課題 F：Jenkins のインストールと基本設定

**F-1. EC2 への Jenkins インストール**
- AL2023 の EC2（t2.micro）に Jenkins をインストールし、`systemd` でサービス登録・自動起動を設定する
- Security Group で 8080 番ポートを自分の IP のみに制限し、ブラウザから管理コンソールにアクセスする
- 初期セットアップウィザードを完了し、推奨プラグインをインストールする

**F-2. Jenkins パイプラインの作成**
- Declarative Pipeline（`Jenkinsfile`）で基本的なビルド・テスト・デプロイパイプラインを作成する

```groovy
pipeline {
    agent any

    stages {
        stage('Checkout') {
            steps {
                checkout scm
            }
        }
        stage('Build') {
            steps {
                sh 'composer install --no-dev'
            }
        }
        stage('Test') {
            steps {
                sh 'php artisan test'
            }
        }
        stage('Deploy') {
            when {
                branch 'main'
            }
            steps {
                sh 'rsync -avz --delete ./ ec2-user@10.0.1.10:/var/www/html/'
            }
        }
    }

    post {
        success {
            echo 'デプロイ成功'
        }
        failure {
            echo 'パイプライン失敗'
        }
    }
}
```

**F-3. GitHub との連携**
- GitHub プラグインをインストールし、リポジトリへのプッシュで Jenkins ジョブが自動起動する Webhook を設定する

---

## 発展課題 G：デプロイ戦略の実装

**G-1. Blue/Green デプロイの実装**
- CodeDeploy の Blue/Green デプロイで新バージョンを別の EC2 にデプロイし、ALB のターゲットグループを切り替える設定を実装する
- デプロイ後の `ValidateService` フックでヘルスチェックが失敗した場合に自動ロールバックされる設定を行う

**G-2. Rolling デプロイの実装**
- ALB 配下の複数 EC2 に対して Rolling デプロイを実装し、一部の EC2 が更新中でも他の EC2 がトラフィックを処理し続けることを確認する
- `MinimumHealthyHosts` を設定し、常に 50% 以上の EC2 が稼働状態を維持するデプロイ設定を行う

**G-3. Canary デプロイのシミュレーション**
- ALB のリスナールールで重み付けルーティングを使い、新バージョンへのトラフィックを 10% → 50% → 100% と段階的に増やす手順を確立する

---

## 発展課題 H：Ansible / Terraform との統合

**H-1. GitHub Actions + Ansible のパイプライン**
- GitHub Actions のワークフローから Ansible Playbook を実行し、コードプッシュでサーバー設定の変更が自動適用されるパイプラインを構築する

```yaml
- name: Run Ansible Playbook
  run: |
    ansible-playbook -i inventory/production \
      --private-key ~/.ssh/deploy_key \
      deploy.yml
```

**H-2. GitHub Actions + Terraform のパイプライン**
- `main` ブランチへのプッシュで `terraform plan` の結果を PR にコメントし、マージ後に `terraform apply` が実行されるワークフローを構築する

```yaml
- name: Terraform Plan
  run: terraform plan -out=tfplan

- name: Terraform Apply
  if: github.ref == 'refs/heads/main'
  run: terraform apply tfplan
```

---

## 発展課題 I：セキュリティとシークレット管理

**I-1. OIDC による AWS 認証（アクセスキー不要）**
- GitHub Actions の OIDC（OpenID Connect）を使い、AWS アクセスキーをシークレットに保存せずに IAM ロールを引き受けて AWS リソースにアクセスする設定を行う

```yaml
- name: Configure AWS credentials
  uses: aws-actions/configure-aws-credentials@v4
  with:
    role-to-assume: arn:aws:iam::123456789:role/GitHubActionsRole
    aws-region: ap-northeast-1
```

**I-2. Secrets Manager からのシークレット取得**
- デプロイスクリプト内で AWS Secrets Manager から DB パスワードを取得し、環境変数として渡す設定を実装する
- GitHub Secrets・AWS Secrets Manager・AWS SSM Parameter Store の使い分け基準をまとめる

**I-3. デプロイの監査ログ**
- CloudTrail でデプロイ操作（`codedeploy:CreateDeployment` 等）を監査ログとして記録する設定を有効化する
- GitHub Actions のワークフロー実行履歴と CodeDeploy のデプロイ履歴を照合し、誰がいつどのバージョンをデプロイしたかを追跡できる仕組みを構築する

---

## 発展課題 J：各ツールの比較と使い分け

**J-1. 比較表の作成**

| 観点 | GitHub Actions | AWS CodePipeline + CodeDeploy | Jenkins |
|------|--------------|-------------------------------|---------|
| ホスティング | クラウド（GitHub） | クラウド（AWS） | 自己ホスト |
| 料金 | 無料枠あり（2000 分/月） | 有料（パイプライン $1/月〜） | 無料（EC2 料金のみ） |
| AWS 統合 | OIDC で対応 | ネイティブ | プラグインで対応 |
| 設定ファイル | YAML（.github/workflows/） | コンソール / CloudFormation | Groovy（Jenkinsfile） |
| プラグインエコシステム | Actions マーケットプレイス | 限定的 | 1800 以上のプラグイン |
| スケーラビリティ | 高（GitHub 管理） | 高（AWS 管理） | 自己管理 |
| 学習コスト | 低〜中 | 中 | 高 |
| 現場採用率 | 急増中（新規プロジェクト） | AWS 依存プロジェクト | レガシー〜中規模 |

**J-2. 現場別の推奨選択**
- スタートアップ・新規プロジェクト（GitHub 中心）→ GitHub Actions
- AWS を中心に使う企業・フルマネージドを望む場合 → CodePipeline + CodeDeploy
- オンプレミス・自社データセンター・細かなカスタマイズが必要な場合 → Jenkins
- 複数クラウド・ハイブリッド環境で統一したい場合 → Jenkins または GitLab CI/CD

---

*以上（CI/CD ツール 基本・発展課題）*
