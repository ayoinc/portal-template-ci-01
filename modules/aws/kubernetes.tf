locals {
  # Current-generation x86 instance types per node size. On-demand node groups
  # use the first one; Spot node groups draw from all of them for capacity.
  node_instance_types = {
    small  = ["t3.medium", "t3a.medium"]
    medium = ["c6i.xlarge", "c6a.xlarge", "c5.xlarge"]
    large  = ["c6i.2xlarge", "c6a.2xlarge", "c5.2xlarge"]
    xlarge = ["c6i.4xlarge", "c6a.4xlarge", "c5.4xlarge"]
  }

  node_capacity_type = local.cost_optimized ? "SPOT" : "ON_DEMAND"

  create_cluster_autoscaler_role = var.enable_kubernetes && var.enable_autoscaling
  monitor_cluster                = var.enable_kubernetes && var.enable_monitoring
}

# -----------------------------------------------------------------------------
# Control plane
# -----------------------------------------------------------------------------

resource "aws_iam_role" "cluster" {
  count = var.enable_kubernetes ? 1 : 0

  name = "${var.name_prefix}-eks-cluster"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Action    = "sts:AssumeRole"
      Principal = { Service = "eks.${local.dns_suffix}" }
    }]
  })

  tags = var.tags
}

resource "aws_iam_role_policy_attachment" "cluster" {
  count = var.enable_kubernetes ? 1 : 0

  role       = aws_iam_role.cluster[0].name
  policy_arn = "arn:${local.partition}:iam::aws:policy/AmazonEKSClusterPolicy"
}

# EKS writes control-plane logs to this name; creating it first sets the
# retention and the encryption key.
resource "aws_cloudwatch_log_group" "cluster" {
  count = local.monitor_cluster ? 1 : 0

  name              = "/aws/eks/${var.name_prefix}/cluster"
  retention_in_days = local.log_retention_days
  kms_key_id        = local.kms_key_arn

  tags = var.tags
}

resource "aws_eks_cluster" "this" {
  count = var.enable_kubernetes ? 1 : 0

  name                = var.name_prefix
  role_arn            = aws_iam_role.cluster[0].arn
  version             = var.kubernetes_version
  deletion_protection = var.require_deletion_protection

  enabled_cluster_log_types = var.enable_monitoring ? ["api", "audit", "authenticator", "controllerManager", "scheduler"] : []

  access_config {
    authentication_mode                         = "API_AND_CONFIG_MAP"
    bootstrap_cluster_creator_admin_permissions = true
  }

  vpc_config {
    subnet_ids              = local.private_subnet_ids
    endpoint_private_access = true
    endpoint_public_access  = length(var.kubernetes_api_allowed_cidrs) > 0
    public_access_cidrs     = length(var.kubernetes_api_allowed_cidrs) > 0 ? var.kubernetes_api_allowed_cidrs : null
  }

  # Without a customer-managed key EKS encrypts the cluster data with a key
  # it owns.
  dynamic "encryption_config" {
    for_each = aws_kms_key.this[*].arn

    content {
      resources = ["secrets"]

      provider {
        key_arn = encryption_config.value
      }
    }
  }

  tags = var.tags

  depends_on = [
    aws_iam_role_policy_attachment.cluster,
    aws_cloudwatch_log_group.cluster,
  ]

  lifecycle {
    precondition {
      condition     = local.network_available
      error_message = local.network_required
    }
  }
}

# The private API endpoint answers inside the cluster security group only;
# this opens it to the rest of the VPC (CI runners, bastions, VPN clients).
resource "aws_vpc_security_group_ingress_rule" "cluster_api_from_network" {
  count = var.enable_kubernetes ? 1 : 0

  security_group_id = aws_eks_cluster.this[0].vpc_config[0].cluster_security_group_id
  description       = "Kubernetes API from inside the VPC"
  cidr_ipv4         = local.vpc_cidr
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443

  tags = var.tags
}

# -----------------------------------------------------------------------------
# Worker nodes
# -----------------------------------------------------------------------------

resource "aws_iam_role" "nodes" {
  count = var.enable_kubernetes ? 1 : 0

  name = "${var.name_prefix}-eks-nodes"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Action    = "sts:AssumeRole"
      Principal = { Service = "ec2.${local.dns_suffix}" }
    }]
  })

  tags = var.tags
}

resource "aws_iam_role_policy_attachment" "nodes" {
  for_each = var.enable_kubernetes ? toset([
    "AmazonEKSWorkerNodePolicy",
    "AmazonEKS_CNI_Policy",
    "AmazonEC2ContainerRegistryPullOnly",
  ]) : []

  role       = aws_iam_role.nodes[0].name
  policy_arn = "arn:${local.partition}:iam::aws:policy/${each.value}"
}

# Requires IMDSv2 and encrypts the node volumes. The hop limit of 1 keeps
# pods away from the node's instance role: workloads use EKS Pod Identity.
resource "aws_launch_template" "nodes" {
  count = var.enable_kubernetes ? 1 : 0

  name                   = "${var.name_prefix}-eks-nodes"
  description            = "Worker nodes of the ${var.name_prefix} cluster"
  update_default_version = true

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
  }

  block_device_mappings {
    device_name = "/dev/xvda"

    ebs {
      volume_size           = 50
      volume_type           = "gp3"
      encrypted             = true
      delete_on_termination = true
    }
  }

  tag_specifications {
    resource_type = "instance"

    tags = merge(var.tags, {
      Name = "${var.name_prefix}-node"
    })
  }

  tag_specifications {
    resource_type = "volume"

    tags = merge(var.tags, {
      Name = "${var.name_prefix}-node"
    })
  }

  tags = var.tags
}

