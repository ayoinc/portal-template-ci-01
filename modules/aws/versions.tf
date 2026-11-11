terraform {
  required_version = ">= 1.10"

  # One aws provider configuration, for the primary region, is enough:
  # resources of the disaster-recovery region and of us-east-1 select their
  # region with the per-resource region argument.
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }
}
