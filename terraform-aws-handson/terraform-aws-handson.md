# Terraform で学ぶ AWS 環境構築ハンズオン手順書

VPC + EC2(複数台対応)の最小構成を出発点に、必要に応じて **ALB / NAT Gateway** も追加できるよう module 化した、Terraform 学習用の手順書です。
ローカル PC(Ubuntu)から AWS(東京リージョン)に対して構築します。

---

## 目次

1. [はじめに / 前提条件](#1-はじめに--前提条件)
2. [ローカル環境準備(Ubuntu)](#2-ローカル環境準備ubuntu)
3. [AWS 認証設定](#3-aws-認証設定)
4. [ディレクトリ構成(推奨)](#4-ディレクトリ構成推奨)
5. [Terraform コード解説](#5-terraform-コード解説)
6. [EC2 台数のパラメータ化(count vs for_each)](#6-ec2-台数のパラメータ化count-vs-for_each)
7. [タグ付け・命名規則](#7-タグ付け命名規則)
8. [実行手順(init → plan → apply)](#8-実行手順init--plan--apply)
9. [動作確認(SSH 接続 / ALB アクセス)](#9-動作確認ssh-接続--alb-アクセス)
10. [コスト削減のための停止 / 削除手順](#10-コスト削減のための停止--削除手順)
11. [トラブルシューティング](#11-トラブルシューティング)
12. [次のステップ](#12-次のステップ)
13. [付録 A: HTTPS(443)対応](#13-付録-a-https443対応)

---

## 1. はじめに / 前提条件

### 1.1 本手順書のゴール

- Terraform を使って AWS 上に VPC と EC2 を構築できるようになる
- 台数 / サブネット種別(public/private)/ ALB / NAT を**変数や module 呼び出し有無で柔軟に切替**できる汎用コードを書けるようになる
- Terraform の基本ワークフロー(init → plan → apply → destroy)を理解する

### 1.2 前提条件

| 項目 | 内容 |
| --- | --- |
| クラウド | AWS |
| リージョン | ap-northeast-1(東京) |
| OS(ローカル PC) | **Ubuntu 24.04 LTS**(22.04 / 20.04 でも基本同じ) |
| OS(EC2) | Amazon Linux 2023 |
| Terraform 実行環境 | ローカル PC |
| tfstate 管理 | ローカル(`terraform.tfstate` を手元保存) |
| 必須 | AWS アカウントを保有していること |
| 必須 | EC2 キーペアを作成済みであること(東京リージョンに) |

> ⚠️ **キーペアについて**: AWS マネジメントコンソールで事前に作成し、秘密鍵(`.pem`)をローカル PC に保存しておいてください。

### 1.3 想定する構成(全部入りの場合)

```
                        ┌─────────────────────────────────────────────┐
                        │ VPC (10.0.0.0/16)                           │
                        │                                             │
                        │  ┌── Public Subnet(AZ-a, AZ-b)──────────┐ │
   Internet ── IGW ─────┤  │   ├─ ALB                              │ │
                        │  │   └─ NAT Gateway                      │ │
                        │  └──────────────────────────────────────┘ │
                        │                                             │
                        │  ┌── Private Subnet(AZ-a, AZ-b)─────────┐ │
                        │  │   ├─ EC2 #1                           │ │
                        │  │   └─ EC2 #2                           │ │
                        │  └──────────────────────────────────────┘ │
                        └─────────────────────────────────────────────┘
```

### 1.4 構成バリエーション(本手順書で切替可能)

`envs/dev` で module の呼び出し有無と変数を変えるだけで、以下のパターンを作れます。

| パターン | network | compute (public) | compute (private) | nat | alb |
| --- | --- | --- | --- | --- | --- |
| ①最小構成 | ○ | ○ |  |  |  |
| ②ALB付き | ○ | ○ |  |  | ○ |
| ③本番似(推奨) | ○ |  | ○ | ○ | ○ |

> 💡 ③が最も実務に近い構成。学習が進んだら③に挑戦してみてください。

### 1.5 リージョン変更について

本手順書のコードは **リージョン変更に対応**しています。`terraform.tfvars` の `region` を変えるだけで、別のリージョンにそのまま構築できます。

```hcl
# Example: change to Oregon
region = "us-west-2"

# Example: change to N. Virginia
region = "us-east-1"

# Example: change to Osaka
region = "ap-northeast-3"
```

#### 仕組み

| 要素 | リージョン依存 | 本手順書での対応 |
| --- | --- | --- |
| AZ 名(`ap-northeast-1a` 等) | あり | `data "aws_availability_zones"` で**自動取得**(後述) |
| AMI ID | あり | `data "aws_ami"` で**最新の AL2023 を動的取得** |
| キーペア | あり(リージョン単位で別物) | ⚠️ 利用するリージョンで**事前作成**が必要 |
| AWS CLI のデフォルトリージョン | — | Terraform の `region` と揃えると混乱が少ない |

#### リージョン変更時のチェックリスト

- [ ] 利用したいリージョンで**キーペアを作成済み**
- [ ] そのキーペア名を `terraform.tfvars` の `key_pair_name` に指定
- [ ] `terraform.tfvars` の `region` を変更
- [ ] 必要なら `aws configure` のデフォルトリージョンも変更
- [ ] `terraform plan` で AZ や AMI が想定通りに解決されるか確認

#### 利用可能な AZ を確認するコマンド

```bash
aws ec2 describe-availability-zones --region ap-northeast-1 \
  --query "AvailabilityZones[].ZoneName" --output text
```

> ⚠️ リージョンによって AZ 数が異なります(東京は a/c/d、大阪は a/b/c など)。本手順書は **先頭 2 つの AZ を自動利用**する作りです。

---

## 2. ローカル環境準備(Ubuntu)

### 2.1 必要なツール

- Terraform(v1.6 以上推奨)
- AWS CLI(v2)
- Git(任意 / コード管理用)

### 2.2 Terraform のインストール(Ubuntu)

公式の HashiCorp APT リポジトリを追加してインストールします。

```bash
# 必要パッケージ
sudo apt-get update
sudo apt-get install -y gnupg software-properties-common curl lsb-release

# HashiCorp の GPG キー
wget -O- https://apt.releases.hashicorp.com/gpg | \
  sudo gpg --dearmor -o /usr/share/keyrings/hashicorp-archive-keyring.gpg

# リポジトリ追加
echo "deb [signed-by=/usr/share/keyrings/hashicorp-archive-keyring.gpg] \
  https://apt.releases.hashicorp.com $(lsb_release -cs) main" | \
  sudo tee /etc/apt/sources.list.d/hashicorp.list

# インストール
sudo apt-get update
sudo apt-get install -y terraform

# 確認
terraform -version
```

### 2.3 AWS CLI のインストール(Ubuntu)

```bash
sudo apt-get install -y unzip
curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "awscliv2.zip"
unzip awscliv2.zip
sudo ./aws/install

# 確認
aws --version
```

### 2.4 補足: VS Code を使う場合

Ubuntu に VS Code を入れている場合は、以下の拡張機能が便利です。

- HashiCorp Terraform(構文ハイライト・補完)
- AWS Toolkit(任意)

---

## 3. AWS 認証設定

### 3.1【推奨・初学者向け】IAM ユーザー + アクセスキー

学習用の IAM ユーザーを作成し、コンソールログイン用パスワード、必要なポリシー、MFA、アクセスキーまで一通り設定します。**最初の準備が一番丁寧に説明が必要**なので、ステップごとに区切って書きます。

#### 3.1.0 事前準備: 請求アラートの設定(最重要)

実作業の前に、必ず**請求アラート**を設定してください。AWS は従量課金制で、設定ミスや消し忘れで予期せぬ高額請求が発生します。

**手順の概要**:

1. **ルートユーザー**で AWS マネジメントコンソールにログイン
2. 右上のアカウント名 → **「請求とコスト管理」** → **「請求設定」**
3. 「無料利用枠の使用アラートを受信する」「CloudWatch 請求アラートを受信する」にチェック → 保存
4. リージョンを **「米国東部(バージニア北部) us-east-1」** に切り替え(請求メトリクスは us-east-1 にのみ集約されているため)
5. **CloudWatch** → 「アラーム」 → 「アラームの作成」
6. メトリクス選択: 「請求」 → 「概算合計請求額」 → 「USD」
7. 条件: しきい値「10」(USD)を超えたら通知
8. 通知先: 新しい SNS トピックを作成し、自分のメールアドレスを登録
9. 届いた確認メールの **「Confirm subscription」** リンクをクリック → ステータスが「確認済み」になればOK

> ⚠️ **メールアドレスのタイプミスに注意**: 確認メールが届かない場合は、まず迷惑メールフォルダ、それでも無ければ SNS のサブスクリプション画面でエンドポイント(メールアドレス)を確認してください。間違っていたら、サブスクリプションを作り直します(SNSトピック自体は流用可能)。

#### 3.1.1 IAM ユーザーを作成

1. AWS マネジメントコンソールの上部検索バーで **「IAM」** と入力 → クリック
2. 左メニュー **「ユーザー」** → 右上の **「ユーザーの作成」** ボタンをクリック
3. ステップ 1: ユーザー詳細

| 項目 | 設定値 |
| --- | --- |
| ユーザー名 | `terraform-learner`(任意) |
| AWS マネジメントコンソールへのユーザーアクセスを提供 | **☑ チェック** |
| ユーザータイプ | 「IAM ユーザーを作成します」 |
| コンソールパスワード | 「カスタムパスワード」を選択し、12文字以上の強いパスワードを設定 |
| ユーザーは次回のサインイン時に新しいパスワードを作成する必要があります | **☐ チェックを外す**(自分用なので) |

4. **「次へ」** をクリック

> 💡 **パスワード変更フラグについて**: チェックを入れたままにすると、初回ログイン時にパスワード再設定画面に飛ばされます。古いパスワードと新しいパスワードの両方を入力して変更できます。

#### 3.1.2 ポリシーをアタッチ

ステップ 2「許可を設定」画面で:

1. **「ポリシーを直接アタッチする」** を選択
2. 検索ボックスに以下を順番に入力し、それぞれチェックを入れる
   - `AmazonEC2FullAccess`
   - `AmazonVPCFullAccess`
   - `ElasticLoadBalancingFullAccess` ← **ALB を使うので追加**
3. **「次へ」** → 確認画面で内容を確認 → **「ユーザーの作成」**

> ⚠️ 本番では最小権限の原則に従って絞ること。学習用なら上記の FullAccess 3つで十分。
> 💡 `AmazonEC2FullAccess` には VPC 操作の権限も多く含まれていますが、明示的に `AmazonVPCFullAccess` も付けておくと安全です。

#### 3.1.3 サインインリンクの確認

作成完了後、ユーザー一覧から `terraform-learner` をクリック → **「セキュリティ認証情報」** タブ → 「コンソールサインインリンク」を確認してメモします。

```
例: https://123456789012.signin.aws.amazon.com/console
```

このURLは、IAM ユーザーがログインするときに使います。**アカウント ID(12桁)**を含むので覚えにくければエイリアスを設定するのも一手(IAM ダッシュボードの「AWS アカウント」セクションから設定可能)。

#### 3.1.4 MFA(多要素認証)の設定

##### なぜルートユーザーから設定するのか

`terraform-learner` には IAM 操作の権限が付いていないため(EC2/VPC/ELB FullAccessのみ)、**自分自身の MFA を設定しようとすると `iam:ListUsers` のアクセス拒否エラー**になります。そのため、**ルートユーザー**でログインして対象 IAM ユーザーに MFA を割り当てます。

##### 手順

1. 現在の IAM ユーザーセッションからログアウト → **ルートユーザー**で再ログイン
2. **IAM** → **「ユーザー」** → `terraform-learner` をクリック
3. **「セキュリティ認証情報」** タブ → **「多要素認証 (MFA)」** セクション → **「MFA デバイスの割り当て」**
4. デバイス名: 任意(例: `my-phone`)
5. MFA デバイスのタイプ: **「認証アプリケーション」** を選択
6. スマホで **Google Authenticator**(または同等の認証アプリ)を起動 → 「+」ボタン → 「QRコードをスキャン」
7. PC 画面の QR コードをスキャン
8. 入力欄が 2 つあるので、**連続する 2 つの 6桁コード**を入力(1つ目を入力後、30秒待って新しいコードを2つ目に入力)
9. **「MFA を追加」**

> ⚠️ 連続する 2 つのコードが必要なので、1つ入力したら**30秒ほど待つ**ことを忘れずに。

#### 3.1.5 アクセスキーの作成

Terraform/AWS CLI から AWS にアクセスするためのキーペアです。引き続きルートユーザーでもよいですが、IAM ユーザーに切り替えても作成できます(自分自身のアクセスキーは作成可能)。

1. **IAM** → **「ユーザー」** → `terraform-learner` をクリック
2. **「セキュリティ認証情報」** タブ → **「アクセスキー」** セクション → **「アクセスキーを作成」**
3. ユースケース: **「コマンドラインインターフェイス (CLI)」** を選択
4. 「上記のレコメンデーションを理解し、アクセスキーを作成します」にチェック → **「次へ」**
5. 説明タグ(任意、例: `Terraform learning - local PC`)
6. **「アクセスキーを作成」**
7. ⚠️ **作成完了画面で必ず `.csv ファイルをダウンロード`** をクリック
   - **シークレットアクセスキーはこの画面でしか確認できません**
   - 一度閉じると二度と取得できないので、必ず保存
8. **「完了」** をクリック

> ⚠️ **絶対NG**: アクセスキーを GitHub などの公開リポジトリにコミットすること。自動スキャンで検出されるとアカウント停止の恐れがあります。
> ✅ **推奨保管先**: パスワードマネージャー(1Password、Bitwarden 等)、ローカル PC の暗号化フォルダ。

##### アクセスキーが正しく作成されたか確認

「セキュリティ認証情報」タブの「アクセスキー」セクションに、`AKIA...` で始まる 20 文字のアクセスキー ID が表示されていれば作成済みです。

#### 3.1.6 EC2 キーペアの作成

EC2 インスタンスに SSH 接続するための鍵を、東京リージョンで作成します。

> ⚠️ **アクセスキー(IAM)** と **キーペア(EC2)** は別物です。前者は CLI 用、後者は SSH 用。

1. リージョンが **「アジアパシフィック(東京)」** になっていることを確認
2. 上部検索バーで **「EC2」** → クリック
3. 左メニュー下部 **「ネットワーク & セキュリティ」** → **「キーペア」**
4. 右上 **「キーペアを作成」**

| 項目 | 設定値 |
| --- | --- |
| 名前 | `handson-key`(任意。Terraform で参照する名前) |
| キーペアのタイプ | RSA |
| プライベートキーファイル形式 | **.pem**(Linux/Mac 用) |

5. **「キーペアを作成」** → `handson-key.pem` が自動でダウンロードされる
   - **この .pem は再ダウンロード不可**。失くしたらキーペア作り直し。
6. ローカル PC で安全な場所に配置し、パーミッションを設定

```bash
mkdir -p ~/.ssh
mv ~/Downloads/handson-key.pem ~/.ssh/
chmod 400 ~/.ssh/handson-key.pem
ls -l ~/.ssh/handson-key.pem
# -r-------- 1 user user ... handson-key.pem  となっていればOK
```

> ⚠️ `chmod 400` は SSH 接続時に必須。パーミッションが緩いと SSH 接続できません。

#### 3.1.7 AWS CLI の認証情報を設定

ローカル PC で `aws configure` を実行し、`.csv` から値をコピペします。

```bash
aws configure
# AWS Access Key ID [None]:     <.csv の Access key ID をペースト>
# AWS Secret Access Key [None]: <.csv の Secret access key をペースト>
# Default region name [None]:   ap-northeast-1
# Default output format [None]: json
```

> 💡 Secret access key はペースト時に**画面に表示されません**(セキュリティ仕様)。表示されないのが正常です。

#### 3.1.8 動作確認

認証情報が正しく設定されたか確認します。

```bash
aws sts get-caller-identity
```

期待される出力:

```json
{
    "UserId": "AIDA....",
    "Account": "123456789012",
    "Arn": "arn:aws:iam::123456789012:user/terraform-learner"
}
```

`Arn` の末尾が `user/terraform-learner` になっていれば成功です。

東京リージョンのキーペアも確認できます。

```bash
aws ec2 describe-key-pairs --region ap-northeast-1
```

`handson-key` が表示されれば、認証もポリシーも正しく動作している証拠です。

#### 3.1.9 セキュリティのまとめ

学習用とはいえ、以下は守ってください。

- ☑ ルートユーザーでの作業は最小限に
- ☑ IAM ユーザーには MFA を設定
- ☑ アクセスキーは安全な場所に保管、Git にコミットしない
- ☑ 請求アラートを設定済み
- ☑ 学習が終わったらアクセスキーを削除(または無効化)

### 3.2【発展】IAM Identity Center(SSO)

```bash
aws configure sso
# SSO start URL:        https://your-org.awsapps.com/start
# SSO region:           us-east-1
# (ブラウザでログイン承認)
# Default region:       ap-northeast-1
# CLI profile name:     terraform-learner
```

```bash
export AWS_PROFILE=terraform-learner
aws sts get-caller-identity
```

---

## 4. ディレクトリ構成(推奨)

学習目的かつ「ALB / NAT を必要なときだけ呼び出したい」という方針から、以下の構成にします。

```
terraform-aws-handson/
├── envs/
│   └── dev/
│       ├── main.tf          # module 呼び出し(ON/OFF はここで制御)
│       ├── variables.tf
│       ├── outputs.tf
│       ├── terraform.tfvars # 値の定義(Git にコミットしない)
│       ├── providers.tf
│       └── versions.tf
├── modules/
│   ├── network/             # VPC, Subnet, IGW, Route Table
│   ├── compute/             # EC2, Security Group
│   ├── alb/                 # ALB, Target Group, Listener  ← 別module
│   └── nat/                 # NAT Gateway, EIP, Route        ← 別module
├── .gitignore
└── README.md
```

### .gitignore(必須)

```gitignore
# Terraform
*.tfstate
*.tfstate.*
.terraform/
.terraform.lock.hcl
crash.log

# 機密情報
*.tfvars
!example.tfvars

# OS
.DS_Store
```

ディレクトリは以下のコマンドで一気に作れます。

```bash
mkdir -p terraform-aws-handson/{envs/dev,modules/{network,compute,alb,nat}}
cd terraform-aws-handson
```

---

## 5. Terraform コード解説

> ⚠️ **コードを `vi` などのエディタに貼るときの注意**
> - ブラウザでレンダリングされた手順書から直接コピーすると、**HTML エンティティ(`&quot;` など)や余分な装飾文字が混入**して `Error: Invalid argument name` や `Quoted strings may not be split over multiple lines` が発生することがあります
> - 対策:
>   1. **手順書の Markdown(.md)ファイル自体を開いて**コードブロックの中身をコピー(プレーンテキストの状態でコピーできる)
>   2. または、コードブロック右上の **コピーボタン**(対応する Markdown ビューア)を使う
>   3. 貼った後は `head -5 ファイル名` でプレーンテキストになっているか確認
> - **全角文字(コメント・括弧・スペース)**はコードブロック内に書かないこと。`This character is not used within the language` のエラーになります。本手順書のコードはすべて半角・英語にしてあります

### 5.1 `envs/dev/versions.tf`

```hcl
terraform {
  required_version = ">= 1.6.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}
```

### 5.2 `envs/dev/providers.tf`

```hcl
provider "aws" {
  region = var.region

  default_tags {
    tags = {
      Project     = var.project_name
      Environment = var.environment
      ManagedBy   = "Terraform"
    }
  }
}
```

### 5.3 `envs/dev/variables.tf`

```hcl
# ===== Common =====
variable "region" {
  type    = string
  default = "ap-northeast-1"
}

variable "project_name" {
  type    = string
  default = "handson"
}

variable "environment" {
  type    = string
  default = "dev"
}

# ===== Network =====
variable "vpc_cidr" {
  type    = string
  default = "10.0.0.0/16"
}

variable "public_subnet_cidrs" {
  type    = list(string)
  default = ["10.0.1.0/24", "10.0.2.0/24"]
}

variable "private_subnet_cidrs" {
  type    = list(string)
  default = ["10.0.11.0/24", "10.0.12.0/24"]
}

# AZs are auto-detected in network module by default.
# Override here only if needed.
variable "availability_zones" {
  description = "Explicit AZ list. Empty means auto-detect first 2 AZs in the region."
  type        = list(string)
  default     = []
}

# ===== EC2 =====
variable "instance_type" {
  type    = string
  default = "t3.micro"
}

variable "instance_count" {
  type    = number
  default = 2
}

variable "key_pair_name" {
  type = string
}

variable "allowed_ssh_cidr" {
  description = "CIDR allowed to SSH (used when EC2 is in public subnet). Empty means no SSH ingress."
  type        = string
  default     = ""
}

variable "ec2_subnet_type" {
  description = "Where to place EC2: public or private"
  type        = string
  default     = "public"

  validation {
    condition     = contains(["public", "private"], var.ec2_subnet_type)
    error_message = "ec2_subnet_type must be 'public' or 'private'."
  }
}

# ===== Feature toggles =====
variable "enable_nat" {
  description = "Create NAT Gateway. Required when ec2_subnet_type=private."
  type        = bool
  default     = false
}

variable "enable_alb" {
  description = "Create ALB"
  type        = bool
  default     = false
}

variable "alb_allowed_cidr" {
  description = "CIDR allowed to access ALB on HTTP(80)"
  type        = string
  default     = "0.0.0.0/0"
}
```

### 5.4 `envs/dev/terraform.tfvars`(自分用の値)

⚠️ Git にコミットしない。

```hcl
project_name     = "handson"
environment      = "dev"

key_pair_name    = "my-keypair-name"   # your key pair name
allowed_ssh_cidr = "203.0.113.10/32"   # your global IP/32
instance_count   = 2

# Pattern 1: minimal
ec2_subnet_type = "public"
enable_nat      = false
enable_alb      = false

# Pattern 2: with ALB (EC2 still public)
# ec2_subnet_type = "public"
# enable_nat      = false
# enable_alb      = true

# Pattern 3: production-like (EC2 in private, NAT + ALB)
# ec2_subnet_type = "private"
# enable_nat      = true
# enable_alb      = true
```

> 💡 自分のグローバル IP は以下で確認できます。
> ```bash
> curl https://checkip.amazonaws.com
> ```

### 5.5 `envs/dev/main.tf`

ここがハイライト。**`count = var.enable_xxx ? 1 : 0` パターン**で module の有無を制御します。

```hcl
locals {
  name_prefix = "${var.project_name}-${var.environment}"

  # Subnet IDs where EC2 instances will be placed
  ec2_subnet_ids = var.ec2_subnet_type == "public" ? module.network.public_subnet_ids : module.network.private_subnet_ids
}

# ===== network (always) =====
module "network" {
  source = "../../modules/network"

  name_prefix          = local.name_prefix
  vpc_cidr             = var.vpc_cidr
  public_subnet_cidrs  = var.public_subnet_cidrs
  private_subnet_cidrs = var.private_subnet_cidrs
  availability_zones   = var.availability_zones  # empty => auto-detect in module
}

# ===== NAT (optional) =====
module "nat" {
  source = "../../modules/nat"
  count  = var.enable_nat ? 1 : 0

  name_prefix            = local.name_prefix
  public_subnet_id       = module.network.public_subnet_ids[0]
  private_route_table_id = module.network.private_route_table_id
}

# ===== EC2 =====
module "compute" {
  source = "../../modules/compute"

  name_prefix         = local.name_prefix
  vpc_id              = module.network.vpc_id
  subnet_ids          = local.ec2_subnet_ids
  associate_public_ip = var.ec2_subnet_type == "public"
  instance_type       = var.instance_type
  instance_count      = var.instance_count
  key_pair_name       = var.key_pair_name
  allowed_ssh_cidr    = var.allowed_ssh_cidr
}

# ===== ALB (optional) =====
module "alb" {
  source = "../../modules/alb"
  count  = var.enable_alb ? 1 : 0

  name_prefix         = local.name_prefix
  vpc_id              = module.network.vpc_id
  public_subnet_ids   = module.network.public_subnet_ids
  target_instance_ids = module.compute.instance_ids
  allowed_cidr        = var.alb_allowed_cidr
}
```

> 💡 `count = var.enable_xxx ? 1 : 0` は Terraform で **module を ON/OFF する定番パターン**。参照側は `module.alb[0].xxx` のように添字が必要です(下記 outputs を参照)。

### 5.6 `envs/dev/outputs.tf`

```hcl
output "vpc_id" {
  value = module.network.vpc_id
}

output "ec2_subnet_type" {
  value = var.ec2_subnet_type
}

output "ec2_public_ips" {
  description = "Public IPs (valid when EC2 is in public subnet)"
  value       = module.compute.public_ips
}

output "ec2_private_ips" {
  value = module.compute.private_ips
}

output "alb_dns_name" {
  value = var.enable_alb ? module.alb[0].dns_name : null
}

output "ssh_commands" {
  description = "SSH command examples (shown only when EC2 is public)"
  value       = var.ec2_subnet_type == "public" ? module.compute.ssh_commands : []
}
```

---

### 5.7 `modules/network`

#### variables.tf

```hcl
variable "name_prefix" { type = string }
variable "vpc_cidr" { type = string }
variable "public_subnet_cidrs" { type = list(string) }
variable "private_subnet_cidrs" { type = list(string) }

variable "availability_zones" {
  description = "Explicit AZ list. Empty means auto-detect first 2 AZs in the region."
  type        = list(string)
  default     = []
}
```

#### main.tf

```hcl
# Auto-detect available AZs in the region
data "aws_availability_zones" "available" {
  state = "available"
}

locals {
  # Use explicit AZs if given, otherwise first 2 auto-detected AZs
  azs = length(var.availability_zones) > 0 ? var.availability_zones : slice(data.aws_availability_zones.available.names, 0, 2)
}

# VPC
resource "aws_vpc" "this" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = { Name = "${var.name_prefix}-vpc" }
}

# IGW
resource "aws_internet_gateway" "this" {
  vpc_id = aws_vpc.this.id
  tags   = { Name = "${var.name_prefix}-igw" }
}

# Public Subnets
resource "aws_subnet" "public" {
  count = length(var.public_subnet_cidrs)

  vpc_id                  = aws_vpc.this.id
  cidr_block              = var.public_subnet_cidrs[count.index]
  availability_zone       = local.azs[count.index]
  map_public_ip_on_launch = true

  tags = { Name = "${var.name_prefix}-public-${local.azs[count.index]}" }
}

# Private Subnets
resource "aws_subnet" "private" {
  count = length(var.private_subnet_cidrs)

  vpc_id            = aws_vpc.this.id
  cidr_block        = var.private_subnet_cidrs[count.index]
  availability_zone = local.azs[count.index]

  tags = { Name = "${var.name_prefix}-private-${local.azs[count.index]}" }
}

# Public Route Table
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.this.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.this.id
  }

  tags = { Name = "${var.name_prefix}-public-rt" }
}

resource "aws_route_table_association" "public" {
  count          = length(aws_subnet.public)
  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

# Private Route Table (NAT route is added by nat module)
resource "aws_route_table" "private" {
  vpc_id = aws_vpc.this.id
  tags   = { Name = "${var.name_prefix}-private-rt" }
}

resource "aws_route_table_association" "private" {
  count          = length(aws_subnet.private)
  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private.id
}
```

> 💡 **設計のポイント**
> - `data "aws_availability_zones"` でリージョン内の AZ を自動取得し、`region` 変数を変えるだけで別リージョンに対応可能
> - private 用 route table は network module が作り、**NAT への route は nat module が追加**する分離設計
> - サブネット数(=AZ数)は `public_subnet_cidrs` のリスト長で決まる。3 AZ にしたい場合は CIDR を 3 つに増やすだけ

#### outputs.tf

```hcl
output "vpc_id" { value = aws_vpc.this.id }
output "public_subnet_ids" { value = aws_subnet.public[*].id }
output "private_subnet_ids" { value = aws_subnet.private[*].id }
output "private_route_table_id" { value = aws_route_table.private.id }
```

---

### 5.8 `modules/nat`

#### variables.tf

```hcl
variable "name_prefix" { type = string }
variable "public_subnet_id" { type = string }
variable "private_route_table_id" { type = string }
```

#### main.tf

```hcl
# EIP for NAT
resource "aws_eip" "nat" {
  domain = "vpc"
  tags   = { Name = "${var.name_prefix}-nat-eip" }
}

# NAT Gateway
resource "aws_nat_gateway" "this" {
  allocation_id = aws_eip.nat.id
  subnet_id     = var.public_subnet_id

  tags = { Name = "${var.name_prefix}-nat" }
}

# Add route to NAT in private route table
resource "aws_route" "private_to_nat" {
  route_table_id         = var.private_route_table_id
  destination_cidr_block = "0.0.0.0/0"
  nat_gateway_id         = aws_nat_gateway.this.id
}
```

> ⚠️ **コスト注意**: NAT Gateway は **1 時間あたり約 $0.062 + データ転送料金**がかかります(東京)。学習が終わったら必ず `destroy` してください。

#### outputs.tf

```hcl
output "nat_gateway_id" { value = aws_nat_gateway.this.id }
```

---

### 5.9 `modules/compute`

#### variables.tf

```hcl
variable "name_prefix" { type = string }
variable "vpc_id" { type = string }
variable "subnet_ids" { type = list(string) }
variable "associate_public_ip" { type = bool }
variable "instance_type" { type = string }
variable "instance_count" { type = number }
variable "key_pair_name" { type = string }

variable "allowed_ssh_cidr" {
  type    = string
  default = ""
}
```

#### main.tf

```hcl
# Latest Amazon Linux 2023 AMI
data "aws_ami" "al2023" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["al2023-ami-2023.*-x86_64"]
  }
}

# Security Group for EC2
resource "aws_security_group" "ec2" {
  name        = "${var.name_prefix}-ec2-sg"
  description = "Security group for EC2"
  vpc_id      = var.vpc_id

  # Allow SSH only when allowed_ssh_cidr is set
  dynamic "ingress" {
    for_each = var.allowed_ssh_cidr != "" ? [1] : []
    content {
      description = "SSH"
      from_port   = 22
      to_port     = 22
      protocol    = "tcp"
      cidr_blocks = [var.allowed_ssh_cidr]
    }
  }

  # HTTP from inside the VPC only (ALB health check / internal access)
  ingress {
    description = "HTTP from VPC"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["10.0.0.0/16"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${var.name_prefix}-ec2-sg" }
}

# EC2
resource "aws_instance" "this" {
  count = var.instance_count

  ami                         = data.aws_ami.al2023.id
  instance_type               = var.instance_type
  key_name                    = var.key_pair_name
  subnet_id                   = var.subnet_ids[count.index % length(var.subnet_ids)]
  vpc_security_group_ids      = [aws_security_group.ec2.id]
  associate_public_ip_address = var.associate_public_ip

  # Install nginx for ALB health check / smoke test
  user_data = <<-EOF
              #!/bin/bash
              dnf install -y nginx
              echo "Hello from $(hostname)" > /usr/share/nginx/html/index.html
              systemctl enable --now nginx
              EOF

  tags = { Name = "${var.name_prefix}-ec2-${format("%02d", count.index + 1)}" }
}
```

#### outputs.tf

```hcl
output "instance_ids" { value = aws_instance.this[*].id }
output "public_ips" { value = aws_instance.this[*].public_ip }
output "private_ips" { value = aws_instance.this[*].private_ip }

output "ssh_commands" {
  value = [
    for i in aws_instance.this :
    "ssh -i ~/.ssh/${var.key_pair_name}.pem ec2-user@${i.public_ip}"
  ]
}
```

---

### 5.10 `modules/alb`

#### variables.tf

```hcl
variable "name_prefix" { type = string }
variable "vpc_id" { type = string }
variable "public_subnet_ids" { type = list(string) }
variable "target_instance_ids" { type = list(string) }

variable "allowed_cidr" {
  type    = string
  default = "0.0.0.0/0"
}
```

#### main.tf

```hcl
# Security Group for ALB
resource "aws_security_group" "alb" {
  name        = "${var.name_prefix}-alb-sg"
  description = "Security group for ALB"
  vpc_id      = var.vpc_id

  ingress {
    description = "HTTP"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = [var.allowed_cidr]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${var.name_prefix}-alb-sg" }
}

# ALB
resource "aws_lb" "this" {
  name               = "${var.name_prefix}-alb"
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb.id]
  subnets            = var.public_subnet_ids

  tags = { Name = "${var.name_prefix}-alb" }
}

# Target Group
resource "aws_lb_target_group" "this" {
  name     = "${var.name_prefix}-tg"
  port     = 80
  protocol = "HTTP"
  vpc_id   = var.vpc_id

  health_check {
    path                = "/"
    healthy_threshold   = 2
    unhealthy_threshold = 2
    interval            = 30
    timeout             = 5
    matcher             = "200"
  }

  tags = { Name = "${var.name_prefix}-tg" }
}

# Listener(HTTP)
resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.this.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.this.arn
  }
}

# Attach EC2 instances to Target Group
resource "aws_lb_target_group_attachment" "this" {
  count = length(var.target_instance_ids)

  target_group_arn = aws_lb_target_group.this.arn
  target_id        = var.target_instance_ids[count.index]
  port             = 80
}
```

#### outputs.tf

```hcl
output "dns_name" { value = aws_lb.this.dns_name }
output "alb_arn" { value = aws_lb.this.arn }
output "target_group_arn" { value = aws_lb_target_group.this.arn }
output "zone_id" { value = aws_lb.this.zone_id }
```

---

## 6. EC2 台数のパラメータ化(count vs for_each)

### 6.1 `count` の特徴

- 「同じものを N 個作る」場合に使用
- 添字(0, 1, 2, ...)で管理される
- 本手順書の `aws_instance.this` で採用している方式
- ⚠️ 落とし穴: 途中の要素を削除すると以降がズレて再作成される

### 6.2 `for_each` の特徴

- 「個別に名前や属性が異なるものを作る」場合
- map または set のキーで管理される(順序非依存)

```hcl
variable "instances" {
  type = map(object({
    instance_type = string
    subnet_index  = number
  }))
  default = {
    "web-01" = { instance_type = "t3.micro", subnet_index = 0 }
    "web-02" = { instance_type = "t3.small", subnet_index = 1 }
  }
}

resource "aws_instance" "this" {
  for_each = var.instances

  ami           = data.aws_ami.al2023.id
  instance_type = each.value.instance_type
  subnet_id     = var.subnet_ids[each.value.subnet_index]
  tags          = { Name = each.key }
}
```

### 6.3 使い分けの目安

| やりたいこと | おすすめ |
| --- | --- |
| 同一スペックを N 台 | `count` |
| 名前ごとに違う設定 | `for_each` |
| 将来的に台数増減を頻繁にする | `for_each`(再作成事故が減る) |

---

## 7. タグ付け・命名規則

### 7.1 命名規則

`<project>-<env>-<resource>-<連番 or 識別子>`

例: `handson-dev-ec2-01`, `handson-dev-vpc`, `handson-dev-alb`

### 7.2 タグ

| タグキー | 例 |
| --- | --- |
| `Name` | `handson-dev-ec2-01` |
| `Project` | `handson` |
| `Environment` | `dev` |
| `ManagedBy` | `Terraform` |

本手順書では `provider` の `default_tags` で `Project / Environment / ManagedBy` を自動付与し、各リソースで `Name` のみ個別指定しています。

---

## 8. 実行手順(init → plan → apply)

```bash
cd terraform-aws-handson/envs/dev

terraform init
terraform fmt -recursive
terraform validate
terraform plan
terraform apply   # yes
```

### パターンごとの apply 例

#### パターン①最小構成

```hcl
# terraform.tfvars
ec2_subnet_type = "public"
enable_nat      = false
enable_alb      = false
```

#### パターン②ALB 付き(EC2 はまだ public)

```hcl
ec2_subnet_type = "public"
enable_nat      = false
enable_alb      = true
```

#### パターン③本番似(EC2 を private に移動)

```hcl
ec2_subnet_type  = "private"
enable_nat       = true
enable_alb       = true
allowed_ssh_cidr = ""    # private, no SSH ingress (need bastion or SSM Session Manager)
```

> ⚠️ パターン③に変更すると EC2 は**再作成**されます。`plan` で必ず確認。

---

## 9. 動作確認(SSH 接続 / ALB アクセス)

### 9.1 SSH 接続(EC2 が public のとき)

```bash
chmod 400 ~/.ssh/my-keypair-name.pem
# terraform output ssh_commands で表示されたコマンドを使う
ssh -i ~/.ssh/my-keypair-name.pem ec2-user@<public_ip>
```

> Amazon Linux 2023 のデフォルトユーザーは `ec2-user`。

### 9.2 ALB アクセス

```bash
terraform output alb_dns_name
# 例: handson-dev-alb-1234567890.ap-northeast-1.elb.amazonaws.com

curl http://$(terraform output -raw alb_dns_name)
# → Hello from ip-10-0-x-x  などが返ってくれば成功
```

数回叩くと EC2 が分散されることが確認できます(`hostname` が変わる)。

### 9.3 private 配置時の SSH(参考)

EC2 を private に置くと直接 SSH できません。実務では以下のいずれかを使います。

- **AWS Systems Manager Session Manager**(踏み台不要、おすすめ)
- 踏み台 EC2(public に置く)経由で SSH

学習段階では一旦 public に戻して確認するのが楽です。

---

## 10. コスト削減のための停止 / 削除手順

### 10.1 一時停止(EC2 のみ)

```bash
aws ec2 describe-instances \
  --filters "Name=tag:Project,Values=handson" \
  --query "Reservations[].Instances[].InstanceId" --output text

aws ec2 stop-instances --instance-ids i-xxxxx i-yyyyy
aws ec2 start-instances --instance-ids i-xxxxx i-yyyyy
```

> ⚠️ NAT Gateway は停止できません。**起動中ずっと課金**されるため、使わない時間が長いなら `destroy` 推奨。

### 10.2 ALB / NAT だけ削除する

`terraform.tfvars` で `enable_alb = false` / `enable_nat = false` にして `apply`。

> 💡 これも module ON/OFF パターンの便利な点。

### 10.3 全削除

```bash
cd terraform-aws-handson/envs/dev
terraform destroy   # yes
```

### 10.4 削除確認

```bash
terraform state list
```

AWS コンソールで以下を確認。

- EC2 / EIP / NAT Gateway / ALB / Target Group / VPC / SG

---

## 11. トラブルシューティング

| 症状 | 原因 | 対処 |
| --- | --- | --- |
| `Error: Invalid argument name` / `"network" ">module ...` のような奇妙な文字列 | ブラウザレンダリングからのコピペで HTML エンティティが混入 | `.md` の生ファイル(ソース表示)からコピペし直す。`head -5 ファイル名` でプレーンか確認 |
| `Error: Invalid character` / `This character is not used within the language` | 全角文字(日本語コメント・全角括弧・全角スペース)混入 | 該当行を見つけて半角英数字に修正 |
| `Quoted strings may not be split over multiple lines` | 上記2つに付随して発生することが多い | 同上の対処で大抵解消 |
| `Error: No valid credential sources found` | AWS 認証情報未設定 | `aws sts get-caller-identity` で確認、`aws configure` を再実行 |
| `InvalidKeyPair.NotFound` | キーペア名が間違い / 別リージョン | コンソールで `ap-northeast-1` を確認 |
| `UnauthorizedOperation` | IAM 権限不足 | 必要なポリシー(EC2/VPC/ELB)が付いているか |
| `iam:ListUsers` の AccessDenied | IAM ユーザーに IAM 操作権限がない | MFA 設定などはルートユーザーから行う(3.1.4 参照) |
| SSH がタイムアウト | SG の許可 IP が現在と異なる | `allowed_ssh_cidr` を更新して再 apply |
| ALB の URL でつながらない | TG のヘルスチェック失敗 | EC2 で `nginx` が起動しているか、SG で VPC 内 80 を許可しているか |
| ALB 作成時に `subnets` エラー | サブネットが 1 AZ のみ | ALB は最低 2 AZ 必要。`public_subnet_cidrs` を 2 件に |
| NAT 経由でも通信できない | private RT に NAT route がない | `nat module` の `aws_route` が作られたか確認 |
| `terraform plan` で差分が出続ける | 手動変更 | 手動変更を戻す or コードに反映 |
| `Error acquiring the state lock` | ロック残り | プロセス終了を確認後 `terraform force-unlock <LOCK_ID>` |

---

## 12. 次のステップ

### 12.1 tfstate のリモート管理(S3 + DynamoDB)

```hcl
# envs/dev/backend.tf
terraform {
  backend "s3" {
    bucket         = "your-tfstate-bucket"
    key            = "handson/dev/terraform.tfstate"
    region         = "ap-northeast-1"
    dynamodb_table = "terraform-locks"
    encrypt        = true
  }
}
```

### 12.2 環境追加(prod)

`envs/prod/` を作って同じ module を別パラメータで呼び出す。

### 12.3 構成の発展

- RDS を追加して 3 層 Web 構成
- Session Manager で踏み台レス SSH
- Auto Scaling Group + ALB
- CI/CD(GitHub Actions)で `plan` / `apply` 自動化

### 12.4 学習リソース

- [Terraform 公式チュートリアル(AWS)](https://developer.hashicorp.com/terraform/tutorials/aws-get-started)
- [AWS Provider ドキュメント](https://registry.terraform.io/providers/hashicorp/aws/latest/docs)

---

## 13. 付録 A: HTTPS(443)対応

HTTPS にするには **ACM 証明書** + **Route 53 のドメイン**が必要です。学習段階ではドメイン取得済みの場合のみ進めてください。

### A.1 事前準備(手動)

1. Route 53 でドメイン取得 or 既存ドメインのホストゾーン作成
2. ACM(ap-northeast-1)で証明書を発行・**DNS 検証で「発行済み」状態にする**
3. 証明書 ARN をメモ

### A.2 module/alb の拡張(差分のみ)

```hcl
# Add to variables.tf
variable "certificate_arn" {
  type    = string
  default = ""
}

# Add to main.tf SG: HTTPS ingress
ingress {
  description = "HTTPS"
  from_port   = 443
  to_port     = 443
  protocol    = "tcp"
  cidr_blocks = [var.allowed_cidr]
}

# Add HTTPS Listener
resource "aws_lb_listener" "https" {
  count             = var.certificate_arn != "" ? 1 : 0
  load_balancer_arn = aws_lb.this.arn
  port              = 443
  protocol          = "HTTPS"
  ssl_policy        = "ELBSecurityPolicy-TLS13-1-2-2021-06"
  certificate_arn   = var.certificate_arn

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.this.arn
  }
}

# Optional: HTTP -> HTTPS redirect
# Replace default_action in aws_lb_listener.http with type=redirect
```

### A.3 envs/dev での呼び出し

```hcl
module "alb" {
  source = "../../modules/alb"
  count  = var.enable_alb ? 1 : 0

  # ...
  certificate_arn = "arn:aws:acm:ap-northeast-1:123456789012:certificate/xxxxxxxx"
}
```

### A.4 Route 53 で ALB に向ける(任意)

```hcl
resource "aws_route53_record" "app" {
  zone_id = "Z123456ABCDEFG"
  name    = "app.example.com"
  type    = "A"

  alias {
    name                   = module.alb[0].dns_name
    zone_id                = module.alb[0].zone_id
    evaluate_target_health = true
  }
}
```

---

## 付録 B: チェックリスト

### 作業前

- [ ] AWS アカウントにログインできる
- [ ] 東京リージョンにキーペアを作成済み
- [ ] 秘密鍵(`.pem`)をローカルに保存済み
- [ ] `aws sts get-caller-identity` が成功
- [ ] `terraform -version` が表示される
- [ ] 自分のグローバル IP を確認(`curl https://checkip.amazonaws.com`)

### 作業後

- [ ] `terraform destroy` を実行
- [ ] AWS コンソールで EC2 / NAT / EIP / ALB / VPC が削除されたことを確認
- [ ] 使い続けないアクセスキーは削除
