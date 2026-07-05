output "role_arn" {
  description = "作成した read-only ロールの ARN (動作確認の aws sts assume-role に使う)"
  value       = aws_iam_role.readonly.arn
}
