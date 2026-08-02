#requires -Version 2.0

function Test-DDMBlank {
    param($Value)
    if ($null -eq $Value) { return $true }
    return ([string]$Value).Trim().Length -eq 0
}

function Get-DDMSha256 {
    param([Parameter(Mandatory=$true)][string]$Path)
    $Sha=[System.Security.Cryptography.SHA256]::Create()
    $Stream=[System.IO.File]::OpenRead($Path)
    try { return ([BitConverter]::ToString($Sha.ComputeHash($Stream))).Replace('-','').ToUpperInvariant() }
    finally { $Stream.Close(); $Sha.Dispose() }
}

function Write-DDMAtomicText {
    param([string]$Path,[string]$Value,[string]$EncodingName='UTF8')
    $Parent=Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $Parent)) { New-Item -Path $Parent -ItemType Directory -Force | Out-Null }
    $Temp=$Path+'.new-'+[guid]::NewGuid().ToString('N')
    try {
        if ($EncodingName -eq 'ASCII') { [System.IO.File]::WriteAllText($Temp,$Value,[System.Text.Encoding]::ASCII) }
        else { [System.IO.File]::WriteAllText($Temp,$Value,(New-Object System.Text.UTF8Encoding($false))) }
        Move-Item -LiteralPath $Temp -Destination $Path -Force
    } finally { Remove-Item -LiteralPath $Temp -Force -ErrorAction SilentlyContinue }
}

function Read-DDMFirstLine {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return '' }
    return ([string](Get-Content -LiteralPath $Path -ErrorAction SilentlyContinue | Select-Object -First 1)).Trim()
}

function Import-DDMClixmlSafe {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { throw "Arquivo CLIXML ausente: $Path" }
    $Item=Get-Item -LiteralPath $Path
    if (($Item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) { throw "CLIXML nao pode ser reparse point: $Path" }
    return Import-Clixml -LiteralPath $Path
}

function Export-DDMClixmlAtomic {
    param($InputObject,[string]$Path,[int]$Depth=8)
    $Parent=Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $Parent)) { New-Item -Path $Parent -ItemType Directory -Force | Out-Null }
    $Temp=$Path+'.new-'+[guid]::NewGuid().ToString('N')
    try { $InputObject | Export-Clixml -LiteralPath $Temp -Depth $Depth; Move-Item -LiteralPath $Temp -Destination $Path -Force }
    finally { Remove-Item -LiteralPath $Temp -Force -ErrorAction SilentlyContinue }
}

function Compare-DDMSemVer {
    param([string]$Left,[string]$Right)
    $Pattern='^(\d+)\.(\d+)\.(\d+)(?:-([0-9A-Za-z.-]+))?$'
    if ($Left -notmatch $Pattern) { throw "SemVer invalido: $Left" }
    $LMajor=[int]$Matches[1];$LMinor=[int]$Matches[2];$LPatch=[int]$Matches[3];$LPre=[string]$Matches[4]
    if ($Right -notmatch $Pattern) { throw "SemVer invalido: $Right" }
    $RMajor=[int]$Matches[1];$RMinor=[int]$Matches[2];$RPatch=[int]$Matches[3];$RPre=[string]$Matches[4]
    foreach ($Pair in @(@($LMajor,$RMajor),@($LMinor,$RMinor),@($LPatch,$RPatch))) {
        if ($Pair[0] -lt $Pair[1]) { return -1 }
        if ($Pair[0] -gt $Pair[1]) { return 1 }
    }
    if ((Test-DDMBlank $LPre) -and (Test-DDMBlank $RPre)) { return 0 }
    if (Test-DDMBlank $LPre) { return 1 }
    if (Test-DDMBlank $RPre) { return -1 }
    return [string]::Compare($LPre,$RPre,$true)
}

function Get-DDMSystemInfo {
    $Os=Get-WmiObject Win32_OperatingSystem -ErrorAction Stop
    $Cs=Get-WmiObject Win32_ComputerSystem -ErrorAction Stop
    $Version=New-Object System.Version([string]$Os.Version)
    $ArchRaw=([string]$Os.OSArchitecture+' '+[string]$env:PROCESSOR_ARCHITEW6432+' '+[string]$env:PROCESSOR_ARCHITECTURE).ToUpperInvariant()
    $Arch=if($ArchRaw -match 'ARM64'){'ARM64'}elseif($ArchRaw -match 'IA64'){'IA64'}elseif($ArchRaw -match 'AMD64|X64'){'AMD64'}elseif($ArchRaw -match 'X86|32-BIT'){'X86'}elseif($ArchRaw -match '64-BIT'){'AMD64'}else{'UNKNOWN'}
    $IsServer=([int]$Os.ProductType -ne 1)
    return New-Object PSObject -Property @{Caption=[string]$Os.Caption;Version=$Version;ProductType=[int]$Os.ProductType;IsServer=$IsServer;Architecture=$Arch;Domain=[string]$Cs.Domain;PartOfDomain=[bool]$Cs.PartOfDomain;Class=$(if($IsServer){'SERVER'}else{'WORKSTATION'});OsTag=$(if($IsServer){'WIN_SERVER'}else{'WIN_CLIENT'})}
}

