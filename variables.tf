####################
# Variables
####################
variable "aws_region" {
  description = "AWS region to deploy into"
  type        = string
  default     = "eu-west-1"
}

variable "env" {
  description = "Deployment environment to use for resources (dev, test, prod)"
  type        = string
  default     = "dev"
}

variable "allowed_ssh_cidr" {
  description = "CIDR allowed to SSH into instances (replace with your IP/CIDR)"
  type        = string
  default     = "203.0.113.0/32"
}
