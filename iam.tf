# ECS Express Mode に必要な IAM ロール 3 種。
#  - infrastructure: Express Mode が ALB/ASG 等を構成するために assume するロール
#  - execution:      ECS エージェントが ECR pull / logs / secrets 取得に使うロール
#  - task:           hakumei アプリが CUR S3 read / COH / CE を呼ぶロール

# --- インフラロール (Express Mode 用) ---
resource "aws_iam_role" "infrastructure" {
  name = "${var.service_name}-ecs-express-infrastructure"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "ecs.amazonaws.com" }
    }]
  })
  tags = var.tags
}

resource "aws_iam_role_policy_attachment" "infrastructure_managed" {
  role       = aws_iam_role.infrastructure.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSInfrastructureRoleforExpressGatewayServices"
}

# Express Mode がネットワーク構成を読むための ec2:Describe 群
resource "aws_iam_role_policy" "infrastructure_ec2_describe" {
  name = "ec2-describe"
  role = aws_iam_role.infrastructure.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "ec2:DescribeVpcs",
        "ec2:DescribeSubnets",
        "ec2:DescribeSecurityGroups",
        "ec2:DescribeNetworkInterfaces",
        "ec2:DescribeAvailabilityZones",
      ]
      Resource = "*"
    }]
  })
}

# --- タスク実行ロール (ECR pull / logs / secrets 取得) ---
resource "aws_iam_role" "execution" {
  name = "${var.service_name}-ecs-express-execution"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "ecs-tasks.amazonaws.com" }
    }]
  })
  tags = var.tags
}

resource "aws_iam_role_policy_attachment" "execution_managed" {
  role       = aws_iam_role.execution.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

# Secrets Manager から secret を注入するため、実行ロールに GetSecretValue を付与。
# basic_auth が無効化されている場合は basic_auth シークレットを参照しない。
resource "aws_iam_role_policy" "execution_secrets" {
  name = "secrets-access"
  role = aws_iam_role.execution.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = ["secretsmanager:GetSecretValue"]
      Resource = concat(
        [aws_secretsmanager_secret.bedrock_api_key.arn],
        var.basic_auth_enabled ? [aws_secretsmanager_secret.basic_auth[0].arn] : [],
      )
    }]
  })
}

# --- タスクロール (アプリが使う、最小権限) ---
resource "aws_iam_role" "task" {
  name = "${var.service_name}-ecs-express-task"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "ecs-tasks.amazonaws.com" }
    }]
  })
  tags = var.tags
}

# CUR S3 read (同一アカウントの CUR バケット) + Cost Optimization Hub / Cost Explorer。
# COH / CE は read-only API のためリソースレベル制限不可 (Resource = "*")。
resource "aws_iam_role_policy" "task_app" {
  name = "hakumei-app-access"
  role = aws_iam_role.task.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "CurS3Read"
        Effect   = "Allow"
        Action   = ["s3:GetObject", "s3:ListBucket"]
        Resource = ["arn:aws:s3:::${var.cur_s3_bucket}", "arn:aws:s3:::${var.cur_s3_bucket}/*"]
      },
      {
        Sid    = "CostOptimizationHubRead"
        Effect = "Allow"
        Action = [
          "cost-optimization-hub:ListRecommendations",
          "cost-optimization-hub:GetRecommendation",
          "cost-optimization-hub:ListEnrollmentStatuses",
        ]
        Resource = "*"
      },
      {
        Sid    = "CostExplorerRead"
        Effect = "Allow"
        Action = [
          "ce:GetSavingsPlansPurchaseRecommendation",
          "ce:GetReservationPurchaseRecommendation",
          "ce:GetCostAndUsage",
        ]
        Resource = "*"
      },
      {
        # ACH-496: Trusted Advisor のコスト最適化チェック (推定節約額の取り込み)。
        # read-only API のためリソースレベル制限不可。Business/Enterprise Support 必須で、
        # 未契約時はアプリ側が notice を出して COH / CUR 推奨のみで動作する。
        Sid      = "TrustedAdvisorRead"
        Effect   = "Allow"
        Action   = ["trustedadvisor:ListRecommendations"]
        Resource = "*"
      },
      {
        # AIチャットで「自社環境の状況」を読み取るための最小 read 群。
        # 自アカウント単体のみ。他アカウントへの AssumeRole は member_account_ids
        # 指定時のみ別ポリシー (task_member_assume) で付与する (README §8 参照)。
        Sid    = "AwsApiReadOnly"
        Effect = "Allow"
        Action = [
          "ec2:Describe*",
          "rds:Describe*",
          "cloudwatch:GetMetricStatistics",
          "cloudwatch:ListMetrics",
          "s3:List*",
          "s3:GetBucketLifecycleConfiguration",
          "s3:GetBucketLocation",
        ]
        Resource = "*"
      },
      {
        # ノート機能の S3 永続化。本バケットに限定して GetObject / PutObject /
        # DeleteObject / ListBucket を許可する。アプリ側 (src/lib/notes/store.ts) は
        # notes/<scope>/<YYYY-MM-DD>.md のキー設計で読み書きする。
        Sid    = "NotesS3ReadWrite"
        Effect = "Allow"
        Action = [
          "s3:GetObject",
          "s3:PutObject",
          "s3:DeleteObject",
          "s3:ListBucket",
        ]
        Resource = [
          aws_s3_bucket.notes.arn,
          "${aws_s3_bucket.notes.arn}/*",
        ]
      },
    ]
  })
}

# ACH-500: メンバーアカウントのリソース実態を AI チャットから読むためのクロスアカウント
# AssumeRole。member_account_ids 指定時のみ作成し、対象を各メンバーの
# hakumei-readonly-role (member-readonly-role/ で作成、名前固定) に限定する。
# メンバー側ロールの信頼ポリシーも本タスクロール ARN に限定されるため相互に最小権限。
resource "aws_iam_role_policy" "task_member_assume" {
  count = length(var.member_account_ids) > 0 ? 1 : 0

  name = "hakumei-member-assume"
  role = aws_iam_role.task.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid      = "AssumeMemberReadonlyRole"
      Effect   = "Allow"
      Action   = "sts:AssumeRole"
      Resource = [for id in distinct(var.member_account_ids) : "arn:aws:iam::${id}:role/hakumei-readonly-role"]
    }]
  })
}