function Get-DDMTargetAgent {
    param($SystemInfo,$Product)
    if (@('ARM64','IA64','UNKNOWN') -contains [string]$SystemInfo.Architecture) { throw "Arquitetura nao suportada pelos artefatos do produto: $($SystemInfo.Architecture)" }
    if ($SystemInfo.IsServer -and $SystemInfo.Version.Major -eq 6 -and $SystemInfo.Version.Minor -le 1) { return New-Object PSObject -Property @{Family='AGENT1';Architecture=$SystemInfo.Architecture;Service='Zabbix Agent';OppositeService='Zabbix Agent 2'} }
    $Server2012=$SystemInfo.IsServer -and $SystemInfo.Version.Major -eq 6 -and $SystemInfo.Version.Minor -ge 2
    $ModernServer=$SystemInfo.IsServer -and $SystemInfo.Version.Major -ge 10
    $ModernClient=(-not $SystemInfo.IsServer) -and $SystemInfo.Version.Major -ge 10
    if ($Server2012 -or $ModernServer -or $ModernClient) {
        if ($SystemInfo.Architecture -ne 'AMD64') { throw 'Agent 2 com pacote completo de plugins exige Windows AMD64 neste produto.' }
        if ($Server2012 -and -not [bool]$Product.AllowAgent2OnServer2012) { throw 'Server 2012/2012 R2 bloqueado pela configuracao do produto.' }
        return New-Object PSObject -Property @{Family='AGENT2';Architecture='AMD64';Service='Zabbix Agent 2';OppositeService='Zabbix Agent'}
    }
    throw "Windows nao suportado: $($SystemInfo.Caption) $($SystemInfo.Version)"
}

function Convert-DDMIPv4ToUInt32 {
    param([string]$Address)
    $Parts=$Address.Split('.')
    if ($Parts.Count -ne 4) { throw "IPv4 invalido: $Address" }
    [uint64]$Value=0
    foreach ($Part in $Parts) { $N=0;if(-not[int]::TryParse($Part,[ref]$N) -or $N -lt 0 -or $N -gt 255){throw "IPv4 invalido: $Address"};$Value=($Value -shl 8) -bor [uint64]$N }
    return [uint32]$Value
}

function Get-DDMCidrInfo {
    param([string]$Cidr)
    $Pair=$Cidr.Split('/');$Prefix=0
    if($Pair.Count -ne 2 -or -not[int]::TryParse($Pair[1],[ref]$Prefix) -or $Prefix -lt 0 -or $Prefix -gt 32){throw "CIDR invalido: $Cidr"}
    [uint64]$Ip=[uint64](Convert-DDMIPv4ToUInt32 $Pair[0]);[uint64]$Mask=if($Prefix -eq 0){0}else{([uint64]4294967295 -shl (32-$Prefix)) -band [uint64]4294967295};[uint64]$Network=$Ip -band $Mask;[uint64]$Broadcast=$Network -bor ((-bnot $Mask) -band [uint64]4294967295)
    $Octets=@();for($I=3;$I -ge 0;$I--){$Octets+=[string](($Network -shr ($I*8)) -band 255)}
    return New-Object PSObject -Property @{Cidr=$Cidr;Prefix=$Prefix;Network=$Network;Broadcast=$Broadcast;Canonical=(($Octets -join '.')+'/'+$Prefix)}
}

function Test-DDMCidrOverlap { param([string]$Left,[string]$Right);$L=Get-DDMCidrInfo $Left;$R=Get-DDMCidrInfo $Right;return($L.Network -le $R.Broadcast -and $R.Network -le $L.Broadcast) }
function Test-DDMIPv4InCidr { param([string]$Address,[string]$Cidr);$Info=Get-DDMCidrInfo $Cidr;[uint64]$Ip=[uint64](Convert-DDMIPv4ToUInt32 $Address);return($Ip -ge $Info.Network -and $Ip -le $Info.Broadcast) }

