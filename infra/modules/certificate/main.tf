# A certificate browsers trust, proved by DNS: ACM asks for a special record,
# Terraform writes it into Route 53, ACM sees it and issues the certificate.
# No email, no manual step, and it renews itself for as long as the record exists.

resource "aws_acm_certificate" "this" {
  domain_name       = var.domain_name
  validation_method = "DNS"

  # A replacement is issued and attached before the old one is removed.
  lifecycle {
    create_before_destroy = true
  }

  tags = merge(var.tags, { Name = var.domain_name })
}

resource "aws_route53_record" "validation" {
  zone_id         = var.zone_id
  name            = one([for d in aws_acm_certificate.this.domain_validation_options : d.resource_record_name])
  type            = one([for d in aws_acm_certificate.this.domain_validation_options : d.resource_record_type])
  records         = [one([for d in aws_acm_certificate.this.domain_validation_options : d.resource_record_value])]
  ttl             = 60
  allow_overwrite = true
}

# Waits until ACM has actually issued the certificate. Anything that uses the
# ARN from here can't start with a certificate that isn't ready.
resource "aws_acm_certificate_validation" "this" {
  certificate_arn         = aws_acm_certificate.this.arn
  validation_record_fqdns = [aws_route53_record.validation.fqdn]
}
