# #704: 夜間・週末に ECS タスクを自動停止するオプトイン設定。
# enable_scheduled_scaling (デフォルト false) で有効化。トレードオフ・推奨設定は
# variables.tf の enable_scheduled_scaling description と README「夜間・週末の
# ECS タスク自動停止」を参照。

# ECS Express Mode がサービス作成時に自動生成する Application Auto Scaling の
# scalable target を、そのリソース ID (service/<cluster>/<service>) で直接参照する。
# 実機確認済み (2026-08-22、aws application-autoscaling describe-scalable-targets):
# terraform で scalable target 自体を管理 (register) する必要はなく、
# aws_appautoscaling_scheduled_action の resource_id にこの文字列を渡すだけでよい。
locals {
  ecs_service_resource_id = regex("service/.*$", aws_ecs_express_gateway_service.this.service_arn)
}

resource "aws_appautoscaling_scheduled_action" "scale_down" {
  count = var.enable_scheduled_scaling ? 1 : 0

  name               = "${var.service_name}-scheduled-scale-down"
  service_namespace  = "ecs"
  resource_id        = local.ecs_service_resource_id
  scalable_dimension = "ecs:service:DesiredCount"
  schedule           = var.scheduled_scaling_scale_down_cron
  timezone           = var.scheduled_scaling_timezone

  scalable_target_action {
    min_capacity = 0
    max_capacity = 0
  }

  # scalable target は Express Mode がサービス起動時に自動生成するため、サービス本体の
  # 作成完了を待ってから scheduled action を作る (target 不在での apply エラーを防ぐ)。
  depends_on = [aws_ecs_express_gateway_service.this]
}

resource "aws_appautoscaling_scheduled_action" "scale_up" {
  count = var.enable_scheduled_scaling ? 1 : 0

  name               = "${var.service_name}-scheduled-scale-up"
  service_namespace  = "ecs"
  resource_id        = local.ecs_service_resource_id
  scalable_dimension = "ecs:service:DesiredCount"
  schedule           = var.scheduled_scaling_scale_up_cron
  timezone           = var.scheduled_scaling_timezone

  scalable_target_action {
    min_capacity = var.scheduled_scaling_min_task_count
    max_capacity = var.scheduled_scaling_max_task_count
  }

  depends_on = [aws_ecs_express_gateway_service.this]
}

# アプリの /settings 画面が現在のスケジュール設定を読み取り専用で表示するための権限
# (2026-08-22 設計協議: 画面からの編集は行わない。アプリが自分自身の可用性を書き換える
# 自己参照的な権限は与えない。書き込み [PutScheduledAction 等] は一切許可しない)。
# enable_scheduled_scaling の有効/無効に関わらず常時付与する (他の read-only 権限群
# [COH/CE/TA 等] と同じ方針。無効環境では DescribeScheduledActions が単に空配列を返し、
# アプリ側はその結果からカード自体を表示しない)。
resource "aws_iam_role_policy" "task_scheduled_scaling_read" {
  name = "hakumei-scheduled-scaling-read"
  role = aws_iam_role.task.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        # アプリは自分がどの ECS service で動いているか (サービス名は Express Mode が
        # ランダム生成するため env では渡せない、main.tf のコメント参照) を、渡された
        # ECS_CLUSTER (クラスタ名は固定で既知) 内の service 一覧から自己解決する。
        # このクラスタには hakumei の service が 1 つしか存在しない前提。
        Sid      = "EcsListServicesRead"
        Effect   = "Allow"
        Action   = ["ecs:ListServices"]
        Resource = "*"
      },
      {
        Sid    = "ScheduledScalingRead"
        Effect = "Allow"
        # DescribeScheduledActions のレスポンス (ScheduledAction 型) に schedule / timezone /
        # scalable_target_action (min/max capacity) が含まれるため、これ単体で表示に必要な
        # 情報が揃う。DescribeScalableTargets は不要 (2026-08-22、AWS公式ドキュメントで確認)。
        Action = [
          "application-autoscaling:DescribeScheduledActions",
        ]
        # read-only API のためリソースレベル制限不可 (COH/CE/TA と同様)。
        Resource = "*"
      }
    ]
  })
}
