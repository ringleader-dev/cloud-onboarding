terraform {
  required_version = ">= 1.3"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.0"
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
