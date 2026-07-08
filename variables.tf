# ユーザーが terraform.tfvars で埋める入力変数。
#
# 必須: aws_account_id / cur_s3_bucket / cur_s3_prefix / customer_name
# 必須 (basic_auth_enabled = true のとき): basic_auth_user / basic_auth_password
# 任意: それ以外 (デフォルトのまま運用可)。
#
# Basic 認証: デフォルト ON。WAF / Cognito / 閉域内デプロイ等で独自にアクセス制御する
# 場合は `basic_auth_enabled = false` で無効化可能。OFF 時は Secrets Manager (basic-auth)
# を作らず、コンテナに `BASIC_AUTH_DISABLED=1` を注入してアプリ層 (middleware.ts) でも
# 素通りさせる。OFF 時のアクセス制御責任はユーザー側。
#
# 注: aws_region は ap-northeast-1 必須 (本構成の動作保証範囲)。
# 他リージョンの利用は今後対応。

# ------------------------------------------------------------------------------
# 必須変数
# ------------------------------------------------------------------------------

variable "aws_account_id" {
  description = "デプロイ先 AWS アカウント ID (12 桁)。CUR S3 バケット所有者と同一前提"
  type        = string
  validation {
    condition     = can(regex("^[0-9]{12}$", var.aws_account_id))
    error_message = "aws_account_id は 12 桁の数字である必要があります"
  }
}

variable "customer_name" {
  description = "顧客識別子。Secrets Manager / リソース名 prefix に使う (例: \"acme\")。英小文字・数字・ハイフンのみ。"
  type        = string
  validation {
    condition     = can(regex("^[a-z0-9-]{1,30}$", var.customer_name))
    error_message = "customer_name は英小文字・数字・ハイフンのみ、30 文字以内"
  }
}

variable "cur_s3_bucket" {
  description = "CUR 2.0 が配信されている S3 バケット名 (自社の AWS Billing で設定したもの)"
  type        = string
}

variable "cur_s3_prefix" {
  description = "CUR データの S3 プレフィックス (例: \"data-exports/cur2-hourly/<export-name>/data\")"
  type        = string
}

variable "bedrock_api_key" {
  description = <<-EOT
    顧客が自社 AWS アカウントで発行した Bedrock 長期 API キー文字列。
    このキーで呼ぶ Bedrock は顧客アカウントのものなので Bedrock 利用料は顧客負担。
    初回 apply 時に Secrets Manager に投入され、ECS タスクが起動時に取得する。
    空のまま apply するとタスクが AWSCURRENT 不在で起動失敗して service 安定化が完了しない。

    機微値のため tfvars に書く場合は git commit 禁止 (.gitignore で除外済み)。
    -var "bedrock_api_key=..." や TF_VAR_bedrock_api_key 環境変数で渡すのも可。
    write-only attribute で投入するため tfstate には保存されない (Codex レビュー対応)。
    ローテーション時は bedrock_api_key_version を increment + 値更新で再 apply する。
  EOT
  type        = string
  sensitive   = true
  ephemeral   = true
  validation {
    condition     = length(var.bedrock_api_key) > 0
    error_message = "bedrock_api_key は必須です (自社 AWS で発行した Bedrock API キーを指定)。空のまま apply すると ECS タスクが起動失敗します。"
  }
}

variable "bedrock_api_key_version" {
  description = <<-EOT
    bedrock_api_key の write-only 投入を Terraform に「変更あり」と認識させるための
    バージョン番号。secret_string_wo は tfstate に値が残らない代わりに変更検知ができないため、
    値を更新したら本変数も increment して apply する (1, 2, 3, ...)。
  EOT
  type        = number
  default     = 1
}

variable "basic_auth_enabled" {
  description = <<-EOT
    アプリ層 Basic 認証を有効化するか。デフォルト true (有効)。
    false にした場合は Secrets Manager (basic-auth) を作らず、コンテナに
    BASIC_AUTH_DISABLED=1 を注入してアプリ側でも認証チェックをスキップする。
    OFF にする場合は WAF / Cognito / 閉域構成などユーザー側で別途アクセス制御すること。
  EOT
  type        = bool
  default     = true
}

# で導入した http_public_access_mitigation 変数は撤去。
# ECS Express Mode の払い出し endpoint は HTTPS のみ公開で HTTP(80) は受け付けないため、
# Basic 認証 ON のまま apply しても認証情報の平文露出は発生しない (実機確認 2026-06-26)。
# 詳細は main.tf の precondition 撤去理由コメント参照。
#
# ただし basic_auth_enabled = false (アプリ層 Basic 認証 OFF) の場合は HTTPS でも
# 無認証公開になるため、外部アクセス制御の有無を別途 external_access_control_mitigation で
# 自己申告させる (mitigation precondition は main.tf)。

