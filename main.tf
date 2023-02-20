data "azurerm_client_config" "current" {}

resource "random_string" "name" {
  lower   = true
  upper   = false
  numeric = false
  special = false
  length  = 16
}

resource "azurerm_resource_group" "rg" {
  name     = "${var.resource_groups_prefix}-${random_string.name.result}"
  location = var.location
}

resource "azurerm_storage_account" "adls" {
  name                     = random_string.name.result
  location                 = azurerm_resource_group.rg.location
  resource_group_name      = azurerm_resource_group.rg.name
  account_tier             = "Standard"
  account_replication_type = "LRS"
  account_kind             = "StorageV2"
  is_hns_enabled           = "true"
  public_network_access_enabled = "true"
}

resource "azurerm_role_assignment" "role_assignment" {
  scope                = azurerm_storage_account.adls.id
  role_definition_name = "Storage Blob Data Contributor"
  principal_id         = data.azurerm_client_config.current.object_id
}

resource "time_sleep" "role_assignment_sleep" {
  create_duration = "60s"
  triggers = {
    role_assignment = azurerm_role_assignment.role_assignment.id
  }
}

resource "azurerm_user_assigned_identity" "adf_uami" {
  location            = azurerm_resource_group.rg.location
  name                = "adfuami-${random_string.name.result}"
  resource_group_name = azurerm_resource_group.rg.name
}

resource "azurerm_role_assignment" "uami_role_assignment" {
  scope                = azurerm_storage_account.adls.id
  role_definition_name = "Storage Blob Data Contributor"
  principal_id         = azurerm_user_assigned_identity.adf_uami.principal_id
}

resource "azurerm_storage_data_lake_gen2_filesystem" "adls_filesystem" {
  for_each           = var.adls_filesystems
  name               = each.value
  storage_account_id = azurerm_storage_account.adls.id
  depends_on         = [time_sleep.role_assignment_sleep]
}

resource "azurerm_storage_blob" "csv_copy" {
  name                   = "${azurerm_storage_data_lake_gen2_filesystem.adls_filesystem["input_copy"].name}.csv"
  storage_account_name   = azurerm_storage_account.adls.name
  storage_container_name = azurerm_storage_data_lake_gen2_filesystem.adls_filesystem["input_copy"].name
  type                   = "Block"
  source                 = "input.csv"
  depends_on = [azurerm_storage_data_lake_gen2_filesystem.adls_filesystem["input_copy"]]
}

resource "azurerm_storage_blob" "csv_flow" {
  name                   = "${azurerm_storage_data_lake_gen2_filesystem.adls_filesystem["input_flow"].name}.csv"
  storage_account_name   = azurerm_storage_account.adls.name
  storage_container_name = azurerm_storage_data_lake_gen2_filesystem.adls_filesystem["input_flow"].name
  type                   = "Block"
  source                 = "input.csv"
  depends_on = [azurerm_storage_data_lake_gen2_filesystem.adls_filesystem["input_flow"]]
}

resource "azurerm_data_factory" "adf" {
  name                            = random_string.name.result
  location                        = azurerm_resource_group.rg.location
  resource_group_name             = azurerm_resource_group.rg.name
  managed_virtual_network_enabled = true
  identity {
    type = "SystemAssigned, UserAssigned"
    identity_ids = [azurerm_user_assigned_identity.adf_uami.id]
  }
}

resource "azurerm_data_factory_integration_runtime_azure" "adf_integration_runtime" {
  name                    = "adfintegrationruntime"
  data_factory_id         = azurerm_data_factory.adf.id
  location                = azurerm_data_factory.adf.location
  virtual_network_enabled = true
  cleanup_enabled = false
  time_to_live_min = 60
}

resource "azurerm_data_factory_managed_private_endpoint" "adf_managed_pe" {
  name               = "adf_managed_pe"
  data_factory_id    = azurerm_data_factory.adf.id
  target_resource_id = azurerm_storage_account.adls.id
  subresource_name   = "dfs"
}

