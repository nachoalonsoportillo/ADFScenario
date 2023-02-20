provider "azurerm" {
  features {}
}

terraform {
  required_providers {
    azapi = {
      source = "Azure/azapi"
      version = "1.3.0"
    }
  }
}
