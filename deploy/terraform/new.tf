provider "aws" {
  region              = var.region
  allowed_account_ids = [var.aws_account_id]
}

provider "aws" {
  region = "us-east-1"
  alias  = "virginia"
}

provider "kubernetes" {
  host                   = aws_eks_cluster.main.endpoint
  cluster_ca_certificate = base64decode(aws_eks_cluster.main.certificate_authority[0].data)
  token                  = data.aws_eks_cluster_auth.main.token
 
}

provider "helm" {
  kubernetes {
    host                   = aws_eks_cluster.main.endpoint
    cluster_ca_certificate = base64decode(aws_eks_cluster.main.certificate_authority[0].data)

    exec {
      api_version = "client.authentication.k8s.io/v1beta1"
      command     = "aws"
      args = ["eks", "get-token", "--cluster-name", aws_eks_cluster.main.name]
    }
  }
}

provider "kubectl" {
  apply_retry_count      = 5
  host                   = aws_eks_cluster.main.endpoint
  cluster_ca_certificate = base64decode(aws_eks_cluster.main.certificate_authority[0].data)
  load_config_file       = false

  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    args = ["eks", "get-token", "--cluster-name", aws_eks_cluster.main.name]
  }
}

terraform {
  backend "s3" {
    bucket = local.backendBucket
    region = local.region
    key    = local.key
  }

  required_providers {
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
    }
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    kubectl = {
      source  = "gavinbunney/kubectl"
      version = "~> 1.14"
    }
  }
}


# Declare the aws_eks_cluster_auth data source
data "aws_eks_cluster_auth" "main" {
  name = var.cluster_name

  depends_on = [
    aws_eks_cluster.main
  ]
}

# Declare the aws_eks_cluster data source
data "aws_eks_cluster" "main" {
  name = var.cluster_name

  depends_on = [
    aws_eks_cluster.main
  ]
}


######################################
# VPC Resources
resource "aws_vpc" "main" {
  cidr_block = "10.0.0.0/16"
  
  enable_dns_hostnames = true
  enable_dns_support   = true

  tags = {
    Name = "karpenter-eks-vpc"
  }
  
}

resource "aws_subnet" "private" {
  count             = 3
  vpc_id            = aws_vpc.main.id
  cidr_block        = "10.0.${count.index + 1}.0/24"
  availability_zone = "eu-west-2${["a", "b", "c"][count.index]}"

  tags = {
    "kubernetes.io/role/internal-elb"  = "1"
    "karpenter.sh/discovery"           = "karpenter-eks"
  }
}

resource "aws_subnet" "public" {
  count             = 3
  vpc_id            = aws_vpc.main.id
  cidr_block        = "10.0.${count.index + 101}.0/24"
  availability_zone = "eu-west-2${["a", "b", "c"][count.index]}"

  tags = {
    "kubernetes.io/role/elb" = "1"
  }
}

resource "aws_subnet" "intra" {
  count             = 3
  vpc_id            = aws_vpc.main.id
  cidr_block        = "10.0.${count.index + 104}.0/24"
  availability_zone = "eu-west-2${["a", "b", "c"][count.index]}"
}

# Internet Gateway
resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id

  tags = {
    Name = "karpenter-eks-igw"
  }
}

# NAT Gateway
resource "aws_eip" "nat" {
  domain = "vpc"
}

resource "aws_nat_gateway" "main" {
  allocation_id = aws_eip.nat.id
  subnet_id     = aws_subnet.public[0].id
}

# Route Tables
resource "aws_route_table" "private" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.main.id
  }
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }
}

# Route Table Associations
resource "aws_route_table_association" "private" {
  count          = 3
  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private.id
}

resource "aws_route_table_association" "public" {
  count          = 3
  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

# EKS Cluster IAM Role
resource "aws_iam_role" "eks_cluster" {
  name = "eks-cluster-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "eks.amazonaws.com"
        }
      }
    ]
  })
}

# EKS Cluster IAM Role Policy Attachments
resource "aws_iam_role_policy_attachment" "eks_cluster_policy" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSClusterPolicy"
  role       = aws_iam_role.eks_cluster.name
}

resource "aws_iam_role_policy_attachment" "eks_vpc_resource_controller" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSVPCResourceController"
  role       = aws_iam_role.eks_cluster.name
}

