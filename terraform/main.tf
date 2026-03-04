terraform {
  required_version = ">= 1.5.0"

  required_providers {
    dbtcloud = {
      source  = "dbt-labs/dbtcloud"
      version = "~> 1.8"
    }
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }

  # Uncomment to store state remotely (recommended for team use)
  # backend "s3" {
  #   bucket = "your-tf-state-bucket"
  #   key    = "sportsco-project-migration/terraform.tfstate"
  #   region = "us-east-1"
  # }
}

provider "dbtcloud" {
  account_id = var.dbt_account_id
  token      = var.dbt_token
  host_url   = var.dbt_host_url
}

provider "aws" {
  region = var.aws_region
}