function Get-DDMLocalIPv4Info {
    $Result=@();$Adapters=Get-WmiObject Win32_NetworkAdapterConfiguration -Filter 'IPEnabled=True' -ErrorAction SilentlyContinue
    foreach($Adapter in @($Adapters)){$HasGateway=@($Adapter.DefaultIPGateway).Count -gt 0;foreach($Address in @($Adapter.IPAddress)){if([string]$Address -match '^\d{1,3}(\.\d{1,3}){3}$' -and [string]$Address -notmatch '^169\.254\.'){try{[void](Convert-DDMIPv4ToUInt32 ([string]$Address))}catch{continue};$Result+=New-Object PSObject -Property @{Address=[string]$Address;HasDefaultGateway=$HasGateway;Description=[string]$Adapter.Description}}}}
    return @($Result|Sort-Object Address -Unique)
}

function Get-DDMDetectedModules {
    param($Product)
    $Modules=@('CORE');$Services=@(Get-Service -ErrorAction SilentlyContinue)
    foreach($Rule in @($Product.DefaultModuleDetection)){$Detected=$false;foreach($Pattern in @($Rule.ServicePatterns)){if(@($Services|Where-Object{$_.Name -like [string]$Pattern}).Count -gt 0){$Detected=$true;break}};if(-not$Detected){foreach($Path in @($Rule.FilePatterns)){if(Test-Path -LiteralPath ([string]$Path)){$Detected=$true;break}}};if($Detected -and $Modules -notcontains [string]$Rule.Module){$Modules+=[string]$Rule.Module}}
    return @($Modules|Sort-Object -Unique)
}

function Get-DDMRuleIdentity($Rule) {
    return '{0}|{1}|{2}|{3}|{4}|{5}' -f [string]$Rule.Site,[string]$Rule.GroupSite,[string]$Rule.Proxy,[string]$Rule.ProxyActive,[string]$Rule.Class,[string]$Rule.Area
}

function Select-DDMNetworkRule {
    param($Client,[string]$ComputerName,[string]$PreferredSite)
    $Rules=@($Client.Networks)
    if($Rules.Count -eq 0){if([bool]$Client.Scope.RequireNetworkMatch){throw 'O cliente exige rede, mas nao possui regras de rede.'};return $null}
    if(-not(Test-DDMBlank $PreferredSite)){
        $SiteRules=@($Rules|Where-Object{([string]$_.Site).ToUpperInvariant() -eq $PreferredSite.ToUpperInvariant()})
        if($SiteRules.Count -eq 0){throw "Site explicito sem regra de rede/proxy: $PreferredSite"};if($SiteRules.Count -eq 1){return$SiteRules[0]}
        $TopPriority=($SiteRules|Measure-Object -Property Priority -Maximum).Maximum;$Top=@($SiteRules|Where-Object{[int]$_.Priority -eq [int]$TopPriority});$Destinations=@($Top|ForEach-Object{Get-DDMRuleIdentity $_}|Sort-Object -Unique)
        if($Destinations.Count -ne 1){throw "Site explicito ambiguo: $PreferredSite ($($Destinations -join '; '))"};return$Top[0]
    }
    $Ignored=@();if($Client.Exceptions -and $Client.Exceptions.IgnoredIPv4){$Ignored=@($Client.Exceptions.IgnoredIPv4)};$Ips=@(Get-DDMLocalIPv4Info|Where-Object{$Ignored -notcontains $_.Address});$Matches=@()
    foreach($Rule in $Rules){$Prefix=[int](([string]$Rule.Cidr).Split('/')[1]);$Priority=if($null -ne $Rule.Priority){[int]$Rule.Priority}else{0};foreach($Ip in $Ips){if(Test-DDMIPv4InCidr $Ip.Address ([string]$Rule.Cidr)){$Matches+=New-Object PSObject -Property @{Rule=$Rule;Ip=$Ip.Address;Gateway=[bool]$Ip.HasDefaultGateway;Priority=$Priority;Prefix=$Prefix}}}}
    if($Matches.Count -eq 0){if([bool]$Client.Scope.RequireNetworkMatch){throw "Nenhuma rede aprovada corresponde aos IPv4 locais: $(@($Ips.Address) -join ', ')"};return $null}
    $Sorted=@($Matches|Sort-Object @{Expression='Gateway';Descending=$true},@{Expression='Priority';Descending=$true},@{Expression='Prefix';Descending=$true},@{Expression='Ip';Descending=$false});$Best=$Sorted[0];$Ties=@($Sorted|Where-Object{$_.Gateway -eq $Best.Gateway -and $_.Priority -eq $Best.Priority -and $_.Prefix -eq $Best.Prefix});$Identities=@($Ties|ForEach-Object{Get-DDMRuleIdentity $_.Rule}|Sort-Object -Unique)
    if($Identities.Count -gt 1){throw "Empate de redes com destinos diferentes: $($Identities -join '; ')"};return$Best.Rule
}

