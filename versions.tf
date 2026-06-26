# hakumei (ECS Express Mode + ALB) の Terraform 構成。
#
# aws_ecs_express_gateway_service.this の image と network_configuration は
# lifecycle.ignore_changes で除外する。ECS Express が自動付与する AmazonECSManaged SG
# とリビジョン管理が terraform フル apply で巻き戻されないようにするため。

terraform {
  # ephemeral 変数 / secret_string_wo (write-only attribute) を使うため Terraform 1.11+ が必要。
  required_version = ">= 1.11"

  required_providers {
    aws = {
      source = "hashicorp/aws"
      # aws_ecs_express_gateway_service は ECS Express Mode (2025-11 GA) 対応の
      # 比較的新しいリソース。aws provider 6.x 以降が必要。
      # ephemeral 変数 + secret_string_wo もこのバージョン以降で利用可能。
      version = ">= 6.0"
    }
  }

  # tfstate はユーザー環境の標準に合わせて backend を構成してください (推奨: S3 + DynamoDB lock)。
  # backend "s3" {
  #   bucket         = "<your-tfstate-bucket>"
  #   key            = "hakumei/terraform.tfstate"
  #   region         = "ap-northeast-1"
  #   dynamodb_table = "<your-lock-table>"
  #   encrypt        = true
  # }
}

provider "aws" {
  region = var.aws_region

  # 必須入力 aws_account_id を allowed_account_ids に渡し、
  # AWS_PROFILE 誤指定で別アカウントに ECS/ALB/IAM/Secrets を作るのを防ぐ。
  # 不一致なら apply 前に Terraform が エラーで停止する。
  allowed_account_ids = [var.aws_account_id]
}
