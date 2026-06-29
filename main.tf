terraform {
  required_version = ">= 1.6"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    archive = {
      source  = "hashicorp/archive"
      version = "~> 2.0"
    }
  }
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project   = var.project_name
      ManagedBy = "terraform"
    }
  }
}
variable "aws_region" {
  description = "AWS region to deploy into"
  type        = string
  default     = "ap-southeast-2"
}

variable "project_name" {
  description = "Short name used to prefix all resource names"
  type        = string
  default     = "cp-resume"
}

variable "sender_email" {
  description = "SES-verified address used as the From: address on contact-form emails"
  type        = string
  # Set this in terraform.tfvars — do not commit that file
}

variable "recipient_email" {
  description = "Address that receives contact-form submissions"
  type        = string
  # Set this in terraform.tfvars
}

resource "aws_sns_topic" "billing_alerts" {
  name = "${var.project_name}-billing-alerts"
}

resource "aws_sns_topic_subscription" "billing_alerts_email" {
  topic_arn = aws_sns_topic.billing_alerts.arn
  protocol  = "email"
  endpoint  = var.sender_email
}

resource "aws_budgets_budget" "monthly_cost_alert" {
  name         = "${var.project_name}-monthly-cost-alert"
  budget_type  = "COST"
  limit_amount = "1.00"
  limit_unit   = "USD"
  time_unit    = "MONTHLY"
  time_period_start = formatdate("YYYY-MM-01_00:00", timestamp())

  notification {
    comparison_operator       = "GREATER_THAN"
    threshold                 = 1
    threshold_type            = "ABSOLUTE_VALUE"
    notification_type         = "ACTUAL"
    subscriber_sns_topic_arns = [aws_sns_topic.billing_alerts.arn]
  }
}

# ── DynamoDB visitor-counter table ─────────────────────────────────────────
# Free tier: 25 read + 25 write capacity units per month, forever.
# Provisioned at 1/1 — more than enough for a portfolio page.

resource "aws_dynamodb_table" "visitor_counter" {
  name         = "${var.project_name}-visitor-counter"
  billing_mode = "PROVISIONED"
  hash_key     = "id"

  attribute {
    name = "id"
    type = "S"
  }

  read_capacity  = 1
  write_capacity = 1
}
# ── SES email identity ──────────────────────────────────────────────────────
# Applying this resource sends a verification email to sender_email.
# You MUST click the link in that email before contact-form submissions will
# work.  Check spam if it doesn't arrive within a few minutes.
#
# SES starts in sandbox mode: you can only send TO verified addresses.
# Since the contact form only ever emails you, sandbox mode is sufficient —
# no production-access request needed.

resource "aws_ses_email_identity" "sender" {
  email = var.sender_email
}
data "aws_iam_policy_document" "lambda_assume_role" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

# ── Visitor counter role ────────────────────────────────────────────────────
resource "aws_iam_role" "visitor_counter" {
  name               = "${var.project_name}-visitor-counter-role"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume_role.json
}

resource "aws_iam_role_policy_attachment" "visitor_counter_basic" {
  role       = aws_iam_role.visitor_counter.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_iam_role_policy" "visitor_counter_dynamodb" {
  name = "dynamodb-update"
  role = aws_iam_role.visitor_counter.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["dynamodb:UpdateItem"]
      Resource = aws_dynamodb_table.visitor_counter.arn
    }]
  })
}

# ── Contact form role ───────────────────────────────────────────────────────
resource "aws_iam_role" "contact_form" {
  name               = "${var.project_name}-contact-form-role"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume_role.json
}

