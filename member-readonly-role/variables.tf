# ユーザーが terraform.tfvars で埋める入力変数 (メンバーアカウントごとに 1 セット)。

variable "member_account_id" {
  description = "ロールを作成するメンバーアカウントの ID (12 桁)。apply に使う credential のアカウントと一致している必要がある"
  type        = string
  validation {
    condition     = can(regex("^[0-9]{12}$", var.member_account_id))
    error_message = "member_account_id は 12 桁の数字である必要があります"
  }
}

variable "trusted_principal_arn" {
  description = <<-EOT
    信頼元 (hakumei 本体スタックの ECS タスクロール) の ARN。
    本体スタックの `terraform output task_role_arn` の値をそのまま指定する。
    例: arn:aws:iam::123456789012:role/hakumei-ecs-express-task
  EOT
  type        = string
  validation {
    condition     = can(regex("^arn:aws:iam::[0-9]{12}:role/", var.trusted_principal_arn))
    error_message = "trusted_principal_arn は IAM ロール ARN (arn:aws:iam::<12桁>:role/...) を指定してください"
  }
}

variable "aws_region" {
  description = "provider のリージョン。IAM はグローバルのためどのリージョンでも同じ結果になる"
  type        = string
  default     = "ap-northeast-1"
}

variable "tags" {
  description = "作成するロールに付与する共通タグ"
  type        = map(string)
  default = {
    Project = "hakumei"
    Owner   = "achroma"
  }
}
