# Container registry of container, ML and serverless platforms.
resource "aws_ecr_repository" "this" {
  count = local.create_registry ? 1 : 0

  name                 = var.name_prefix
  image_tag_mutability = "IMMUTABLE"
  force_delete         = !var.require_deletion_protection

  image_scanning_configuration {
    scan_on_push = true
  }

  encryption_configuration {
    encryption_type = var.enable_kms ? "KMS" : "AES256"
    kms_key         = local.kms_key_arn
  }

  tags = var.tags
}

# Untagged layers left behind by rebuilt images are removed after two weeks.
resource "aws_ecr_lifecycle_policy" "this" {
  count = local.create_registry ? 1 : 0

  repository = aws_ecr_repository.this[0].name

  policy = jsonencode({
    rules = [{
      rulePriority = 1
      description  = "Expire untagged images after 14 days"
      selection = {
        tagStatus   = "untagged"
        countType   = "sinceImagePushed"
        countUnit   = "days"
        countNumber = 14
      }
      action = { type = "expire" }
    }]
  })
}
