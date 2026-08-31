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
`enable_workstation_identities`, on by default and scoped to `iam:PassRole` under one
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
- if you created the landing pad: **`subnet_id`** and a **security-group id** — and there are
  **two**, one for workstations with an egress policy and one for those without. Which one a
  workstation gets is the difference between an enforced policy and a workstation that will not
  start: see [Which security group a workstation gets](#which-security-group-a-workstation-gets).
- if you reserved one: **`gateway_subnet_id`**, where the DNS / HTTPS proxy VM will run

## Reaching your workstations

| | needs | provided by |
|---|---|---|
| **Bringing the workstation up** | **egress** from the VM to the Ringleader control plane | a public IP + internet gateway (the default), or a NAT gateway |
| **Using the workstation** (`rl shell`, `rl tmux`, port-forwards, VS Code Web) | **inbound TCP 22**, from wherever you run `rl` | a security-group rule (`ssh_source_ranges` / `SshSourceCidr`) — or private connectivity |
| **Using a workstation type that runs its own SSH daemon** | additionally, **inbound on a secondary SSH port** | a rule that follows `ssh_source_ranges` unless you override it (`secondary_ssh_source_ranges` / `SecondarySshSourceCidr`) |

A workstation gets a **public IP by default** (`providerConfig.aws.assignPublicIp`), so
the internet gateway alone gives it egress — no NAT gateway, no hourly bill. Set
`assignPublicIp: false` for a private workstation, and create the NAT gateway
(`create_nat_gateway`) so it still has egress. Ringleader ships **no bastion and no SSH
tunnel**: a workstation with no inbound path finishes setting up and reports
Ready, but nobody can open it.

**The secondary SSH port follows port 22.** Some Ringleader workstation types run their own SSH
daemon on a second port inside the instance, while the instance's own sshd keeps 22, and
`rl shell` dials that port for such a workstation; others never use it, and for those the rule is
harmless. So rather than making you find out which kind you are running, both paths mirror
whatever you set for 22 — `secondary_ssh_source_ranges` (Terraform) and
`SECONDARY_SSH_SOURCE_CIDR` (`deploy.sh`) override it, and `[]` / `none` closes it. Open nothing
for 22 and nothing opens for 2222. You never supply the port number: both paths carry it.

## Optional: egress control

By default a workstation can reach anything your network routes. Ringleader can narrow that
to an allowlist you declare in the workstation manifest — a set of IP ranges and hostnames —
enforced by security groups that Ringleader creates and keeps in step with the manifest.

It is **on by default**, and granting it restricts nothing on its own: until you declare an
egress policy on a workstation, everything behaves exactly as it does today.

```hcl
egress_vpc_ids = []   # empty uses the VPC this module creates

# enable_egress_control = false   # to opt out
```
```bash
EGRESS_CONTROL=false ./deploy.sh   # the CloudFormation path, to opt out
```

It grants two sets of actions and no more — the objects a policy compiles to, and the routing
that makes a workstation's traffic arrive at the proxy:

| action | why |
|---|---|
| `ec2:CreateSecurityGroup`, `ec2:DeleteSecurityGroup` | one group per distinct egress policy |
| `ec2:AuthorizeSecurityGroupEgress`, `ec2:RevokeSecurityGroupEgress` | keep that group's rules in step with the manifest |
| `ec2:AuthorizeSecurityGroupIngress`, `ec2:RevokeSecurityGroupIngress` | the DNS / HTTPS proxy's own group, which has to admit workstation traffic |
| `ec2:ModifyNetworkInterfaceAttribute` | move a running workstation onto the group its policy compiled to — and clear the source/destination check on the proxy's own interface, without which AWS silently drops every packet it forwards |
| route-table and subnet writes (`CreateRouteTable`, `CreateRoute`, `AssociateRouteTable`, `CreateSubnet`, …) | steer a workstation's traffic at the proxy. An AWS route table is **per subnet**, so per-policy steering needs a subnet per policy |

**Bound them to a VPC.** With `egress_vpc_ids` set — or with `create_network = true`, where
the module uses the VPC it made — the permissions apply only to security groups in that VPC.
If you bring your own network and name no VPC, the only bound is `allowed_regions`, which
lets Ringleader manage security groups anywhere in that region. The `egress_scope` output
tells you which of the three you ended up with, so it is worth reading after an apply.

Ringleader compiles each distinct policy into **one** security group and attaches it to the
workstations carrying that policy. That is not just tidiness: AWS caps a network interface at
**5 security groups** and **1,000 rules**, and a region at **2,500 groups**, so a group per
workstation would not reach fleet scale.

### Which security group a workstation gets

The landing pad creates **two** security groups, and a workstation carries one of them:

| Hand back | For | Inbound | Egress |
|---|---|---|---|
| `security_group_id` / `SecurityGroupId` | a workstation with **no** `spec.egress` | SSH from your ranges | **all** |
| `inbound_only_security_group_id` / `InboundOnlySecurityGroupId` | a workstation that **declares** `spec.egress` | the same rules | **none** |

**Why two, and why not just one narrower group.** EC2 **aggregates** the rules of every
security group attached to a network interface, and a security group is **allow-only** — it
cannot express a deny. So the group Ringleader compiles your policy into can only ever *add*
to what the workstation's other groups already permit. Put it beside a group that allows
`0.0.0.0/0` and the union is `0.0.0.0/0`: the policy restricts nothing, however correct the
group Ringleader built. Put it beside a group with **no egress rules** and the union is exactly
the policy. That is the entire reason the second group exists, and why it looks, wrongly, like
a group somebody forgot to finish.

Both are needed. Strip the egress rule from the first group instead and every workstation
*without* a policy loses the egress it needs to come up at all.

**Ringleader fails loudly rather than quietly.** Launch a workstation that declares
`spec.egress` while it carries a group permitting egress and Ringleader **refuses to create
it**, naming the offending group, rather than start a box it would have to report as enforced
while it reaches the whole internet. If you see that message, you handed back the landing-pad
id where the inbound-only one belonged.

**Do not "fix" the inbound-only group by adding an egress rule.** It has none on purpose, and
one rule of any kind there re-breaks every policy-bearing workstation in the VPC. The
CloudFormation copy carries a single placeholder rule to `127.0.0.1/32` for a mechanical
reason — CloudFormation restores AWS's own allow-all rule if the egress list is empty — and
loopback traffic never reaches the interface, so it permits nothing.

**It follows egress control.** Turn `enable_egress_control` / `EnableEgressControl` off and the
inbound-only group is not created: with no policies to compile there is nothing for it to sit
beside, and an unused group still counts against the account's 2,500-group cap. Turning egress
control back on creates it in the same apply that restores the grants.

## Room for the DNS / HTTPS proxy

Restricting egress by **hostname** rather than by address range means the connection has to
pass something that can read the hostname off it. Ringleader runs a small proxy VM in your
account for that: it reads the TLS SNI on 443 and the HTTP Host on 80, checks the name against
that workstation's policy, and re-resolves it itself rather than trusting the address the box
was heading for. That VM does not exist yet, but it is worth reserving its address range now.

`create_gateway_subnet` is on by default at `10.60.240.0/24`. To skip it:

```hcl
create_gateway_subnet = false
```
```bash
CREATE_GATEWAY_SUBNET=false ./deploy.sh
```

It creates an **empty subnet and its route table**, neither of which AWS bills for. Two
properties of that subnet are cost decisions rather than conveniences:

- **It is public**, routed through the internet gateway. The proxy carries a fleet's whole
  outbound volume, and internet ingress is free on every cloud — so a proxy with its own public
  address pays nothing for it. The same bytes through a NAT gateway meter at **$0.045/GB**.
- **It shares the workstations subnet's availability zone.** AWS charges cross-AZ traffic in
  **both directions** ($0.01/GB each way), so at 10 TB/month a misplaced proxy costs $200 —
  more than the instance running it.

### The NAT gateway, and why the proxy eventually replaces it

`create_nat_gateway` is also on by default and is **the one thing here that costs money**:
$0.045/hour plus **$0.045/GB processed**, whether or not anything uses it. It exists so a
workstation with `assignPublicIp: false` still has egress. Turn it off if all your workstations
get public IPs, which is the default and which the internet gateway already serves for free.

Worth knowing for later: once the proxy ships, a fleet of private workstations can reach the
internet through it instead, and the proxy meters nothing. At 10 TB/month that is a saving of
roughly **$420 against managed NAT** — so for a fleet already behind NAT, egress control
arrives *cheaper* than the status quo rather than as new spend. For a fleet whose workstations
have public addresses today, the proxy is new spend; which of the two you are is worth working
out before you budget for it.

**One thing this also fixed.** `create_nat_gateway` previously created a NAT gateway that
nothing routed to, so a workstation with `assignPublicIp: false` had no egress at all. There is
now a private route table pointing at it — `private_route_table_id` — and you can associate any
subnet that should reach the internet without a public IP with it.

## Plan your CIDRs before the second region

An AWS VPC is regional. A second region means a second VPC, and joining them later needs an
**inter-region Transit Gateway**, which cannot route overlapping CIDRs. Applying this module
in another region on the default `vpc_cidr` gives you two VPCs that can never be peered, and
the fix at that point is to renumber and re-onboard.

So pick the ranges up front, even if you only need one region today:

| region | `vpc_cidr` | `subnet_cidr` | `gateway_subnet_cidr` |
|---|---|---|---|
| first | `10.60.0.0/16` | `10.60.0.0/20` | `10.60.240.0/24` |
| second | `10.61.0.0/16` | `10.61.0.0/20` | `10.61.240.0/24` |
| third | `10.62.0.0/16` | `10.62.0.0/20` | `10.62.240.0/24` |

Ringleader's proxy VMs are regional, so each region runs its own; nothing here requires the
regions to be joined at all until you want one proxy to serve several.

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
