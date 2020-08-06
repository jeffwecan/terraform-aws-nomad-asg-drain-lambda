output "asg_lifecycle_lambda_security_group_id" {
  description = "Security group ID associated with the lambda that responds to ASG lifecycle hook events."
  value       = aws_security_group.nomad_asg_lifecycle_handler.id
}

output "asg_lifecycle_lambda_role_arn" {
  description = "IAM role ARN associated with the lambda that responds to ASG lifecycle hook events."
  value       = aws_iam_role.nomad_asg_lifecycle_handler.arn
}