resource "aws_iam_role_policy_attachment" "contact_form_basic" {
  role       = aws_iam_role.contact_form.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_iam_role_policy" "contact_form_ses" {
  name = "ses-send"
  role = aws_iam_role.contact_form.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["ses:SendEmail", "ses:SendRawEmail"]
      Resource = aws_ses_email_identity.sender.arn
    }]
  })
}
# ── Zip the source files ────────────────────────────────────────────────────
data "archive_file" "visitor_counter" {
  type        = "zip"
  source_file = "${path.module}/lambda_src/lambda_visitor_counter.py"
  output_path = "${path.module}/dist/visitor_counter.zip"
}

data "archive_file" "contact_form" {
  type        = "zip"
  source_file = "${path.module}/lambda_src/lambda_contact_form.py"
  output_path = "${path.module}/dist/contact_form.zip"
}

# ── Visitor counter function ────────────────────────────────────────────────
resource "aws_lambda_function" "visitor_counter" {
  function_name    = "${var.project_name}-visitor-counter"
  role             = aws_iam_role.visitor_counter.arn
  runtime          = "python3.12"
  handler          = "lambda_visitor_counter.lambda_handler"
  filename         = data.archive_file.visitor_counter.output_path
  source_code_hash = data.archive_file.visitor_counter.output_base64sha256

  environment {
    variables = {
      TABLE_NAME     = aws_dynamodb_table.visitor_counter.name
      ALLOWED_ORIGIN = "https://${aws_cloudfront_distribution.resume.domain_name}"
    }
  }
}

# ── Contact form function ───────────────────────────────────────────────────
resource "aws_lambda_function" "contact_form" {
  function_name    = "${var.project_name}-contact-form"
  role             = aws_iam_role.contact_form.arn
  runtime          = "python3.12"
  handler          = "lambda_contact_form.lambda_handler"
  filename         = data.archive_file.contact_form.output_path
  source_code_hash = data.archive_file.contact_form.output_base64sha256

  environment {
    variables = {
      SENDER_EMAIL    = var.sender_email
      RECIPIENT_EMAIL = var.recipient_email
      SES_REGION      = var.aws_region
      ALLOWED_ORIGIN  = "https://${aws_cloudfront_distribution.resume.domain_name}"
    }
  }
}

# ── API Gateway for public access to the Lambda functions ─────────────────
resource "aws_api_gateway_rest_api" "resume" {
  name        = "${var.project_name}-api"
  description = "Public API for the resume site visitor counter and contact form"
}

resource "aws_api_gateway_resource" "visitor_counter" {
  rest_api_id = aws_api_gateway_rest_api.resume.id
  parent_id   = aws_api_gateway_rest_api.resume.root_resource_id
  path_part   = "visitor-counter"
}

resource "aws_api_gateway_resource" "contact_form" {
  rest_api_id = aws_api_gateway_rest_api.resume.id
  parent_id   = aws_api_gateway_rest_api.resume.root_resource_id
  path_part   = "contact-form"
}

resource "aws_api_gateway_method" "visitor_counter" {
  rest_api_id   = aws_api_gateway_rest_api.resume.id
  resource_id   = aws_api_gateway_resource.visitor_counter.id
  http_method   = "GET"
  authorization = "NONE"
}

resource "aws_api_gateway_method" "contact_form" {
  rest_api_id   = aws_api_gateway_rest_api.resume.id
  resource_id   = aws_api_gateway_resource.contact_form.id
  http_method   = "POST"
  authorization = "NONE"
}

resource "aws_api_gateway_method" "visitor_counter_options" {
  rest_api_id   = aws_api_gateway_rest_api.resume.id
  resource_id   = aws_api_gateway_resource.visitor_counter.id
  http_method   = "OPTIONS"
  authorization = "NONE"
}

resource "aws_api_gateway_method" "contact_form_options" {
  rest_api_id   = aws_api_gateway_rest_api.resume.id
  resource_id   = aws_api_gateway_resource.contact_form.id
  http_method   = "OPTIONS"
  authorization = "NONE"
}

