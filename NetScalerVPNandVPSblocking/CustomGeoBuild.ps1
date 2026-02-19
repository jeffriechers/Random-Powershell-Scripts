# -------------------------------
# CONFIG
# -------------------------------
param (
    [Parameter(Mandatory = $true)]
    [string]$CsvPath # Name of the Maxmind DB Downloaded.
)

$GitHubUrl   = "https://raw.githubusercontent.com/X4BNet/lists_vpn/refs/heads/main/output/datacenter/ipv4.txt"
$OutputPath   = ".\CustomGeoIP.csv" # Output file
$VpnContinent = "VPN"                       # Faux continent override
# -------------------------------


# Convert dotted IPv4 → UInt32
function Convert-IPToInt {
    param([string]$IP)
    if ([string]::IsNullOrWhiteSpace($IP)) {
        throw "IP address is empty"
    }

    $parts = $IP.Trim() -split '\.'

    if ($parts.Count -ne 4) {
        throw "Invalid IPv4 address format: '$IP'"
    }

    $bytes = foreach ($p in $parts) {
        if ($p -notmatch '^\d+$' -or [int]$p -gt 255) {
            throw "Invalid IPv4 octet '$p' in '$IP'"
        }
        [byte]$p
    }

    [Array]::Reverse($bytes)
    return [BitConverter]::ToUInt32($bytes, 0)
}

function Find-RangeBinary {
    param(
        [uint32]$value,
        [array]$ranges
    )

    $low = 0
    $high = $ranges.Count - 1

    while ($low -le $high) {
        $mid = [int](($low + $high) / 2)
        $r = $ranges[$mid]

        if ($value -lt $r.Start) {
            $high = $mid - 1
        }
        elseif ($value -gt $r.End) {
            $low = $mid + 1
        }
        else {
            return $r  
        }
    }

    return $null
}



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
    if ($ipAddr.AddressFamily -ne [Net.Sockets.AddressFamily]::InterNetwork) {
        throw "Can only process CIDR for IPv4"
    }

    $shiftCnt = 32 - $maskLen
    $mask = -bnot ((1 -shl $shiftCnt) - 1)

    $ipNum = [Net.IPAddress]::NetworkToHostOrder(
        [BitConverter]::ToInt32($ipAddr.GetAddressBytes(), 0)
    )

    $ipStart = ($ipNum -band $mask)
    $ipEnd   = ($ipNum -bor (-bnot $mask))

    
    $startIP = ([BitConverter]::GetBytes(
        [Net.IPAddress]::HostToNetworkOrder($ipStart)
    ) | ForEach-Object { $_ }) -join '.'

    $endIP = ([BitConverter]::GetBytes(
        [Net.IPAddress]::HostToNetworkOrder($ipEnd)
    ) | ForEach-Object { $_ }) -join '.'


    return [PSCustomObject]@{
        Start   = $ipStart
        End     = $ipEnd
        StartIP = $startIP
        EndIP   = $endIP
    }
}

Write-Host "Downloading CIDR list..."
$CIDRs = Invoke-WebRequest -Uri $GitHubUrl -UseBasicParsing |
         Select-Object -ExpandProperty Content

$CIDRList = $CIDRs -split "\r?\n" |
    ForEach-Object { $_.Trim() } |
    Where-Object { $_ -ne "" }



# Convert all CIDRs into "start-end" strings
Write-Host "Convert CIDRs to ranges"
$ranges = foreach ($cidr in $CIDRList) {
    try {
        $obj = cidrToIpRange $cidr
        if ($obj) { $obj }
    }
    catch {
        Write-Warning "Failed to convert $cidr"
    }
}
$ranges = $ranges | Sort-Object Start

# Load CSV
# Skip the first 7 metadata lines
$raw = Get-Content $CsvPath | Select-Object -Skip 7

# Define the real column names (based on your sample)
$headers = @(
    "startip",      # 0
    "endip",        # 1
    "continent",    # 2
    "country",      # 3
    "region",       # 4
    "subdivision2", # 5
    "city",         # 6
    "unused1",      # 7
    "latitude",     # 8
    "longitude"     # 9
)


# Convert to CSV objects with proper headers
$Rows = $raw | ConvertFrom-Csv -Header $headers
Write-Host "Analyze Locations CSV, and replace known VPN and VPS Subnets with custom $VpnContinent Continent Entry"
foreach ($row in $Rows) {

    $rowStart = Convert-IPToInt $row.startip
    $rowEnd   = Convert-IPToInt $row.endip
$range = Find-RangeBinary -value $rowStart -ranges $ranges

if ($range -and $rowEnd -le $range.End) {
    $row.continent = $VpnContinent
}
}
$headerBlock = @(
    "NSGEO1.0"
    "Qualifier1=Continent"
    "Qualifier2=Country_Code"
    "Qualifier3=Subdivision_1_Name"
    "Qualifier4=Subdivision_2_Name"
    "Qualifier5=City"
    "Start"
)

# Export with header, then remove it
$Rows |
    Export-Csv -Path $OutputPath -NoTypeInformation |
    Out-Null

# Remove CSV header + ALL quotes, write as ASCII immediately
$clean = (Get-Content $OutputPath | Select-Object -Skip 1) -replace '"',''
$clean | Set-Content $OutputPath -Encoding ASCII

# Prepend NSGEO header block
$final = $headerBlock + $clean
$final | Set-Content $OutputPath -Encoding ASCII

Write-Host "Updated CSV written to: $OutputPath"