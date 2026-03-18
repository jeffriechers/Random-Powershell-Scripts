Thanks to https://github.com/X4BNet/lists_vpn for creating and maintaining these lists.

PowerShell script to download a CIDR text file containing all the subnets for commercial VPN and VPS providers from github, and then process it through a NetScaler GeoIP Location CSV.  Where it finds items in the CSV that are listed in the downloaded CIDR file it replaces the Continent entry with a custom VPN entry.  You then can create a Responder Policy to match that VPN Continent value to flag or drop traffic accessing from those subnets.  This process is faster matching and processing than analyzing 9 datasets for matching IPs.

## How to use - Build your own updated version
- Sign up for a MaxMind account, and download either the country or city csv.
- Using the NetScaler Console or Console Service deploy the ZIP file to a NetScaler.
- WINSCP into the NetScaler instance and download the converted CSV from \var\netscaler\locdb\Citrix_Netscaler_InBuilt_GeoIP_DB_-uploaddate-.csv
- Download the CustomGeoBuild.ps1 to your machine.
- From PowerShell run .\CustomGeoBuild.ps1 Citrix_Netscaler_InBuilt_GeoIP_DB_-uploaddate-.csv

If you downloaded the City Database, this process will run for ~1 hour.  For the Country Database it will run for ~15 minutes.
- Upload the new CustomGeoIP.csv directly to your NetScalers under \var\netscaler\locdb with WINSCP
- From the NetScaler web console select this new database as the location database.  At this time pushing a custom CSV from NetScaler Console does not work.

Working with Citrix Support on this, as pushing a custom CSV should work.

- Create a custom Message Action and Responder to look for the custom continent code.
```
add audit messageaction VPNBLOCKLIST WARNING "CLIENT.IP.SRC + \" was dropped because they are listed in the new VPN and VPS Blocking Method\"" -logtoNewnslog YES
add responder policy Drop_VPN_VPS "CLIENT.IP.SRC.MATCHES_LOCATION(\"VPN.*.*.*.*.*\")" DROP -logAction VPNBLOCKLIST
```
- Bind this policy at a lower number than your Geo Location blocking, so you can identify VPN and VPS hits from outside your allowed geo locations.

## How to use - Sample version I provide here
- Download CustomGeoIP.zip
- Unzip CustomGeoIP.csv from zip.
- Upload the new CuistomGeoIP.csv directly to your NetScalers as the new location database
Working with Citrix Support on this, as pushing a custom CSV doesn't currently work from NetScaler Console.
- Create a custom Message Action and Responder to look for the custom continent code.
```
add audit messageaction VPNBLOCKLIST WARNING "CLIENT.IP.SRC + \" was dropped because they are listed in the new VPN and VPS Blocking Method\"" -logtoNewnslog YES
add responder policy Drop_VPN_VPS "CLIENT.IP.SRC.MATCHES_LOCATION(\"VPN.*.*.*.*.*\")" DROP -logAction VPNBLOCKLIST
```
- Bind this policy at a lower number than your Geo Location blocking, so you can identify VPN and VPS hits from outside your allowed geo locations.
