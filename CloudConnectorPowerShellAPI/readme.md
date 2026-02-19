This is my collection of PowerShell 7 scripts for API administration of Citrix Cloud Connector Appliances.

* CredentialsCheck.ps1
Check to see if authentication to your appliance has been setup, if not it will setup that authentication from your device.

.\CredentialsCheck.ps1 "FQDNofConnectorAppliance"

* ReplaceConnectorSSLCert.ps1
Login to your appliance, and upload a replacement certificate and key.  This is required if you want to use the AOT function from your infrastructure.

Convert your certificate to PEM format, and place the key and certificate in the powershell script before running.

Also upload your Root and Intermediate Certificate via the Connector Appliance GUI.

.\ReplaceConnectorSSLCert.ps1 "FQDNofConnectorAppliance"