function Expand-DDMTokens {
    param([string]$Template,$Tokens)
    $Result=$Template
    foreach($Key in @($Tokens.Keys)){$Result=$Result.Replace(('{'+[string]$Key+'}'),[string]$Tokens[$Key])}
    if($Result -match '\{[A-Z0-9_]+\}'){throw "Token nao resolvido em: $Result"}
    return$Result
}

function Resolve-DDMClientIdentity {
    param($Client,$Product,$SystemInfo)
    if([int]$Client.SchemaVersion -ne [int]$Product.ClientSchemaVersion){throw "Schema incompatível. Cliente=$($Client.SchemaVersion), motor=$($Product.ClientSchemaVersion)"}
    if(-not$SystemInfo.PartOfDomain){throw 'A maquina nao pertence a dominio.'}
    $ActualDomain=([string]$SystemInfo.Domain).Trim().TrimEnd('.').ToLowerInvariant()
    $Accepted=@($Client.Scope.AcceptedDomains|ForEach-Object{([string]$_).Trim().TrimEnd('.').ToLowerInvariant()}|Where-Object{$_})
    if($Accepted -notcontains $ActualDomain){throw "Dominio nao permitido: $($SystemInfo.Domain)"}
    if($SystemInfo.IsServer -and -not[bool]$Client.Scope.ServersAllowed){throw 'Servidores nao permitidos pelo cliente.'};if((-not$SystemInfo.IsServer) -and -not[bool]$Client.Scope.WorkstationsAllowed){throw 'Workstations nao permitidas pelo cliente.'}
    if(-not(Test-DDMBlank $Client.Scope.DomainSid)){try{$Root=[ADSI]'LDAP://RootDSE';$DomainEntry=[ADSI]('LDAP://'+[string]$Root.defaultNamingContext);$SidBytes=$DomainEntry.Properties['objectSid'].Value;$DomainSid=(New-Object System.Security.Principal.SecurityIdentifier($SidBytes,0)).Value;if($DomainSid -ne [string]$Client.Scope.DomainSid){throw "SID de dominio divergente: $DomainSid"}}catch{throw "Nao foi possivel validar DomainSid: $($_.Exception.Message)"}}
    $Cluster='';$ExplicitSite='';$Node=$env:COMPUTERNAME.ToUpperInvariant()
    if($Client.Exceptions -and $Client.Exceptions.ExplicitHyperVNodes -and $Client.Exceptions.ExplicitHyperVNodes.ContainsKey($Node)){$Cluster=[string]$Client.Exceptions.ExplicitHyperVNodes[$Node];if($Client.Exceptions.ClusterSiteMap -and $Client.Exceptions.ClusterSiteMap.ContainsKey($Cluster)){$ExplicitSite=[string]$Client.Exceptions.ClusterSiteMap[$Cluster]}}
    $Rule=Select-DDMNetworkRule $Client $env:COMPUTERNAME $ExplicitSite;$Site='';$GroupSite='';$Proxy='';$ProxyActive='';$Class=$SystemInfo.Class;$Area='';$Role=''
    if($Rule){$Site=[string]$Rule.Site;$GroupSite=[string]$Rule.GroupSite;$Proxy=[string]$Rule.Proxy;$ProxyActive=$(if($Rule.ProxyActive){[string]$Rule.ProxyActive}else{[string]$Rule.Proxy});if($Rule.Class){$Class=[string]$Rule.Class};$Area=[string]$Rule.Area}
    else{if($Client.Communication.Proxy){$Proxy=[string]$Client.Communication.Proxy}elseif($Client.Communication.Server){$Proxy=[string]$Client.Communication.Server};if($Client.Communication.ProxyActive){$ProxyActive=[string]$Client.Communication.ProxyActive}elseif($Client.Communication.ServerActive){$ProxyActive=[string]$Client.Communication.ServerActive}else{$ProxyActive=$Proxy}}
    if(-not(Test-DDMBlank $ExplicitSite)){$Site=$ExplicitSite};if(Test-DDMBlank $Proxy){throw 'Proxy nao resolvido.'}
    $Modules=Get-DDMDetectedModules $Product;if($Modules -contains 'ADDS'){$Role='ADDS'}elseif($Modules -contains 'HYPERV'){$Role='HYPERV'}elseif($Modules -contains 'VEEAM'){$Role='VEEAM'}elseif($Modules -contains 'MSSQL'){$Role='MSSQL'}else{$Role=$Class}
    $Base=$env:COMPUTERNAME.ToUpperInvariant();$BaseWithout=$Base;if($BaseWithout.StartsWith('SRV-')){$BaseWithout=$BaseWithout.Substring(4)};$Pattern=[string]$Client.Identity.HostnamePattern
    if($Client.Identity.NormalHostnamePattern){if($Class -eq 'IND' -and $Client.Identity.IndustrialHostnamePattern){$Pattern=[string]$Client.Identity.IndustrialHostnamePattern}else{$Pattern=[string]$Client.Identity.NormalHostnamePattern}}
    $ProductTag=if($Client.ProductTag){[string]$Client.ProductTag}else{[string]$Product.ProductCode}
    $Tokens=@{SITE=$Site;GROUP_SITE=$GroupSite;ORIGNAME=$env:COMPUTERNAME.ToUpperInvariant();BASE=$BaseWithout;BASE_WITHOUT_SRV_PREFIX=$BaseWithout;OS=$SystemInfo.OsTag;CLASS=$Class;AREA=$Area;ROLE=$Role;GROUP_ROLE=$Role;CLUSTER=$Cluster;PRODUCT_TAG=$ProductTag;PRODUCT_VERSION=$Product.ProductVersion;MODULES=($Modules -join ',')}
    $Hostname=(Expand-DDMTokens $Pattern $Tokens).ToUpperInvariant();if($Hostname.Length -gt 128 -or $Hostname -notmatch '^[A-Z0-9._-]+$'){throw "Hostname invalido: $Hostname"};$Metadata=Expand-DDMTokens ([string]$Client.Identity.MetadataTemplate) $Tokens;if($Metadata -match "`r|`n"){throw 'HostMetadata nao pode conter quebra de linha.'};$Bytes=[System.Text.Encoding]::UTF8.GetByteCount($Metadata);$Limit=if($Client.Identity.HostMetadataMaxBytes){[int]$Client.Identity.HostMetadataMaxBytes}else{2034};if($Bytes -gt $Limit){throw "HostMetadata excede $Limit bytes: $Bytes"}
    return New-Object PSObject -Property @{Hostname=$Hostname;Metadata=$Metadata;Proxy=$Proxy;ProxyActive=$ProxyActive;Site=$Site;GroupSite=$GroupSite;Class=$Class;Area=$Area;Role=$Role;Cluster=$Cluster;Modules=$Modules}
}