# EKS Cluster Security Group
resource "aws_security_group" "eks_cluster" {
  name        = "eks-cluster-sg"
  description = "Cluster communication with worker nodes"
  vpc_id      = aws_vpc.main.id

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "eks-cluster-sg"
  }
}

# EKS Cluster
resource "aws_eks_cluster" "main" {
  name     = var.cluster_name
  role_arn = aws_iam_role.eks_cluster.arn
  version  = "1.30"

  vpc_config {
    subnet_ids              = concat(aws_subnet.private[*].id, aws_subnet.intra[*].id)
    security_group_ids      = [aws_security_group.eks_cluster.id]
    endpoint_public_access  = true
  }

  # Ensure the IAM Role has proper permissions before creating the cluster
  depends_on = [
    aws_iam_role_policy_attachment.eks_cluster_policy,
    aws_iam_role_policy_attachment.eks_vpc_resource_controller
  ]
}

# EKS Addons
resource "aws_eks_addon" "coredns" {
  cluster_name = aws_eks_cluster.main.name
  addon_name   = "coredns"
}

resource "aws_eks_addon" "kube_proxy" {
  cluster_name = aws_eks_cluster.main.name
  addon_name   = "kube-proxy"
}

resource "aws_eks_addon" "vpc_cni" {
  cluster_name = aws_eks_cluster.main.name
  addon_name   = "vpc-cni"
}

resource "aws_eks_addon" "pod_identity_agent" {
  cluster_name = aws_eks_cluster.main.name
  addon_name   = "eks-pod-identity-agent"
}

# Node Group IAM Role
resource "aws_iam_role" "eks_node_group" {
  name = "eks-node-group-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "ec2.amazonaws.com"
        }
      }
    ]
  })
}

# Node Group IAM Role Policy Attachments
resource "aws_iam_role_policy_attachment" "eks_worker_node_policy" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy"
  role       = aws_iam_role.eks_node_group.name
}

resource "aws_iam_role_policy_attachment" "eks_cni_policy" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy"
  role       = aws_iam_role.eks_node_group.name
}

resource "aws_iam_role_policy_attachment" "ecr_read_only" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
  role       = aws_iam_role.eks_node_group.name
}

# Node Group
resource "aws_eks_node_group" "karpenter" {
  cluster_name    = aws_eks_cluster.main.name
  node_group_name = "karpenter"
  node_role_arn   = aws_iam_role.eks_node_group.arn
  subnet_ids      = aws_subnet.private[*].id

  scaling_config {
    desired_size = 2
    max_size     = 10
    min_size     = 2
  }

  ami_type       = "AL2023_x86_64_STANDARD"
  instance_types = ["m5.large"]

  taint {
    key    = "CriticalAddonsOnly"
    value  = "true"
    effect = "NO_SCHEDULE"
  }

  depends_on = [
    aws_iam_role_policy_attachment.eks_worker_node_policy,
    aws_iam_role_policy_attachment.eks_cni_policy,
    aws_iam_role_policy_attachment.ecr_read_only
  ]
}

# Karpenter Controller IAM Role
resource "aws_iam_role" "karpenter_controller" {
  name = "karpenter-controller-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Federated = aws_iam_openid_connect_provider.eks_oidc.arn
        }
        Action = "sts:AssumeRoleWithWebIdentity"
        Condition = {
          StringEquals = {
            "${aws_iam_openid_connect_provider.eks_oidc.url}:sub" = "system:serviceaccount:karpenter:karpenter"
          }
        }
      }
    ]
  })
  depends_on = [
    aws_iam_openid_connect_provider.eks_oidc
  ]
}


