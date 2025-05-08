terraform {
  required_version = ">= 1.11.4"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "5.97.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "3.4.3"
    }
  }
}

# 東京リージョンで S3／Route53、us-east-1 で ACM を使います
provider "aws" {
  region = "ap-northeast-1"
}

provider "aws" {
  alias  = "us_east_1"
  region = "us-east-1"
}

provider "random" {}

variable "domain_name" {
  description = "CloudFront で使うドメイン (例: example.com)"
  type        = string
}

variable "fallback_domain" {
  type        = string
  description = "マッピングなし時にリダイレクトする新ドメイン (例: new-domain.example.com)"
}

variable "mapping_file" {
  description = "redirect マッピングを含む JSON ファイルパス"
  type        = string
  default     = "mapping.json"
}

locals {
  redirect_mappings = jsondecode(file(var.mapping_file))
}

resource "random_id" "suffix" {
  byte_length = 4
}

# ──────────────
# Route53 Hosted Zone を Terraform で作成
# ──────────────
resource "aws_route53_zone" "zone" {
  name = var.domain_name
}

# ──────────────
# ACM 証明書 (DNS 検証) — CloudFront 用 (us-east-1)
# ──────────────
resource "aws_acm_certificate" "cert" {
  provider          = aws.us_east_1
  domain_name       = var.domain_name
  validation_method = "DNS"

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_route53_record" "cert_validation" {
  for_each = {
    for dvo in aws_acm_certificate.cert.domain_validation_options :
    dvo.domain_name => {
      name   = dvo.resource_record_name
      record = dvo.resource_record_value
      type   = dvo.resource_record_type
    }
  }

  zone_id = aws_route53_zone.zone.zone_id
  name    = each.value.name
  type    = each.value.type
  records = [each.value.record]
  ttl     = 60
}

resource "aws_acm_certificate_validation" "cert" {
  provider                = aws.us_east_1
  certificate_arn         = aws_acm_certificate.cert.arn
  validation_record_fqdns = [for rec in aws_route53_record.cert_validation : rec.fqdn]
}

# ──────────────
# S3 バケット (静的ウェブサイトホスティング用)
# ──────────────
resource "aws_s3_bucket" "redirect" {
  bucket        = "${var.domain_name}-redirect-${random_id.suffix.hex}"
  force_destroy = true

  tags = {
    Name = "redirect-bucket"
  }
}

resource "aws_s3_bucket_ownership_controls" "redirect" {
  bucket = aws_s3_bucket.redirect.id
  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

resource "aws_s3_bucket_public_access_block" "redirect" {
  bucket = aws_s3_bucket.redirect.id

  block_public_acls       = false
  block_public_policy     = false
  ignore_public_acls      = false
  restrict_public_buckets = false
}

resource "aws_s3_bucket_policy" "redirect" {
  bucket = aws_s3_bucket.redirect.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "PublicReadGetObject"
      Effect    = "Allow"
      Principal = "*"
      Action    = "s3:GetObject"
      Resource  = "${aws_s3_bucket.redirect.arn}/*"
    }]
  })
}

resource "aws_s3_bucket_website_configuration" "redirect" {
  bucket = aws_s3_bucket.redirect.id

  index_document {
    suffix = "index.html"
  }

  error_document {
    key = "error.html"
  }

  routing_rule {
    condition {
      http_error_code_returned_equals = "404"
    }
    redirect {
      host_name        = var.fallback_domain
      protocol         = "https"
      replace_key_with = ""  # ルートへ飛ばす
    }
  }
}

# JSON マッピングから S3 オブジェクトを一括作成
resource "aws_s3_object" "redirects" {
  for_each = local.redirect_mappings

  bucket           = aws_s3_bucket.redirect.id
  key              = each.key
  website_redirect = each.value
  content          = ""   # 0バイトオブジェクト
}

# ──────────────
# CloudFront Distribution
# ──────────────
resource "aws_cloudfront_distribution" "cdn" {
  enabled             = true
  is_ipv6_enabled     = true
  comment             = "redirect for ${var.domain_name}"
  default_root_object = ""

  origin {
    origin_id   = "s3-website"
    domain_name = "${aws_s3_bucket.redirect.bucket}.s3-website-ap-northeast-1.amazonaws.com"

    custom_origin_config {
      http_port              = 80
      https_port             = 443
      origin_protocol_policy = "http-only"
      origin_ssl_protocols   = ["TLSv1.2"]
    }
  }

  default_cache_behavior {
    target_origin_id       = "s3-website"
    viewer_protocol_policy = "redirect-to-https"
    allowed_methods        = ["GET", "HEAD"]
    cached_methods         = ["GET", "HEAD"]
    forwarded_values {
      query_string = false
      cookies {
        forward = "none"
      }
    }
  }

  aliases = [var.domain_name]

  viewer_certificate {
    acm_certificate_arn      = aws_acm_certificate.cert.arn
    ssl_support_method       = "sni-only"
    minimum_protocol_version = "TLSv1.2_2021"
  }

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  tags = {
    Name = "redirect-cdn"
  }
}

# ──────────────
# Route53 Alias レコード (apex) を CloudFront に向ける
# ──────────────
resource "aws_route53_record" "cdn_alias" {
  zone_id = aws_route53_zone.zone.zone_id
  name    = var.domain_name
  type    = "A"

  alias {
    name                   = aws_cloudfront_distribution.cdn.domain_name
    zone_id                = aws_cloudfront_distribution.cdn.hosted_zone_id
    evaluate_target_health = false
  }
}
