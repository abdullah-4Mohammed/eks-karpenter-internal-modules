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

#add
provider "kubernetes" {
  host                   = module.eks.cluster_endpoint
  cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)

  exec {
    api_version = "client.authentication.k8s.io/v1alpha1"
    command     = "aws"
    args = [
      "eks", "get-token", 
      "--cluster-name", module.eks.cluster_name
    ]
  }
}

provider "helm" {
  kubernetes {
    host                   = module.eks.cluster_endpoint
    cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)

    exec {
      api_version = "client.authentication.k8s.io/v1alpha1"
      command     = "aws"
      args        = [
        "eks", 
        "get-token", 
        "--cluster-name", 
        module.eks.cluster_name
      ]
    }
  }
}



