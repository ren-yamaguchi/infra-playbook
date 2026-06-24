# Map keyed by SG name: "common", plus each user-defined SG name.
output "security_group_ids" {
  value = merge(
    { "common" = aws_security_group.common.id },
    { for k, sg in aws_security_group.extra : k => sg.id },
  )
}
