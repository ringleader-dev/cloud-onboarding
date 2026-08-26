# Onboarding AWS

Run this **once, in your own AWS account**, to let a Ringleader control plane create,
manage, and tear down **workstation EC2 instances** in your account — your account, your
bill, your VPC — with only the permissions the workstation lifecycle needs and never
account admin.

Keyless: no IAM user, no access key. Ringleader authenticates with a short-lived,
Ringleader-signed **OIDC token** whose subject is **your org id**, which your account's
IAM OIDC trust admits and no other customer's token can match. Revoke by deleting the
OIDC provider (or the role).

## What you create

| Resource | Purpose |
|---|---|
| **IAM OIDC identity provider** | trusts Ringleader's per-org issuer (`<issuer>/org/<org-id>`) with client id `<issuer>/org/<org-id>/aws` |
| **IAM role** (`ringleader-workstations`) | assumed via `sts:AssumeRoleWithWebIdentity`; trust pins **both** `aud` and `sub` to your org; permissions cover only the EC2 workstation lifecycle + the SSM public-parameter read that resolves an AMI |
| _optional_ **VPC + public subnet + internet gateway + security group** | a landing pad: egress out (so a workstation can come up), inbound SSH from the CIDRs you name, and — only if you ask — a secondary SSH port |

The permissions policy is exactly these three statements — no wildcard on any action:

- eleven named read-only actions: `ec2:DescribeInstances`, `DescribeInstanceStatus`,
  `DescribeInstanceTypes`, `DescribeImages`, `DescribeSubnets`,
  `DescribeSecurityGroups`, `DescribeVpcs`, `DescribeVolumes`,
  `DescribeNetworkInterfaces`, `DescribeTags`, `DescribeAvailabilityZones` — on `*`,
  because EC2 `Describe` actions have no resource-level scoping,
- `ec2:RunInstances` / `TerminateInstances` / `StartInstances` / `StopInstances` /
  `CreateTags` / `DeleteTags` — optionally bounded to one region via
  `aws:RequestedRegion`,
- `ssm:GetParameters` / `GetParameter` on `arn:aws:ssm:*::parameter/aws/service/*` — the
  AWS-owned public AMI parameters.

No `iam:*` unless you opt into per-workstation instance profiles (Terraform
`enable_workstation_identities`, off by default and scoped to `iam:PassRole` under one
path).

## Values Ringleader gives you

| Value | Example |
|---|---|
| **Issuer URL** | `https://oidc-app.ringleader.dev` |
| **Your organization id** | `0192f5bf-af83-7178-8d0a-f1c7aea06bde` |

Everything else derives from those two:

- OIDC provider URL = `<issuer-url>/org/<org-id>`
- audience (`aud`) = `<issuer-url>/org/<org-id>/aws`
- subject (`sub`) = `org:<org-id>`

## Pick a path

Use whichever your team already runs. They create the same OIDC provider, role, and
optional network, with one difference: the per-workstation instance-profile option
(`enable_workstation_identities`, below) exists only on the Terraform path.

### CloudFormation (`aws` CLI)

```sh
cd cloudformation
ISSUER_URL=https://oidc-app.ringleader.dev \
ORG_UID=<org-id> \
REGION=us-east-1 \
CREATE_NETWORK=true \
SSH_SOURCE_CIDR=<your.office.ip/32> \
  ./deploy.sh
```

`deploy.sh` computes the issuer TLS thumbprint, substitutes the one condition-key
placeholder CloudFormation cannot parameterize, deploys the stack, and prints the
outputs.

### Terraform

```sh
cd terraform/examples/standalone
cp terraform.tfvars.example terraform.tfvars   # fill in issuer + org_uid
terraform init && terraform apply
terraform output handoff
```

The Terraform module derives the thumbprint automatically.

## What you hand back to Ringleader

- **`target_role_arn`** → `arn:aws:iam::<account-id>:role/ringleader-workstations`
- your **region**
- if you created the landing pad: **`subnet_id`** and **`security_group_id`**

## Reaching your workstations

| | needs | provided by |
|---|---|---|
| **Bringing the workstation up** | **egress** from the VM to the Ringleader control plane | a public IP + internet gateway (the default), or a NAT gateway |
| **Using the workstation** (`rl shell`, `rl tmux`, port-forwards, VS Code Web) | **inbound TCP 22**, from wherever you run `rl` | a security-group rule (`ssh_source_ranges` / `SshSourceCidr`) — or private connectivity |
| **Using a workstation type that runs its own SSH daemon** | additionally, **inbound on a secondary SSH port** | an opt-in rule (`secondary_ssh_source_ranges` / `SecondarySshSourceCidr`), off by default |

A workstation gets a **public IP by default** (`providerConfig.aws.assignPublicIp`), so
the internet gateway alone gives it egress — no NAT gateway, no hourly bill. Set
`assignPublicIp: false` for a private workstation, and create the NAT gateway
(`create_nat_gateway`) so it still has egress. Ringleader ships **no bastion and no SSH
tunnel**: a workstation with no inbound path finishes setting up and reports
Ready, but nobody can open it.

**The secondary SSH port is opt-in and off by default.** Some Ringleader workstation types run
their own SSH daemon on a second port inside the instance, while the instance's own sshd keeps 22,
and `rl shell` dials that port for such a workstation. Set `secondary_ssh_source_ranges`
(Terraform) or `SECONDARY_SSH_SOURCE_CIDR` (`deploy.sh`) to open it on the workstations security
group; leave it unset and **no rule is created** — your account admits exactly what it admits
today. Ringleader tells you whether the workstations you plan to run need it, and you never supply
the port number: both paths carry it.

## Workstations hold no AWS identity by default

A workstation runs with **no instance profile** unless an administrator sets
`providerConfig.aws.iamInstanceProfile`. Without that, nothing inside the workstation can act as any
IAM principal. Attaching one needs `iam:PassRole`, which this module grants only when you
set `enable_workstation_identities` — read its warning first.

## Notes

- **AMIs are x86-64.** The alias table (`ubuntu-24.04`, `debian-12`,
  `amazonlinux-2023`, …) resolves x86-64 AMIs, so use an x86-64 instance type (default
  `t3.medium`).
- **The thumbprint is a formality, and both paths compute it for you.** Creating an IAM
  OIDC provider requires a `ThumbprintList`, but since 2023 AWS validates an IdP served
  from a well-known public CA against its own trust store and ignores the value. Both
  paths read the issuer's live TLS chain anyway rather than hardcode one:
  `terraform` via the `tls_certificate` data source, `deploy.sh` via `openssl s_client`.

  **The CloudFormation template does carry a hardcoded `Thumbprint` default**
  (Google Trust Services Root R1, Ringleader's issuer CA at the time of writing). It is
  only ever used if you deploy `ringleader-onboarding.yaml` **by hand** without passing
  `Thumbprint` — `deploy.sh` always overrides it with the freshly computed value. If
  Ringleader's issuer moves to a different CA, that stale default still onboards
  correctly, because AWS ignores it for a public-CA issuer. Pass your own value if your
  account policy requires an accurate one.

More detail: <https://docs.ringleader.dev/cloud-onboarding/aws/>.
