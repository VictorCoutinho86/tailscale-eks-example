data "aws_route53_zone" "platform" {
  name         = var.route53_domain_name
  private_zone = false
}

locals {
  route53_hosted_zone_arn = "arn:${data.aws_partition.current.partition}:route53:::hostedzone/${data.aws_route53_zone.platform.zone_id}"
}

resource "aws_acm_certificate" "platform" {
  domain_name       = "*.${trimsuffix(var.route53_domain_name, ".")}"
  validation_method = "DNS"

  lifecycle {
    create_before_destroy = true
  }

  tags = local.tags
}

resource "aws_route53_record" "platform_certificate_validation" {
  for_each = {
    for option in aws_acm_certificate.platform.domain_validation_options : option.domain_name => {
      name   = option.resource_record_name
      record = option.resource_record_value
      type   = option.resource_record_type
    }
  }

  allow_overwrite = true
  zone_id         = data.aws_route53_zone.platform.zone_id
  name            = each.value.name
  type            = each.value.type
  ttl             = 60
  records         = [each.value.record]
}

resource "aws_acm_certificate_validation" "platform" {
  certificate_arn = aws_acm_certificate.platform.arn

  validation_record_fqdns = [
    for record in aws_route53_record.platform_certificate_validation : record.fqdn
  ]
}
