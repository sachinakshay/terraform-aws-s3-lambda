# Provider configuration
provider "aws" {
  region = "us-east-1"
}

# Generate key pair
resource "tls_private_key" "key_pair" {
  algorithm = "RSA"
  rsa_bits  = 4096
}

# Create key pair in AWS
resource "aws_key_pair" "key_pair" {
  key_name   = "ec2-key-pair"
  public_key = tls_private_key.key_pair.public_key_openssh
}

# Save private key locally
resource "local_file" "private_key" {
  content  = tls_private_key.key_pair.private_key_pem
  filename = "${path.module}/ec2-key-pair.pem"
}

# Create S3 bucket
resource "aws_s3_bucket" "pem_bucket" {
  bucket = "my-pem-bucket-${random_string.random.result}"
}

# Create random string for unique bucket name
resource "random_string" "random" {
  length  = 8
  special = false
  upper   = false
}

# Enable versioning for S3 bucket
resource "aws_s3_bucket_versioning" "pem_bucket_versioning" {
  bucket = aws_s3_bucket.pem_bucket.id
  versioning_configuration {
    status = "Enabled"
  }
}

# Create VPC
resource "aws_vpc" "main" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_hostnames = true
  enable_dns_support   = true

  tags = {
    Name = "main"
  }
}

# Create public subnet
resource "aws_subnet" "public" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = "10.0.1.0/24"
  map_public_ip_on_launch = true

  tags = {
    Name = "Public Subnet"
  }
}

# Create Internet Gateway
resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id

  tags = {
    Name = "Main IGW"
  }
}

# Create route table
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }

  tags = {
    Name = "Public Route Table"
  }
}

# Associate route table with subnet
resource "aws_route_table_association" "public" {
  subnet_id      = aws_subnet.public.id
  route_table_id = aws_route_table.public.id
}

# Create security group for EC2
resource "aws_security_group" "ec2_sg" {
  name        = "ec2_security_group"
  description = "Security group for EC2 instance"
  vpc_id      = aws_vpc.main.id

  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# Create EC2 instance
resource "aws_instance" "ec2_instance" {
  ami                    = "ami-0453ec754f44f9a4a" # Update with latest Amazon Linux 2 AMI
  instance_type          = "t2.micro"
  key_name              = aws_key_pair.key_pair.key_name
  subnet_id             = aws_subnet.public.id
  vpc_security_group_ids = [aws_security_group.ec2_sg.id]

  tags = {
    Name = "EC2 Instance"
  }
}

# Upload .pem file to S3
resource "aws_s3_object" "pem_upload" {
  bucket     = aws_s3_bucket.pem_bucket.id
  key        = "ec2-key-pair.pem"
  source     = local_file.private_key.filename
  depends_on = [local_file.private_key]
}

# Create ECR repository
resource "aws_ecr_repository" "lambda_repo" {
  name         = "lambda-pem-copy-repo"
  force_delete = true
}

# Create IAM role for Lambda
resource "aws_iam_role" "lambda_role" {
  name = "lambda_pem_copy_role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = "sts:AssumeRole"
      Effect = "Allow"
      Principal = {
        Service = "lambda.amazonaws.com"
      }
    }]
  })
}

# Create IAM policy for Lambda
resource "aws_iam_role_policy" "lambda_policy" {
  name = "lambda_pem_copy_policy"
  role = aws_iam_role.lambda_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "s3:GetObject",
          "s3:PutObject",
          "ec2:DescribeInstances",
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents",
          "ec2:CreateTags"
        ]
        Resource = ["*"]
      }
    ]
  })
}

# Create Lambda function
resource "aws_lambda_function" "pem_copy" {
  function_name = "pem_copy_function"
  role          = aws_iam_role.lambda_role.arn
  package_type  = "Image"
  image_uri     = "${aws_ecr_repository.lambda_repo.repository_url}:latest"
  timeout       = 300

  environment {
    variables = {
      S3_BUCKET       = aws_s3_bucket.pem_bucket.id
      EC2_INSTANCE_ID = aws_instance.ec2_instance.id
    }
  }
}

# Create S3 bucket trigger for Lambda
resource "aws_s3_bucket_notification" "lambda_trigger" {
  bucket = aws_s3_bucket.pem_bucket.id

  lambda_function {
    lambda_function_arn = aws_lambda_function.pem_copy.arn
    events              = ["s3:ObjectCreated:*"]
    filter_suffix       = ".pem"
  }
}

# Add permission for S3 to invoke Lambda
resource "aws_lambda_permission" "s3_lambda" {
  statement_id  = "AllowS3Invoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.pem_copy.function_name
  principal     = "s3.amazonaws.com"
  source_arn    = aws_s3_bucket.pem_bucket.arn
}