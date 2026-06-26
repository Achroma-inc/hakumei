# 顧客カスタムドメインで HTTPS 公開 (任意、domain_name 指定時のみ作成)。
#
# ECS Express Mode は payload エンドポイント (*.ecs.<region>.on.aws) を AWS Managed 証明書付き
# HTTPS で公開するため、カスタムドメイン不要なら本ファイルのリソースは作られない (count = 0)。
# domain_name 指定時は以下を構築する:
#
#  - ACM 証明書 (var.aws_region、DNS validation、route53_hosted_zone_id で自動検証)
#  - ECS Express が作った HTTPS listener に SNI で追加証明書を登録
#  - Route 53 で var.domain_name → ALB の Alias A レコード
#  - listener rule の host-header に custom domain を追記 (Express デフォルトは payload DNS のみマッチ)

locals {
  custom_domain_enabled = var.domain_name != null
}

# --- 入力 precondition (domain_name と route53_hosted_zone_id はペア必須) ---
# 片方だけ指定したケースを apply 前にブロックする。
resource "terraform_data" "custom_domain_inputs_check" {
  count = local.custom_domain_enabled || var.route53_hosted_zone_id != null ? 1 : 0
  lifecycle {
    precondition {
      condition = (
        (var.domain_name == null) == (var.route53_hosted_zone_id == null)
      )
      error_message = "domain_name と route53_hosted_zone_id はペアで指定すること (片方だけ指定不可)。両方 null ならカスタムドメイン不要で ECS Express デフォルト URL を使う。"
    }
  }
}

# --- ECS Express が作った ALB / Listener を読む ---
# Express は AmazonECSManaged=true タグを ALB に付け、サービスの tags を ALB にも伝播させる。
# main.tf で aws_ecs_express_gateway_service に Service = var.service_name を必ず付与する
# よう merge しているため、Service タグで顧客の var.tags 上書きと無関係に引ける。
data "aws_lb" "ecs_express" {
  count = local.custom_domain_enabled ? 1 : 0
  tags = {
    Service          = var.service_name
    AmazonECSManaged = "true"
  }
  depends_on = [aws_ecs_express_gateway_service.this]
}

data "aws_lb_listener" "https" {
  count             = local.custom_domain_enabled ? 1 : 0
  load_balancer_arn = data.aws_lb.ecs_express[0].arn
  port              = 443
}

# --- ACM 証明書 ---

resource "aws_acm_certificate" "custom_domain" {
  count             = local.custom_domain_enabled ? 1 : 0
  domain_name       = var.domain_name
  validation_method = "DNS"

  lifecycle {
    create_before_destroy = true
  }

  tags = merge(var.tags, { Domain = var.domain_name })
}

# DNS validation 用 CNAME を顧客の Hosted Zone に追加
resource "aws_route53_record" "cert_validation" {
  for_each = local.custom_domain_enabled ? {
    for dvo in aws_acm_certificate.custom_domain[0].domain_validation_options : dvo.domain_name => {
      name   = dvo.resource_record_name
      record = dvo.resource_record_value
      type   = dvo.resource_record_type
    }
  } : {}

  zone_id         = var.route53_hosted_zone_id
  name            = each.value.name
  type            = each.value.type
  records         = [each.value.record]
  ttl             = 60
  allow_overwrite = true
}

resource "aws_acm_certificate_validation" "custom_domain" {
  count                   = local.custom_domain_enabled ? 1 : 0
  certificate_arn         = aws_acm_certificate.custom_domain[0].arn
  validation_record_fqdns = [for r in aws_route53_record.cert_validation : r.fqdn]
}

# --- ALB の HTTPS listener に SNI で追加証明書を登録 ---
# ECS Express が貼った default 証明書 (.ecs.<region>.on.aws 用) を残したまま
# SNI で var.domain_name の証明書も使えるようにする。

resource "aws_lb_listener_certificate" "custom_domain" {
  count           = local.custom_domain_enabled ? 1 : 0
  listener_arn    = data.aws_lb_listener.https[0].arn
  certificate_arn = aws_acm_certificate_validation.custom_domain[0].certificate_arn
}

# --- Route 53 A レコード (ALB Alias) ---

resource "aws_route53_record" "custom_domain" {
  count   = local.custom_domain_enabled ? 1 : 0
  zone_id = var.route53_hosted_zone_id
  name    = var.domain_name
  type    = "A"

  alias {
    name                   = data.aws_lb.ecs_express[0].dns_name
    zone_id                = data.aws_lb.ecs_express[0].zone_id
    evaluate_target_health = true
  }
}

# --- ALB listener rule の host-header に custom domain を追記 ---
#
# Express Mode はデフォルト listener rule (Priority 1) を Host = <payload DNS> のみマッチで作る。
# これを編集して var.domain_name もマッチさせる。
#
# Terraform で aws_lb_listener_rule リソースとして管理すると Express の動的 weight 変更と
# 差分競合するため、null_resource + AWS CLI で idempotent に追記する。
# Express 再構成で消えた場合は terraform apply で復元される。

resource "null_resource" "alb_rule_host_header" {
  count = local.custom_domain_enabled ? 1 : 0

  triggers = {
    listener_arn = data.aws_lb_listener.https[0].arn
    custom_host  = var.domain_name
    express_dns  = data.aws_lb.ecs_express[0].dns_name
  }

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    command     = <<-EOT
      set -euo pipefail
      LISTENER_ARN='${data.aws_lb_listener.https[0].arn}'
      CUSTOM='${var.domain_name}'
      RULE_ARN=$(aws elbv2 describe-rules --listener-arn "$LISTENER_ARN" --query "Rules[?Priority=='1'].RuleArn | [0]" --output text)
      if [ -z "$RULE_ARN" ] || [ "$RULE_ARN" = "None" ]; then
        echo "ERROR: Priority 1 rule not found on $LISTENER_ARN" >&2
        exit 1
      fi
      EXISTING=$(aws elbv2 describe-rules --rule-arns "$RULE_ARN" --query "Rules[0].Conditions[?Field=='host-header'].HostHeaderConfig.Values | [0]" --output json)
      if echo "$EXISTING" | grep -q "\"$CUSTOM\""; then
        echo "host-header already contains $CUSTOM, nothing to do"
        exit 0
      fi
      MERGED=$(echo "$EXISTING" | python3 -c "import json,sys; v=json.load(sys.stdin); v.append('$CUSTOM'); print(json.dumps([{'Field':'host-header','HostHeaderConfig':{'Values':v}}]))")
      echo "Adding $CUSTOM to listener rule $RULE_ARN"
      aws elbv2 modify-rule --rule-arn "$RULE_ARN" --conditions "$MERGED" > /dev/null
    EOT
  }

  depends_on = [aws_lb_listener_certificate.custom_domain]
}
