param(
    [Parameter(Mandatory)]
    [string]$NsConfPath,
    [Parameter(Mandatory)]
    [string]$OutputDotPath,
    [switch]$IncludeLB,
    [switch]$IncludeCS,
    [switch]$IncludeSG,
    [switch]$IncludeVPN,
    [switch]$IncludeAAA,
    [switch]$IncludeGSLB,
    [switch]$SVG,
    [switch]$PNG,
    [string]$GraphName = "netscaler_config"
)

$GraphvizPath = "C:\Program Files\Graphviz\bin\dot.exe"

if (-not (Test-Path $NsConfPath)) {
    throw "ns.conf not found at path: $NsConfPath"
}

Write-Host "Reading and decoding config from $NsConfPath..."
Add-Type -AssemblyName System.Web
$configLines = Get-Content -Path $NsConfPath | ForEach-Object {
    # Decode HTML entities first
    $line = [System.Web.HttpUtility]::HtmlDecode($_)

    # Normalize Unicode dash variants to ASCII hyphen-minus (0x2D) 
    $dashChars = @(
        0x2010, # Hyphen
        0x2011, # Non-breaking hyphen
        0x2012, # Figure dash
        0x2013, # En dash
        0x2014, # Em dash
        0x2015  # Horizontal bar
    )

    foreach ($d in $dashChars) {
        $line = $line -replace [char]$d, '-'
    }

    $line
}
#----------------------------------------------------
#   GLOBAL ANALYTICS EXCLUSION
#   Remove ANY line containing -analyticsProfile
# ---------------------------------------------------------
$configLines = $configLines | Where-Object { $_ -notmatch '-analyticsProfile' }
# ---------------------------
#   HOSTNAME
# ---------------------------
$nsHostname = $null
foreach ($line in $configLines | Where-Object { $_ -match '^set ns hostName ' }) {

    # Normalize HTML entities and strip quotes
    $clean = [System.Web.HttpUtility]::HtmlDecode($line) -replace '"', ''

    if ($clean -match '^set ns hostName\s+(\S+)') {
        $nsHostname = $matches[1]
    }
}
# ---------------------------------------------------------
#   APPLIANCE-LEVEL CONFIG SUMMARY (NSIP, SNIP, VLAN, HA, ROUTE)
# ---------------------------------------------------------
$nsIPs = @()   # NSIP entries
$snips = @()   # SNIP entries
$vlanDefs = @()
$vlanBinds = @()
$haNodes = @()
$defaultRoute = $null
# ---------------------------
#   NSIP from: set ns config -IPAddress
# ---------------------------
foreach ($line in $configLines | Where-Object { $_ -match '^set ns config -IPAddress ' }) {

    if ($line -match '-IPAddress\s+(\S+)\s+-netmask\s+(\S+)') {
        $nsIPs += [PSCustomObject]@{
            IP   = $matches[1]
            Mask = $matches[2]
            Src  = "set ns config"
        }
    }
}
# ---------------------------
#   NSIP from: add HA node 1 <ip>
#   (Node 1 is always the primary NSIP)
# ---------------------------
foreach ($line in $configLines | Where-Object { $_ -match '^add HA node 1 ' }) {

    if ($line -match '^add HA node 1\s+(\S+)') {
        $nsIPs += [PSCustomObject]@{
            IP   = $matches[1]
            Mask = $null
            Src  = "HA node 1"
        }
    }
}
# ---------------------------
#   SNIPs from: add ns ip <ip> <mask>
#   (Exclude VIPs)
# ---------------------------
foreach ($line in $configLines | Where-Object { $_ -match '^add ns ip ' }) {

    if ($line -match '-type\s+VIP') { continue }

    if ($line -match '^add ns ip\s+(\S+)\s+(\S+)') {
        $snips += [PSCustomObject]@{
            IP   = $matches[1]
            Mask = $matches[2]
        }
    }
}
# ---------------------------
#   VLAN definitions 
# ---------------------------
foreach ($line in $configLines | Where-Object { $_ -match '^add vlan ' }) {
    # Decode HTML entities and strip quotes
    $clean = [System.Web.HttpUtility]::HtmlDecode($line) -replace '"', ''
    # Match: add vlan <id> [-aliasName <anything>]
    if ($clean -match '^add vlan\s+(\d+)(?:\s+-aliasName\s+(.+))?') {
        $vlanId = $matches[1]
        $alias = $matches[2]
        if ($alias) {
            # Trim whitespace
            $alias = $alias.Trim()
        }
        $vlanDefs += [PSCustomObject]@{
            VLAN  = $vlanId
            Alias = $alias
        }
    }
}
# ---------------------------
#   VLAN bindings
# ---------------------------
foreach ($line in $configLines | Where-Object { $_ -match '^bind vlan ' }) {
    $vlan = $null
    if ($line -match '^bind vlan\s+(\d+)') {
        $vlan = $matches[1]
    }
    $iface = $null
    if ($line -match '-ifnum\s+(\S+)') {
        $iface = $matches[1]
    }
    $ip = $null
    $mask = $null
    if ($line -match '-IPAddress\s+(\S+)\s+(\S+)') {
        $ip = $matches[1]
        $mask = $matches[2]
    }
    $vlanBinds += [PSCustomObject]@{
        VLAN  = $vlan
        Iface = $iface
        IP    = $ip
        Mask  = $mask
    }
}
# ---------------------------
#   PBR ROUTES (NSIP subnet routing)
# ---------------------------
$pbrRoutes = @()
foreach ($line in $configLines | Where-Object { $_ -match '^add ns pbr ' }) {
    # Normalize HTML entities and strip quotes
    $clean = [System.Web.HttpUtility]::HtmlDecode($line) -replace '"', ''
    # Match: add ns pbr <name> ALLOW -srcIP = <range> -destIP = <range> -nextHop <ip>
    if ($clean -match '^add ns pbr\s+(\S+)\s+ALLOW.*?-srcIP\s*=\s*(\S+)\s+-destIP\s*=\s*(\S+).*?-nextHop\s+(\S+)') {
        $name = $matches[1]
        $srcIP = $matches[2]
        $destIP = $matches[3]
        $nextHop = $matches[4]
        $pbrRoutes += [PSCustomObject]@{
            Name    = $name
            SrcIP   = $srcIP
            DestIP  = $destIP
            NextHop = $nextHop
        }
    }
}
# ---------------------------
#   ROUTES (default + static)
# ---------------------------
$defaultRoute = $null
$staticRoutes = @()
foreach ($line in $configLines | Where-Object { $_ -match '^add route ' }) {
    # Normalize quotes and decode HTML entities
    $clean = [System.Web.HttpUtility]::HtmlDecode($line) -replace '"', ''
    # Match: add route <dest> <mask> <gateway>
    if ($clean -match '^add route\s+(\S+)\s+(\S+)\s+(\S+)') {
        $dest = $matches[1]
        $mask = $matches[2]
        $gateway = $matches[3]
        if ($dest -eq '0.0.0.0' -and $mask -eq '0.0.0.0') {
            # Default route
            $defaultRoute = $gateway
        }
        else {
            # Static route
            $staticRoutes += [PSCustomObject]@{
                Destination = $dest
                Mask        = $mask
                Gateway     = $gateway
            }
        }
    }
}
if ($IncludeLB) {
    # ---------------------------------------------------------
    #   LOAD BALANCING VSERVER PARSING
    # ---------------------------------------------------------
    $lbInfo = @{}
    $lbCerts = @{}
    $lbVservers = @()
    $lbBindings = @()
    # ---------------------------
    #   LB vServers
    # ---------------------------
    $lbVservers = @{}

    foreach ($line in $configLines | Where-Object { $_ -match '^add lb vserver ' }) {

        if ($line -match '^add lb vserver\s+("?)(.+?)\1\s+(\S+)\s+(\S+)\s+(\d+)') {

            $lbName = $matches[2]
            $proto = $matches[3]
            $vip = $matches[4]
            $port = $matches[5]

            $lbVservers[$lbName] = @{
                Protocol = $proto
                VIP      = $vip
                Port     = $port
            }
        }
    }
    # ---------------------------
    #   LB Bindings (services + service groups)
    # ---------------------------
    foreach ($line in $configLines | Where-Object { $_ -match '^bind lb vserver ' }) {

        # Skip analytics and policyName bindings
        if ($line -match '-analyticsProfile') { continue }
        if ($line -match '-policyName') { continue }

        # Case 1: bind lb vserver <vserver> <target>
        # Handles quoted or unquoted names with spaces
        if ($line -match '^bind lb vserver\s+("?)(.+?)\1\s+("?)(.+?)\3(\s+-|$)') {

            $vserver = $matches[2]
            $target = $matches[4].Trim()

            $lbBindings += [PSCustomObject]@{
                VServer = $vserver
                Target  = $target
            }

            continue
        }

        # (Optional) Case 2: if your config uses -serviceName / -serviceGroup explicitly
        if ($line -match '^bind lb vserver\s+("?)(.+?)\1\s+-service(Name|Group)\s+("?)(.+?)\4') {

            $vserver = $matches[2]
            $target = $matches[5].Trim()

            $lbBindings += [PSCustomObject]@{
                VServer = $vserver
                Target  = $target
            }

            continue
        }
    }
    # ---------------------------
    #   LB SSL Certificate Bindings
    # ---------------------------
    foreach ($line in $configLines | Where-Object { $_ -match '^bind ssl vserver ' }) {

        if ($line -match '^bind ssl vserver\s+(\S+)\s+-certkeyName\s+(\S+)') {

            $vserver = $matches[1]
            $cert = $matches[2]

            if (-not $lbCerts.ContainsKey($vserver)) {
                $lbCerts[$vserver] = @()
            }

            $lbCerts[$vserver] += $cert
        }
    }
    # ---------------------------
    #   LB Policy Bindings (Responder + Rewrite)
    # ---------------------------
    if ($null -eq $lbPolicyBindings -or $lbPolicyBindings.GetType().Name -ne 'Hashtable') {
        $lbPolicyBindings = @{}
    }
    foreach ($line in $configLines | Where-Object { $_ -match '^bind lb vserver ' }) {
        if ($line -match '^bind lb vserver\s+("?)(.+?)\1\s+-policyName\s+("?)(.+?)\3\s+-priority\s+(\d+).*?-type\s+(\S+)') {
            $lbvserver = $matches[2] -replace '"', ''
            $policy = $matches[4] -replace '"', ''
            $priority = [int]$matches[5]
            $ptype = $matches[6]
            # Ensure the key exists AND is an array
            if (-not $lbPolicyBindings.ContainsKey($lbvserver)) {
                $lbPolicyBindings[$lbvserver] = @()
            }
            elseif ($lbPolicyBindings[$lbvserver] -isnot [System.Collections.IList]) {
                $lbPolicyBindings[$lbvserver] = @($lbPolicyBindings[$lbvserver])
            }
            # Append binding
            $lbPolicyBindings[$lbvserver] += [PSCustomObject]@{
                Policy   = $policy
                Priority = $priority
                Type     = $ptype
            }
        }
    }
    # ---------------------------
    #   Rewrite Actions
    # ---------------------------
    if (-not $rewriteActions) { $rewriteActions = @{} }
    foreach ($line in $configLines | Where-Object { $_ -match '^add rewrite action ' }) {
        if ($line -match '^add rewrite action\s+("?)(.+?)\1\s+(\S+)\s+(.+)$') {
            $rwActionName = $matches[2]
            $rwActionType = $matches[3]   # replace / delete / insert / etc.
            $rwActionExpr = $matches[4]

            $rewriteActions[$rwActionName] = @{
                Type = $rwActionType
                Expr = $rwActionExpr
            }
        }
    }
    # ---------------------------
    #   Rewrite Policies
    # ---------------------------
    if (-not $rewritePolicies) { $rewritePolicies = @{} }
    foreach ($line in $configLines | Where-Object { $_ -match '^add rewrite policy ' }) {
        if ($line -match '^add rewrite policy\s+("?)(.+?)\1\s+"(.+?)"\s+("?)(.+?)\4$') {
            $policyName = $matches[2]
            $rule = $matches[3]
            $rwActionName = $matches[5]
            $rewritePolicies[$policyName] = @{
                Rule   = $rule
                Action = $rwActionName
            }
        }
    }
}
if ($IncludeCS) {
    # ---------------------------------------------------------
    #   CONTENT SWITCHING (CS) VSERVERS
    # ---------------------------------------------------------
    $csVservers = @()
    $csInfo = @{}
    $csCerts = @{}
    $csBindings = @{}   # FIXED — must be hashtable
    $csPolicies = @{}   # FIXED — must be hashtable
    $csResponderBindings = @{}
    # ---------------------------
    #   CS Policies
    # ---------------------------
    foreach ($line in $configLines | Where-Object { $_ -match '^add cs policy ' }) {

        if ($line -match '^add cs policy\s+(\S+)\s+-rule\s+"(.+)"') {
            $cspolicyName = $matches[1]
            $rule = $matches[2]

            # Hashtable assignment — now valid
            $csPolicies[$cspolicyName] = $rule
        }
    }
    # ---------------------------
    #   CS vServers (VIP + Port)
    # ---------------------------
    foreach ($line in $configLines | Where-Object { $_ -match '^add cs vserver ' }) {
        if ($line -match '^add cs vserver\s+(\S+)\s+\S+\s+(\S+)\s+(\d+)') {
            $name = $matches[1]
            $vip = $matches[2]
            $port = $matches[3]
            $csVservers += $name
            $csInfo[$name] = @{
                VIP  = $vip
                Port = $port
            }
        }
    }
    # ---------------------------
    #   CS Bindings
    # ---------------------------
    foreach ($line in $configLines | Where-Object { $_ -match '^bind cs vserver ' }) {
        # With target LB vserver
        if ($line -match '^bind cs vserver\s+(\S+)\s+-policyName\s+(\S+)\s+-targetLBVserver\s+(\S+)') {
            $csvserver = $matches[1]
            $policy = $matches[2]
            $targetLB = $matches[3]
            if (-not $csBindings.ContainsKey($csvserver)) {
                $csBindings[$csvserver] = @()
            }
            $csBindings[$csvserver] += [PSCustomObject]@{
                Policy   = $policy
                TargetLB = $targetLB
            }
        }
        # Policies bound without LB target (e.g., responder)
        elseif ($line -match '^bind cs vserver\s+(\S+)\s+-policyName\s+(\S+)') {
            $csvserver = $matches[1]
            $policy = $matches[2]
            if (-not $csBindings.ContainsKey($csvserver)) {
                $csBindings[$csvserver] = @()
            }
            $csBindings[$csvserver] += [PSCustomObject]@{
                Policy   = $policy
                TargetLB = $null
            }
        }
        # Matches: -policyName Foo -priority 100 -type REQUEST
        if ($line -match '^bind cs vserver\s+(\S+)\s+-policyName\s+("?)(.+?)\2\s+-priority\s+(\d+).*?-type\s+REQUEST') {
            $csvserver = $matches[1]
            $policy = $matches[3]   # clean name, no quotes
            $priority = [int]$matches[4]
            if (-not $csResponderBindings.ContainsKey($csvserver)) {
                $csResponderBindings[$csvserver] = @()
            }
            $csResponderBindings[$csvserver] += [PSCustomObject]@{
                Policy   = $policy
                Priority = $priority
            }
        }
    }
    # ---------------------------
    #   CS SSL Certificate Bindings
    # ---------------------------
    foreach ($line in $configLines | Where-Object { $_ -match '^bind ssl vserver ' }) {
        if ($line -match '^bind ssl vserver\s+(\S+)\s+-certkeyName\s+(\S+)') {
            $vserver = $matches[1]
            $cert = $matches[2]
            if (-not $csCerts.ContainsKey($vserver)) {
                $csCerts[$vserver] = @()
            }
            $csCerts[$vserver] += $cert
        }
    }
}
if ($IncludeSG) {
    # ---------------------------
    #   Responder Actions
    # ---------------------------
    if (-not $responderActions) { $responderActions = @{} }
    foreach ($line in $configLines | Where-Object { $_ -match '^add responder action ' }) {
        if ($line -match '^add responder action\s+(\S+)\s+(\S+)\s+q\|(.+)\|$') {
            $respActionName = $matches[1]
            $respActionType = $matches[2]
            $respActionExpr = $matches[3]
            $responderActions[$respActionName] = @{
                Type = $respActionType
                Expr = $respActionExpr
            }
            continue
        }
        if ($line -match '^add responder action\s+(\S+)\s+(\S+)\s+q\{(.+)\}$') {
            $respActionName = $matches[1]
            $respActionType = $matches[2]
            $respActionExpr = $matches[3]
            $responderActions[$respActionName] = @{
                Type = $respActionType
                Expr = $respActionExpr
            }
            continue
        }
        if ($line -match '^add responder action\s+(\S+)\s+(\S+)\s+"(.+)"$') {
            $respActionName = $matches[1]
            $respActionType = $matches[2]
            $respActionExpr = $matches[3]
            $responderActions[$respActionName] = @{
                Type = $respActionType
                Expr = $respActionExpr
            }
            continue
        }
    }
    # ---------------------------
    #   Responder Policies
    # ---------------------------
    if (-not $responderPolicies) { $responderPolicies = @{} }
    foreach ($line in $configLines | Where-Object { $_ -match '^add responder policy ' }) {
        if ($line -match '^add responder policy\s+("?)([^"\s]+(?:\s+[^"\s]+)*)\1\s+"(.+?)"\s+(\S+)$') {
            $policyName = $matches[2]
            $rule = $matches[3]
            $respActionName = $matches[4]
            $responderPolicies[$policyName] = @{
                Rule   = $rule
                Action = $respActionName
            }
        }
    }
    # ---------------------------------------------------------
    #   SERVICE GROUPS + MEMBERS
    # ---------------------------------------------------------
    $serviceGroups = @()
    $sgMemberBindings = @()
    # ---------------------------
    #   Service Group Definitions
    # ---------------------------
    foreach ($line in $configLines | Where-Object { $_ -match '^add serviceGroup ' }) {
        $name = $null
        # Case 1: quoted name
        if ($line -match '^add serviceGroup\s+"([^"]+)"') {
            $name = $matches[1]
        }
        # Case 2: unquoted name
        elseif ($line -match '^add serviceGroup\s+(\S+)') {
            $name = $matches[1]
        }
        if ([string]::IsNullOrWhiteSpace($name)) {
            continue
        }
        $serviceGroups += [PSCustomObject]@{
            Name = $name
        }
    }
    # ---------------------------
    #   Service Group Members
    # ---------------------------
    foreach ($line in $configLines | Where-Object { $_ -match '^bind serviceGroup ' }) {
        if ($line -match '^bind serviceGroup\s+("?)(.+?)\1\s+(\S+)\s+(\d+)') {
            $sgMemberBindings += [PSCustomObject]@{
                ServiceGroup = $matches[2].Trim('"')
                Server       = $matches[3]
                Port         = $matches[4]
            }
        }
    }
   
    # ---------------------------------------------------------
    #   SERVICES (INDIVIDUAL BACKEND ENDPOINTS)
    # ---------------------------------------------------------
    $services = @()
    foreach ($line in $configLines | Where-Object { $_ -match '^add service ' }) {
        # Pattern: add service <name> <ipOrServer> <protocol> <port>
        if ($line -match '^add service\s+(\S+)\s+(\S+)\s+(\S+)\s+(\d+)') {
            $services += [PSCustomObject]@{
                Name     = $matches[1]
                Target   = $matches[2]
                Protocol = $matches[3]
                Port     = $matches[4]
            }
        }
    }
}
if ($IncludeVPN) {
    # ---------------------------
    #   Traffic Policies
    # ---------------------------
    $trafficPolicies = @{}
    foreach ($line in $configLines | Where-Object { $_ -match '^add vpn trafficPolicy' }) {
        # Normalize HTML entities and strip quotes
        $clean = [System.Web.HttpUtility]::HtmlDecode($line) -replace '"', ''
        if ($clean -match '^add vpn trafficPolicy\s+(\S+)\s+(.+?)\s+(\S+)$') {
            $name = $matches[1]
            $rule = $matches[2]
            $action = $matches[3]
            $trafficPolicies[$name] = [PSCustomObject]@{
                Name   = $name
                Rule   = $rule
                Action = $action
            }
        }
    }
    # ---------------------------------------------------------
    #   VPN VSERVERS + POLICIES + STA + THEMES
    # ---------------------------------------------------------
    $vpnVservers = @()
    $vpnPolicyDetails = @{}
    $vpnSTA = @{}
    $vpnTheme = @{}
    $vpnInfo = @{}
    $vpnCerts = @{}
    $vpnSessionPolicyBindings = @{}
    # ---------------------------------------------------------
    #   SESSION POLICIES + SESSION ACTIONS
    # ---------------------------------------------------------
    $sessionPolicies = @{}
    $sessionActions = @{}
    # ---------------------------
    #   Session Policies
    # ---------------------------
    foreach ($line in $configLines | Where-Object { $_ -match '^add vpn sessionPolicy ' }) {
        # Case 1: -action <name>
        if ($line -match '^add vpn sessionPolicy\s+(\S+).*?-action\s+(\S+)') {
            $policyName = $matches[1]
            $actionName = $matches[2]
            $sessionPolicies[$policyName] = $actionName
            continue
        }
        # Case 2: <policy> <rule> <action> [flags...]
        # Extract policy name
        if ($line -match '^add vpn sessionPolicy\s+(\S+)\s+(.*)$') {
            $policyName = $matches[1]
            $rest = $matches[2]
            # Remove the rule expression (quoted or unquoted)
            if ($rest -match '^"([^"]+)"\s+(\S+)(.*)$') {
                # Quoted rule
                $actionName = $matches[2]
            }
            elseif ($rest -match '^(\S+)\s+(\S+)(.*)$') {
                # Unquoted rule
                $actionName = $matches[2]
            }
            else {
                continue
            }
            $sessionPolicies[$policyName] = $actionName
            continue
        }
    }
    # ---------------------------
    #   Session Actions
    # ---------------------------
    foreach ($line in $configLines | Where-Object { $_ -match '^add vpn sessionAction ' }) {
        if ($line -match '^add vpn sessionAction\s+(\S+)\s+(.*)$') {
            $actionName = $matches[1]
            $rest = $matches[2]
            $wihome = $null
            if ($rest -match '-wihome\s+(\S+)') {
                $wihome = $matches[1].Trim('"')
            }
            $rdpProfile = $null
            if ($rest -match '-rdpClientProfileName\s+(\S+)') {
                $rdpProfile = $matches[1].Trim('"')
            }
            $sessionActions[$actionName] = @{
                Name       = $actionName
                WIHome     = $wihome
                RDPProfile = $rdpProfile
            }
        }
    }
    # ---------------------------------------------------------
    #   GLOBAL STA SERVERS
    # ---------------------------------------------------------
    $globalSTAServers = @()
    foreach ($line in $configLines | Where-Object { $_ -match '^bind vpn global' }) {
        if ($line -match '^bind vpn global\s+-staServer\s+"(.+?)"') {
            $globalSTAServers += $matches[1]
        }
    }
    # ---------------------------------------------------------
    #   VPN vServers (VIP + Port)
    # ---------------------------------------------------------
    foreach ($line in $configLines | Where-Object { $_ -match '^add vpn vserver ' }) {
        if ($line -match '^add vpn vserver\s+(\S+)\s+(SSL|DTLS)\s+(\S+)\s+(\d+)') {
            $name = $matches[1]
            $type = $matches[2]   # <‑‑ SSL or DTLS
            $vip = $matches[3]
            $port = $matches[4]
            if (-not $vpnVservers.Contains($name)) {
                $vpnVservers += $name
            }
            if (-not $vpnInfo.ContainsKey($name)) {
                $vpnInfo[$name] = @{}
            }
            $vpnInfo[$name].VIP = $vip
            $vpnInfo[$name].Port = $port
            $vpnInfo[$name].Type = $type   # <‑‑ Store SSL/DTLS
            # Extract authnProfile
            if ($line -match '-authnProfile\s+(\S+)') {
                $vpnInfo[$name].AuthProfile = $matches[1]
            }
            # Extract DTLS flag
            if ($line -match '-dtls\s+(\S+)') {
                $vpnInfo[$name].DTLS = $matches[1]
            }
        }
    }
    # ---------------------------------------------------------
    #   VPN SSL Certificate Bindings
    # ---------------------------------------------------------
    foreach ($line in $configLines | Where-Object { $_ -match '^bind ssl vserver ' }) {
        if ($line -match '^bind ssl vserver\s+(\S+)\s+-certkeyName\s+(\S+)') {
            $vserver = $matches[1]
            $cert = $matches[2]
            if (-not $vpnCerts.ContainsKey($vserver)) {
                $vpnCerts[$vserver] = @()
            }
            $vpnCerts[$vserver] += $cert
        }
    }
    # ---------------------------------------------------------
    #   VPN Policy Bindings
    # ---------------------------------------------------------
    foreach ($line in $configLines | Where-Object { $_ -match '^bind vpn vserver ' }) {
        # Traffic / Request / Response / Session policies
        if ($line -match '^bind vpn vserver\s+(\S+)\s+-policy\s+("?)(.+?)\2\s+-priority\s+(\d+).*?-gotoPriorityExpression\s+(\S+).*?-type\s+(\S+)') {
            $vserver = $matches[1]
            $policy = $matches[3].Trim('"')
            $priority = [int]$matches[4]
            $goto = $matches[5]
            $ptype = $matches[6]
            if ($policy.StartsWith("_")) { continue }
            if (-not $vpnPolicyDetails.ContainsKey($vserver)) {
                $vpnPolicyDetails[$vserver] = @()
            }
            $vpnPolicyDetails[$vserver] += [PSCustomObject]@{
                Policy   = $policy
                Priority = $priority
                Goto     = $goto
                Type     = $ptype
            }
            # Track session policies for chaining
            if ($sessionPolicies.ContainsKey($policy)) {
                if (-not $vpnSessionPolicyBindings.ContainsKey($vserver)) {
                    $vpnSessionPolicyBindings[$vserver] = @()
                }
                if ($vpnSessionPolicyBindings[$vserver] -notcontains $policy) {
                    $vpnSessionPolicyBindings[$vserver] += $policy
                }
            }
        }
        # ---------------------------------------------------------
        #   LOCAL STA SERVERS
        # ---------------------------------------------------------
        if ($line -match '^bind vpn vserver\s+(\S+)\s+-staServer\s+"(.+?)"') {
            $vserver = $matches[1]
            $sta = $matches[2]
            if (-not $vpnSTA.ContainsKey($vserver)) {
                $vpnSTA[$vserver] = @()
            }
            $vpnSTA[$vserver] += $sta
        }
        # ---------------------------------------------------------
        #   Portal Theme
        # ---------------------------------------------------------
        if ($line -match '^bind vpn vserver\s+(\S+)\s+-portaltheme\s+(\S+)') {
            $vpnTheme[$matches[1]] = $matches[2]
        }
    }
    # ---------------------------------------------------------
    #   ENSURE ALL VPN VSERVERS HAVE STA LISTS
    # ---------------------------------------------------------
    foreach ($vserver in $vpnVservers) {
        if (-not $vpnSTA.ContainsKey($vserver)) {
            $vpnSTA[$vserver] = @()
        }
    }
    # ---------------------------------------------------------
    #   MERGE GLOBAL STAS INTO ALL NON‑DTLS VSERVERS
    # ---------------------------------------------------------
    foreach ($vserver in @($vpnSTA.Keys)) {
        # Skip DTLS vServers entirely
        if ($vpnInfo[$vserver].Type -eq "DTLS") { continue }
        foreach ($gSta in $globalSTAServers) {
            if ($vpnSTA[$vserver] -notcontains $gSta) {
                $vpnSTA[$vserver] += $gSta
            }
        }
    }
}
if ($IncludeAAA) {
    # ---------------------------------------------------------
    #   AAA VSERVERS + POLICIES + NEXTFACTOR
    # ---------------------------------------------------------
    $aaaVservers = @()
    $aaaBindings = @()
    # ---------------------------
    #   AAA vServers
    # ---------------------------
    foreach ($line in $configLines | Where-Object { $_ -match '^add authentication vserver ' }) {
        if ($line -match '^add authentication vserver\s+(\S+)') {
            $aaaVservers += $matches[1]
        }
    }
    # ---------------------------
    #   AUTHENTICATION PROFILES
    # ---------------------------
    $authProfiles = @()
    foreach ($line in $configLines | Where-Object { $_ -match '^add authentication authnProfile ' }) {
        $clean = [System.Web.HttpUtility]::HtmlDecode($line) -replace '"', ''
        if ($clean -match '^add authentication authnProfile\s+(\S+).*?-authnVsName\s+(\S+)') {
            $authProfiles += [PSCustomObject]@{
                Profile = $matches[1]
                AAA     = $matches[2]
            }
        }
    }
    # ---------------------------
    #   AAA Policy Bindings
    # ---------------------------
    foreach ($line in $configLines | Where-Object { $_ -match '^bind authentication vserver ' }) {
        if ($line -match '^bind authentication vserver\s+(\S+)\s+-policy\s+(\S+)') {
            $vserver = $matches[1]
            $policy = $matches[2]
            # Skip internal policies
            if ($policy.StartsWith("_")) { continue }
            $nextFactor = $null
            if ($line -match '-nextFactor\s+(\S+)') {
                $nextFactor = $matches[1]
            }
            $aaaBindings += [PSCustomObject]@{
                VServer    = $vserver
                Policy     = $policy
                NextFactor = $nextFactor
            }
        }
    }
}
if ($IncludeGSLB) {
    # ---------------------------
    #   GSLB vServers
    # ---------------------------
    $gslbVservers = @{}
    foreach ($line in $configLines | Where-Object { $_ -match '^add gslb vserver ' }) {
        if ($line -match '^add gslb vserver\s+(\S+)\s+(\S+)') {
            $name = $matches[1]
            $protocol = $matches[2]
            $gslbVservers[$name] = @{
                Protocol = $protocol
                Domains  = @()
                Services = @()
            }
        }
    }
    # ---------------------------
    #   GSLB Sites
    # ---------------------------
    $gslbSites = @{}
    foreach ($line in $configLines | Where-Object { $_ -match '^add gslb site ' }) {
        if ($line -match '^add gslb site\s+(\S+)\s+(\S+)\s+-publicIP\s+(\S+)') {
            $siteName = $matches[1]
            $siteIP = $matches[2]
            $publicIP = $matches[3]
            $gslbSites[$siteName] = @{
                IP       = $siteIP
                PublicIP = $publicIP
            }
        }
    }
    # ---------------------------
    #   GSLB Services
    # ---------------------------
    $gslbServices = @{}
    foreach ($line in $configLines | Where-Object { $_ -match '^add gslb service ' }) {
        if ($line -match '^add gslb service\s+(\S+)\s+(\S+)\s+(\S+)\s+(\d+).*?-publicIP\s+(\S+).*?-siteName\s+(\S+)') {
            $svcName = $matches[1]
            $svcIP = $matches[2]
            $svcProto = $matches[3]
            $svcPort = $matches[4]
            $publicIP = $matches[5]
            $siteName = $matches[6]
            $gslbServices[$svcName] = @{
                IP       = $svcIP
                Proto    = $svcProto
                Port     = $svcPort
                PublicIP = $publicIP
                Site     = $siteName
            }
        }
    }
    # ---------------------------
    #   GSLB vServer → Service Bindings
    # ---------------------------
    foreach ($line in $configLines | Where-Object { $_ -match '^bind gslb vserver ' }) {
        # Service binding
        if ($line -match '^bind gslb vserver\s+(\S+)\s+-serviceName\s+(\S+)') {
            $vs = $matches[1]
            $svc = $matches[2]
            if ($gslbVservers.ContainsKey($vs)) {
                $gslbVservers[$vs].Services += $svc
            }
        }
        # Domain binding
        if ($line -match '^bind gslb vserver\s+(\S+)\s+-domainName\s+(\S+)') {
            $vs = $matches[1]
            $domain = $matches[2]
            if ($gslbVservers.ContainsKey($vs)) {
                $gslbVservers[$vs].Domains += $domain
            }
        }
    }
}
# --------------------------------------------------------------------------------------------------------------------------------------------------------------
# ---------------------------------------------------------
#   DOT GRAPH INITIALIZATION
# ---------------------------------------------------------
$dot = @()
$dot += "digraph `"$GraphName`" {"
$dot += "  rankdir=LR;"
$dot += "  graph [fontsize=10, fontname=""Segoe UI""];"
$dot += "  node  [style=filled, fontname=""Segoe UI"", fontsize=9];"
$dot += "  edge  [fontname=""Segoe UI"", fontsize=8];"
# ---------------------------------------------------------
#   APPLIANCE SUMMARY TABLE (HTML LABEL)
# ---------------------------------------------------------
$dot += "  appliance_info [shape=plaintext label=<"
$dot += "    <TABLE BORDER='1' CELLBORDER='1' CELLSPACING='0'>"
# Header with optional hostname
if ($nsHostname) {
    $dot += "      <TR><TD COLSPAN='2'><B>Appliance Summary – $nsHostname</B></TD></TR>"
}
else {
    $dot += "      <TR><TD COLSPAN='2'><B>Appliance Summary</B></TD></TR>"
}
# NSIPs
foreach ($ip in $nsIPs) {
    $src = if ($ip.Src) { " ($($ip.Src))" } else { "" }
    $mask = if ($ip.Mask) { $ip.Mask } else { "" }
    $dot += "      <TR><TD>NSIP</TD><TD>$($ip.IP) $mask$src</TD></TR>"
}
# SNIPs
foreach ($ip in $snips) {
    $dot += "      <TR><TD>SNIP</TD><TD>$($ip.IP) / $($ip.Mask)</TD></TR>"
}
# VLAN definitions
foreach ($v in $vlanDefs) {
    $alias = if ($v.Alias) { $v.Alias } else { "" }
    $dot += "      <TR><TD>VLAN $($v.VLAN)</TD><TD>$alias</TD></TR>"
}
# VLAN bindings
foreach ($b in $vlanBinds) {
    $details = @()
    if ($b.Iface) { $details += "Iface: $($b.Iface)" }
    if ($b.IP) { $details += "IP: $($b.IP)" }
    if ($b.Mask) { $details += "Mask: $($b.Mask)" }
    $dot += "      <TR><TD>VLAN $($b.VLAN) Bind</TD><TD>$([string]::Join(', ', $details))</TD></TR>"
}
# HA nodes
foreach ($h in $haNodes) {
    $dot += "      <TR><TD>HA Node $($h.NodeID)</TD><TD>$($h.IP)</TD></TR>"
}
# PBR routes
foreach ($p in $pbrRoutes) {
    $dot += "      <TR><TD>PBR-$($p.Name)</TD><TD>srcIP: $($p.SrcIP), destIP: $($p.DestIP), nextHop: $($p.NextHop)</TD></TR>"
}
# Default route
if ($defaultRoute) {
    $dot += "      <TR><TD>Default Route</TD><TD>$defaultRoute</TD></TR>"
}
# Static routes
foreach ($r in $staticRoutes) {
    $dot += "      <TR><TD>Static Route</TD><TD>$($r.Destination) / $($r.Mask) → $($r.Gateway)</TD></TR>"
}
$dot += "    </TABLE>"
$dot += "  >];"
# ---------------------------------------------------------
#   LEGEND
# ---------------------------------------------------------
$dot += "  legend [shape=plaintext, fontsize=9, fontname=""Segoe UI"", label=<"
$dot += "    <TABLE BORDER='1' CELLBORDER='1' CELLSPACING='0'>"
$dot += "      <TR><TD COLSPAN='2'><B>Legend</B></TD></TR>"
# LB
if ($IncludeLB) {
    $dot += "      <TR>"
    $dot += "        <TD><TABLE BORDER='0' CELLBORDER='1' CELLSPACING='0'><TR><TD BGCOLOR='#c5e1a5'>LB</TD></TR></TABLE></TD>"
    $dot += "        <TD>Load Balancing vServer</TD>"
    $dot += "      </TR>"
}
# CS
if ($IncludeCS) {
    $dot += "      <TR>"
    $dot += "        <TD><TABLE BORDER='0' CELLBORDER='1' CELLSPACING='0'><TR><TD BGCOLOR='#ffe082'>CS</TD></TR></TABLE></TD>"
    $dot += "        <TD>Content Switching vServer</TD>"
    $dot += "      </TR>"
}
# SG
if ($IncludeSG) {
    $dot += "      <TR>"
    $dot += "        <TD><TABLE BORDER='0' CELLBORDER='1' CELLSPACING='0'><TR><TD BGCOLOR='#b3e5fc'>SG</TD></TR></TABLE></TD>"
    $dot += "        <TD>Service Group</TD>"
    $dot += "      </TR>"
    $dot += "      <TR>"
    $dot += "        <TD><TABLE BORDER='0' CELLBORDER='1' CELLSPACING='0'><TR><TD BGCOLOR='#fff59d'>SVC</TD></TR></TABLE></TD>"
    $dot += "        <TD>Service</TD>"
    $dot += "      </TR>"
}
# VPN
if ($IncludeVPN) {
    $dot += "      <TR>"
    $dot += "        <TD><TABLE BORDER='0' CELLBORDER='1' CELLSPACING='0'><TR><TD BGCOLOR='#ffab91'>VPN</TD></TR></TABLE></TD>"
    $dot += "        <TD>Gateway / VPN vServer</TD>"
    $dot += "      </TR>"
    # Local STA
    $dot += "      <TR>"
    $dot += "        <TD><TABLE BORDER='0' CELLBORDER='1' CELLSPACING='0'><TR><TD BGCOLOR='#bbdefb'>Local STA</TD></TR></TABLE></TD>"
    $dot += "        <TD>Directly bound STA server</TD>"
    $dot += "      </TR>"
    # Global STA
    $dot += "      <TR>"
    $dot += "        <TD><TABLE BORDER='0' CELLBORDER='1' CELLSPACING='0'><TR><TD BGCOLOR='#ffe082'>Global STA</TD></TR></TABLE></TD>"
    $dot += "        <TD>Inherited STA server from global binding</TD>"
    $dot += "      </TR>"
    # DTLS
    $dot += "      <TR>"
    $dot += "        <TD><TABLE BORDER='0' CELLBORDER='1' CELLSPACING='0'><TR><TD BGCOLOR='#90caf9'>DTLS</TD></TR></TABLE></TD>"
    $dot += "        <TD>DTLS Companion Gateway</TD>"
    $dot += "      </TR>"
}
# AAA
if ($IncludeAAA) {
    $dot += "      <TR>"
    $dot += "        <TD><TABLE BORDER='0' CELLBORDER='1' CELLSPACING='0'><TR><TD BGCOLOR='#f48fb1'>AAA</TD></TR></TABLE></TD>"
    $dot += "        <TD>AAA vServer</TD>"
    $dot += "      </TR>"
}
# Edges
$dot += "      <TR><TD BGCOLOR='#1976d2'>lb</TD><TD>LB → Target Binding</TD></TR>"
$dot += "      <TR><TD BGCOLOR='#fb8c00'>cs</TD><TD>CS → LB Binding</TD></TR>"
$dot += "      <TR><TD BGCOLOR='#388e3c'>member</TD><TD>Service Group → Member Binding</TD></TR>"
$dot += "      <TR><TD BGCOLOR='#fbc02d'>target</TD><TD>Service → Member Binding</TD></TR>"
$dot += "      <TR><TD BGCOLOR='#7b1fa2'>authProfile</TD><TD>AAA / VPN Authentication Policy Binding</TD></TR>"
$dot += "      <TR><TD BGCOLOR='#c2185b'>aaa</TD><TD>AAA Policy Binding</TD></TR>"
$dot += "      <TR><TD BGCOLOR='#8e24aa'>next</TD><TD>AAA Next Factor Policy Binding</TD></TR>"
$dot += "      <TR><TD BGCOLOR='#e64a19'>request</TD><TD>Request Responder Policy Binding</TD></TR>"
$dot += "      <TR><TD BGCOLOR='#7cb342'>sess</TD><TD>VPN Session Policy Binding</TD></TR>"
$dot += "      <TR><TD BGCOLOR='#1565c0'>response</TD><TD>Response Responder Policy Binding</TD></TR>"
$dot += "      <TR><TD BGCOLOR='#1e88e5'>sta</TD><TD>VPN STA Binding</TD></TR>"
$dot += "      <TR><TD BGCOLOR='#00838f'>ica</TD><TD>ICA Request Policy Binding</TD></TR>"
$dot += "      <TR><TD BGCOLOR='#6a1b9a'>traffic</TD><TD>Traffic Policy Binding</TD></TR>"
$dot += "    </TABLE>"
$dot += "  >];"
$dot += @"
  # ---------------------------------------------------------
  #   TOP HEADER CLUSTER (Summary + Legend)
  # ---------------------------------------------------------
  subgraph cluster_header {
    rank=source;
    style=invis;        # No border around the cluster
    margin=0;

    # Invisible anchors for left and right alignment
    header_left  [shape=point, width=0, height=0, label=""];
    header_right [shape=point, width=0, height=0, label=""];

    # Force horizontal ordering inside the header
    header_left    -> appliance_info [style=invis];
    appliance_info -> legend         [style=invis];
    legend         -> header_right   [style=invis];
  }
"@
# ---------------------------------------------------------
#   LB NODES
# ---------------------------------------------------------
if ($IncludeLB) {
    foreach ($lb in $lbVservers.Keys) {
        $lb = $lb.Replace('"', '\"')
        $label = "LB: $lb"
        if ($lbInfo.ContainsKey($lb)) {
            $label += "\nVIP: $($lbInfo[$lb].VIP):$($lbInfo[$lb].Port)"
        }
        if ($lbCerts.ContainsKey($lb)) {
            $label += "\nCerts:"
            foreach ($c in $lbCerts[$lb]) {
                $label += "\n - $c"
            }
        }
        $dot += "  `"$lb`" [shape=box, fillcolor=""#90caf9"", label=""$label""];"
    }
    # ---------------------------
    #   LB → Policy → Action Graph
    # ---------------------------
    foreach ($lb in $lbPolicyBindings.Keys) {
        $lb = $lb.Replace('"', '\"')
        $ordered = $lbPolicyBindings[$lb] | Sort-Object Priority
        foreach ($binding in $ordered) {
            $policy = $binding.Policy
            $ptype = $binding.Type   # REQUEST / RESPONSE / NONE
            #
            # Determine policy type: responder or rewrite
            #
            $isResponder = $responderPolicies.ContainsKey($policy)
            $isRewrite = $rewritePolicies.ContainsKey($policy)
            #
            # ---------------------------
            #   RESPONDER POLICY
            # ---------------------------
            #
            if ($isResponder) {
                $rule = $responderPolicies[$policy].Rule
                $respActionName = $responderPolicies[$policy].Action
                # Policy node
                $polLabel = "RESPPOL: $policy"
                if ($rule) { $polLabel += "\n$rule" }
                $dot += "  `"$policy`" [shape=note, fillcolor=""#dcedc8"", label=""$polLabel""];"
                # LB → Policy
                $dot += "  `"$lb`" -> `"$policy`" [color=""#6a1b9a"", label=""$ptype""];"
                # Action lookup (null‑safe)
                $actInfo = $null
                if ($respActionName -and $responderActions.ContainsKey($respActionName)) {
                    $actInfo = $responderActions[$respActionName]
                }
                if (-not $actInfo) {
                    $actInfo = @{
                        Type = "unknown"
                        Expr = ""
                    }
                }
                # Action node
                $actLabel = "RESPACT: $respActionName"
                if ($actInfo.Expr) { $actLabel += "\n$($actInfo.Expr)" }
                $dot += "  `"$respActionName`" [shape=note, fillcolor=""#c5e1a5"", label=""$actLabel""];"
                # Policy → Action
                $dot += "  `"$policy`" -> `"$respActionName`" [color=""#2e7d32"", label=""action""];"
                continue
            }
            #
            # ---------------------------
            #   REWRITE POLICY
            # ---------------------------
            #
            if ($isRewrite) {
                $rule = $rewritePolicies[$policy].Rule
                $rwActionName = $rewritePolicies[$policy].Action
                # Policy node
                $polLabel = "REWRITEPOL: $policy"
                if ($rule) { $polLabel += "\n$rule" }
                $dot += "  `"$policy`" [shape=note, fillcolor=""#ffe082"", label=""$polLabel""];"
                # LB → Policy
                $dot += "  `"$lb`" -> `"$policy`" [color=""#fb8c00"", label=""$ptype""];"
                # Action lookup (null‑safe)
                $actInfo = $null
                if ($rwActionName -and $rewriteActions.ContainsKey($rwActionName)) {
                    $actInfo = $rewriteActions[$rwActionName]
                }
                if (-not $actInfo) {
                    $actInfo = @{
                        Type = "unknown"
                        Expr = ""
                    }
                }
                # Action node
                $exprForDot = $actInfo.Expr
                $exprForDot = $exprForDot.Replace('\', '\\')
                $exprForDot = $exprForDot.Replace('"', '\"')
                $actLabel = "REWRITEACT: $rwActionName"
                if ($exprForDot) { $actLabel += "\n$exprForDot" }
                $dot += "  `"$rwActionName`" [shape=note, fillcolor=""#ffcc80"", label=""$actLabel""];"
                # Policy → Action
                $dot += "  `"$policy`" -> `"$rwActionName`" [color=""#ef6c00"", label=""action""];"
                continue
            }
            #
            # ---------------------------
            #   UNKNOWN POLICY (fallback)
            # ---------------------------
            #
            $dot += "  `"$policy`" [shape=note, fillcolor=""#ffcdd2"", label=""UNKNOWNPOL: $policy""];"
            $dot += "  `"$lb`" -> `"$policy`" [color=""#b71c1c"", label=""unknown""];"
        }
    }
}

