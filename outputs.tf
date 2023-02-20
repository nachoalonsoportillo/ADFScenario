output "name" {
    value = "https://adf.azure.com/en/home?factory=${azurerm_data_factory.adf.id}"
    description = "URL pointing to the Data Factory web UI"
}