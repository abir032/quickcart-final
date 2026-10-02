output "certificate_arn" {
  description = "The issued certificate. Read from the validation, so it only exists once the certificate is ready."
  value       = aws_acm_certificate_validation.this.certificate_arn
}