# HACK: no support exists as of now in azurerm provider for auto-approval when adding ADF managed private endpoints
# (https://github.com/hashicorp/terraform-provider-azurerm/issues/19777)
resource "null_resource" "adf_managed_pe_approval" {
  depends_on = [azurerm_data_factory_managed_private_endpoint.adf_managed_pe]
  provisioner "local-exec" {
    command     = <<-EOT
          $storage_id = $(az network private-endpoint-connection list --id ${azurerm_storage_account.adls.id} --query "[?contains(properties.privateEndpoint.id, 'vnet')].id" -o json) | ConvertFrom-Json
          az network private-endpoint-connection approve --id $storage_id --description "Approved in Terraform"
        EOT
    interpreter = ["PowerShell", "-Command"]
  }
}

resource "azapi_resource" "credential" {
  type = "Microsoft.DataFactory/factories/credentials@2018-06-01"
  name = "credential"
  parent_id = azurerm_data_factory.adf.id
  body = jsonencode({
    properties = {
      type = "ManagedIdentity"
      typeProperties = {
        resourceId = azurerm_user_assigned_identity.adf_uami.id
      }
    }
  })
  response_export_values = ["properties.type", "properties.typeProperties.resourceId"]
}

resource "azurerm_data_factory_linked_custom_service" "adls" {
  name            = "AzureDataLakeStorage"
  data_factory_id = azurerm_data_factory.adf.id
  type            = "AzureBlobFS"
  type_properties_json = <<JSON
  {
    "url": "${azurerm_storage_account.adls.primary_dfs_endpoint}",
    "credential": {
      "referenceName": "${azapi_resource.credential.name}",
      "type": "CredentialReference"
    }
  }
  JSON
  integration_runtime {
    name = azurerm_data_factory_integration_runtime_azure.adf_integration_runtime.name
  }
}

resource "azurerm_data_factory_dataset_delimited_text" "storage" {
  name                = "storage"
  data_factory_id     = azurerm_data_factory.adf.id
  linked_service_name = azurerm_data_factory_linked_custom_service.adls.name
  azure_blob_fs_location {
    file_system = "@dataset().filesystem"
    filename = "@dataset().file"
  }
  parameters = {
    filesystem = ""
    path = ""
    file = ""
  }
  column_delimiter = ","
  escape_character = "\\"
  quote_character  = "\""
  row_delimiter = "\r"
  first_row_as_header = true
}

resource "azurerm_data_factory_pipeline" "adf_pipeline_copy_activity" {
  name            = "Copy from ${azurerm_storage_data_lake_gen2_filesystem.adls_filesystem["input_copy"].name} to ${azurerm_storage_data_lake_gen2_filesystem.adls_filesystem["output_copy"].name} with Copy Activity"
  data_factory_id = azurerm_data_factory.adf.id
  activities_json = <<JSON
  [
            {
                "name": "Copy from input to output",
                "type": "Copy",
                "dependsOn": [],
                "policy": {
                    "timeout": "0.12:00:00",
                    "retry": 0,
                    "retryIntervalInSeconds": 30,
                    "secureOutput": false,
                    "secureInput": false
                },
                "userProperties": [],
                "typeProperties": {
                    "source": {
                        "type": "DelimitedTextSource",
                        "storeSettings": {
                            "type": "AzureBlobFSReadSettings",
                            "recursive": true,
                            "enablePartitionDiscovery": false
                        },
                        "formatSettings": {
                            "type": "DelimitedTextReadSettings"
                        }
                    },
                    "sink": {
                        "type": "DelimitedTextSink",
                        "storeSettings": {
                            "type": "AzureBlobFSWriteSettings"
                        },
                        "formatSettings": {
                            "type": "DelimitedTextWriteSettings",
                            "quoteAllText": true,
                            "fileExtension": ".txt"
                        }
                    },
                    "enableStaging": false,
                    "translator": {
                        "type": "TabularTranslator",
                        "typeConversion": true,
                        "typeConversionSettings": {
                            "allowDataTruncation": true,
                            "treatBooleanAsNumber": false
                        }
                    }
                },
                "inputs": [
                    {
                        "referenceName": "${azurerm_data_factory_dataset_delimited_text.storage.name}",
                        "type": "DatasetReference",
                        "parameters": {
                            "file": "${azurerm_storage_data_lake_gen2_filesystem.adls_filesystem["input_copy"].name}.csv",
                            "path": "void",
                            "filesystem": "${azurerm_storage_data_lake_gen2_filesystem.adls_filesystem["input_copy"].name}"
                        }
                    }
                ],
                "outputs": [
                    {
                        "referenceName": "${azurerm_data_factory_dataset_delimited_text.storage.name}",
                        "type": "DatasetReference",
                        "parameters": {
                            "file": "${azurerm_storage_data_lake_gen2_filesystem.adls_filesystem["output_copy"].name}.csv",
                            "path": "void",
                            "filesystem": "${azurerm_storage_data_lake_gen2_filesystem.adls_filesystem["output_copy"].name}"
                        }
                    }
                ]
            }
  ]
  JSON
}