resource "aws_api_gateway_integration" "visitor_counter" {
  rest_api_id             = aws_api_gateway_rest_api.resume.id
  resource_id             = aws_api_gateway_resource.visitor_counter.id
  http_method             = aws_api_gateway_method.visitor_counter.http_method
  integration_http_method = "POST"
  type                    = "AWS_PROXY"
  uri                     = aws_lambda_function.visitor_counter.invoke_arn
}

resource "aws_api_gateway_integration" "contact_form" {
  rest_api_id             = aws_api_gateway_rest_api.resume.id
  resource_id             = aws_api_gateway_resource.contact_form.id
  http_method             = aws_api_gateway_method.contact_form.http_method
  integration_http_method = "POST"
  type                    = "AWS_PROXY"
  uri                     = aws_lambda_function.contact_form.invoke_arn
}

resource "aws_api_gateway_integration" "visitor_counter_options" {
  rest_api_id = aws_api_gateway_rest_api.resume.id
  resource_id = aws_api_gateway_resource.visitor_counter.id
  http_method = aws_api_gateway_method.visitor_counter_options.http_method
  type        = "MOCK"
  request_templates = {
    "application/json" = "{\"statusCode\": 200}"
  }
}

resource "aws_api_gateway_integration" "contact_form_options" {
  rest_api_id = aws_api_gateway_rest_api.resume.id
  resource_id = aws_api_gateway_resource.contact_form.id
  http_method = aws_api_gateway_method.contact_form_options.http_method
  type        = "MOCK"
  request_templates = {
    "application/json" = "{\"statusCode\": 200}"
  }
}

resource "aws_api_gateway_method_response" "visitor_counter_options" {
  rest_api_id = aws_api_gateway_rest_api.resume.id
  resource_id = aws_api_gateway_resource.visitor_counter.id
  http_method = aws_api_gateway_method.visitor_counter_options.http_method
  status_code = "200"
  response_parameters = {
    "method.response.header.Access-Control-Allow-Headers" = true
    "method.response.header.Access-Control-Allow-Methods" = true
    "method.response.header.Access-Control-Allow-Origin"  = true
  }
}

resource "aws_api_gateway_method_response" "contact_form_options" {
  rest_api_id = aws_api_gateway_rest_api.resume.id
  resource_id = aws_api_gateway_resource.contact_form.id
  http_method = aws_api_gateway_method.contact_form_options.http_method
  status_code = "200"
  response_parameters = {
    "method.response.header.Access-Control-Allow-Headers" = true
    "method.response.header.Access-Control-Allow-Methods" = true
    "method.response.header.Access-Control-Allow-Origin"  = true
  }
}

resource "aws_api_gateway_integration_response" "visitor_counter_options" {
  rest_api_id = aws_api_gateway_rest_api.resume.id
  resource_id = aws_api_gateway_resource.visitor_counter.id
  http_method = aws_api_gateway_method.visitor_counter_options.http_method
  status_code = aws_api_gateway_method_response.visitor_counter_options.status_code
  response_parameters = {
    "method.response.header.Access-Control-Allow-Headers" = "'Content-Type,X-Amz-Date,Authorization,X-Api-Key,X-Amz-Security-Token'"
    "method.response.header.Access-Control-Allow-Methods" = "'GET,OPTIONS'"
    "method.response.header.Access-Control-Allow-Origin"  = "'https://${aws_cloudfront_distribution.resume.domain_name}'"
  }
}

resource "aws_api_gateway_integration_response" "contact_form_options" {
  rest_api_id = aws_api_gateway_rest_api.resume.id
  resource_id = aws_api_gateway_resource.contact_form.id
  http_method = aws_api_gateway_method.contact_form_options.http_method
  status_code = aws_api_gateway_method_response.contact_form_options.status_code
  response_parameters = {
    "method.response.header.Access-Control-Allow-Headers" = "'Content-Type,X-Amz-Date,Authorization,X-Api-Key,X-Amz-Security-Token'"
    "method.response.header.Access-Control-Allow-Methods" = "'POST,OPTIONS'"
    "method.response.header.Access-Control-Allow-Origin"  = "'https://${aws_cloudfront_distribution.resume.domain_name}'"
  }
}

