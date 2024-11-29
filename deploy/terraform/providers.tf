terraform {
  required_providers {
    aws = {
      source = "hashicorp/aws"
      version = "~> 5.42.0" #"4.22.0"
    }
    kubernetes = ">= 2.5.0"
    helm       = ">= 2.0"
  }
  backend "s3" {
    bucket = "${local.backendBucket}"
    key    = "${local.key}"
    region = "${local.region}"
  }
}

provider "aws" {
  region = var.region
}




