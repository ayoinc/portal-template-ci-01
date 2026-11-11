data "aws_availability_zones" "available" {
  state = "available"

  # Leaves out Local Zones and Wavelength Zones.
  filter {
    name   = "opt-in-status"
    values = ["opt-in-not-required"]
  }
}

# The CIDR of a network passed in is needed for rules that admit the whole VPC.
data "aws_vpc" "existing" {
  count = !var.enable_networking && var.existing_network != null ? 1 : 0

  id = var.existing_network.network_id
}

locals {
  availability_zones = slice(data.aws_availability_zones.available.names, 0, var.availability_zone_count)
  subnet_count       = var.enable_networking ? var.availability_zone_count : 0

  # The VPC CIDR is cut into quarters: the first holds the public subnets (a
  # sixteenth of the VPC each), the other three are one private subnet each.
  public_subnet_cidrs  = [for i in range(var.availability_zone_count) : cidrsubnet(var.network_cidr, 4, i)]
  private_subnet_cidrs = [for i in range(var.availability_zone_count) : cidrsubnet(var.network_cidr, 2, i + 1)]

  # NAT gateways are billed per zone: one per zone for zone-independent egress,
  # a single shared one when cost is optimised outside production.
  nat_gateway_count = !var.enable_networking ? 0 : local.cost_optimized ? 1 : var.availability_zone_count

  # Tags that let Kubernetes load balancer controllers discover the subnets.
  public_subnet_role_tags  = var.enable_kubernetes ? { "kubernetes.io/role/elb" = "1" } : {}
  private_subnet_role_tags = var.enable_kubernetes ? { "kubernetes.io/role/internal-elb" = "1" } : {}

  create_flow_logs = var.require_flow_logs && local.network_available
}

# -----------------------------------------------------------------------------
# VPC and subnets
# -----------------------------------------------------------------------------

resource "aws_vpc" "this" {
  count = var.enable_networking ? 1 : 0

  cidr_block           = var.network_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = merge(var.tags, {
    Name = var.name_prefix
  })
}

# The default security group is emptied so that nothing can rely on it.
resource "aws_default_security_group" "this" {
  count = var.enable_networking ? 1 : 0

  vpc_id = aws_vpc.this[0].id

  tags = merge(var.tags, {
    Name = "${var.name_prefix}-default-unused"
  })
}

resource "aws_internet_gateway" "this" {
  count = var.enable_networking ? 1 : 0

  vpc_id = aws_vpc.this[0].id

  tags = merge(var.tags, {
    Name = var.name_prefix
  })
}

resource "aws_subnet" "public" {
  count = local.subnet_count

  vpc_id            = aws_vpc.this[0].id
  cidr_block        = local.public_subnet_cidrs[count.index]
  availability_zone = local.availability_zones[count.index]

  # Load balancers and NAT gateways get their own addresses; nothing else
  # launched here becomes public by accident.
  map_public_ip_on_launch = false

  tags = merge(var.tags, local.public_subnet_role_tags, {
    Name = "${var.name_prefix}-public-${local.availability_zones[count.index]}"
    Tier = "public"
  })
}

resource "aws_subnet" "private" {
  count = local.subnet_count

  vpc_id            = aws_vpc.this[0].id
  cidr_block        = local.private_subnet_cidrs[count.index]
  availability_zone = local.availability_zones[count.index]

  tags = merge(var.tags, local.private_subnet_role_tags, {
    Name = "${var.name_prefix}-private-${local.availability_zones[count.index]}"
    Tier = "private"
  })
}

# -----------------------------------------------------------------------------
# Routing: public subnets through the internet gateway, private through NAT
# -----------------------------------------------------------------------------

resource "aws_route_table" "public" {
  count = var.enable_networking ? 1 : 0

  vpc_id = aws_vpc.this[0].id

  tags = merge(var.tags, {
    Name = "${var.name_prefix}-public"
  })
}

resource "aws_route" "public_internet" {
  count = var.enable_networking ? 1 : 0

  route_table_id         = aws_route_table.public[0].id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.this[0].id
}

