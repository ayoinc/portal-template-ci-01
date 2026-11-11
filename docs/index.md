# sample-infrastructure

The sample service's "web" stack: network, database and storage

## Overview

This repository holds an infrastructure stack on AWS, described in
Terraform and deployed by GitHub Actions to 2 environments:
`staging`, `production`. Each environment has its own settings file, its own state
and its own stage in the pipeline.

| Setting | Value |
| ------- | ----- |
| Cloud | AWS |
| Infrastructure pattern | `web-application` |
| AWS region | `us-east-1` |
| Owner | `group:default/platform-team` |

## Features

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

Everything is implemented by `modules/aws`. The root module passes it the settings
and applies the rules described below.

### What a feature creates

| Feature | Result |
| ------- | ------ |
| Network | Network with public and private subnets in two zones and NAT for outbound traffic. When off, name an existing network in `terraform.tfvars` (`aws_existing_network`) before enabling components that need one |
| Tiered security groups | Separate web, app and data tiers; data stores accept traffic from the app tier and the cluster only |
| Kubernetes | Managed cluster with private nodes and a private API; `kubernetes_api_allowed_cidrs` opens the API to listed networks |
| Database | Private, encrypted managed database with generated credentials; highly available in production |
| Object storage | Private, versioned, encrypted bucket that accepts TLS only |
| CDN | CDN in front of the object storage, HTTPS only; the storage is reachable through the CDN only |
| Web application firewall | Managed-rule policy, attached to the CDN when there is one |
| Secret store | Holds the generated database credentials |
| Customer-managed keys | One key with rotation for storage, database, secrets and logs |
| Backups | Backup vault and plan; database backups kept for 35 days instead of 7 |
| Monitoring | Central log destination, diagnostics of the components, dashboard |
| Alerting | Notification target and alert rules for the components that exist; set `alert_email` to receive them |
| Disaster recovery | Object storage and database backups replicated to the secondary region |
| Cost optimisation | Storage lifecycle tiering; outside production also spot nodes, a single NAT and the smallest database tier |

### Infrastructure pattern

`web-application` adds nothing beyond the features above.

### Monitoring solution

`native`: the cloud's own logging, dashboards and alerts.

### Compliance baseline

`compliance_framework` applies a baseline on top of the settings and tags
every resource with it. It makes the stack meet the framework's technical
expectations for these settings; it does not replace an audit.

| Framework | Minimum log retention | Customer-managed keys | Backups | Deletion protection | Flow logs |
| --------- | --------------------- | --------------------- | ------- | ------------------- | --------- |
| `none`    | as set                | as set                | as set  | production only     | no        |
| `cis`     | 365 days              | as set                | as set  | production only     | yes       |
| `pci-dss` | 365 days              | yes                   | yes     | yes                 | yes       |
| `hipaa`   | 2192 days (6 years)   | yes                   | yes     | yes                 | yes       |
| `sox`     | 2557 days (7 years)   | yes                   | yes     | yes                 | no        |
| `gdpr`    | as set                | yes                   | yes     | production only     | no        |

This stack uses `none`. The output `effective_settings` shows the
settings after the baseline is applied.

## Environments

| File | Purpose |
| ---- | ------- |
| `terraform.tfvars` | Settings shared by every environment |
| `environments/staging.tfvars` | Settings of `staging`; they take precedence |
| `environments/production.tfvars` | Settings of `production`; they take precedence |

Resource names start with the stack name and the short environment (`dev`,
`stg`, `prod`). Production is always protected from deletion and gets a highly
available database.

To add an environment, copy one of the files, set `environment`, and add the
name to the three `matrix.environment` lists in the workflow.

## CI/CD Pipeline

`.github/workflows/terraform.yaml` runs on every push to `main`, on pull
requests and on demand.

| Job           | What it does                                                                  | Needs credentials |
| ------------- | ----------------------------------------------------------------------------- | ----------------- |
| Validate      | `terraform fmt -check`, `terraform init -backend=false`, `terraform validate` | No                |
| Lint          | TFLint with the Terraform and cloud rule sets                                 | No                |
| Test          | `terraform test` for the stack and for each module, against mocked providers  | No                |
| Security scan | Trivy per environment, with that environment's settings; fails on HIGH and CRITICAL findings | No |
| Plan          | `terraform plan` per environment against its remote state                     | Yes               |
| Apply         | `terraform apply` of that plan, one environment after the other, on pushes to `main` | Yes        |

Plan and Apply are skipped, not failed, until all of these repository secrets
are set:

| Secret | Purpose |
| ------ | ------- |
| `AWS_ROLE_ARN` | IAM role the workflow assumes through GitHub OIDC |
| `TF_STATE_BUCKET` | S3 bucket that stores the Terraform state (in `us-east-1`, or the region named by the variable `TF_STATE_REGION`) |

Each Apply runs in the GitHub environment of the same name. Add required
reviewers to an environment (for example `production`) to approve its applies
by hand. Start the workflow manually with the action `destroy` to remove the
stack.

## Working Locally

These checks need Terraform 1.10 or later and no cloud account:

```bash
terraform fmt -check -recursive
terraform init -backend=false
terraform validate
terraform test
```

To plan an environment from your machine, initialise with its state:

```bash
terraform init \
  -backend-config="bucket=<state bucket>" \
  -backend-config="key=sample-infrastructure/staging/terraform.tfstate" \
  -backend-config="region=us-east-1"
terraform plan -var-file=environments/staging.tfvars
```

## Repository Structure

```
sample-infrastructure/
├── .github/workflows/terraform.yaml   # Validation and deployment pipeline
├── docs/index.md                      # This documentation
├── environments/                      # One settings file per environment
├── modules/                           # The stack per cloud
├── tests/infrastructure.tftest.hcl    # Tests of the stack against mocked providers
├── backend.tf                         # Remote state
├── locals.tf                          # Names, tags and the compliance baselines
├── main.tf                            # Calls the modules
├── outputs.tf
├── providers.tf
├── terraform.tfvars                   # Settings shared by every environment
├── variables.tf
├── versions.tf
├── .tflint.hcl                        # TFLint configuration
├── catalog-info.yaml                  # Backstage catalog entry
└── mkdocs.yml                         # TechDocs configuration
```
