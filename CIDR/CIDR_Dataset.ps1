# Parameters
$GitHubUrl   = "https://raw.githubusercontent.com/X4BNet/lists_vpn/refs/heads/main/output/vpn/ipv4.txt"
#$GitHubUrl   = "https://raw.githubusercontent.com/X4BNet/lists_vpn/refs/heads/main/output/datacenter/ipv4.txt" # Includes datacenter virtual machine hosts, and consumer vpns.
#$GitHubUrl   = "https://raw.githubusercontent.com/jeffriechers/Random-Powershell-Scripts/refs/heads/main/Subnettest.txt" # Text file with overlapping subnets for testing.
$OutputDir   = ".\NetScalerDatasets"
$BaseName = "VPNBlocklist"
$ChunkSize   = 5000

# Ensure output directory exists
if (-not (Test-Path $OutputDir)) {
    New-Item -ItemType Directory -Path $OutputDir | Out-Null
}

# ================================
# DOWNLOAD CIDR LIST
# ================================
Write-Host "Downloading CIDR list..."
$CIDRs = Invoke-WebRequest -Uri $GitHubUrl -UseBasicParsing |
         Select-Object -ExpandProperty Content

$CIDRList = $CIDRs -split "\r?\n" |
    ForEach-Object { $_.Trim() } |
    Where-Object { $_ -ne "" }

Write-Host "Downloaded $($CIDRList.Count) CIDRs."

# ================================
# CIDR → INTEGER RANGE CONVERSION
# ================================
function Get-IPRange {
    param([string]$cidr)

    $addr, $mask = $cidr -split '/'
    [int]$mask = $mask

    $ip = [Net.IPAddress]::Parse($addr)
    $bytes = $ip.GetAddressBytes()
    $ipInt = [Net.IPAddress]::NetworkToHostOrder([BitConverter]::ToInt32($bytes, 0))

    $shift = 32 - $mask
    $maskInt = -bnot ((1 -shl $shift) - 1)

    $network = $ipInt -band $maskInt
    $broadcast = $network + ((1 -shl $shift) - 1)

    return [PSCustomObject]@{
        CIDR      = $cidr
        Network   = $network
        Broadcast = $broadcast
        Mask      = $mask
    }
}

Write-Host "Normalizing CIDRs..."
$cidrRanges = $CIDRList | ForEach-Object { Get-IPRange $_ }

# ================================
# REMOVE NESTED / OVERLAPPING SUBNETS
# ================================
Write-Host "Removing nested subnets..."

# Sort broadest → narrowest
$cidrRanges = $cidrRanges | Sort-Object Mask

$kept = @()
$duplicates = @()

foreach ($entry in $cidrRanges) {
    $isInside = $false
    $container = $null

    foreach ($k in $kept) {
        if ($entry.Network -ge $k.Network -and $entry.Broadcast -le $k.Broadcast) {
            $isInside = $true
            $container = $k
            break
        }
    }

    if ($isInside) {
        $duplicates += [PSCustomObject]@{
            CIDR   = $entry.CIDR
            Reason = "Contained within $($container.CIDR)"
        }
    } else {
        $kept += $entry
    }
}

Write-Host "Kept $($kept.Count) CIDRs after collapsing."
Write-Host "Excluded $($duplicates.Count) nested CIDRs."

# ================================
# REPORT DUPLICATES
# ================================
if ($duplicates.Count -gt 0) {
    Write-Host ""
    Write-Host "===== NESTED CIDRs EXCLUDED =====" -ForegroundColor Yellow
    Write-Host ""

    foreach ($d in $duplicates) {
        Write-Host ("Excluded: {0,-18}  ({1})" -f $d.CIDR, $d.Reason) -ForegroundColor DarkYellow
    }

    Write-Host ""
    Write-Host "Total nested CIDRs excluded: $($duplicates.Count)" -ForegroundColor Yellow
    Write-Host ""
}

# ================================
# PREPARE FINAL OUTPUT LIST
# ================================
$finalCIDRs = $kept | Sort-Object Network | Select-Object -ExpandProperty CIDR

# ================================
# CHUNK INTO FILES OF 5000 LINES
# ================================
Write-Host "Chunking into $ChunkSize-line dataset files..."

$chunks = [System.Collections.Generic.List[object]]::new()
$chunk = @()

foreach ($cidr in $finalCIDRs) {
    $chunk += $cidr
    if ($chunk.Count -ge $ChunkSize) {
        $chunks.Add($chunk)
        $chunk = @()
    }
}
if ($chunk.Count -gt 0) { $chunks.Add($chunk) }

# ================================
# WRITE DATASET FILES WITH PREFIX
# ================================
for ($i = 0; $i -lt $chunks.Count; $i++) {

    $datasetName = "$BaseName$($i+1)"
    $filePath    = Join-Path $OutputDir "$datasetName.txt"

    # First line required by NetScaler
    $headerLine = "add policy dataset $datasetName ipv4"

    # Prefix each CIDR with the bind command
    $formattedLines = foreach ($cidr in $chunks[$i]) {
        "bind policy dataset $datasetName $cidr"
    }

    # Combine header + CIDR lines
    $output = @($headerLine) + $formattedLines

    # Write the file
    $output | Out-File -FilePath $filePath -Encoding ascii

    Write-Host "Created dataset file: $filePath"
}

Write-Host ""
Write-Host "All done. Created $($chunks.Count) dataset files." -ForegroundColor Green