function Test-DDMPortOwnedByProcess {
    param([int]$Port,[string[]]$ProcessNames)
    $Lines=@(& netstat.exe -ano -p tcp 2>$null|Select-String (':{0}\s+.*LISTENING\s+(\d+)$' -f $Port))
    foreach($Line in $Lines){if([string]$Line -match '(\d+)\s*$'){try{$P=Get-Process -Id ([int]$Matches[1]) -ErrorAction Stop;if($ProcessNames -contains $P.ProcessName.ToLowerInvariant()){return $true}}catch{}}};return $false
}

function Get-DDMFreeSpaceMB {
    param([string]$Path)
    $Root=[System.IO.Path]::GetPathRoot($Path);$Disk=Get-WmiObject Win32_LogicalDisk -Filter ("DeviceID='"+$Root.TrimEnd('\')+"'") -ErrorAction SilentlyContinue;if($null -eq $Disk){return 0};return[math]::Floor([double]$Disk.FreeSpace/1MB)
}

function Set-DDMLocalSecureAcl {
    param([Parameter(Mandatory=$true)][string]$Path)
    if(-not(Test-Path -LiteralPath $Path)){New-Item -Path $Path -ItemType Directory -Force|Out-Null}
    & icacls.exe $Path /inheritance:r /grant:r '*S-1-5-18:(OI)(CI)F' '*S-1-5-32-544:(OI)(CI)F' '*S-1-5-32-545:(OI)(CI)RX' /T /C /Q|Out-Null
    if($LASTEXITCODE -ne 0){throw "Falha ao proteger ACL local: $Path (ExitCode=$LASTEXITCODE)"}
}
