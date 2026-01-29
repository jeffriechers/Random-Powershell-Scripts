# Parameters
$GitHubUrl   = "https://raw.githubusercontent.com/X4BNet/lists_vpn/refs/heads/main/output/vpn/ipv4.txt"
$OutputDir   = "C:\NetScalerDatasets"
$DatasetName = "VPNBlocklist"

# Ensure output directory exists
if (-not (Test-Path $OutputDir)) {
    New-Item -ItemType Directory -Path $OutputDir | Out-Null
}

# Download the CIDR list
$CIDRs = Invoke-WebRequest -Uri $GitHubUrl -UseBasicParsing | Select-Object -ExpandProperty Content
$CIDRList = $CIDRs -split "\r?\n" |
    ForEach-Object { $_.Trim() } |
    Where-Object { $_ -ne "" }
function cidrToIpRange {
    param (
        [string] $cidrNotation
    )

    $addr, $maskLength = $cidrNotation -split '/'
    [int]$maskLen = 0
    if (-not [int32]::TryParse($maskLength, [ref] $maskLen)) {
        throw "Cannot parse CIDR mask length string: '$maskLen'"
    }
    if (0 -gt $maskLen -or $maskLen -gt 32) {
        throw "CIDR mask length must be between 0 and 32"
    }
    $ipAddr = [Net.IPAddress]::Parse($addr)
    if ($ipAddr -eq $null) {
        throw "Cannot parse IP address: $addr"
    }
    if ($ipAddr.AddressFamily -ne [Net.Sockets.AddressFamily]::InterNetwork) {
        throw "Can only process CIDR for IPv4"
    }

    $shiftCnt = 32 - $maskLen
    $mask = -bnot ((1 -shl $shiftCnt) - 1)
    $ipNum = [Net.IPAddress]::NetworkToHostOrder([BitConverter]::ToInt32($ipAddr.GetAddressBytes(), 0))
    $ipStart = ($ipNum -band $mask) + 1
    $ipEnd = ($ipNum -bor (-bnot $mask)) - 1

    # return as tuple of strings:
    ([BitConverter]::GetBytes([Net.IPAddress]::HostToNetworkOrder($ipStart)) | ForEach-Object { $_ } ) -join '.'
    ([BitConverter]::GetBytes([Net.IPAddress]::HostToNetworkOrder($ipEnd)) | ForEach-Object { $_ } ) -join '.'
}
$start, $end = $CIDRList | ForEach-Object { cidrToIpRange $_ } | Where-Object { $_ -ne $null }

# Convert all CIDRs into "start-end" strings
$ranges = foreach ($cidr in $CIDRList) {
    try {
        $start, $end = cidrToIpRange $cidr
        if ($start -and $end) {
            "$start - $end"
        }
    }
    catch {
        Write-Warning "Failed to convert $cidr"
    }
}

# Remove any nulls
$ranges = $ranges | Where-Object { $_ -ne $null }

# Split into chunks of 5000 entries
$chunkSize = 5000
$chunks = [System.Collections.Generic.List[object]]::new()

for ($i = 0; $i -lt $ranges.Count; $i += $chunkSize) {
    $endIndex = [Math]::Min($i + $chunkSize - 1, $ranges.Count - 1)
    $chunks.Add($ranges[$i..$endIndex])
}

# Write each chunk to a dataset file
# for ($j = 0; $j -lt $chunks.Count; $j++) {
#     $fileName = Join-Path $OutputDir "$DatasetName-$($j+1).txt"
#     $chunks[$j] | Out-File -FilePath $fileName -Encoding ascii
#     Write-Host "Created dataset file: $fileName"
# }
for ($j = 0; $j -lt $chunks.Count; $j++) {

    $datasetFileName = "$DatasetName$($j+1)"   # e.g., VPNBlocklist1
    $filePath = Join-Path $OutputDir "$datasetFileName.txt"

    # Rewrite each range line to include the dataset name
    $formattedLines = foreach ($line in $chunks[$j]) {
        # $line is "start - end"
        $parts = $line -split '\s*-\s*'
        $startIP = $parts[0]
        $endIP   = $parts[1]

        "bind policy dataset $datasetFileName $startIP -endRange $endIP"
    }

    $formattedLines | Out-File -FilePath $filePath -Encoding ascii
    Write-Host "Created dataset file: $filePath"
}