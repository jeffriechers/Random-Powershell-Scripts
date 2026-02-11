Thanks to https://github.com/X4BNet/lists_vpn for creating and maintaining these lists.

## CIDRtoRange_Dataset.ps1
PowerShell script to download a CIDR text file from github and convert it into a Ranged NetScaler dataset format.  Default is set to pull from X4BNet for VPN providers ip ranges.  It breaks the output into 5000 line maximum text files in a copy and paste format to create and populate the datasets.

## CIDR_Dataset.ps1
PowerShell script to download a CIDR text file from github and convert it into a Ranged NetScaler dataset format.  Default is set to pull from X4BNet for VPN providers ip ranges.  This PowerShell script will de-duplicate any entries in the text file for overlapping subnets.  It breaks the output into 5000 line maximum text files in a copy and paste format to create and populate the datasets.

## Commands to add to NetScaler
Here are the commands I use to block these subnets on my NetScaler.  These were built from the datacenters ipv4.txt download.  If you only build the vpn ipv4.txt you will have less VPNBlocklists to add to your Responder Policy.

After importing these, you can bind them to any external Load Balancer, Content Switch, or NetScaler Gateway you want to be blocked to these IPs.

```
add audit messageaction VPNBLOCKLIST WARNING "CLIENT.IP.SRC + \" was dropped because they are listed in the VPN Blocklist\"" -logtoNewnslog YES
add responder policy "VPN and Datacenter Block" "(CLIENT.IP.SRC.TYPECAST_TEXT_T.CONTAINS_ANY(\"VPNBlocklist1\") || CLIENT.IP.SRC.TYPECAST_TEXT_T.CONTAINS_ANY(\"VPNBlocklist2\") || CLIENT.IP.SRC.TYPECAST_TEXT_T.CONTAINS_ANY(\"VPNBlocklist3\") || CLIENT.IP.SRC.TYPECAST_TEXT_T.CONTAINS_ANY(\"VPNBlocklist4\") || CLIENT.IP.SRC.TYPECAST_TEXT_T.CONTAINS_ANY(\"VPNBlocklist5\") || CLIENT.IP.SRC.TYPECAST_TEXT_T.CONTAINS_ANY(\"VPNBlocklist6\") || CLIENT.IP.SRC.TYPECAST_TEXT_T.CONTAINS_ANY(\"VPNBlocklist7\") ||  CLIENT.IP.SRC.TYPECAST_TEXT_T.CONTAINS_ANY(\"VPNBlocklist8\") ||  CLIENT.IP.SRC.TYPECAST_TEXT_T.CONTAINS_ANY(\"VPNBlocklist9\")) " DROP -logAction VPNBLOCKLIST
```