resource "aws_iam_role_policy" "karpenter_controller" {
  name = "karpenter-controller-policy"
  role = aws_iam_role.karpenter_controller.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "ec2:CreateLaunchTemplate",
          "ec2:CreateFleet",
          "ec2:RunInstances",
          "ec2:DescribeInstances",
          "ec2:DescribeInstanceTypes",
          "ec2:DescribeRouteTables",
          "ec2:DescribeSecurityGroups",
          "ec2:DescribeSubnets",
          "ec2:DescribeVpcs",
          "ec2:DeleteLaunchTemplate",
          "ec2:TerminateInstances",
          "ec2:DescribeInstanceTypeOfferings",
          "ec2:DescribeLaunchTemplates",
          "ec2:CreateTags",
          "ec2:DeleteTags",
          "ec2:DescribeSpotPriceHistory",
          "pricing:GetProducts",
          "ssm:GetParameter",
          "iam:PassRole",
          "ec2:DescribeImages",
          "ec2:DescribeSpotInstanceRequests"
        ]
        Resource = "*"
      }
    ]
  })
}
############
# resource "aws_eks_addon" "ebs_csi_driver" {
#   cluster_name             = aws_eks_cluster.main.name
#   addon_name              = "aws-ebs-csi-driver"
#   addon_version           = "v1.25.0"
#   service_account_role_arn = aws_iam_role.ebs_csi_driver.arn
# }

resource "aws_iam_instance_profile" "karpenter_instance_profile" {
  name = "KarpenterNodeInstanceProfile"
  role = aws_iam_role.eks_node_group.name
}
###############
data "tls_certificate" "eks_oidc" {
  url = aws_eks_cluster.main.identity[0].oidc[0].issuer
}
# OIDC Provider using the TLS certificate's SHA1 fingerprint
resource "aws_iam_openid_connect_provider" "eks_oidc" {
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = [data.tls_certificate.eks_oidc.certificates[0].sha1_fingerprint]
  url             = aws_eks_cluster.main.identity[0].oidc[0].issuer
}
##################

#sqs setup
# Create SQS Queue for Karpenter Interruption Events
resource "aws_sqs_queue" "karpenter_interruption_queue" {
  name = "karpenter-interruption-queue"
  
  # Optional: Configure queue properties
  visibility_timeout_seconds = 300
  message_retention_seconds  = 1209600  # 14 days
  
  tags = {
    Name        = "Karpenter Interruption Queue"
    ManagedBy   = "Terraform"
    Cluster     = var.cluster_name
  }
}

resource "aws_cloudwatch_event_rule" "spot_interruption" {
  name        = "capture-spot-interruption"
  description = "Capture EC2 Spot Instance Interruption Warnings"

  event_pattern = jsonencode({
    source      = ["aws.ec2"]
    detail-type = ["EC2 Spot Instance Interruption Warning"]
  })
}

resource "aws_cloudwatch_event_target" "spot_interruption" {
  rule      = aws_cloudwatch_event_rule.spot_interruption.name
  target_id = "SendToSQS"
  arn       = aws_sqs_queue.karpenter_interruption_queue.arn
}
# IAM Policy to allow Karpenter to use the SQS Queue
resource "aws_iam_role_policy" "karpenter_sqs_policy" {
  name = "karpenter-sqs-policy"
  role = aws_iam_role.karpenter_controller.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "sqs:DeleteMessage",
          "sqs:GetQueueAttributes",
          "sqs:GetQueueUrl",
          "sqs:ReceiveMessage"
        ]
        Resource = aws_sqs_queue.karpenter_interruption_queue.arn
      }
    ]
  })
}


###############################################################################
# Karpenter
###############################################################################
module "karpenter" {
  source = "terraform-aws-modules/eks/aws//modules/karpenter"

  cluster_name = module.eks.cluster_name

  enable_v1_permissions = true

  enable_pod_identity             = true
  create_pod_identity_association = true

  # Attach additional IAM policies to the Karpenter node IAM role
  node_iam_role_additional_policies = {
    AmazonSSMManagedInstanceCore = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
  }
}

###############################################################################
# Karpenter Helm
###############################################################################
resource "helm_release" "karpenter" {
  namespace           = "kube-system"
  name                = "karpenter"
  repository          = "oci://public.ecr.aws/karpenter"
  repository_username = data.aws_ecrpublic_authorization_token.token.user_name
  repository_password = data.aws_ecrpublic_authorization_token.token.password
  chart               = "karpenter"
  version             = "1.0.0"
  wait                = false

  values = [
    <<-EOT
    serviceAccount:
      name: ${module.karpenter.service_account}
    settings:
      clusterName: ${module.eks.cluster_name}
      clusterEndpoint: ${module.eks.cluster_endpoint}
      interruptionQueue: ${module.karpenter.queue_name}
    EOT
  ]
}

