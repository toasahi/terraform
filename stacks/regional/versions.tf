terraform {
  required_version = ">= 1.10.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 6.52.0, < 7.0.0" # >= 6.30 for aws_nat_gateway availability_mode (Regional NAT), >= 6.52 for aws_dynamodb_table key_schema
    }
    archive = {
      source  = "hashicorp/archive"
      version = ">= 2.4.0, < 3.0.0"
    }
    random = {
      source  = "hashicorp/random"
      version = ">= 3.6.0, < 4.0.0"
    }
  }

  # Partial configuration: bucket/key/region come from envs/prod/backend-<region>.hcl.
  # use_lockfile (S3 native locking, Terraform >= 1.10) replaces the DynamoDB lock table.
  backend "s3" {}
}
