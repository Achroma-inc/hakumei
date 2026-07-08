# hakumei メンバーアカウント用 read-only ロール (ACH-500)。
#
# hakumei 本体 (管理アカウント) の AI チャットが、組織内メンバーアカウントの
# リソース実態 (EC2 describe 等) を読むための AssumeRole 先ロールを作る。
# **メンバーアカウントごとに 1 回、そのアカウントの credential で apply する**
# (本体スタックとは別 state。手順は配布 README §5 参照)。
#
# - 信頼元: hakumei 本体スタックの ECS タスクロール (output `task_role_arn`)
# - 権限: AWS 管理ポリシー ReadOnlyAccess (読み取りのみ、変更系は一切不可)
# - ロール名: hakumei-readonly-role 固定。アプリ側 (HAKUMEI_MEMBER_ROLE_NAME の
#   デフォルト) および本体スタックのタスクロール権限とこの名前で対応しているため、
#   変更する場合は Achroma に相談してください。

terraform {
  required_version = ">= 1.11"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 6.0"
    }
  }

  # tfstate はユーザー環境の標準に合わせて backend を構成してください。
  # メンバーアカウントごとに state を分けること (別 key / workspace / ディレクトリ複製)。
  # backend "s3" {
  #   bucket = "<your-tfstate-bucket>"
  #   key    = "hakumei/member-readonly-role/<member-account-id>.tfstate"
  #   region = "ap-northeast-1"
  # }
}

provider "aws" {
  region = var.aws_region

  # 必須入力 member_account_id を allowed_account_ids に渡し、AWS_PROFILE 誤指定で
  # 意図しないアカウントに IAM ロールを作るのを防ぐ (本体スタックと同じ安全装置)。
  allowed_account_ids = [var.member_account_id]
}

locals {
  # アプリ (src/lib/aws-api/assume-role.ts) が assume する固定ロール名
  role_name = "hakumei-readonly-role"
}

resource "aws_iam_role" "readonly" {
  name = local.role_name
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Action    = "sts:AssumeRole"
      Principal = { AWS = var.trusted_principal_arn }
    }]
  })
  tags = var.tags
}

resource "aws_iam_role_policy_attachment" "readonly" {
  role       = aws_iam_role.readonly.name
  policy_arn = "arn:aws:iam::aws:policy/ReadOnlyAccess"
}
