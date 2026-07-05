# apply 後にユーザーが参照する値。

locals {
  # ECS Express Mode は払い出す *.ecs.<region>.on.aws エンドポイントを HTTPS のみで
  # 公開する (AWS Managed 証明書)。HTTP(80) は受け付けない。
  #
  # AWS Provider 6.x の ingress_paths[0].endpoint は scheme 付きで返る場合と
  # scheme なしホスト名のみ返る場合があり、provider バージョンで揺れる。
  # startswith で正規化して https:// を保証する。
  raw_endpoint = aws_ecs_express_gateway_service.this.ingress_paths[0].endpoint
  # scheme が付いていなければ https:// を前置、http:// で来た場合は https:// に書き換え、
  # https:// で来た場合はそのまま返す。
  default_endpoint_url = (
    startswith(local.raw_endpoint, "https://") ? local.raw_endpoint :
    startswith(local.raw_endpoint, "http://") ? replace(local.raw_endpoint, "http://", "https://") :
    "https://${local.raw_endpoint}"
  )
}

output "service_url" {
  description = "hakumei にアクセスする URL (HTTPS)。Basic 認証を求められたら tfvars に書いた user/password を入力。domain_name 指定時はカスタムドメインの URL を返す"
  value = (
    var.domain_name != null
    ? "https://${var.domain_name}"
    : local.default_endpoint_url
  )
}

output "default_service_url" {
  description = "ECS Express デフォルトエンドポイント URL (カスタムドメイン指定時も AWS 払い出しの URL を保持)"
  value       = local.default_endpoint_url
}

output "bedrock_secret_id" {
  description = "Bedrock API キーの Secret ID (Secrets Manager)。本構成では initial apply で値も投入される。ローテーション時は bedrock_api_key_version を increment して再 apply"
  value       = aws_secretsmanager_secret.bedrock_api_key.name
}

output "cluster_name" {
  description = "ECS クラスタ名"
  value       = aws_ecs_cluster.this.name
}

output "log_group" {
  description = "CloudWatch Logs ロググループ名 (起動失敗時の調査に使う)"
  value       = aws_cloudwatch_log_group.this.name
}

output "service_arn" {
  description = "ECS Express Gateway Service ARN (イメージ更新時に aws ecs update-express-gateway-service で使う)"
  value       = aws_ecs_express_gateway_service.this.service_arn
}

output "service_name" {
  description = "サービス名 prefix (Lambda 関数名 <service_name>-auto-update などの組み立てに使う)"
  value       = var.service_name
}

output "auto_update_lambda_function_name" {
  description = "自動更新 Lambda の関数名 (auto_update_enabled = false なら null)。手動 invoke 時に使う"
  value       = local.auto_update_enabled ? aws_lambda_function.auto_update[0].function_name : null
}

output "task_role_arn" {
  description = "ECS タスクロール ARN (ACH-500)。member-readonly-role/ の trusted_principal_arn に指定する"
  value       = aws_iam_role.task.arn
}
