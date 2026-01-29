#Requires -Version 7.0
param (
    [Parameter(Mandatory = $true)]
    [string]$baseUrl #FQDN of Delivery Controller to run export from.
)

# --- Step 1: Check current credential status ---
$status = Invoke-RestMethod -Method GET `
    -Uri "$baseUrl/credentials" `
    -Headers @{
    Accept     = "*/*"
    Connection = "keep-alive"
} `
    -SkipCertificateCheck

$status

# --- Step 2: If credentials are NOT set up, prompt and POST them ---
if (-not $status.credentialsAreSetup) {

    Write-Host "Connector credentials are not set up. Please enter new credentials."

    # Prompt user for username/password
    $cred = Get-Credential -Message "Enter connector admin credentials"

    # Build JSON body
    $body = @{
        username = $cred.UserName
        password = $cred.GetNetworkCredential().Password
    } | ConvertTo-Json

    # POST to /credentials
    $response = Invoke-RestMethod -Method POST `
        -Uri "$baseUrl/credentials" `
        -Headers @{
        Accept         = "*/*"
        "Content-Type" = "application/json"
    } `
        -Body $body `
        -SkipCertificateCheck

    Write-Host "Credentials have been submitted."
    $response
}
else {
    Write-Host "Credentials are already set up."
}