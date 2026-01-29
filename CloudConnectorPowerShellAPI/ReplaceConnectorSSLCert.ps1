#Requires -Version 7.0
#Requires -Version 7.0
param (
    [Parameter(Mandatory = $true)]
    [string]$baseUrl #FQDN of Delivery Controller to run export from.
)

Write-Host "Please enter your connector login credentials."

# --- Step 1: Prompt for login ---
$cred = Get-Credential -Message "Enter connector login credentials"

$loginBody = @{
    username = $cred.UserName
    password = $cred.GetNetworkCredential().Password
} | ConvertTo-Json

$loginUri = "$baseUrl/`$login"   # escape the $ so PowerShell sends /$login

# --- Step 2: POST /$login and capture token ---
$loginResponse = Invoke-RestMethod -Method POST `
    -Uri $loginUri `
    -Headers @{
    "Accept"       = "*/*"
    "Content-Type" = "application/json"
} `
    -Body $loginBody `
    -SkipCertificateCheck

# Extract token (adjust property name if the appliance uses a different field)
$token = $loginResponse.token

Write-Host "Login successful. Token acquired."

# --- Step 3: Prepare certificate payload ---
$certPem = @"
-----BEGIN CERTIFICATE-----

-----END CERTIFICATE-----
"@

$keyPem = @"
-----BEGIN PRIVATE KEY-----

-----END PRIVATE KEY-----
"@

$replaceBody = @{
    certBytes  = $certPem
    key        = $keyPem
    passphrase = ""  # leave empty if not needed
} | ConvertTo-Json -Depth 5

$replaceUri = "$baseUrl/`$replaceSslCert"

# --- Step 4: POST /$replaceSslCert with Bearer token ---
$replaceResponse = Invoke-RestMethod -Method POST `
    -Uri $replaceUri `
    -Headers @{
    "Accept"        = "application/json"
    "Authorization" = "Bearer $token"
    "Content-Type"  = "application/json"
} `
    -Body $replaceBody `
    -SkipCertificateCheck

Write-Host "SSL certificate replacement request submitted."
$replaceResponse