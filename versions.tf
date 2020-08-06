terraform {
  required_version = ">= 0.13"
  required_providers {
    archive = {
      source  = "hashicorp/archive"
      version = "~> 1.3.0"
    }
    aws = {
      source  = "hashicorp/aws"
      version = "~> 2.65.0"
    }
    pypi = {
      source  = "jeffwecan/pypi"
      version = "0.0.3"
    }
  }
}