resource "azurerm_data_factory_data_flow" "dataflow" {
  name            = "dataflow"
  data_factory_id = azurerm_data_factory.adf.id

  source {
    name = "source"
    dataset {
      name = azurerm_data_factory_dataset_delimited_text.storage.name
    }
  }

  sink {
    name = "sink"
    dataset {
      name = azurerm_data_factory_dataset_delimited_text.storage.name
    }
  }
  script = <<EOT
source(allowSchemaDrift: true,
     validateSchema: false,
     ignoreNoFilesFound: false) ~> source
source sink(allowSchemaDrift: true,
     validateSchema: false,
     umask: 0022,
     preCommands: [],
     postCommands: [],
     skipDuplicateMapInputs: true,
     skipDuplicateMapOutputs: true) ~> sink
  EOT
}

resource "azurerm_data_factory_pipeline" "adf_pipeline_data_flow" {
  name            = "Copy from ${azurerm_storage_data_lake_gen2_filesystem.adls_filesystem["input_flow"].name} to ${azurerm_storage_data_lake_gen2_filesystem.adls_filesystem["output_flow"].name} with Data Flow"
  data_factory_id = azurerm_data_factory.adf.id
  activities_json = <<JSON
  [
            {
                "name": "Copy from input to output",
                "type": "ExecuteDataFlow",
                "dependsOn": [],
                "policy": {
                    "timeout": "0.12:00:00",
                    "retry": 0,
                    "retryIntervalInSeconds": 30,
                    "secureOutput": false,
                    "secureInput": false
                },
                "userProperties": [],
                "typeProperties": {
                    "dataflow": {
                        "referenceName": "${azurerm_data_factory_data_flow.dataflow.name}",
                        "type": "DataFlowReference",
                        "datasetParameters": {
                            "source": {
                                "file": "${azurerm_storage_data_lake_gen2_filesystem.adls_filesystem["input_flow"].name}.csv",
                                "filesystem": "${azurerm_storage_data_lake_gen2_filesystem.adls_filesystem["input_flow"].name}",
                                "path": "void"
                            },
                            "sink": {
                                "file": "${azurerm_storage_data_lake_gen2_filesystem.adls_filesystem["output_flow"].name}.csv",
                                "filesystem": "${azurerm_storage_data_lake_gen2_filesystem.adls_filesystem["output_flow"].name}",
                                "path": "void"
                            }
                        }
                    },
                    "integrationRuntime": {
                        "referenceName": "${azurerm_data_factory_integration_runtime_azure.adf_integration_runtime.name}",
                        "type": "IntegrationRuntimeReference"
                    },
                    "traceLevel": "Fine"
                }
            }  ]
  JSON

  depends_on = [azurerm_data_factory_dataset_delimited_text.storage]
}