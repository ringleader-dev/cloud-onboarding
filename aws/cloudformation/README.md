# Ringleader AWS onboarding — CloudFormation

`ringleader-onboarding.yaml` creates the IAM OIDC provider, the federated role, and
(optionally) a public-subnet landing-pad network. `deploy.sh` wraps `aws cloudformation
deploy` with every org-specific value derived for you.

## Deploy

```sh
ISSUER_URL=https://oidc-app.ringleader.dev \
ORG_UID=<org-id> \
REGION=us-east-1 \
CREATE_NETWORK=true \
SSH_SOURCE_CIDR=<your.ip/32> \
  ./deploy.sh
```

Env vars: `ISSUER_URL`, `ORG_UID` (required); `REGION` (default `us-east-1`), `STACK_NAME`
(`ringleader-onboarding`), `ROLE_NAME` (`ringleader-workstations`), `CREATE_NETWORK`
(`true`), `SSH_SOURCE_CIDR` (empty), `SECONDARY_SSH_SOURCE_CIDR` (mirrors `SSH_SOURCE_CIDR`),
`ALLOWED_REGION` (default `$REGION`), plus the five in *Parameters* below.

`SECONDARY_SSH_SOURCE_CIDR` **follows `SSH_SOURCE_CIDR`** unless you set it: it opens a second
SSH port on the workstations security group, which some Ringleader workstation types run their
own SSH daemon on while the instance's own sshd keeps 22, and which is harmless for the types
that do not. Set it to `none` to close the port, or to a different CIDR to open it more
narrowly. Open nothing for 22 and nothing opens for 2222. You never supply the port number —
the template carries it.

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
`Thumbprint`, `RoleName`, `AllowedRegion`, `CreateNetwork`, `VpcCidr`, `SubnetCidr`,
`SshSourceCidr`, `SecondarySshSourceCidr`.

Egress control and the proxy subnet add five more: `EnableEgressControl` (`true`),
`EgressVpcId` (empty — uses the VPC this stack creates), `CreateNatGateway` (`true`),
`CreateGatewaySubnet` (`true`) and `GatewaySubnetCidr` (`10.60.240.0/24`). `deploy.sh` exposes
them as `EGRESS_CONTROL`, `EGRESS_VPC_ID`, `CREATE_NAT_GATEWAY`, `CREATE_GATEWAY_SUBNET` and
`GATEWAY_SUBNET_CIDR`; [`../README.md`](../README.md#optional-egress-control) explains what
each one grants, and [the root README](../../README.md#what-is-on-by-default-and-how-to-turn-it-off)
lists everything that is on by default. `CreateGatewaySubnet=true` keeps the NAT gateway on,
since the proxy VM has no public IP and NAT is its only route out — and the NAT gateway is the
one default that bills hourly.

Deploy with `--capabilities CAPABILITY_NAMED_IAM` (the role has a fixed name).

### About the `Thumbprint` default

`Thumbprint` is the SHA-1 of the CA at the top of the issuer's TLS chain. `deploy.sh`
always recomputes it from the live chain and passes it, so the default below is used
**only if you deploy the template by hand without passing `Thumbprint`**.

That default is a hardcoded value — Google Trust Services Root R1, Ringleader's issuer CA
at the time of writing — and it is deliberately not a problem if it goes stale: since 2023
AWS validates an IdP served from a well-known public CA against its own trust store and
ignores the thumbprint entirely. Onboarding still succeeds. Pass your own value if your
account policy requires the field to be accurate:

```sh
THUMBPRINT=$(echo | openssl s_client -servername oidc-app.ringleader.dev \
  -connect oidc-app.ringleader.dev:443 -showcerts 2>/dev/null \
  | awk 'BEGIN{c=0} /-----BEGIN CERTIFICATE-----/{c++} {cert[c]=cert[c]$0"\n"} END{printf "%s", cert[c]}' \
  | openssl x509 -fingerprint -sha1 -noout | sed 's/.*=//; s/://g' | tr 'A-Z' 'a-z')
```

## Outputs

`TargetRoleArn`, `OidcProviderArn`, and — with `CreateNetwork=true` — `SubnetId`,
`SecurityGroupId` and `VpcId`. With the proxy subnet on, also `GatewaySubnetId`; with a NAT
gateway, `PrivateRouteTableId`. Hand the role ARN, region, and (if created) subnet +
security group back to Ringleader.

## Revoke

`aws cloudformation delete-stack --stack-name ringleader-onboarding`.
