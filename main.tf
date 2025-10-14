terraform {

  required_providers {

    aws = {

      source = "hashicorp/aws"

      version = "~> 5.0"

    }

  }



  required_version = ">= 1.6.0"

}



provider "aws" {

  region = var.aws_region



}

resource "aws_vpc" "main" {
  cidr_block = "10.0.0.0/16"

  tags = {
    Name = "MainVPC"
  }
}




# Fetch the latest Amazon Linux 2 AMI
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

resource "aws_instance" "free_ec2" {
  ami           = data.aws_ami.amazon_linux.id
  instance_type = "t3.micro" # Updated for Free Tier eligibility

  tags = {
    Name = "TerraformFreeTierLab"
  }
}




# Free S3 bucket

resource "aws_s3_bucket" "lab_bucket" {

  bucket = "terraform-lab-bucket-${random_id.bucket_suffix.hex}"

}



resource "random_id" "bucket_suffix" {

  byte_length = 4

}