resource "aws_eks_node_group" "this" {
  count = var.enable_kubernetes ? 1 : 0

  cluster_name    = aws_eks_cluster.this[0].name
  node_group_name = "default"
  node_role_arn   = aws_iam_role.nodes[0].arn
  subnet_ids      = local.private_subnet_ids

  ami_type       = "AL2023_x86_64_STANDARD"
  capacity_type  = local.node_capacity_type
  instance_types = local.cost_optimized ? local.node_instance_types[var.node_size] : slice(local.node_instance_types[var.node_size], 0, 1)

  launch_template {
    id      = aws_launch_template.nodes[0].id
    version = aws_launch_template.nodes[0].latest_version
  }

  scaling_config {
    min_size     = var.min_nodes
    max_size     = var.enable_autoscaling ? var.max_nodes : var.min_nodes
    desired_size = var.min_nodes
  }

  update_config {
    max_unavailable_percentage = 33
  }

  node_repair_config {
    enabled = true
  }

  tags = var.tags

  # Nodes need their policies, and a route to pull images, before they can join.
  depends_on = [
    aws_iam_role_policy_attachment.nodes,
    aws_route.private_nat,
  ]

  lifecycle {
    # The cluster autoscaler owns the node count between the bounds.
    ignore_changes = [scaling_config[0].desired_size]
  }
}

# -----------------------------------------------------------------------------
# Add-ons and workload identities
# -----------------------------------------------------------------------------

# Hands IAM roles to service accounts through pod identity associations.
resource "aws_eks_addon" "pod_identity_agent" {
  count = var.enable_kubernetes ? 1 : 0

  cluster_name = aws_eks_cluster.this[0].name
  addon_name   = "eks-pod-identity-agent"

  tags = var.tags

  depends_on = [aws_eks_node_group.this]
}

# Role of the Kubernetes cluster autoscaler. Deploy the autoscaler with the
# service account kube-system/cluster-autoscaler to scale the node group
# between min_nodes and max_nodes.
resource "aws_iam_role" "cluster_autoscaler" {
  count = local.create_cluster_autoscaler_role ? 1 : 0

  name = "${var.name_prefix}-cluster-autoscaler"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Action    = ["sts:AssumeRole", "sts:TagSession"]
      Principal = { Service = "pods.eks.${local.dns_suffix}" }
    }]
  })

  tags = var.tags
}

resource "aws_iam_role_policy" "cluster_autoscaler" {
  count = local.create_cluster_autoscaler_role ? 1 : 0

  name = "scale-node-groups"
  role = aws_iam_role.cluster_autoscaler[0].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "Discover"
        Effect = "Allow"
        Action = [
          "autoscaling:DescribeAutoScalingGroups",
          "autoscaling:DescribeAutoScalingInstances",
          "autoscaling:DescribeLaunchConfigurations",
          "autoscaling:DescribeScalingActivities",
          "autoscaling:DescribeTags",
          "ec2:DescribeImages",
          "ec2:DescribeInstanceTypes",
          "ec2:DescribeLaunchTemplateVersions",
          "ec2:GetInstanceTypesFromInstanceRequirements",
        ]
        Resource = "*"
      },
      {
        Sid      = "DescribeNodeGroup"
        Effect   = "Allow"
        Action   = "eks:DescribeNodegroup"
        Resource = aws_eks_node_group.this[0].arn
      },
      {
        Sid    = "ScaleOwnNodeGroups"
        Effect = "Allow"
        Action = [
          "autoscaling:SetDesiredCapacity",
          "autoscaling:TerminateInstanceInAutoScalingGroup",
        ]
        Resource = "arn:${local.partition}:autoscaling:${var.region}:${local.account_id}:autoScalingGroup:*:autoScalingGroupName/*"
        Condition = {
          StringEquals = {
            "aws:ResourceTag/k8s.io/cluster-autoscaler/${var.name_prefix}" = "owned"
          }
        }
      },
    ]
  })
}

resource "aws_eks_pod_identity_association" "cluster_autoscaler" {
  count = local.create_cluster_autoscaler_role ? 1 : 0

  cluster_name    = aws_eks_cluster.this[0].name
  namespace       = "kube-system"
  service_account = "cluster-autoscaler"
  role_arn        = aws_iam_role.cluster_autoscaler[0].arn

  tags = var.tags

  depends_on = [aws_eks_addon.pod_identity_agent]
}

# Role of the CloudWatch agent and Fluent Bit that the observability add-on
# runs on every node.
resource "aws_iam_role" "container_insights" {
  count = local.monitor_cluster ? 1 : 0

  name = "${var.name_prefix}-container-insights"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Action    = ["sts:AssumeRole", "sts:TagSession"]
      Principal = { Service = "pods.eks.${local.dns_suffix}" }
    }]
  })

  tags = var.tags
}

resource "aws_iam_role_policy_attachment" "container_insights" {
  count = local.monitor_cluster ? 1 : 0

  role       = aws_iam_role.container_insights[0].name
  policy_arn = "arn:${local.partition}:iam::aws:policy/CloudWatchAgentServerPolicy"
}

# Ships container logs and Container Insights metrics to CloudWatch.
resource "aws_eks_addon" "container_insights" {
  count = local.monitor_cluster ? 1 : 0

  cluster_name = aws_eks_cluster.this[0].name
  addon_name   = "amazon-cloudwatch-observability"

  pod_identity_association {
    role_arn        = aws_iam_role.container_insights[0].arn
    service_account = "cloudwatch-agent"
  }

  tags = var.tags

  depends_on = [
    aws_eks_addon.pod_identity_agent,
    aws_iam_role_policy_attachment.container_insights,
  ]
}
