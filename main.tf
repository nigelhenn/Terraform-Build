terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
  required_version = ">= 1.6.0"
}

provider "aws" {
  region = var.aws_region
}

variable "aws_region" {
  description = "AWS region to deploy into"
  type        = string
  default     = "eu-west-1"
}

variable "allowed_ssh_cidr" {
  description = "CIDR allowed to SSH into instance"
  type        = string
  default     = "0.0.0.0/0"
}

data "aws_vpc" "default" {
  default = true
}

data "aws_subnets" "default" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }
}

data "aws_ami" "amazon_linux" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["amzn2-ami-hvm-*-x86_64-gp2"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

resource "aws_security_group" "basic_sg" {
  name        = "basic-sg"
  description = "Allow SSH and HTTP"
  vpc_id      = data.aws_vpc.default.id

  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [var.allowed_ssh_cidr]
  }

  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "basic-sg"
  }
}

resource "aws_instance" "basic_ec2" {
  ami                         = data.aws_ami.amazon_linux.id
  instance_type               = "t3.micro"
  subnet_id                   = data.aws_subnets.default.ids[0]
  vpc_security_group_ids      = [aws_security_group.basic_sg.id]
  associate_public_ip_address = true

  user_data = <<EOF
#!/bin/bash
yum update -y
amazon-linux-extras install -y nginx1
systemctl enable nginx
systemctl start nginx
EOF

  tags = {
    Name = "BasicEC2"
  }
}

resource "aws_s3_bucket" "lab_bucket" {
  bucket = "terraform-lab-bucket-${random_id.suffix.hex}"
  acl    = "private"
}

resource "random_id" "suffix" {
  byte_length = 4
}

resource "aws_dynamodb_table" "lab_table" {
  name         = "terraform-lab-table-${random_id.suffix.hex}"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "id"

  attribute {
    name = "id"
    type = "S"
  }
}

resource "aws_iam_role" "ec2_s3_role" {
  name = "terraform-lab-ec2-s3-role-${random_id.suffix.hex}"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = {
        Service = "ec2.amazonaws.com"
      }
    }]
  })
}

resource "aws_iam_instance_profile" "ec2_profile" {
  name = "terraform-lab-profile-${random_id.suffix.hex}"
  role = aws_iam_role.ec2_s3_role.name
}

data "aws_iam_policy_document" "s3_put" {
  statement {
    actions   = ["s3:PutObject"]
    resources = ["${aws_s3_bucket.lab_bucket.arn}/*"]
  }
}

resource "aws_iam_policy" "s3_put_policy" {
  name   = "terraform-lab-s3-put-${random_id.suffix.hex}"
  policy = data.aws_iam_policy_document.s3_put.json
}

resource "aws_iam_role_policy_attachment" "attach_put" {
  role       = aws_iam_role.ec2_s3_role.name
  policy_arn = aws_iam_policy.s3_put_policy.arn
}

resource "aws_s3_object" "index" {
  bucket = aws_s3_bucket.lab_bucket.id
  key    = "index.html"
  content = "<html><body><h1>Hello from Terraform</h1></body></html>"
}

output "instance_public_ip" {
  value = aws_instance.basic_ec2.public_ip
}

output "instance_id" {
  value = aws_instance.basic_ec2.id
}
