# sample-infrastructure

The sample service's "web" stack: network, database and storage

Infrastructure stack on AWS, managed with Terraform. Pattern:
`web-application`. Environments: `staging`, `production`.

## What the stack contains

| Feature | Setting | Value |
| ------- | ------- | ----- |
| Network | `enable_networking` | on |
| Tiered security groups | `enable_security_group_rules` | on |
| Kubernetes | `enable_kubernetes` | off |
| Database | `enable_database` | on: `postgresql` |
| Object storage | `enable_storage` | on |
| CDN | `enable_cdn` | off |
| Web application firewall | `enable_waf` | off |
| Secret store | `enable_secrets_manager` | on |
| Customer-managed keys | `enable_kms` | on |
| Backups | `enable_backup` | on |
| Compliance baseline | `compliance_framework` | `none` |
| Monitoring | `enable_monitoring` | on: `native` |
| Alerting | `enable_alerting` | on |
| Log retention | `log_retention_days` | 30 days |
| Disaster recovery | `enable_disaster_recovery` | off |
| Cost optimisation | `enable_cost_optimization` | on |

The settings live in `terraform.tfvars` and apply to every environment;
`environments/<name>.tfvars` holds what differs per environment. Edit and push
to change the stack.

## Pipeline

`.github/workflows/terraform.yaml` runs on every push and pull request.
Formatting, validation, TFLint, `terraform test` against mocked providers and
a Trivy scan per environment need no credentials and always run. Plan and
Apply run per environment and are skipped until these repository secrets are
set:

| Secret | Purpose |
| ------ | ------- |
| `AWS_ROLE_ARN` | IAM role the workflow assumes through GitHub OIDC |
| `TF_STATE_BUCKET` | S3 bucket that stores the Terraform state (in `us-east-1`, or the region named by the variable `TF_STATE_REGION`) |

## Working locally

Checks that need no cloud account:

```bash
terraform fmt -check -recursive
terraform init -backend=false
terraform validate
terraform test
```

Planning an environment:

```bash
terraform init \
  -backend-config="bucket=<state bucket>" \
  -backend-config="key=sample-infrastructure/staging/terraform.tfstate" \
  -backend-config="region=us-east-1"
terraform plan -var-file=environments/staging.tfvars
```

See `docs/index.md` for details.
