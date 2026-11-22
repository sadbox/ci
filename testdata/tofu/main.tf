# lint.yml's OpenTofu fixture: a root (it has a .terraform.lock.hcl) whose
# state is encrypted with a passphrase from a variable, which CI never has:
# tofu validate and tflint must pass without it.
terraform {
  required_version = ">= 1.13.0"

  required_providers {
    random = {
      source  = "hashicorp/random"
      version = "3.7.2"
    }
  }

  encryption {
    key_provider "pbkdf2" "state" {
      passphrase = var.state_passphrase
    }
    method "aes_gcm" "state" {
      keys = key_provider.pbkdf2.state
    }
    state {
      method   = method.aes_gcm.state
      enforced = true
    }
    plan {
      method   = method.aes_gcm.state
      enforced = true
    }
  }
}

variable "state_passphrase" {
  description = "The state encryption passphrase."
  type        = string
  sensitive   = true
}

resource "random_pet" "fixture" {}

output "name" {
  description = "The generated name."
  value       = random_pet.fixture.id
}
