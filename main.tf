# hakumei の ECS Express Mode サービス本体。
# 単一リソース aws_ecs_express_gateway_service が Fargate サービス + ALB (HTTPS) +
# オートスケール + CloudWatch を自動構成する。HTTPS は ECS Express Mode のデフォルト
# (AWS Managed 証明書、HTTP/2、HTTP(80) は受け付けない)。
# カスタムドメインは custom-domain.tf を参照 (domain_name + route53_hosted_zone_id 指定時のみ)。

resource "aws_ecs_cluster" "this" {
  name = var.service_name
  tags = var.tags
}

resource "aws_cloudwatch_log_group" "this" {
  name              = "/aws/ecs/${var.service_name}"
  retention_in_days = 30
  tags              = var.tags
}

resource "aws_ecs_express_gateway_service" "this" {
  cluster                 = aws_ecs_cluster.this.name
  execution_role_arn      = aws_iam_role.execution.arn
  infrastructure_role_arn = aws_iam_role.infrastructure.arn
  task_role_arn           = aws_iam_role.task.arn
  health_check_path       = var.health_check_path
  cpu                     = var.cpu
  memory                  = var.memory

  # secret_version の作成完了を待ってからサービスを作る (race 排除)。
  # 参照は secret.arn だけなので Terraform graph 上は version 作成を待たないため、
  # 明示的な depends_on を入れないと AWSCURRENT 不在で起動失敗する。
  depends_on = [
    aws_secretsmanager_secret_version.bedrock_api_key,
    aws_secretsmanager_secret_version.basic_auth,
  ]

  network_configuration {
    subnets         = local.subnet_ids
    security_groups = [aws_security_group.ecs.id]
  }

  primary_container {
    image          = var.app_image
    container_port = var.container_port

    aws_logs_configuration {
      log_stream_prefix = "ecs"
      log_group         = aws_cloudwatch_log_group.this.name
    }

    # 非機微の設定値は environment (平文で可)
    environment {
      name  = "NODE_ENV"
      value = "production"
    }
    environment {
      name  = "CUR_S3_BUCKET"
      value = var.cur_s3_bucket
    }
    environment {
      name  = "CUR_S3_PREFIX"
      value = var.cur_s3_prefix
    }
    environment {
      name  = "AWS_REGION"
      value = var.aws_region
    }
    # ノート (日次運用メモ) を S3 に永続化するためのバケット名。アプリ側はこの env が
    # 設定されていれば S3 に書き、未設定なら Map インメモリ fallback する。
    environment {
      name  = "NOTES_S3_BUCKET"
      value = aws_s3_bucket.notes.bucket
    }

    # basic_auth_enabled = false のときだけ BASIC_AUTH_DISABLED=1 を注入し、
    # アプリ側 middleware で fail-closed (503) をバイパスして素通りさせる。
    dynamic "environment" {
      for_each = var.basic_auth_enabled ? [] : [1]
      content {
        name  = "BASIC_AUTH_DISABLED"
        value = "1"
      }
    }

    # 機微値は Secrets Manager 参照 (平文にしない)。
    secret {
      name       = "BEDROCK_API_KEY"
      value_from = aws_secretsmanager_secret.bedrock_api_key.arn
    }
    # Basic 認証が ON のときのみ Secrets Manager から user/password を注入。
    dynamic "secret" {
      for_each = var.basic_auth_enabled ? [1] : []
      content {
        name       = "BASIC_AUTH_USER"
        value_from = "${aws_secretsmanager_secret.basic_auth[0].arn}:user::"
      }
    }
    dynamic "secret" {
      for_each = var.basic_auth_enabled ? [1] : []
      content {
        name       = "BASIC_AUTH_PASSWORD"
        value_from = "${aws_secretsmanager_secret.basic_auth[0].arn}:password::"
      }
    }
  }

  # ALB lookup を service_name で行うため Service タグを必ず付与する。
  # var.tags をユーザーが上書きしても custom-domain.tf の data source 引きが壊れないよう
  # merge で強制付与する (Service が var.tags 内にあっても上書き)。
  tags = merge(var.tags, { Service = var.service_name })

  # Terraform と実態の drift を構造的に解消する責務分離:
  #   - image                : 新バージョン配布時に var.app_image を更新して再 apply (or 自動更新 Lambda)
  #   - network_configuration: ECS Express が AmazonECSManaged=true SG を自動付与・自動管理する
  # ignore_changes で terraform フル apply が ECS の自動処理を巻き戻さないようにする。
  #
  # basic_auth_enabled = false の場合は HTTPS でも無認証公開になるため、WAF / Cognito /
  # 閉域 NW など外部アクセス制御を明示させる precondition を維持する。
  # Basic 認証 ON ならアプリ層認証で守られるため本 precondition は無視される。
  lifecycle {
    ignore_changes = [
      primary_container[0].image,
      network_configuration,
    ]
    precondition {
      condition     = var.basic_auth_enabled || var.external_access_control_mitigation != null
      error_message = "basic_auth_enabled = false にする場合は HTTPS でも無認証公開になるため、外部アクセス制御方式を external_access_control_mitigation で明示すること (\"waf-cognito\" / \"private-network-only\" / \"reverse-proxy-auth\")。詳細は variables.tf の description 参照。"
    }
  }
}
