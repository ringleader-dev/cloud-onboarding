# Ringleader AWS onboarding — CloudFormation

`ringleader-onboarding.yaml` creates the IAM OIDC provider, the federated role, and
(optionally) a public-subnet landing-pad network. `deploy.sh` wraps `aws cloudformation
deploy` with every org-specific value derived for you.

## Deploy

```sh
ISSUER_URL=https://oidc-app.ringleader.dev \
ORG_UID=<org-id> \
REGION=us-east-1 \
REGION_INDEX=0 \
CREATE_NETWORK=true \
SSH_SOURCE_CIDR=<your.ip/32> \
  ./deploy.sh
```

`REGION_INDEX` is **required** whenever this creates a network, and picks which `/16` the
landing pad takes: the VPC gets `10.(60 + REGION_INDEX).0.0/16` and every subnet is carved out
of it. Give your first region `0`, which is `10.60.0.0/16`, and the next region `1`. There is no
default. An AWS VPC is regional, and two VPCs on one range can never be peered. Neither `deploy.sh`
nor CloudFormation can tell a first region from a second, so a default would give the second region
the first one's range without a warning. See
[`../README.md`](../README.md#a-second-region-name-it-do-not-renumber-it).

Env vars: `ISSUER_URL`, `ORG_UID` (required); `REGION_INDEX` (required with a network);
`REGION` (default `us-east-1`), `STACK_NAME`
(`ringleader-onboarding`), `ROLE_NAME` (`ringleader-workstations`), `CREATE_NETWORK`
(`true`), `SSH_SOURCE_CIDR` (empty), `SECONDARY_SSH_SOURCE_CIDR` (mirrors `SSH_SOURCE_CIDR`),
`ALLOWED_REGION` (default `$REGION`), plus the five in *Parameters* below.

`SECONDARY_SSH_SOURCE_CIDR` **follows `SSH_SOURCE_CIDR`** unless you set it: it opens a second
SSH port on the workstations security group, which some Ringleader workstation types run their
own SSH daemon on while the instance's own sshd keeps 22, and which is harmless for the types
that do not. Set it to `none` to create no rule for the port, or to a different CIDR to open it
more narrowly. Open nothing for 22 and the template opens nothing for 2222 either, while
Ringleader's security group still admits both ports to its workstations.
[Reaching your workstations](../README.md#reaching-your-workstations) says how. You never supply
the port number: the template carries it.

## The one placeholder

CloudFormation cannot build an object **key** from a parameter, and the IAM trust-policy
condition keys are `<issuer-host+path>:aud` and `:sub`. So the template carries the token
`__OIDC_PROVIDER__` in exactly those two keys, and `deploy.sh` substitutes it (with e.g.
`oidc-app.ringleader.dev/org/<org-id>`) before deploying. Deploying the template by hand? Run
that one substitution first:

```sh
sed -i "s|__OIDC_PROVIDER__|oidc-app.ringleader.dev/org/<org-id>|g" ringleader-onboarding.yaml
```

## Parameters (when deploying by hand)

`IssuerUrl` = `<issuer>/org/<org-id>`, `Audience` = `<IssuerUrl>/aws`, `Subject` = `org:<org-id>`,
`Thumbprint`, `RoleName`, `AllowedRegion`, `CreateNetwork`, `RegionIndex` (no default —
required when `CreateNetwork=true`), `VpcCidr` and `SubnetCidr` (both empty — overrides,
derived from `RegionIndex` when unset), `SshSourceCidr`, `SecondarySshSourceCidr`.

Two more grant capabilities on the role rather than on the network. `EnableWorkstationIdentities`
(`true`) grants `iam:PassRole` on roles under `WorkstationIdentityPath` (`/ringleader/`), to
`ec2.amazonaws.com` only, so a workstation can run as an IAM role of yours.
`EnableArtifactStorage` (`true`) lets Ringleader hold artifact payloads in an S3 bucket in this
account rather than in its own; `ArtifactStorageBucket` (empty) takes the managed width, where
Ringleader creates and converges its own buckets bounded by ARN to names beginning
`ringleader-`, and naming a bucket you made narrows the grant to that one ARN with no
`CreateBucket`, `DeleteBucket` or lifecycle write. `deploy.sh` exposes all four as
`WORKSTATION_IDENTITIES`, `WORKSTATION_IDENTITY_PATH`, `ARTIFACT_STORAGE` and
`ARTIFACT_STORAGE_BUCKET`.

Egress control and the two egress-control subnets add seven more: `EnableEgressControl`
(`true`), `EgressVpcId` (empty — uses the VPC this stack creates), `CreateNatGateway` (`true`),
`CreateGatewaySubnet` (`true`), `GatewaySubnetCidr` (empty — an override; unset it derives the
241st `/24` of the VPC range), `CreateGovernedSubnet` (`true`) and `GovernedSubnetCidr` (empty —
likewise the 15th `/20`). `deploy.sh` exposes them as
`EGRESS_CONTROL`, `EGRESS_VPC_ID`, `CREATE_NAT_GATEWAY`, `CREATE_GATEWAY_SUBNET`,
`GATEWAY_SUBNET_CIDR`, `CREATE_GOVERNED_SUBNET` and `GOVERNED_SUBNET_CIDR`;
[`../README.md`](../README.md#optional-egress-control) explains what
each one grants, and [the root README](../../README.md#what-is-on-by-default-and-how-to-turn-it-off)
lists everything that is on by default. `CreateNatGateway` is the one that costs money —
hourly plus $0.045/GB — and it is independent of `CreateGatewaySubnet`, whose subnet is public
and routed through the internet gateway.

The two subnets are for different things and only the second holds workstations:
`GatewaySubnet` is where the egress gateway VM runs — hand `GatewaySubnetId` back as
`spec.subnet` on the `EgressGateway`, and Ringleader builds no gateway VM until you do — and
`GovernedSubnet` is where the workstations that proxy **governs** go. The stack gives `GovernedSubnet` no route-table
association and no public IPs on purpose — Ringleader claims the subnet by associating a table
of its own, and refuses one that already carries an association. Until a proxy steers it, a
workstation in there has no egress at all; see
[`../README.md`](../README.md#and-a-subnet-for-the-workstations-that-proxy-governs).

Six optional slots make one more governed subnet for each further namespace that runs its own
proxy: `AdditionalGovernedSubnet1Label` and `AdditionalGovernedSubnet1Cidr` through
`AdditionalGovernedSubnet6Label` and `AdditionalGovernedSubnet6Cidr`. `deploy.sh` fills them from
`ADDITIONAL_GOVERNED_SUBNETS`, and each filled slot outputs `AdditionalGovernedSubnet<n>Id`. See
[`../README.md`](../README.md#one-governed-subnet-per-namespace-that-runs-a-proxy).

`CreateFlowLogs` (`false`) records a VPC flow log for all traffic in the stack's VPC, into a
CloudWatch Logs group that keeps the records for `FlowLogRetentionDays` (`365`). It also creates the
role that delivers them, which only VPC Flow Logs can assume. It is off by default, because it bills
per GB and grants Ringleader nothing. The stack refuses it without `CreateNetwork=true`. `deploy.sh`
exposes the two as `CREATE_FLOW_LOGS` and `FLOW_LOG_RETENTION_DAYS`, and passes each only when you
set it, so a later run keeps what the stack has. The delivery role
holds `logs:CreateLogGroup`, `CreateLogStream`, `PutLogEvents` and `DescribeLogStreams` on that one
group and its streams, and `logs:DescribeLogGroups` on `*`, which IAM cannot scope. See
[`../README.md`](../README.md#optional-flow-logs-for-the-vpc).

Deploy with `--capabilities CAPABILITY_NAMED_IAM` (the role has a fixed name).

### About the `Thumbprint` default

`Thumbprint` is the SHA-1 of the CA at the top of the issuer's TLS chain. `deploy.sh`
always recomputes it from the live chain and passes it, so the default below is used
**only if you deploy the template by hand without passing `Thumbprint`**.

That default is the thumbprint of Google Trust Services Root R1, the CA at the top of Ringleader's
issuer chain. When the issuer's certificate chains to a CA that AWS trusts, AWS checks it against
its own list of trusted CAs and not against the thumbprint. AWS uses the thumbprint only when it
cannot fetch the certificate or the server requires TLS 1.3. So if the issuer moves to another CA
that AWS trusts, a stale default still lets Ringleader assume the role. Pass your own value if your
account policy needs the field to be accurate:

```sh
THUMBPRINT=$(echo | openssl s_client -servername oidc-app.ringleader.dev \
  -connect oidc-app.ringleader.dev:443 -showcerts 2>/dev/null \
  | awk 'BEGIN{c=0} /-----BEGIN CERTIFICATE-----/{c++} {cert[c]=cert[c]$0"\n"} END{printf "%s", cert[c]}' \
  | openssl x509 -fingerprint -sha1 -noout | sed 's/.*=//; s/://g' | tr 'A-Z' 'a-z')
```

## Outputs

`TargetRoleArn`, `OidcProviderArn`, and — with `CreateNetwork=true` — `SubnetId`,
`SecurityGroupId` and `VpcId`; plus `InboundOnlySecurityGroupId` while egress control is on.
With the proxy subnet on, also `GatewaySubnetId`; with a NAT gateway, `PrivateRouteTableId`; with
flow logs, `FlowLogGroupName`, which is for you and not for Ringleader.
Hand the role ARN, region, and (if created) subnet + security group back to Ringleader —
plus `GatewaySubnetId`, which goes on the `EgressGateway` as `spec.subnet` rather than on a
workstation, and `GovernedSubnetId` for the workstations that carry an egress policy. Each filled
slot adds an `AdditionalGovernedSubnet<n>Id`, for one namespace's workstations only.

**Two security groups, and the choice is not cosmetic.** `SecurityGroupId` is the landing pad:
egress out, inbound SSH. `InboundOnlySecurityGroupId` has the same inbound rules and no usable
egress, and it is the one a workstation that declares `spec.egress` must carry — see
[the union rule](../README.md#which-security-group-a-workstation-gets). Give a policy-bearing
workstation the first id and Ringleader refuses to launch it.

## Changing the template

`deploy.sh` deploys the template with `aws cloudformation deploy --template-file` and no S3
bucket, and the AWS CLI refuses a template over 51,200 bytes on that path. CI fails when the
template `deploy.sh` renders is over that size (`.github/scripts/check_template_size.py`), so
keep each comment in `ringleader-onboarding.yaml` to one line. Write the reasoning here or in
[`../README.md`](../README.md) instead.

Three edits to the template hurt the customers who apply it:

- **Changing `GroupDescription` on either security group.** CloudFormation can change a group's
  description only by replacing the group, and it refuses to replace a group with a fixed
  `GroupName`, so the stack update fails. The rules in `SecurityGroupIngress` and
  `SecurityGroupEgress` update without replacing the group.
- **Removing the `127.0.0.1/32` egress rule on the inbound-only group.** When CloudFormation
  creates a security group whose `SecurityGroupEgress` is empty or absent, AWS adds its allow-all
  egress rule. This rule is what gives a new group no usable egress. See
  [Which security group a workstation gets](../README.md#which-security-group-a-workstation-gets).
- **Adding a `Default` to `RegionIndex`.** A customer's second region would then take the first
  region's range.

The gateway subnet has a route table of its own rather than sharing the workstations subnet's,
so a route added for the gateway never changes where a workstation's traffic goes.

## Revoke

`aws cloudformation delete-stack --stack-name ringleader-onboarding`.
