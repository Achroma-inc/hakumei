# hakumei コンテナを毎日 04:00 JST に自動更新する仕組み。
#
# 仕組み:
#   1. EventBridge Scheduler が日次 (デフォルト JST 04:00) で Lambda を invoke
#   2. Lambda が ECR Public DescribeImages で `hakumei:<tag>` の現在 digest を取得
#   3. ECS Express Gateway Service の primaryContainer.image を
#      `public.ecr.aws/<registry>/<repo>@sha256:<digest>` 形式に差し替えて update
#   4. ECS Express がローリングデプロイ (zero downtime) で新リビジョン投入
#
# ECS Express は image 文字列が同一だと再 pull しないため、:latest を渡しても新しい
# イメージは降りてこない。Lambda 側で都度 digest を解決し image URI を変えることで
# 確実に新バージョンを反映する。すでに同じ digest が走っていれば no-op で終了。
#
# auto_update_enabled = false にすると Lambda / Scheduler / IAM ロールいずれも作らない。

locals {
  auto_update_enabled = var.auto_update_enabled
  # public.ecr.aws/<registry>/<repo>:<tag> をパースして registry / repo / tag を取り出す。
  # ECR Public 以外を指定された場合は自動更新を諦める前提なので、ここでは
  # var.app_image_registry / var.app_image_repository / var.app_image_tag を直接受ける。
}

# ---------- Lambda パッケージング ----------

data "archive_file" "auto_update_lambda" {
  count       = local.auto_update_enabled ? 1 : 0
  type        = "zip"
  source_dir  = "${path.module}/lambda/auto_update"
  output_path = "${path.module}/.terraform-build/auto-update-lambda.zip"
}

# ---------- IAM (Lambda 実行ロール) ----------

resource "aws_iam_role" "auto_update_lambda" {
  count = local.auto_update_enabled ? 1 : 0
  name  = "${var.service_name}-auto-update-lambda"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
    }]
  })

  tags = var.tags
}

# CloudWatch Logs への書き込み (Lambda 実行ログ)
resource "aws_iam_role_policy_attachment" "auto_update_lambda_logs" {
  count      = local.auto_update_enabled ? 1 : 0
  role       = aws_iam_role.auto_update_lambda[0].name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_iam_role_policy" "auto_update_lambda" {
  count = local.auto_update_enabled ? 1 : 0
  name  = "auto-update"
  role  = aws_iam_role.auto_update_lambda[0].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      # digest 解決は anonymous な Docker Registry V2 protocol
      # (HTTPS HEAD /v2/<repo>/manifests/<tag>) で行うため、ecr-public:* IAM 権限は不要。
      {
        # ECS Express Service の image 差し替え
        Effect = "Allow"
        Action = [
          "ecs:DescribeExpressGatewayService",
          "ecs:UpdateExpressGatewayService",
        ]
        Resource = aws_ecs_express_gateway_service.this.service_arn
      },
      {
        # update_express_gateway_service は内部で新しい task definition
        # を RegisterTaskDefinition で登録してから ECS Express に差し替える挙動。リソース
        # レベル制限は task-definition family 名前空間に限定できる ARN を使う。
        # ACS Express が作る task definition family は service_name に基づく命名のため
        # ワイルドカードで覆う必要がある。
        Effect = "Allow"
        Action = [
          "ecs:RegisterTaskDefinition",
        ]
        Resource = "*"
      },
      {
        # update_express_gateway_service は内部で task definition を新リビジョン化する際に
        # execution / task ロールを PassRole する必要がある。infrastructure ロールも同様。
        Effect = "Allow"
        Action = "iam:PassRole"
        Resource = [
          aws_iam_role.execution.arn,
          aws_iam_role.task.arn,
          aws_iam_role.infrastructure.arn,
        ]
        Condition = {
          StringEquals = { "iam:PassedToService" = "ecs-tasks.amazonaws.com" }
        }
      },
    ]
  })
}

# ---------- Lambda 関数 ----------

resource "aws_lambda_function" "auto_update" {
  count            = local.auto_update_enabled ? 1 : 0
  function_name    = "${var.service_name}-auto-update"
  role             = aws_iam_role.auto_update_lambda[0].arn
  runtime          = "python3.12"
  handler          = "index.handler"
  filename         = data.archive_file.auto_update_lambda[0].output_path
  source_code_hash = data.archive_file.auto_update_lambda[0].output_base64sha256
  timeout          = 60
  memory_size      = 256

  environment {
    variables = {
      SERVICE_ARN         = aws_ecs_express_gateway_service.this.service_arn
      ECR_REGISTRY_ALIAS  = var.app_image_registry_alias
      ECR_REPOSITORY_NAME = var.app_image_repository
      IMAGE_TAG           = var.app_image_tag
      AWS_REGION_ECS      = var.aws_region
    }
  }

  tags = var.tags
}

resource "aws_cloudwatch_log_group" "auto_update" {
  count             = local.auto_update_enabled ? 1 : 0
  name              = "/aws/lambda/${var.service_name}-auto-update"
  retention_in_days = 30
  tags              = var.tags
}

# ---------- EventBridge Scheduler ----------

# Scheduler が Lambda を invoke するためのロール (Scheduler サービスが assume)
resource "aws_iam_role" "auto_update_scheduler" {
  count = local.auto_update_enabled ? 1 : 0
  name  = "${var.service_name}-auto-update-scheduler"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "scheduler.amazonaws.com" }
    }]
  })

  tags = var.tags
}

resource "aws_iam_role_policy" "auto_update_scheduler" {
  count = local.auto_update_enabled ? 1 : 0
  name  = "invoke-lambda"
  role  = aws_iam_role.auto_update_scheduler[0].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = "lambda:InvokeFunction"
      Resource = aws_lambda_function.auto_update[0].arn
    }]
  })
}

resource "aws_scheduler_schedule" "auto_update" {
  count = local.auto_update_enabled ? 1 : 0
  name  = "${var.service_name}-auto-update"

  flexible_time_window {
    mode = "OFF"
  }

  # デフォルト cron(0 19 * * ? *) UTC = JST 04:00。
  # var.update_schedule_timezone で JST 以外にもできる。
  schedule_expression          = var.update_schedule_cron
  schedule_expression_timezone = var.update_schedule_timezone

  target {
    arn      = aws_lambda_function.auto_update[0].arn
    role_arn = aws_iam_role.auto_update_scheduler[0].arn
  }
}
