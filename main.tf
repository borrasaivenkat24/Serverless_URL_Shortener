terraform {
  required_version = ">= 1.10"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
  backend "s3" {
    bucket       = "venkat-tfstate-12345" # same state bucket, different key
    key          = "url-shortener/terraform.tfstate"
    region       = "ap-south-1"
    use_lockfile = true
  }
}

provider "aws" {
  region = "ap-south-1"
}

locals {
  project = "url-shortener"
}

# ---------- Database ----------
resource "aws_dynamodb_table" "urls" {
  name         = "${local.project}-urls"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "code"

  attribute {
    name = "code"
    type = "S"
  }
}

# ---------- IAM role for Lambda ----------
resource "aws_iam_role" "lambda" {
  name = "${local.project}-lambda-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Action    = "sts:AssumeRole"
      Principal = { Service = "lambda.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "logs" {
  role       = aws_iam_role.lambda.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_iam_role_policy" "dynamodb" {
  name = "dynamodb-access"
  role = aws_iam_role.lambda.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["dynamodb:PutItem", "dynamodb:GetItem"]
      Resource = aws_dynamodb_table.urls.arn
    }]
  })
}

# ---------- Lambda functions ----------
data "archive_file" "create" {
  type        = "zip"
  source_file = "${path.module}/lambda/create.py"
  output_path = "${path.module}/build/create.zip"
}

data "archive_file" "redirect" {
  type        = "zip"
  source_file = "${path.module}/lambda/redirect.py"
  output_path = "${path.module}/build/redirect.zip"
}

resource "aws_lambda_function" "create" {
  function_name    = "${local.project}-create"
  role             = aws_iam_role.lambda.arn
  runtime          = "python3.12"
  handler          = "create.handler"
  filename         = data.archive_file.create.output_path
  source_code_hash = data.archive_file.create.output_base64sha256

  environment {
    variables = { TABLE_NAME = aws_dynamodb_table.urls.name }
  }
}

resource "aws_lambda_function" "redirect" {
  function_name    = "${local.project}-redirect"
  role             = aws_iam_role.lambda.arn
  runtime          = "python3.12"
  handler          = "redirect.handler"
  filename         = data.archive_file.redirect.output_path
  source_code_hash = data.archive_file.redirect.output_base64sha256

  environment {
    variables = { TABLE_NAME = aws_dynamodb_table.urls.name }
  }
}

# ---------- API Gateway ----------
resource "aws_apigatewayv2_api" "api" {
  name          = "${local.project}-api"
  protocol_type = "HTTP"
}

resource "aws_apigatewayv2_stage" "default" {
  api_id      = aws_apigatewayv2_api.api.id
  name        = "$default"
  auto_deploy = true
}

resource "aws_apigatewayv2_integration" "create" {
  api_id                 = aws_apigatewayv2_api.api.id
  integration_type       = "AWS_PROXY"
  integration_uri        = aws_lambda_function.create.invoke_arn
  payload_format_version = "2.0"
}

resource "aws_apigatewayv2_integration" "redirect" {
  api_id                 = aws_apigatewayv2_api.api.id
  integration_type       = "AWS_PROXY"
  integration_uri        = aws_lambda_function.redirect.invoke_arn
  payload_format_version = "2.0"
}

resource "aws_apigatewayv2_route" "create" {
  api_id    = aws_apigatewayv2_api.api.id
  route_key = "POST /create"
  target    = "integrations/${aws_apigatewayv2_integration.create.id}"
}

resource "aws_apigatewayv2_route" "redirect" {
  api_id    = aws_apigatewayv2_api.api.id
  route_key = "GET /{code}"
  target    = "integrations/${aws_apigatewayv2_integration.redirect.id}"
}

resource "aws_lambda_permission" "create" {
  statement_id  = "AllowAPIGatewayInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.create.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.api.execution_arn}/*/*"
}

resource "aws_lambda_permission" "redirect" {
  statement_id  = "AllowAPIGatewayInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.redirect.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.api.execution_arn}/*/*"
}

output "api_url" {
  value = aws_apigatewayv2_api.api.api_endpoint
}