###############################################################################
# Karpenter Kubectl
###############################################################################
resource "kubectl_manifest" "karpenter_node_pool" {
  yaml_body = <<-YAML
    apiVersion: karpenter.sh/v1beta1
    kind: NodePool
    metadata:
      name: default
    spec:
      template:
        spec:
          nodeClassRef:
            name: default
          requirements:
            - key: "karpenter.k8s.aws/instance-category"
              operator: In
              values: ["c", "m", "r"]
            - key: "karpenter.k8s.aws/instance-cpu"
              operator: In
              values: ["4", "8", "16", "32"]
            - key: "karpenter.k8s.aws/instance-hypervisor"
              operator: In
              values: ["nitro"]
            - key: "karpenter.k8s.aws/instance-generation"
              operator: Gt
              values: ["2"]
      limits:
        cpu: 1000
      disruption:
        consolidationPolicy: WhenEmpty
        consolidateAfter: 30s
  YAML

  depends_on = [
    kubectl_manifest.karpenter_node_class
  ]
}

resource "kubectl_manifest" "karpenter_node_class" {
  yaml_body = <<-YAML
    apiVersion: karpenter.k8s.aws/v1beta1
    kind: EC2NodeClass
    metadata:
      name: default
    spec:
      amiFamily: AL2023
      role: ${module.karpenter.node_iam_role_name}
      subnetSelectorTerms:
        - tags:
            karpenter.sh/discovery: ${module.eks.cluster_name}
      securityGroupSelectorTerms:
        - tags:
            karpenter.sh/discovery: ${module.eks.cluster_name}
      tags:
        karpenter.sh/discovery: ${module.eks.cluster_name}
  YAML

  depends_on = [
    helm_release.karpenter
  ]
}

###############################################################################
# Inflate deployment
###############################################################################
resource "kubectl_manifest" "karpenter_example_deployment" {
  yaml_body = <<-YAML
    apiVersion: apps/v1
    kind: Deployment
    metadata:
      name: inflate
    spec:
      replicas: 0
      selector:
        matchLabels:
          app: inflate
      template:
        metadata:
          labels:
            app: inflate
        spec:
          terminationGracePeriodSeconds: 0
          containers:
            - name: inflate
              image: public.ecr.aws/eks-distro/kubernetes/pause:3.7
              resources:
                requests:
                  cpu: 1
  YAML

  depends_on = [
    helm_release.karpenter
  ]
}
# ############

# # Example Inflate Deployment
# resource "kubernetes_deployment" "inflate" {
#   metadata {
#     name = "inflate"
#   }

#   spec {
#     replicas = 0
#     selector {
#       match_labels = {
#         app = "inflate"
#       }
#     }

#     template {
#       metadata {
#         labels = {
#           app = "inflate"
#         }
#       }

#       spec {
#         container {
#           name  = "inflate"
#           image = "public.ecr.aws/eks-distro/kubernetes/pause:3.7"
          
#           resources {
#             requests = {
#               cpu = "1"
#             }
#           }
#         }
#         termination_grace_period_seconds = 0
#       }
#     }
#   }
# }

# ###########
# data "aws_ecrpublic_authorization_token" "token" {
#   provider = aws.virginia
# }
# #############
# resource "helm_release" "karpenter" {
#   namespace        = "karpenter"
#   create_namespace = true

#   name                = "karpenter"
#   repository          = "https://charts.karpenter.sh"  # Use the official Helm repository
#   chart               = "karpenter"
#   version             = "0.16.3"
#   wait                = false

#   values = [
#     <<-EOT
#     serviceAccount:
#       name: "karpenter"
#     settings:
#       clusterName: "${aws_eks_cluster.main.name}"
#       clusterEndpoint: "${aws_eks_cluster.main.endpoint}"
#       interruptionQueue: "${aws_sqs_queue.karpenter_interruption_queue.name}"

#     EOT
#   ]

#   set {
#     name  = "serviceAccount.annotations.eks\\.amazonaws\\.com/role-arn"
#     value = aws_iam_role.karpenter_controller.arn
#   }

#   set {
#     name  = "settings.aws.clusterName"
#     value = var.cluster_name
#   }

