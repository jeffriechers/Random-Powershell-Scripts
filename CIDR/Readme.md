
## CIDRtoRange_Dataset.ps1
PowerShell script to download a CIDR text file from github and convert it into a Ranged NetScaler dataset format.  Default is set to pull from X4BNet for VPN providers ip ranges.  It breaks the output into 5000 line maximum text files in a copy and paste format to create and populate the datasets.

## CIDR_Dataset.ps1
PowerShell script to download a CIDR text file from github and convert it into a Ranged NetScaler dataset format.  Default is set to pull from X4BNet for VPN providers ip ranges.  This PowerShell script will de-duplicate any entries in the text file for overlapping subnets.  It breaks the output into 5000 line maximum text files in a copy and paste format to create and populate the datasets.