variable "external_access_control_mitigation" {
  description = <<-EOT
    basic_auth_enabled = false 時の外部アクセス制御方式を明示する。

    本配布物の ECS Express endpoint は HTTPS で公開されるが、Basic 認証 OFF にすると
    アプリ層の認証もスキップされるため、何も被せないと CUR ベースのコスト画面が
    誰でも閲覧可能になる (README 「Basic 認証を無効化する場合」参照)。

    basic_auth_enabled = false の場合は以下のいずれかを明示する必要がある (null なら apply 不可):

    - "waf-cognito": ALB の前に WAF + Cognito などのアプリ層認証を別途構築済み
    - "private-network-only": VPN / Tailscale / Direct Connect / 社内専用線 等の閉域 NW
      からのみアクセスする運用 (顧客 NW 側で到達制限済み)
    - "reverse-proxy-auth": 認証機能を持つリバプロ (Cloudflare Access / IAP / 自社 SSO 等)
      を別途構築済みで、本 ALB は直接公開しない

    basic_auth_enabled = true (デフォルト) なら本変数は null のまま可。
    Terraform は実在を検証しないため、指定した mitigation 構成の存在は顧客側の責任で担保。
  EOT
  type        = string
  default     = null
  validation {
    condition = (
      var.external_access_control_mitigation == null ||
      contains(["waf-cognito", "private-network-only", "reverse-proxy-auth"], var.external_access_control_mitigation)
    )
    error_message = "external_access_control_mitigation は null / \"waf-cognito\" / \"private-network-only\" / \"reverse-proxy-auth\" のいずれかにしてください"
  }
}

# --- カスタムドメイン (任意、) ---
# 指定すると ACM 証明書を発行し、ECS Express の HTTPS listener に SNI で追加証明書を
# 被せ、Route 53 で Alias レコードを引いて顧客固有のドメインで HTTPS 公開する。
# 未指定なら ECS Express デフォルトの *.ecs.<region>.on.aws エンドポイントをそのまま使う
# (どちらでも HTTPS で公開される)。

variable "domain_name" {
  description = <<-EOT
    カスタムドメイン FQDN (例: "hakumei.example.com")。null なら ECS Express デフォルト
    エンドポイント (*.ecs.<region>.on.aws) を使う。
    指定時は route53_hosted_zone_id (DNS 検証 + Alias レコードの登録先) も必須。
  EOT
  type        = string
  default     = null
}

variable "route53_hosted_zone_id" {
  description = <<-EOT
    domain_name が属する Route 53 Hosted Zone ID (Z 始まり、例: "Z0123456789ABCDEFGHIJ")。
    domain_name 指定時に必須。ACM の DNS 検証 CNAME と Alias A レコードをここに作る。
    domain_name 未指定なら null のままで可。
  EOT
  type        = string
  default     = null
}

variable "basic_auth_user" {
  description = "アプリ層 Basic 認証のユーザー名 (basic_auth_enabled = true のとき必須)。ephemeral で tfstate に保存しない"
  type        = string
  sensitive   = true
  ephemeral   = true
  default     = null
}

variable "basic_auth_password" {
  description = "アプリ層 Basic 認証のパスワード (basic_auth_enabled = true のとき必須、長さ 12 文字以上推奨)。ephemeral で tfstate に保存しない"
  type        = string
  sensitive   = true
  ephemeral   = true
  default     = null
  validation {
    # basic_auth_enabled = true のときのみ 8 文字以上を要求 (false なら null 許可)
    condition     = var.basic_auth_password == null || length(var.basic_auth_password) >= 8
    error_message = "basic_auth_password は 8 文字以上にしてください (12 文字以上推奨)"
  }
}

variable "basic_auth_password_version" {
  description = <<-EOT
    basic_auth_user/password の write-only 投入を Terraform に「変更あり」と
    認識させるためのバージョン番号。値を更新したら本変数も increment して apply する。
  EOT
  type        = number
  default     = 1
}

# ------------------------------------------------------------------------------
# 任意変数 (デフォルトで動く)
# ------------------------------------------------------------------------------

variable "aws_region" {
  description = "デプロイ先 AWS リージョン。本構成は ap-northeast-1 のみ動作保証"
  type        = string
  default     = "ap-northeast-1"
  validation {
    condition     = var.aws_region == "ap-northeast-1"
    error_message = "本構成は ap-northeast-1 のみ対応。他リージョンは個別相談"
  }
}

variable "service_name" {
  description = "ECS サービス / クラスタ / ロググループ名のベース"
  type        = string
  default     = "hakumei"
}