resource "aws_lambda_permission" "visitor_counter_api" {
  statement_id  = "AllowExecutionFromAPIGateway"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.visitor_counter.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_api_gateway_rest_api.resume.execution_arn}/*/*"
}

resource "aws_lambda_permission" "contact_form_api" {
  statement_id  = "AllowExecutionFromAPIGateway"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.contact_form.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_api_gateway_rest_api.resume.execution_arn}/*/*"
}

resource "aws_api_gateway_deployment" "resume" {
  rest_api_id = aws_api_gateway_rest_api.resume.id

  triggers = {
    redeployment = sha256(jsonencode([
      aws_api_gateway_resource.visitor_counter.id,
      aws_api_gateway_resource.contact_form.id,
      aws_api_gateway_method.visitor_counter.id,
      aws_api_gateway_method.contact_form.id,
      aws_api_gateway_method.visitor_counter_options.id,
      aws_api_gateway_method.contact_form_options.id,
      aws_api_gateway_integration.visitor_counter.id,
      aws_api_gateway_integration.contact_form.id,
      aws_api_gateway_integration.visitor_counter_options.id,
      aws_api_gateway_integration.contact_form_options.id,
    ]))
  }

  depends_on = [
    aws_api_gateway_integration.visitor_counter,
    aws_api_gateway_integration.contact_form,
    aws_api_gateway_integration.visitor_counter_options,
    aws_api_gateway_integration.contact_form_options,
  ]

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_api_gateway_stage" "resume" {
  deployment_id = aws_api_gateway_deployment.resume.id
  rest_api_id   = aws_api_gateway_rest_api.resume.id
  stage_name    = "prod"
}

# ── CloudFront cache invalidation on HTML change ────────────────────────────
# Runs `aws cloudfront create-invalidation` whenever the rendered HTML changes.
# Requires the AWS CLI to be installed and configured on the machine running
# terraform apply.
resource "null_resource" "invalidate_cache" {
  triggers = {
    html_hash       = md5(local.website_html)
    distribution_id = aws_cloudfront_distribution.resume.id
  }

  provisioner "local-exec" {
    interpreter = ["powershell", "-Command"]
    command     = "aws cloudfront create-invalidation --distribution-id ${aws_cloudfront_distribution.resume.id} --paths '/index.html' --region us-east-1"
  }

  depends_on = [
    aws_s3_object.index,
    aws_cloudfront_distribution.resume,
  ]
}
# ── Rendered HTML: inject Lambda URLs via templatefile() ───────────────────
# Terraform resolves the dependency chain automatically:
#   S3 bucket → CloudFront → Lambda Function URLs → templatefile → S3 object
locals {
  website_html = templatefile("${path.module}/website/index.html.tmpl", {
    visitor_counter_url = "${aws_api_gateway_stage.resume.invoke_url}/visitor-counter"
    contact_form_url    = "${aws_api_gateway_stage.resume.invoke_url}/contact-form"
  })
}

# ── S3 bucket ───────────────────────────────────────────────────────────────
resource "aws_s3_bucket" "resume" {
  # Bucket names are globally unique. Using project_name + account id suffix.
  bucket = "${var.project_name}-site-${data.aws_caller_identity.current.account_id}"
}

data "aws_caller_identity" "current" {}

resource "aws_s3_bucket_public_access_block" "resume" {
  bucket = aws_s3_bucket.resume.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_versioning" "resume" {
  bucket = aws_s3_bucket.resume.id
  versioning_configuration { status = "Enabled" }
}

