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


####################
# Helpers / random suffix
####################
resource "random_id" "suffix" {
  byte_length = 4
}

####################
# AMI and AZs
####################
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

####################
# Core shared resources (S3, DynamoDB, IAM)
####################
resource "aws_s3_bucket" "lab_bucket" {
  bucket = "terraform-lab-bucket-${random_id.suffix.hex}"
  acl    = "private"

  tags = {
    Name = "terraform-lab-bucket-${random_id.suffix.hex}"
  }

  lifecycle_rule {
    id      = "auto-cleanup"
    enabled = true
    expiration {
      days = 30
    }
  }
}

resource "aws_s3_bucket_object" "index" {
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

  tags = {
    Name = "terraform-lab-table"
  }
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
    actions = [
      "s3:PutObject",
      "s3:GetObject",
      "s3:PutObjectAcl",
      "s3:ListBucket"
    ]
    resources = [
      aws_s3_bucket.lab_bucket.arn,
      "${aws_s3_bucket.lab_bucket.arn}/*"
    ]
  }
}

resource "aws_iam_policy" "s3_put_policy" {
  name        = "terraform-lab-s3-put-${random_id.suffix.hex}"
  description = "Allow put/get to the lab bucket"
  policy      = data.aws_iam_policy_document.s3_put.json
}

resource "aws_iam_role_policy_attachment" "attach_put" {
  role       = aws_iam_role.ec2_s3_role.name
  policy_arn = aws_iam_policy.s3_put_policy.arn
}

resource "aws_iam_instance_profile" "ec2_profile" {
  name = "terraform-lab-profile-${random_id.suffix.hex}"
  role = aws_iam_role.ec2_s3_role.name
}

####################
# Per-environment networks (dev, test, prod)
####################
locals {
  envs = ["dev", "test", "prod"]
}

resource "aws_vpc" "env_vpc" {
  for_each             = toset(local.envs)
  cidr_block           = cidrsubnet("10.0.0.0/16", 8, index(local.envs, each.key))
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = {
    Name = "${each.key}-vpc-${random_id.suffix.hex}"
  }
}

resource "aws_subnet" "env_subnet" {
  for_each                = aws_vpc.env_vpc
  vpc_id                  = each.value.id
  cidr_block              = cidrsubnet(each.value.cidr_block, 8, 0) # first /24 in each VPC
  availability_zone       = data.aws_availability_zones.available.names[0]
  map_public_ip_on_launch = true

  tags = {
    Name = "${each.key}-public-subnet-${random_id.suffix.hex}"
  }
}

resource "aws_internet_gateway" "env_igw" {
  for_each = aws_vpc.env_vpc
  vpc_id   = each.value.id

  tags = {
    Name = "${each.key}-igw-${random_id.suffix.hex}"
  }
}

resource "aws_route_table" "env_rt" {
  for_each = aws_vpc.env_vpc
  vpc_id   = each.value.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.env_igw[each.key].id
  }

  tags = {
    Name = "${each.key}-rt-${random_id.suffix.hex}"
  }
}

resource "aws_route_table_association" "env_rta" {
  for_each       = aws_subnet.env_subnet
  subnet_id      = each.value.id
  route_table_id = aws_route_table.env_rt[each.key].id
}

####################
# Environment security groups
####################
resource "aws_security_group" "env_sg" {
  for_each    = aws_vpc.env_vpc
  name        = "${each.key}-sg-${random_id.suffix.hex}"
  description = "Security group for ${each.key} environment"
  vpc_id      = each.value.id

  ingress {
    description = "HTTP"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "SSH from allowed CIDR"
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

  tags = {
    Name = "${each.key}-sg"
  }
}

####################
# Selected environment lookups
####################
locals {
  selected_vpc_id    = aws_vpc.env_vpc[var.env].id
  selected_subnet_id = aws_subnet.env_subnet[var.env].id
  selected_sg_id     = aws_security_group.env_sg[var.env].id
}

####################
# EC2 instance (in selected env)
####################
resource "aws_instance" "free_ec2" {
  ami                    = data.aws_ami.amazon_linux.id
  instance_type          = "t3.micro"
  iam_instance_profile   = aws_iam_instance_profile.ec2_profile.name
  subnet_id              = local.selected_subnet_id
  vpc_security_group_ids = [local.selected_sg_id]
  associate_public_ip_address = true

  user_data = <<EOF
#!/bin/bash
set -e
yum update -y
amazon-linux-extras install -y nginx1
systemctl enable nginx
systemctl start nginx

INSTANCE_ID=\$(curl -s http://169.254.169.254/latest/meta-data/instance-id || echo "unknown")
PRIVATE_IP=\$(curl -s http://169.254.169.254/latest/meta-data/local-ipv4 || echo "unknown")
REGION=${var.aws_region}
BUCKET=${aws_s3_bucket.lab_bucket.bucket}
TABLE=${aws_dynamodb_table.lab_table.name}
ENV=${var.env}

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
    Name = "TerraformFreeTierLab-${var.env}-${random_id.suffix.hex}"
  }
}


####################
# Outputs
####################
output "active_environment" {
  description = "Selected environment"
  value       = var.env
}

output "instance_public_ip" {
  description = "Public IP of the EC2 instance (selected environment)"
  value       = aws_instance.free_ec2.public_ip
}

output "s3_bucket" {
  description = "S3 bucket name"
  value       = aws_s3_bucket.lab_bucket.bucket
}

output "s3_index_url" {
  description = "S3 object URL for index (not static website)"
  value       = "https://${aws_s3_bucket.lab_bucket.bucket}.s3.${var.aws_region}.amazonaws.com/index.html"
}

output "dynamodb_table" {
  description = "DynamoDB table name"
  value       = aws_dynamodb_table.lab_table.name
}

output "vpc_ids" {
  description = "Map of VPC ids per environment"
  value       = { for k, v in aws_vpc.env_vpc : k => v.id }
}

output "subnet_ids" {
  description = "Map of subnet ids per environment"
  value       = { for k, v in aws_subnet.env_subnet : k => v.id }
}

output "security_group_ids" {
  description = "Map of SG ids per environment"
  value       = { for k, v in aws_security_group.env_sg : k => v.id }
}
