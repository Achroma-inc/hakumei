# ネットワーク。
#
# デフォルト (var.subnet_ids 未指定): hakumei 専用 VPC + IGW + public subnet (2 AZ) +
#   route table を新規作成し、導入先の既存 VPC/subnet に一切影響を与えない自己完結構成にする。
# オプション (var.subnet_ids 指定): 顧客の既存 public subnet を流用する。
#
# ECS Express Mode は public サブネット指定で internet-facing ALB + タスク public IP を
# 構成する。outbound (CUR S3 / Bedrock / COH / CE への HTTPS) はタスク public IP 経由で
# NAT Gateway 不要 (IGW のみで完結、コスト最小)。
#
# subnet 指定時はその subnet から vpc_id を解決して SG を同じ VPC に作る
#   (異 VPC subnet 混在を precondition で検出)。

locals {
  # subnet_ids 未指定なら専用 VPC を新規作成する
  create_vpc = length(var.subnet_ids) == 0
}

# --- 専用 VPC を新規作成する経路 (create_vpc = true) ---

# 先頭 2 AZ を使う (ECS Express の ALB は最低 2 AZ を要求)
data "aws_availability_zones" "available" {
  count = local.create_vpc ? 1 : 0
  state = "available"
}

resource "aws_vpc" "this" {
  count                = local.create_vpc ? 1 : 0
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true
  tags                 = merge(var.tags, { Name = "${var.service_name}-vpc" })
}

resource "aws_internet_gateway" "this" {
  count  = local.create_vpc ? 1 : 0
  vpc_id = aws_vpc.this[0].id
  tags   = merge(var.tags, { Name = "${var.service_name}-igw" })
}

# public subnet × 2 (異なる AZ)。/16 を /24 に分割して 2 つ切り出す。
# map_public_ip_on_launch = true で Fargate タスクに public IP を自動割当 → NAT 不要。
resource "aws_subnet" "public" {
  count                   = local.create_vpc ? 2 : 0
  vpc_id                  = aws_vpc.this[0].id
  cidr_block              = cidrsubnet(var.vpc_cidr, 8, count.index)
  availability_zone       = data.aws_availability_zones.available[0].names[count.index]
  map_public_ip_on_launch = true
  tags                    = merge(var.tags, { Name = "${var.service_name}-public-${count.index}" })
}

resource "aws_route_table" "public" {
  count  = local.create_vpc ? 1 : 0
  vpc_id = aws_vpc.this[0].id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.this[0].id
  }
  tags = merge(var.tags, { Name = "${var.service_name}-public-rt" })
}

resource "aws_route_table_association" "public" {
  count          = local.create_vpc ? 2 : 0
  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public[0].id
}

# --- 既存 subnet を流用する経路 (create_vpc = false) ---

# subnet 指定時、全 subnet が同一 VPC にあることを保証し、その VPC ID を SG に使う。
# 異 VPC subnet を混ぜると ECS Express service 作成時に VPC 不一致で失敗するため、
# apply 前に precondition で検出する。
data "aws_subnet" "selected" {
  for_each = local.create_vpc ? toset([]) : toset(var.subnet_ids)
  id       = each.value
}

locals {
  # 使用する subnet ID: 新規作成なら作った public subnet、指定ありならそれ
  subnet_ids = local.create_vpc ? aws_subnet.public[*].id : var.subnet_ids

  # SG を作る VPC: 新規作成なら作った VPC、指定ありなら subnet から解決した VPC
  selected_vpc_ids = toset([for s in data.aws_subnet.selected : s.vpc_id])
  vpc_id           = local.create_vpc ? aws_vpc.this[0].id : one(local.selected_vpc_ids)
}

# ECS タスク用 SG。outbound 全許可 (CUR S3 / Bedrock / COH / CE への HTTPS)。
# Express Mode が ALB SG を自動作成 + ALB → タスクの inbound を自動許可するため、
# inbound はここで定義しない (の責務分離方針)。
resource "aws_security_group" "ecs" {
  name        = "${var.service_name}-ecs-express"
  description = "hakumei ECS Express tasks - outbound HTTPS (CUR/Bedrock/COH/CE)"
  vpc_id      = local.vpc_id

  lifecycle {
    precondition {
      condition     = local.vpc_id != null
      error_message = "subnet_ids に指定された subnet が複数の VPC にまたがっている。同一 VPC の subnet のみ指定すること。"
    }
  }

  egress {
    description = "All outbound (CUR S3 / Bedrock / COH / CE over HTTPS)"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = var.tags
}
