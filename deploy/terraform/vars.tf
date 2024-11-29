# AWS Region
variable "region" {
  type = string
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

locals {
  resourceName = "${var.serviceName}-${var.environment}-${var.regionShortName}"
  key = "tf/${var.environment}.tfstate"
  //region = "${var.region}"
  backendBucket = "${var.backendBucket}"
}

#   vpc_cidr = "10.10.0.0/16"
#   azs      = ["${var.region}a", "${var.region}b"]

#   public_subnets  = ["10.10.1.0/24", "10.10.2.0/24"]
#   private_subnets = ["10.10.3.0/24", "10.10.4.0/24"]
#   intra_subnets   = ["10.10.5.0/24", "10.10.6.0/24"]
# }

# module karpenter 
variable "namespace" {
  description = "The Kubernetes namespace for Karpenter deployment"
  type        = string
  default     = "karpenter"
}

variable "create_namespace" {
  description = "Boolean to create or not the namespace for Karpenter"
  type        = bool
  default     = true
}

variable "service_account_name" {
  description = "The Service Account name for Karpenter"
  type        = string
  default     = "karpenter"
}

variable "create_service_account" {
  description = "Boolean to create or not the service account"
  type        = bool
  default     = true
}

variable "replicas" {
  description = "Number of replicas"
  type        = number
  default     = 1
}

variable "set" {
  description = "Value block with custom STRING values to be merged with the values yaml."
  type = list(object({
    name  = string
    value = string
  }))
  default = null
}

variable "set_sensitive" {
  description = "Value block with custom sensitive values to be merged with the values yaml that won't be exposed in the plan's diff."
  type = list(object({
    path  = string
    value = string
  }))
  default = null
}


variable "cluster_oidc_issuer_url" {
  description = "The URL on the EKS cluster for the OpenID Connect identity provider"
  type        = string
}

variable "cluster_endpoint" {
  description = "Endpoint for your Kubernetes API server"
  type        = string
}

variable "helm_chart_version" {
  description = "The Helm chart version for Karpenter"
  type        = string
  default     = "v0.5.3"
}