resource "aws_route_table_association" "public" {
  count = local.subnet_count

  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public[0].id
}

resource "aws_eip" "nat" {
  count = local.nat_gateway_count

  domain = "vpc"

  tags = merge(var.tags, {
    Name = "${var.name_prefix}-nat-${local.availability_zones[count.index]}"
  })

  depends_on = [aws_internet_gateway.this]
}

resource "aws_nat_gateway" "this" {
  count = local.nat_gateway_count

  allocation_id = aws_eip.nat[count.index].id
  subnet_id     = aws_subnet.public[count.index].id

  tags = merge(var.tags, {
    Name = "${var.name_prefix}-${local.availability_zones[count.index]}"
  })

  depends_on = [aws_internet_gateway.this]
}

resource "aws_route_table" "private" {
  count = local.subnet_count

  vpc_id = aws_vpc.this[0].id

  tags = merge(var.tags, {
    Name = "${var.name_prefix}-private-${local.availability_zones[count.index]}"
  })
}

resource "aws_route" "private_nat" {
  count = local.subnet_count

  route_table_id         = aws_route_table.private[count.index].id
  destination_cidr_block = "0.0.0.0/0"
  nat_gateway_id         = aws_nat_gateway.this[local.nat_gateway_count == 1 ? 0 : count.index].id
}

resource "aws_route_table_association" "private" {
  count = local.subnet_count

  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private[count.index].id
}

# Keeps S3 traffic of the private subnets on the AWS network and off the NAT.
resource "aws_vpc_endpoint" "s3" {
  count = var.enable_networking ? 1 : 0

  vpc_id            = aws_vpc.this[0].id
  service_name      = "com.amazonaws.${var.region}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = aws_route_table.private[*].id

  tags = merge(var.tags, {
    Name = "${var.name_prefix}-s3"
  })
}

# -----------------------------------------------------------------------------
# Flow logs
# -----------------------------------------------------------------------------

resource "aws_iam_role" "flow_logs" {
  count = local.create_flow_logs ? 1 : 0

  name = "${var.name_prefix}-vpc-flow-logs"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Action    = "sts:AssumeRole"
      Principal = { Service = "vpc-flow-logs.${local.dns_suffix}" }
      Condition = {
        StringEquals = { "aws:SourceAccount" = local.account_id }
      }
    }]
  })

  tags = var.tags
}

resource "aws_iam_role_policy" "flow_logs" {
  count = local.create_flow_logs ? 1 : 0

  name = "write-flow-logs"
  role = aws_iam_role.flow_logs[0].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "logs:CreateLogStream",
        "logs:PutLogEvents",
        "logs:DescribeLogGroups",
        "logs:DescribeLogStreams",
      ]
      Resource = "${local.flow_log_group_arn}:*"
    }]
  })
}

resource "aws_flow_log" "this" {
  count = local.create_flow_logs ? 1 : 0

  vpc_id                   = local.vpc_id
  traffic_type             = "ALL"
  log_destination_type     = "cloud-watch-logs"
  log_destination          = local.flow_log_group_arn
  iam_role_arn             = aws_iam_role.flow_logs[0].arn
  max_aggregation_interval = 60

  tags = merge(var.tags, {
    Name = var.name_prefix
  })

  depends_on = [aws_iam_role_policy.flow_logs]
}

# -----------------------------------------------------------------------------
# Private DNS (networking-foundation)
# -----------------------------------------------------------------------------

resource "aws_route53_zone" "private" {
  count = local.create_private_dns ? 1 : 0

  name          = coalesce(var.private_dns_zone_name, "${var.name_prefix}.internal")
  comment       = "Private zone of ${var.name_prefix}"
  force_destroy = !var.require_deletion_protection

  vpc {
    vpc_id = local.vpc_id
  }

  tags = var.tags

  lifecycle {
    precondition {
      condition     = local.network_available
      error_message = local.network_required
    }
  }
}