# ── Bucket policy: allow CloudFront OAC to read objects ────────────────────
resource "aws_s3_bucket_policy" "resume" {
  bucket = aws_s3_bucket.resume.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid    = "AllowCloudFrontOAC"
      Effect = "Allow"
      Principal = {
        Service = "cloudfront.amazonaws.com"
      }
      Action   = "s3:GetObject"
      Resource = "${aws_s3_bucket.resume.arn}/*"
      Condition = {
        StringEquals = {
          "AWS:SourceArn" = aws_cloudfront_distribution.resume.arn
        }
      }
    }]
  })

  depends_on = [aws_s3_bucket_public_access_block.resume]
}

# ── Upload rendered index.html ──────────────────────────────────────────────
resource "aws_s3_object" "index" {
  bucket        = aws_s3_bucket.resume.id
  key           = "index.html"
  content       = local.website_html
  content_type  = "text/html; charset=utf-8"
  # etag changes whenever the content changes, triggering a re-upload + invalidation
  etag          = md5(local.website_html)
}
# ── Origin Access Control ───────────────────────────────────────────────────
resource "aws_cloudfront_origin_access_control" "resume" {
  name                              = "${var.project_name}-oac"
  description                       = "OAC for ${var.project_name} S3 origin"
  origin_access_control_origin_type = "s3"
  signing_behavior                  = "always"
  signing_protocol                  = "sigv4"
}

# ── CloudFront distribution ─────────────────────────────────────────────────
resource "aws_cloudfront_distribution" "resume" {
  enabled             = true
  is_ipv6_enabled     = true
  default_root_object = "index.html"
  comment             = var.project_name

  # PriceClass_200 covers US, EU, Asia, and Oceania (including AU edge
  # locations — closest to Auckland). All within the 1 TB/month free tier.
  price_class = "PriceClass_200"

  origin {
    domain_name              = aws_s3_bucket.resume.bucket_regional_domain_name
    origin_id                = "s3-${aws_s3_bucket.resume.id}"
    origin_access_control_id = aws_cloudfront_origin_access_control.resume.id
  }

  default_cache_behavior {
    allowed_methods        = ["GET", "HEAD"]
    cached_methods         = ["GET", "HEAD"]
    target_origin_id       = "s3-${aws_s3_bucket.resume.id}"
    viewer_protocol_policy = "redirect-to-https"
    compress               = true

    forwarded_values {
      query_string = false
      cookies { forward = "none" }
    }

    min_ttl     = 0
    default_ttl = 3600   # 1 hour; invalidations keep this fresh on deploy
    max_ttl     = 86400  # 1 day
  }

  # Return index.html on 403/404 so direct URL loads work
  custom_error_response {
    error_code            = 403
    response_code         = 200
    response_page_path    = "/index.html"
    error_caching_min_ttl = 10
  }
  custom_error_response {
    error_code            = 404
    response_code         = 200
    response_page_path    = "/index.html"
    error_caching_min_ttl = 10
  }

  restrictions {
    geo_restriction { restriction_type = "none" }
  }

  viewer_certificate {
    cloudfront_default_certificate = true
  }
}
output "resume_url" {
  description = "Your live resume URL"
  value       = "https://${aws_cloudfront_distribution.resume.domain_name}"
}

output "s3_bucket_name" {
  description = "S3 bucket holding the site files"
  value       = aws_s3_bucket.resume.id
}

output "cloudfront_distribution_id" {
  description = "CloudFront distribution ID (needed for manual invalidations)"
  value       = aws_cloudfront_distribution.resume.id
}

output "visitor_counter_url" {
  description = "API Gateway URL for the visitor counter"
  value       = "${aws_api_gateway_stage.resume.invoke_url}/visitor-counter"
}

output "contact_form_url" {
  description = "API Gateway URL for the contact form"
  value       = "${aws_api_gateway_stage.resume.invoke_url}/contact-form"
}

output "ses_verification_reminder" {
  description = "Reminder about SES email verification"
  value       = "ACTION REQUIRED: check ${var.sender_email} for an AWS verification email and click the link before testing the contact form."
}