variable "app_image" {
  description = <<-EOT
    hakumei コンテナイメージ URI。デフォルトは ECR Public の :latest を指し、
    auto_update_enabled = true (デフォルト) の場合は日次で最新 digest に自動更新される。
    特定バージョンに固定したい場合は不変タグまたは digest を指定する:
      public.ecr.aws/y2a9a6u8/hakumei:sha-xxxxxxx
      public.ecr.aws/y2a9a6u8/hakumei@sha256:xxxxxxxxxxxxxxxx
  EOT
  type        = string
  default     = "public.ecr.aws/y2a9a6u8/hakumei:latest"
}

variable "app_image_registry_alias" {
  description = "自動更新 Lambda が Docker Registry V2 protocol で digest を引く際の ECR Public registry alias (URL path の先頭セグメント)。Achroma 配布の hakumei は y2a9a6u8 固定"
  type        = string
  default     = "y2a9a6u8"
}

variable "app_image_repository" {
  description = "自動更新 Lambda が追跡する ECR Public リポジトリ名"
  type        = string
  default     = "hakumei"
}

variable "app_image_tag" {
  description = "自動更新 Lambda が追跡するタグ。日次でこのタグの最新 digest を ECS に反映する"
  type        = string
  default     = "latest"
}

variable "auto_update_enabled" {
  description = <<-EOT
    日次でコンテナを ECR Public の最新版に自動更新するかどうか。
    デフォルト true: Lambda + EventBridge Scheduler を作成し、毎日 update_schedule_cron の
    時刻に ECR Public 上の `app_image_repository:app_image_tag` の最新 digest を取得して
    ECS Express を再デプロイする (no-op で冪等)。
    false にすると Lambda / Scheduler / 専用 IAM ロールいずれも作成しない。
  EOT
  type        = bool
  default     = true
}

variable "update_schedule_cron" {
  description = <<-EOT
    自動更新の実行スケジュール (EventBridge Scheduler の cron 式)。
    デフォルト `cron(0 4 * * ? *)` は update_schedule_timezone と組み合わせて毎日 04:00 (JST)。
    AWS の cron 式は分・時・日・月・曜日・年の 6 フィールド。曜日と日のどちらかを ? にする。
  EOT
  type        = string
  default     = "cron(0 4 * * ? *)"
}

variable "update_schedule_timezone" {
  description = "update_schedule_cron を解釈するタイムゾーン (IANA 名)。デフォルトは JST"
  type        = string
  default     = "Asia/Tokyo"
}

variable "container_port" {
  description = "コンテナの待ち受けポート。hakumei (Next.js standalone) は 3000"
  type        = number
  default     = 3000
}

variable "health_check_path" {
  description = "ALB ターゲットグループのヘルスチェックパス (hakumei は Basic 認証をスキップする /api/health)"
  type        = string
  default     = "/api/health"
}

variable "cpu" {
  description = "Fargate タスク CPU"
  type        = string
  default     = "1024"
}

variable "memory" {
  description = "Fargate タスクメモリ MiB (cpu=1024 なら 2048-8192)"
  type        = string
  default     = "2048"
}

variable "subnet_ids" {
  description = <<-EOT
    (オプション) ECS タスクと ALB を配置する既存の public サブネット ID (最低 2 AZ、同一 VPC)。
    指定するとユーザーの既存 VPC/subnet を流用する。
    空 (デフォルト) の場合は hakumei 専用 VPC + IGW + public subnet (2 AZ) を新規作成し、
    導入先の既存 VPC/subnet に一切影響を与えない。
  EOT
  type        = list(string)
  default     = []
}

variable "vpc_cidr" {
  description = <<-EOT
    subnet_ids 未指定時に新規作成する専用 VPC の CIDR ブロック。
    public subnet 2 つを /24 で切り出す。既存 VPC との衝突を避けたい場合は変更する。
    subnet_ids を指定した場合 (既存 VPC 流用) は無視される。
  EOT
  type        = string
  default     = "10.0.0.0/16"
}

variable "member_account_ids" {
  description = <<-EOT
    (ACH-500) AI チャットの実態確認 (EC2 describe 等) の対象とする
    組織内メンバーアカウントの ID リスト (12 桁)。メンバーアカウントを持つ組織では必須。
    指定するとタスクロールに各アカウントの hakumei-readonly-role への sts:AssumeRole を許可する。
    別途、各メンバーアカウント側で member-readonly-role/ を apply してロールを作ること (README §5)。
    空 (デフォルト) なら AssumeRole 権限は付与しない (単一アカウント運用)。
  EOT
  type        = list(string)
  default     = []
  validation {
    condition     = alltrue([for id in var.member_account_ids : can(regex("^[0-9]{12}$", id))])
    error_message = "member_account_ids の各要素は 12 桁の数字である必要があります"
  }
}

variable "tags" {
  description = "全リソースに付与する共通タグ"
  type        = map(string)
  default = {
    Project = "hakumei"
    Owner   = "achroma"
  }
}
