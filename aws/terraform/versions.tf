terraform {
  required_version = ">= 1.3"

  required_providers {
    # >= 6.0, not >= 5.0, and the reason is one attribute. This module has to learn the region it
    # is being applied in (see `local.region`), which is what binds an entry in region_indexes to a
    # region rather than to whichever tfvars file was reached for. In v6 the only spelling of that
    # which is not deprecated is `data.aws_region.current.region`; `name` and `id` are both
    # deprecated there and will be removed, and `region` does not exist in v5 at all -- referencing
    # it is a schema error, not something try() can rescue. There is no spelling that is clean on
    # both majors, so the floor is what picks one. v6 has been current since mid-2025.
    aws = {
      source  = "hashicorp/aws"
      version = ">= 6.0"
    }
    # Used only to read the issuer's TLS chain so the IAM OIDC provider's
    # thumbprint is derived automatically (AWS ignores it for a well-known public
    # CA, but the API still requires the field to be populated).
    tls = {
      source  = "hashicorp/tls"
      version = ">= 4.0"
    }
  }
}
