###############################################################################
# Environment
###############################################################################
variable "region" {
    type = string
}

variable "aws_account_id" {
    type = string
}

###############################################################################
# Cluster
###############################################################################


locals {
  resourceName = "${var.serviceName}-${var.environment}-${var.regionShortName}"
  key = "tf/${var.environment}.tfstate"
  //region = "${var.region}"
  backendBucket = "${var.backendBucket}"
}


# VPC (network module) variables
variable "vpc_cidr" {
  default = "10.0.0.0/16"
}

variable "availability_zones" {
  type = list(string)
}

# EKS (eks module) variables
variable "cluster_name" {
  type = string
  
}



variable "environment" {
  type = string
}

variable "serviceName" {
  type = string
}


variable "backendBucket" {
  type = string
}

variable "regionShortName" {
  type = string
}