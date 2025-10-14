terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.0"
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
  description = "CIDR allowed to SSH into instances"
  type        = string
  default     = "203.0.113.0/32"
}

resource "random_id" "suffix" {
  byte_length = 4
}

data "aws_availability_zones" "available" {
  state = "available"
}

data "aws_ami" "amazon_linux" {
  most_recent = true
  filter {
    name   = "name"
    values = ["amzn2-ami-hvm-*-x86_64-gp2"]
  }
  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
  owners = ["amazon"]
}

locals {
  envs = {
    dev  = "dev"
    test = "test"
    prod = "prod"
  }

  public_subnet_cidrs = {
    dev  = "10.0.1.0/24"
    test = "10.0.3.0/24"
    prod = "10.0.5.0/24"
  }

  private_subnet_cidrs = {
    dev  = "10.0.2.0/24"
    test = "10.0.4.0/24"
    prod = "10.0.6.0/24"
  }
}

resource "aws_vpc" "lab_vpc" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_support   = true
  enable_dns_hostnames = true
  tags                 = { Name = "lab-vpc" }
}

resource "aws_internet_gateway" "lab_igw" {
  vpc_id = aws_vpc.lab_vpc.id
  tags   = { Name = "lab-igw" }
}

resource "aws_route_table" "public_rt" {
  vpc_id = aws_vpc.lab_vpc.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.lab_igw.id
  }
  tags = { Name = "public-rt" }
}

resource "aws_subnet" "public" {
  for_each                = local.envs
  vpc_id                  = aws_vpc.lab_vpc.id
  cidr_block              = local.public_subnet_cidrs[each.key]
  map_public_ip_on_launch = true
  availability_zone       = data.aws_availability_zones.available.names[0]
  tags                    = { Name = "${each.key}-public-subnet" }
}

resource "aws_subnet" "private" {
  for_each          = local.envs
  vpc_id            = aws_vpc.lab_vpc.id
  cidr_block        = local.private_subnet_cidrs[each.key]
  availability_zone = data.aws_availability_zones.available.names[0]
  tags              = { Name = "${each.key}-private-subnet" }
}

resource "aws_route_table_association" "public_assoc" {
  for_each       = aws_subnet.public
  subnet_id      = each.value.id
  route_table_id = aws_route_table.public_rt.id
}

resource "aws_security_group" "env_sg" {
  for_each    = local.envs
  name        = "${each.key}-sg"
  description = "Allow HTTP and SSH for ${each.key}"
  vpc_id      = aws_vpc.lab_vpc.id

  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [var.allowed_ssh_cidr]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${each.key}-sg" }
}

resource "aws_s3_bucket" "lab_bucket" {
  bucket = "terraform-lab-bucket-${random_id.suffix.hex}"
  tags   = { Name = "terraform-lab-bucket-${random_id.suffix.hex}" }
}

resource "aws_s3_object" "index" {
  bucket       = aws_s3_bucket.lab_bucket.id
  key          = "index.html"
  content_type = "text/html"
  content      = <<HTML
<html>
  <head><title>Terraform Lab</title></head>
  <body>
    <h1>Terraform Lab</h1>
    <p>This site is backed by S3 and an EC2 instance heartbeat.</p>
    <p>Bucket: ${aws_s3_bucket.lab_bucket.bucket}</p>
  </body>
</html>
HTML
}

resource "aws_dynamodb_table" "lab_table" {
  name         = "terraform-lab-table-${random_id.suffix.hex}"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "id"
  attribute {
    name = "id"
    type = "S"
  }
  tags = { Name = "terraform-lab-table" }
}

data "aws_iam_policy_document" "ec2_assume_role" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "ec2_s3_role" {
  name               = "terraform-lab-ec2-s3-role-${random_id.suffix.hex}"
  assume_role_policy = data.aws_iam_policy_document.ec2_assume_role.json
}

data "aws_iam_policy_document" "s3_put" {
  statement {
    actions = ["s3:PutObject", "s3:GetObject", "s3:PutObjectAcl", "s3:ListBucket"]
    resources = [
      aws_s3_bucket.lab_bucket.arn,
      "${aws_s3_bucket.lab_bucket.arn}/*"
    ]
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

resource "aws_iam_instance_profile" "ec2_profile" {
  name = "terraform-lab-profile-${random_id.suffix.hex}"
  role = aws_iam_role.ec2_s3_role.name
}

resource "aws_instance" "lab_instance" {
  for_each                    = local.envs
  ami                         = data.aws_ami.amazon_linux.id
  instance_type               = "t3.micro"
  subnet_id                   = aws_subnet.public[each.key].id
  vpc_security_group_ids      = [aws_security_group.env_sg[each.key].id]
  associate_public_ip_address = true
  iam_instance_profile        = aws_iam_instance_profile.ec2_profile.name

  user_data = <<EOF
#!/bin/bash
yum update -y
amazon-linux-extras install -y nginx1
systemctl enable nginx
systemctl start nginx

INSTANCE_ID=\$(curl -s http://169.254.169.254/latest/meta-data/instance-id || echo "unknown")
PRIVATE_IP=\$(curl -s http://169.254.169.254/latest/meta-data/local-ipv4 || echo "unknown")
REGION=${var.aws_region}
BUCKET=${aws_s3_bucket.lab_bucket.bucket}
TABLE=${aws_dynamodb_table.lab_table.name}
ENV=${each.key}

cat > /usr/share/nginx/html/index.html <<'HTML'
<html>
  <head><title>Terraform Lab EC2</title></head>
  <body>
    <h1>Terraform Lab EC2 status</h1>
    <p>Instance: \$INSTANCE_ID</p>
    <p>Private IP: \$PRIVATE_IP</p>
    <p>Region: \$REGION</p>
    <p>Environment: \$ENV</p>
    <p>S3 bucket: \$BUCKET</p>
    <p>DynamoDB table: \$TABLE</p>
  </body>
</html>
HTML

echo "heartbeat from \$INSTANCE_ID at \$(date -u)" > /tmp/heartbeat.txt
aws s3 cp /tmp/heartbeat.txt s3://\$BUCKET/heartbeat-\$INSTANCE_ID.txt --region \$REGION || true
EOF


  tags = {
    Name        = "TerraformFreeTierLab-${each.key}"
    Environment = each.key
  }
}
