# Remote state in S3, one state file per environment. The bucket, key and
# region are passed to `terraform init` with -backend-config; see README.md.
terraform {
  backend "s3" {
    encrypt      = true
    use_lockfile = true
  }
}
