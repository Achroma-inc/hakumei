# ノート機能 (日次運用メモ) を S3 に永続化する。
#
# 配布物では ECS タスクがインメモリでノートを保持していたため、の日次自動更新
# (タスク再デプロイ) のたびに全ノートが消えていた。
#
# アプリ側 (src/lib/notes/store.ts) は `NOTES_S3_BUCKET` env が設定されていれば S3 へ
# 書き、未設定なら Map インメモリ fallback というデュアル実装になっている。本配布物は
# このバケットを作って env に注入する責務だけ持つ (アプリのコード変更ゼロ)。
#
# バケットは public block ALL + SSE-S3 + versioning + 旧バージョン 30 日 expire で
# 安全側に倒す。destroy 時にユーザーが手動で空にしなくて済むよう force_destroy = true。

resource "aws_s3_bucket" "notes" {
  # 名前は AWS アカウント ID を含めてグローバル衝突を回避。本番 (hakumei-notes-361691197462)
  # と同じ命名規約。バケット名は 63 文字以内・小文字英数字 + ハイフン制約。
  bucket = "${var.service_name}-notes-${var.aws_account_id}"

  # ノートは個人運用メモで destroy 時にユーザーが手動で空にする手間を増やしたくない。
  # 業務影響大の本番データではないため force_destroy で割り切る。
  force_destroy = true

  tags = var.tags
}

# 所有権制御: BucketOwnerEnforced で ACL を完全無効化し、IAM ポリシーのみで権限管理する
# (AWS 公式が 2023 年以降の新規バケットで推奨)。
resource "aws_s3_bucket_ownership_controls" "notes" {
  bucket = aws_s3_bucket.notes.id

  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

# 公開ブロック (誤って public 化されるのを完全に防ぐ)
resource "aws_s3_bucket_public_access_block" "notes" {
  bucket                  = aws_s3_bucket.notes.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# サーバーサイド暗号化 (SSE-S3 / AES256)。KMS を使うと顧客側で KMS 鍵の管理運用が
# 発生するためここでは AES256 で十分とする (ノートは個人運用メモで機微度低)。
resource "aws_s3_bucket_server_side_encryption_configuration" "notes" {
  bucket = aws_s3_bucket.notes.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

# バージョニング (誤削除復元)。
resource "aws_s3_bucket_versioning" "notes" {
  bucket = aws_s3_bucket.notes.id

  versioning_configuration {
    status = "Enabled"
  }
}

# ライフサイクル: 旧バージョン (上書き or 削除で残ったもの) を 30 日後に完全削除。
# ストレージ膨張を防ぐ。直近 30 日以内なら誤削除復元が可能。
# current バージョン (現在のノート本体) には expire を設けない (無期限保持)。
resource "aws_s3_bucket_lifecycle_configuration" "notes" {
  bucket = aws_s3_bucket.notes.id

  # バージョニング有効化を待ってからルールを設定する。
  depends_on = [aws_s3_bucket_versioning.notes]

  rule {
    id     = "expire-noncurrent-versions"
    status = "Enabled"

    # filter なしのルールは provider 5.x 以降でエラーになるため空 filter を明示。
    filter {}

    noncurrent_version_expiration {
      noncurrent_days = 30
    }
  }
}
