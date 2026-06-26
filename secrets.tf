# Secrets Manager の機微値をタスクに secret 注入する。
# 環境変数平文 (primary_container.environment) には載せない。
#
# Bedrock API キー (ユーザーが自社 AWS で発行):
#   - ユーザー自身の AWS アカウントで発行した Bedrock 長期 API キーを var.bedrock_api_key で渡す。
#     このキーで呼ぶ Bedrock はユーザーアカウントのものなので Bedrock 利用料はユーザー負担。
#   - 初回 apply 時に write-only attribute で Secrets Manager に投入する (下記)。
#
# Basic 認証 (user/password):
#   - tfvars に書く (sensitive 変数)。ユーザーが決める値。
#   - JSON で 1 シークレットにまとめ、ECS Express の secret block で key 指定で注入。
#   - basic_auth_enabled = false なら Secrets Manager は作らない。
#     その場合はコンテナに BASIC_AUTH_DISABLED=1 を注入してアプリ側でも素通り。

# --- Bedrock API キー (ユーザーが自社 AWS で発行) ---
# 初回 apply 時に値も同時投入する (空枠だけだと ECS タスクが AWSCURRENT 不在で
# 起動失敗して service 安定化が完了しない)。ユーザーが自社アカウントで発行した API キー文字列を
# var.bedrock_api_key に tfvars / -var / TF_VAR_bedrock_api_key で渡す。
# tfvars に書く場合は git commit 禁止 (README §Step 2 参照)。
resource "aws_secretsmanager_secret" "bedrock_api_key" {
  name        = "${var.service_name}/bedrock-api-key"
  description = "Bedrock API キー (ユーザーが自社 AWS で発行)"
  tags        = var.tags
}

resource "aws_secretsmanager_secret_version" "bedrock_api_key" {
  secret_id = aws_secretsmanager_secret.bedrock_api_key.id
  # secret_string ではなく write-only attribute を使い
  # tfstate に Bedrock API キー文字列を保存しない (Terraform 1.11+ / AWS Provider 6.x の機能)。
  # write-only は state に書かれず diff にも残らないため、ローテーション時は
  # secret_string_wo_version を increment して再 apply する必要がある (apply 時に AWS API へ送られる)。
  secret_string_wo         = var.bedrock_api_key
  secret_string_wo_version = var.bedrock_api_key_version
}

# --- Basic 認証 (ユーザーが決める、basic_auth_enabled で OFF 可能) ---
# basic_auth_enabled = false なら作らない。ON なら user/password が両方セット必須。
resource "aws_secretsmanager_secret" "basic_auth" {
  count       = var.basic_auth_enabled ? 1 : 0
  name        = "${var.service_name}/basic-auth"
  description = "hakumei アプリ層 Basic 認証 (user/password)"
  tags        = var.tags

  lifecycle {
    precondition {
      condition     = var.basic_auth_user != null && var.basic_auth_password != null
      error_message = "basic_auth_enabled = true のときは basic_auth_user と basic_auth_password を指定してください (OFF にする場合は basic_auth_enabled = false)"
    }
  }
}

resource "aws_secretsmanager_secret_version" "basic_auth" {
  count     = var.basic_auth_enabled ? 1 : 0
  secret_id = aws_secretsmanager_secret.basic_auth[0].id
  # write-only attribute で tfstate に user/password を保存しない。
  # 変更時は basic_auth_password_version を increment して再 apply する。
  secret_string_wo = jsonencode({
    user     = var.basic_auth_user
    password = var.basic_auth_password
  })
  secret_string_wo_version = var.basic_auth_password_version
}