# ---------------------------------------------------------
#   CS NODES
# ---------------------------------------------------------
if ($IncludeCS) {
    foreach ($csv in $csVservers) {
        $label = "CS: $csv"
        if ($csInfo.ContainsKey($csv)) {
            $label += "\nVIP: $($csInfo[$csv].VIP):$($csInfo[$csv].Port)"
        }
        if ($csCerts.ContainsKey($csv)) {
            $label += "\nCerts:"
            foreach ($c in $csCerts[$csv]) {
                $label += "\n - $c"
            }
        }
        $dot += "  `"$csv`" [shape=hexagon, fillcolor=""#ffcc80"", label=""$label""];"
    }
    # ---------------------------
    #   CS → Policy → Action Graph
    # ---------------------------
    foreach ($csvserver in $csResponderBindings.Keys) {
        $ordered = $csResponderBindings[$csvserver] | Sort-Object Priority
        foreach ($binding in $ordered) {
            $policy = $binding.Policy
            $rule = $responderPolicies[$policy].Rule
            $respActionName = $responderPolicies[$policy].Action
            # Policy node
            $polLabel = "RESPPOL: $policy"
            if ($rule) { $polLabel += "\n$rule" }
            $dot += "  `"$policy`" [shape=note, fillcolor=""#dcedc8"", label=""$polLabel""];" 
            # CS → Policy
            $dot += "  `"$csvserver`" -> `"$policy`" [color=""#6a1b9a"", label=""request""];" 
            # Action lookup (null‑safe)
            $actInfo = $null
            if ($respActionName -and $responderActions.ContainsKey($respActionName)) {
                $actInfo = $responderActions[$respActionName]
            }
            if (-not $actInfo) {
                $actInfo = @{
                    Type = "unknown"
                    Expr = ""
                }
            }
            # Action node
            $actLabel = "RESPACT: $respActionName"
            if ($actInfo.Expr) { $actLabel += "\n$($actInfo.Expr)" }
            $dot += "  `"$respActionName`" [shape=note, fillcolor=""#c5e1a5"", label=""$actLabel""];" 
            # Policy → Action
            $dot += "  `"$policy`" -> `"$respActionName`" [color=""#2e7d32"", label=""action""];" 
        }
    }
}
# ---------------------------------------------------------
#   SERVICE GROUP NODES
# ---------------------------------------------------------
if ($IncludeSG) {
    foreach ($sg in $serviceGroups) {
        $dot += "  `"$($sg.Name)`" [shape=note, fillcolor=""#c8e6c9"", label=""SG: $($sg.Name)""];"
    }
    foreach ($srv in $sgMemberBindings | Select-Object -ExpandProperty Server -Unique) {
        $dot += "  `"$srv`" [shape=oval, fillcolor=""#ffe082"", label=""SRV: $srv""];"
    }
}
# ---------------------------------------------------------
#   SERVICE NODES + ENDPOINT NODES
# ---------------------------------------------------------
foreach ($svc in $services) {
    # Main service node (name only)
    $dot += "  `"$($svc.Name)`" [shape=oval, fillcolor=""#fff59d"", label=""SVC: $($svc.Name)""];"
    # Endpoint node name: <serviceName>_<target>_<port>
    $endpointName = "$($svc.Name)_$($svc.Target)_$($svc.Port)"
    $endpointLabel = "$($svc.Target):$($svc.Port) ($($svc.Protocol))"
    $dot += "  `"$endpointName`" [shape=note, fillcolor=""#fff9c4"", label=""$endpointLabel""];"
    # Edge: service -> endpoint
    $dot += "  `"$($svc.Name)`" -> `"$endpointName`" [color=""#fbc02d"", label=""target""];"
}
# ---------------------------------------------------------
#   VPN NODES
# ---------------------------------------------------------
if ($IncludeVPN) {
    # ---------------------------------------------------------
    #   VPN vServer → Authentication Profile
    # ---------------------------------------------------------
    foreach ($vpn in $vpnVservers) {
        if ($vpnInfo[$vpn].AuthProfile) {
            $dot += "  `"$vpn`" -> `"$($vpnInfo[$vpn].AuthProfile)`" [color=""#6a1b9a"", label=""authProfile""];"
        }
    }
    foreach ($vpn in $vpnVservers) {
        $label = "GW: $vpn"
        if ($vpnInfo.ContainsKey($vpn)) {
            $label += "\nVIP: $($vpnInfo[$vpn].VIP):$($vpnInfo[$vpn].Port)"
        }
        if ($vpnCerts.ContainsKey($vpn)) {
            $label += "\nCerts:"
            foreach ($c in $vpnCerts[$vpn]) {
                $label += "\n - $c"
            }
        }
        # DTLS-aware color selection
        $fill = "#ffab91"   # default SSL color
        if ($vpnInfo[$vpn].Type -eq "DTLS" -or $vpnInfo[$vpn].DTLS -eq "ON") {
            $fill = "#90caf9"   # DTLS color
        }
        $dot += "  `"$vpn`" [shape=octagon, fillcolor=""$fill"", label=""$label""];" 
    }
    # Portal Themes
    foreach ($vpn in $vpnTheme.Keys) {
        $theme = $vpnTheme[$vpn]
        $dot += "  `"$theme`" [shape=note, fillcolor=""#ffe0b2"", label=""Theme: $theme""];"
        $dot += "  `"$vpn`" -> `"$theme`" [color=""#6d4c41"", label=""theme""];"
    }
    # STA Servers
    foreach ($vpn in $vpnSTA.Keys) {
        foreach ($sta in $vpnSTA[$vpn]) {
            # Default = local STA color
            $staColor = "#bbdefb"   # light blue
            # If this STA came from global bindings, use a different color
            if ($globalSTAServers -contains $sta) {
                $staColor = "#ffe082"   # amber (global)
            }
            $dot += "  `"$sta`" [shape=note, fillcolor=""$staColor"", label=""STA: $sta""];" 
            $dot += "  `"$vpn`" -> `"$sta`" [color=""#1e88e5"", label=""sta""];" 
        }
    }
    # VPN Policies
    foreach ($vpn in $vpnPolicyDetails.Keys) {
        $ordered = $vpnPolicyDetails[$vpn] | Sort-Object Priority
        foreach ($p in $ordered) {
            $polNode = $p.Policy
            # Skip drawing VPN edge if this policy is ALSO a session policy
            if ($vpnSessionPolicyBindings[$vpn] -contains $polNode) {
                continue
            }
            # Build the policy node
            $label = "POL: $($p.Policy)`nPri: $($p.Priority)`nType: $($p.Type)`nGoto: $($p.Goto)"
            $dot += "  `"$polNode`" [shape=note, fillcolor=""#dcedc8"", label=""$label""];"
            # TRAFFIC POLICY edge
            if ($trafficPolicies.ContainsKey($polNode)) {
                $dot += "  `"$vpn`" -> `"$polNode`" [color=""#6a1b9a"", label=""traffic""];"
                continue
            }
            # ICA_REQUEST edge
            if ($p.Type -eq 'ICA_REQUEST') {
                $dot += "  `"$vpn`" -> `"$polNode`" [color=""#00838f"", label=""ica""];"
                continue
            }
            # RESPONSE edge
            if ($p.Type -eq 'RESPONSE') {
                $dot += "  `"$vpn`" -> `"$polNode`" [color=""#1565c0"", label=""response""];"
                continue
            }
            # Normal VPN policy edge
            $dot += "  `"$vpn`" -> `"$polNode`" [color=""#e64a19"", label=""request""];"
        }
    }
    # SessionPolicy → SessionAction chaining
    foreach ($vpn in $vpnSessionPolicyBindings.Keys) {
        foreach ($pol in $vpnSessionPolicyBindings[$vpn]) {
            # Always define the session policy node
            $dot += "  `"$pol`" [shape=note, fillcolor=""#c5e1a5"", label=""SESSPOL: $pol""];"
            $dot += "  `"$vpn`" -> `"$pol`" [color=""#7cb342"", label=""sess""];"
            $actionName = $sessionPolicies[$pol]
            $act = $sessionActions[$actionName]
            $actLabel = "SESSACT: $($act.Name)"
            if ($act.WIHome) { $actLabel += "\n - WIHome: $($act.WIHome)" }
            if ($act.RDPProfile) { $actLabel += "\n - RDP Profile: $($act.RDPProfile)" }
            $dot += "  `"$actionName`" [shape=note, fillcolor=""#aed581"", label=""$actLabel""];"
            $dot += "  `"$pol`" -> `"$actionName`" [color=""#558b2f"", label=""action""];"
        }
    }
}
# ---------------------------------------------------------
#   AAA NODES
# ---------------------------------------------------------
if ($IncludeAAA) {
    foreach ($aaa in $aaaVservers) {
        $dot += "  `"$aaa`" [shape=diamond, fillcolor=""#f48fb1"", label=""AAA: $aaa""];"
    }
    # Authentication Profile nodes
    foreach ($p in $authProfiles) {
        $dot += "  `"$($p.Profile)`" [shape=box, style=filled, fillcolor=""#d1c4e9"", label=""$($p.Profile)""];"
    }
    foreach ($pol in $aaaBindings | Select-Object -ExpandProperty Policy -Unique) {
        $dot += "  `"$pol`" [shape=note, fillcolor=""#e1bee7"", label=""POL: $pol""];"
    }
    foreach ($b in $aaaBindings) {
        $dot += "  `"$($b.VServer)`" -> `"$($b.Policy)`" [color=""#c2185b"", label=""aaa""];"
    }
    foreach ($b in $aaaBindings | Where-Object { $_.NextFactor }) {
        $dot += "  `"$($b.Policy)`" -> `"$($b.NextFactor)`" [color=""#8e24aa"", label=""next""];"
    }
}
if ($IncludeGSLB) {
    foreach ($vs in $gslbVservers.Keys) {
        $info = $gslbVservers[$vs]
        #
        # GSLB vServer node
        #
        $label = "GSLB VS: $vs\nProtocol: $($info.Protocol)"
        if ($info.Domains.Count -gt 0) {
            $label += "\nDomains: " + ($info.Domains -join ", ")
        }
        $dot += "  `"$vs`" [shape=hexagon, style=filled, fillcolor=""#ffe0b2"", label=""$label""];"
        #
        # GSLB Services under this vServer
        #
        foreach ($svc in $info.Services) {
            $svcInfo = $gslbServices[$svc]
            $svcLabel = "GSLB Service: $svc"
            $svcLabel += "\nIP: $($svcInfo.IP)"
            $svcLabel += "\nProto: $($svcInfo.Proto)"
            $svcLabel += "\nPort: $($svcInfo.Port)"
            $svcLabel += "\nPublic IP: $($svcInfo.PublicIP)"
            $dot += "  `"$svc`" [shape=box, style=filled, fillcolor=""#bbdefb"", label=""$svcLabel""];"
            # vServer → Service
            $dot += "  `"$vs`" -> `"$svc`" [color=""#1e88e5""];"
            #
            # GSLB Site for this service
            #
            $site = $svcInfo.Site
            $siteInfo = $gslbSites[$site]
            $siteLabel = "Site: $site"
            $siteLabel += "\nIP: $($siteInfo.IP)"
            $siteLabel += "\nPublic IP: $($siteInfo.PublicIP)"
            $dot += "  `"$site`" [shape=oval, style=filled, fillcolor=""#c8e6c9"", label=""$siteLabel""];"
            # Service → Site
            $dot += "  `"$svc`" -> `"$site`" [color=""#43a047""];"
        }
    }
}
# ---------------------------------------------------------
#   LB EDGES
# ---------------------------------------------------------
# ---------------------------
#   LB → Target Bindings (safe)
# ---------------------------
if ($IncludeLB) {

    foreach ($b in $lbBindings) {

        # Sanitize both node names for DOT
        $vsSafe = $b.VServer.Replace('"', '\"')
        $targetSafe = $b.Target.Replace('"', '\"')

        $dot += "  `"$vsSafe`" -> `"$targetSafe`" [color=""#1976d2"", label=""lb""];"
    }
}
# ---------------------------------------------------------
#   CS EDGES
# ---------------------------------------------------------
if ($IncludeCS) {
    # ---------------------------
    #   CS Graph Edges
    # ---------------------------
    foreach ($csvserver in $csBindings.Keys) {
        foreach ($binding in $csBindings[$csvserver]) {
            $policy = $binding.Policy
            $target = $binding.TargetLB
            # Draw the policy node
            $rule = $csPolicies[$policy]
            $label = "CSPOL: $policy"
            if ($rule) { $label += "\n$rule" }
            $dot += "  `"$policy`" [shape=note, fillcolor=""#fff59d"", label=""$label""];" 
            # CS vServer → CS Policy
            $dot += "  `"$csvserver`" -> `"$policy`" [color=""#f57f17"", label=""cs""];" 
            # CS Policy → LB vServer (if present)
            if ($target) {
                $dot += "  `"$policy`" -> `"$target`" [color=""#e65100"", label=""target""];" 
            }
        }
    }
}
# ---------------------------------------------------------
#   SERVICE GROUP MEMBER EDGES
# ---------------------------------------------------------
if ($IncludeSG) {
    foreach ($b in $sgMemberBindings) {
        $dot += "  `"$($b.ServiceGroup)`" -> `"$($b.Server)`" [color=""#388e3c"", label=""member""];"
    }
}
# ---------------------------------------------------------
#   AUTHENTICATION PROFILE → AAA VSERVER EDGES
# ---------------------------------------------------------
foreach ($p in $authProfiles) {
    $dot += "  `"$($p.Profile)`" -> `"$($p.AAA)`" [color=""#6a1b9a"", label=""authProfile""];"
}
$dot += "}"
# ---------------------------------------------------------
#   WRITE DOT FILE (UTF-8 NO BOM)
# ---------------------------------------------------------
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
[System.IO.File]::WriteAllLines($OutputDotPath, $dot, $utf8NoBom)
if ($SVG) {
    # check for Graphviz installation
    if (-not (Test-Path $GraphvizPath)) {
        Write-Host "Graphviz not found at path: $GraphvizPath"
        Write-Host "Download and install Graphviz from https://graphviz.org/download/"
        Write-Host "DOT file written to $OutputDotPath"
        Write-Host "Render with:"
        Write-Host "  dot -Tpng $OutputDotPath -o netscaler.png"
        Write-Host "  dot -Tsvg $OutputDotPath -o netscaler.svg"
        exit 1
    }
    else {
        &$GraphvizPath -Tsvg $OutputDotPath -o $OutputDotPath.replace('.dot', '.svg')
        Write-Host "SVG file written to $($OutputDotPath.replace('.dot', '.svg'))"
    }
}
else {
    if ($PNG) {}
    else {
        Write-Host "DOT file written to $OutputDotPath"
        Write-Host "Render with:"
        Write-Host "  dot -Tpng $OutputDotPath -o netscaler.png"
        Write-Host "  dot -Tsvg $OutputDotPath -o netscaler.svg"
        exit 1
    }
}
if ($PNG) {
    # check for Graphviz installation
    if (-not (Test-Path $GraphvizPath)) {
        Write-Host "Graphviz not found at path: $GraphvizPath"
        Write-Host "Download and install Graphviz from https://graphviz.org/download/"
        Write-Host "DOT file written to $OutputDotPath"
        Write-Host "Render with:"
        Write-Host "  dot -Tpng $OutputDotPath -o netscaler.png"
        Write-Host "  dot -Tsvg $OutputDotPath -o netscaler.svg"
        exit 1
    }
    else {
        &$GraphvizPath -Tpng $OutputDotPath -o $OutputDotPath.replace('.dot', '.png')
        Write-Host "PNG file written to $($OutputDotPath.replace('.dot', '.png'))"
    }
}
else {
    Write-Host "DOT file written to $OutputDotPath"
    Write-Host "Render with:"
    Write-Host "  dot -Tpng $OutputDotPath -o netscaler.png"
    Write-Host "  dot -Tsvg $OutputDotPath -o netscaler.svg"
}