#   set {
#     name  = "settings.aws.defaultInstanceProfile"
#     value = "KarpenterNodeInstanceProfile"
#   }

#   set {
#     name  = "crds.create"
#     value = "true"
#   }

#   depends_on = [
#     aws_eks_cluster.main,
#     aws_eks_node_group.karpenter
#   ]
# }

# # Create the Karpenter Provisioner
# resource "kubectl_manifest" "karpenter_provisioner" {
#   yaml_body = <<-YAML
# apiVersion: karpenter.sh/v1alpha5
# kind: Provisioner
# metadata:
#   name: karpenter
#   namespace: karpenter
# spec:
#   requirements:
#     - key: kubernetes.io/arch
#       operator: In
#       values: ["amd64"]
#     - key: kubernetes.io/os
#       operator: In
#       values: ["linux"]
#     - key: karpenter.sh/capacity-type
#       operator: In
#       values: ["spot", "on-demand"]
#   limits:
#     resources:
#       cpu: 1000
#   providerRef:
#     name: default
# ---
# apiVersion: karpenter.sh/v1alpha5
# kind: AWSNodeTemplate
# metadata:
#   name: default
# spec:
#   subnetSelector:
#     karpenter.sh/discovery: "karpenter-eks"
#   securityGroupSelector:
#     karpenter.sh/discovery: "karpenter-eks"
# YAML

#   depends_on = [
#     helm_release.karpenter  # Ensure the provisioner is created after Karpenter is installed
#   ]
# }

# resource "helm_release" "karpenter" {
#   namespace        = "karpenter"
#   create_namespace = true

#   name                = "karpenter"
#   repository          = "oci://public.ecr.aws/karpenter"
#   repository_username = data.aws_ecrpublic_authorization_token.token.user_name
#   repository_password = data.aws_ecrpublic_authorization_token.token.password
#   chart               = "karpenter"
#   version             = "1.1.0"
#   wait                = false
#   ## interruptionQueue: "${aws_sqs_queue.karpenter_interruption_queue.name}"  
#   ## you can add it to the values below if you want to use the interruption queue
#   values = [
#     <<-EOT
#     serviceAccount:
#       name: "karpenter"
#     settings:
#       clusterName: "${aws_eks_cluster.main.name}"
#       clusterEndpoint: "${aws_eks_cluster.main.endpoint}"
#       interruptionQueue: "${aws_sqs_queue.karpenter_interruption_queue.name}"
      
#     EOT
#   ]

#   set {
#     name  = "serviceAccount.annotations.eks\\.amazonaws\\.com/role-arn"
#     value = aws_iam_role.karpenter_controller.arn
#   }

#   set {
#     name  = "settings.aws.clusterName"
#     value = var.cluster_name
#   }

#   set {
#     name  = "settings.aws.defaultInstanceProfile"
#     value = "KarpenterNodeInstanceProfile"
#   }

#   set {
#     name  = "crds.create"
#     value = "true"
#   }

#   depends_on = [
#     aws_eks_cluster.main,
#     aws_eks_node_group.karpenter
#   ]
# }

# # Then create the Provisioner
# resource "kubectl_manifest" "karpenter_provisioner" {
#   yaml_body = <<-YAML
# apiVersion: karpenter.sh/v1beta1
# kind: Provisioner
# metadata:
#   name: karpenter
#   namespace: karpenter
# spec:
#   requirements:
#     - key: kubernetes.io/arch
#       operator: In
#       values: ["amd64"]
#     - key: kubernetes.io/os
#       operator: In
#       values: ["linux"]
#     - key: karpenter.sh/capacity-type
#       operator: In
#       values: ["spot", "on-demand"]
#   limits:
#     resources:
#       cpu: 1000
#   providerRef:
#     name: default
# ---
# apiVersion: karpenter.sh/v1beta1
# kind: AWSNodeTemplate
# metadata:
#   name: default
# spec:
#   subnetSelector:
#     karpenter.sh/discovery: "karpenter-eks"
#   securityGroupSelector:
#     karpenter.sh/discovery: "karpenter-eks"
# YAML

#   depends_on = [
#     helm_release.karpenter  # Ensure the provisioner is created after Karpenter is installed
#   ]
# }