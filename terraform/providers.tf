terraform {
  required_version = ">= 1.9, < 2.0"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.0"
    }
    azapi = {
      source  = "azure/azapi"
      version = "~> 2.4"
    }
    azuread = {
      source  = "hashicorp/azuread"
      version = "~> 2.50"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.5"
    }
    modtm = {
      source  = "azure/modtm"
      version = "~> 0.3"
    }
  }
}

provider "azurerm" {
  subscription_id = var.subscription_id

  # Disable automatic resource provider registration.
  # All providers required for Azure Local are already registered by
  # scripts/01Lab/00_AzurePreRequisites.ps1 (step 5). Leaving auto-registration
  # enabled would require the SPN to have */register/action at subscription
  # scope, which is broader than needed for this lab.
  resource_provider_registrations = "none"

  features {
    resource_group {
      prevent_deletion_if_contains_resources = false
    }
    key_vault {
      # Automatically purge soft-deleted Key Vaults on destroy so that
      # terraform apply can recreate them with the same name on the next run.
      purge_soft_delete_on_destroy = true
    }
  }
}

provider "azapi" {}

provider "azuread" {}
