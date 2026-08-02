function Write-CentralLog([string]$Message,[string]$Level='INFO') {
    $Line='{0} [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'),$Level,$Message
    Write-Host $Line
    $Parent=Split-Path -Parent $LogPath
    if (-not (Test-Path -LiteralPath $Parent)) { New-Item -Path $Parent -ItemType Directory -Force | Out-Null }
    Add-Content -LiteralPath $LogPath -Value $Line -Encoding UTF8
}

function Read-DDMClientPs1Safe([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path)) { throw "CLIENTE.ps1 ausente: $Path" }
    $Item=Get-Item -LiteralPath $Path
    if (($Item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'CLIENTE.ps1 nao pode ser reparse point.' }
    $Raw=[System.IO.File]::ReadAllText($Path)
    if ($Raw -notmatch '(?ms)^\s*(?:#.*\r?\n\s*)*\$DDMClient\s*=\s*(?<data>@\{.*\})\s*$') {
        throw 'CLIENTE.ps1 deve conter somente comentarios e uma atribuicao literal para $DDMClient.'
    }
    $Data=$Matches['data']
    $Temp=Join-Path $RunRoot 'CLIENTE.safe.psd1'
    [System.IO.File]::WriteAllText($Temp,$Data,(New-Object System.Text.UTF8Encoding($false)))
    try { $Client=Import-PowerShellDataFile -LiteralPath $Temp }
    catch { throw "CLIENTE.ps1 rejeitado pelo parser seguro: $($_.Exception.Message)" }
    if ($null -eq $Client -or -not ($Client -is [hashtable])) { throw 'CLIENTE.ps1 nao resultou em hashtable.' }
    return $Client
}

function Assert-DDMNoSecrets($Value,[string]$Path='DDMClient') {
    if ($null -eq $Value) { return }
    if ($Value -is [System.Collections.IDictionary]) {
        foreach ($Key in @($Value.Keys)) {
            $Name=[string]$Key
            if ($Name -match '(?i)(password|passwd|secret|token|credential|api.?key|private.?key|psk)') { throw "Campo de segredo proibido em CLIENTE.ps1: $Path.$Name" }
            Assert-DDMNoSecrets $Value[$Key] ($Path + '.' + $Name)
        }
    } elseif ($Value -is [System.Collections.IEnumerable] -and -not ($Value -is [string])) {
        $Index=0; foreach ($Item in $Value) { Assert-DDMNoSecrets $Item ($Path + '[' + $Index + ']'); $Index++ }
    }
}

function Assert-DDMHostOrIp([string]$Value,[string]$Label) {
    if ([string]::IsNullOrWhiteSpace($Value)) { throw "$Label vazio." }
    if ($Value -match '[\s,;]') { throw "$Label deve conter um unico host ou IP: $Value" }
    if ($Value.Length -gt 255) { throw "$Label excede 255 caracteres." }
}

function Assert-DDMClient([hashtable]$Client,$Product) {
    foreach ($Name in @('SchemaVersion','ConfigVersion','ClientId','DisplayName','Status','ProductionReady','MinimumEngineVersion','Update','Scope','Communication','Identity','Networks','Deployment','AutoRegistration')) {
        if (-not $Client.ContainsKey($Name)) { throw "CLIENTE.ps1 sem campo obrigatorio: $Name" }
    }
    Assert-DDMNoSecrets $Client
    if ([int]$Client.SchemaVersion -ne [int]$Product.ClientSchemaVersion) { throw "Schema incompatível: $($Client.SchemaVersion)" }
    [void](Compare-DDMSemVer ([string]$Client.ConfigVersion) '0.0.0')
    if ([string]::IsNullOrWhiteSpace([string]$Client.ClientId) -or [string]$Client.ClientId -notmatch '^[A-Z0-9_-]+$') { throw 'ClientId vazio ou invalido.' }

    $EndpointModes=@('LOCAL_BOOTSTRAP_SCHEDULED_TASK','MANUAL_LOCAL_BOOTSTRAP')
    if ($EndpointModes -notcontains [string]$Client.Update.EndpointMode) { throw 'EndpointMode invalido.' }
    if ([string]$Client.Update.CentralUpdateMode -notmatch '^(GITHUB_RELEASE_LATEST_STABLE_7_0|MANUAL_LATEST_STABLE_7_0_PACKAGE)$') { throw 'CentralUpdateMode invalido.' }
    if ([string]::IsNullOrWhiteSpace([string]$Client.Update.CentralPath)) { throw 'CentralPath vazio.' }
    if ($Client.Update.MaxOfflineCacheDays -and ([int]$Client.Update.MaxOfflineCacheDays -lt 1 -or [int]$Client.Update.MaxOfflineCacheDays -gt 90)) { throw 'MaxOfflineCacheDays deve estar entre 1 e 90.' }

    if (-not [bool]$Client.Deployment.InstallAllCompatibleModules) { throw 'InstallAllCompatibleModules deve permanecer true.' }
    if ([bool]$Client.Deployment.ApplicationTemplatesLinkedAutomatically -or [bool]$Client.AutoRegistration.LinkApplicationTemplatesAutomatically) { throw 'Templates de aplicacao nao podem ser vinculados automaticamente pelo motor.' }
    if ($Client.Deployment.Ring -and @('LAB','CANARY','PILOT','PRODUCTION') -notcontains [string]$Client.Deployment.Ring) { throw 'Deployment.Ring invalido.' }
    if ($Client.Deployment.ContainsKey('AllowSystemRun') -and [bool]$Client.Deployment.AllowSystemRun -ne [bool]$Product.AllowSystemRun) { throw 'AllowSystemRun do cliente diverge da politica aprovada do produto.' }

    if ($Client.AutoRegistration.ContainsKey('EngineExecutesServerActions') -and [bool]$Client.AutoRegistration.EngineExecutesServerActions) { throw 'O motor local nao executa acoes no Zabbix Server.' }
    if ($Client.AutoRegistration.ActionOwner -and [string]$Client.AutoRegistration.ActionOwner -ne 'ZABBIX_SERVER_CONFIGURATION') { throw 'AutoRegistration.ActionOwner invalido.' }

    if ([string]::IsNullOrWhiteSpace([string]$Client.Identity.MetadataTemplate)) { throw 'MetadataTemplate vazio.' }
    $HostnamePattern=if($Client.Identity.HostnamePattern){[string]$Client.Identity.HostnamePattern}else{[string]$Client.Identity.NormalHostnamePattern}
    if ([string]::IsNullOrWhiteSpace($HostnamePattern)) { throw 'Padrao de hostname vazio.' }
    if (@($Client.Scope.AcceptedDomains).Count -eq 0) { throw 'AcceptedDomains vazio.' }

    $Status=[string]$Client.Status
    $PublishableStatus=@('PILOT_READY','PILOT_READY_AFTER_ACL','PRODUCTION_READY')
    if ([bool]$Client.ProductionReady) {
        if ($Status -ne 'PRODUCTION_READY') { throw 'ProductionReady=true exige Status=PRODUCTION_READY.' }
        if (@($Client.Blockers).Count -gt 0) { throw 'ProductionReady=true com Blockers preenchido.' }
    } elseif ($Status -eq 'PRODUCTION_READY') {
        throw 'Status=PRODUCTION_READY exige ProductionReady=true.'
    }
    if ($PublishableStatus -contains $Status -and $Status -ne 'PRODUCTION_READY' -and [bool]$Client.ProductionReady) { throw 'Estado de piloto nao pode estar marcado como producao.' }
    if ((Compare-DDMSemVer ([string]$Client.MinimumEngineVersion) ([string]$Product.ProductVersion)) -gt 0) { throw 'Cliente exige motor mais novo.' }

    $ListenPort=if($Client.Communication.ListenPort){[int]$Client.Communication.ListenPort}else{[int]$Product.ListenPort}
    if ($ListenPort -lt 1 -or $ListenPort -gt 65535) { throw 'Communication.ListenPort invalido.' }
    if ([string]$Client.Communication.TLSMode -ne 'UNENCRYPTED_INTERNAL') { throw 'TLSMode ainda nao implementado pelo motor. Use UNENCRYPTED_INTERNAL.' }

    $Rules=@($Client.Networks)
    if ($Rules.Count -eq 0 -and [bool]$Client.Scope.RequireNetworkMatch) { throw 'RequireNetworkMatch=true sem Networks.' }
    if ($Rules.Count -eq 0) {
        $FixedProxy=if($Client.Communication.Proxy){[string]$Client.Communication.Proxy}elseif($Client.Communication.Server){[string]$Client.Communication.Server}else{''}
        Assert-DDMHostOrIp $FixedProxy 'Communication.Proxy/Server'
    }
    foreach ($Rule in $Rules) {
        $Info=Get-DDMCidrInfo ([string]$Rule.Cidr)
        if ($Info.Canonical -ne [string]$Rule.Cidr) { throw "CIDR nao canonico: $($Rule.Cidr). Use $($Info.Canonical)" }
        if ([string]::IsNullOrWhiteSpace([string]$Rule.Site)) { throw "Site vazio: $($Rule.Cidr)" }
        Assert-DDMHostOrIp ([string]$Rule.Proxy) ("Proxy da rede " + [string]$Rule.Cidr)
        if ($Rule.ProxyActive) { Assert-DDMHostOrIp ([string]$Rule.ProxyActive) ("ProxyActive da rede " + [string]$Rule.Cidr) }
        if ($null -eq $Rule.Priority) { throw "Priority ausente: $($Rule.Cidr)" }
    }
    $Duplicates=@($Rules | Group-Object Cidr | Where-Object Count -gt 1)
    if ($Duplicates.Count -gt 0) { throw "CIDRs duplicados: $(@($Duplicates.Name) -join ', ')" }
    for ($I=0;$I -lt $Rules.Count;$I++) {
        for ($J=$I+1;$J -lt $Rules.Count;$J++) {
            if (Test-DDMCidrOverlap ([string]$Rules[$I].Cidr) ([string]$Rules[$J].Cidr)) {
                $A=Get-DDMCidrInfo ([string]$Rules[$I].Cidr); $B=Get-DDMCidrInfo ([string]$Rules[$J].Cidr)
                $SameRank=([int]$Rules[$I].Priority -eq [int]$Rules[$J].Priority -and $A.Prefix -eq $B.Prefix)
                $IdentityA='{0}|{1}|{2}|{3}|{4}|{5}' -f $Rules[$I].Site,$Rules[$I].GroupSite,$Rules[$I].Proxy,$Rules[$I].ProxyActive,$Rules[$I].Class,$Rules[$I].Area
                $IdentityB='{0}|{1}|{2}|{3}|{4}|{5}' -f $Rules[$J].Site,$Rules[$J].GroupSite,$Rules[$J].Proxy,$Rules[$J].ProxyActive,$Rules[$J].Class,$Rules[$J].Area
                if ($SameRank -and $IdentityA -ne $IdentityB) { throw "Redes sobrepostas sem desempate: $($Rules[$I].Cidr) e $($Rules[$J].Cidr)" }
            }
        }
    }
    if ($Client.Exceptions -and $Client.Exceptions.IgnoredIPv4) { foreach ($Ip in @($Client.Exceptions.IgnoredIPv4)) { [void](Convert-DDMIPv4ToUInt32 ([string]$Ip)) } }
    if (-not [string]::IsNullOrWhiteSpace([string]$Client.Scope.DomainSid) -and [string]$Client.Scope.DomainSid -notmatch '^S-1-5-21-(\d+-){2}\d+$') { throw 'DomainSid invalido.' }
    if ($Client.Exceptions -and $Client.Exceptions.ExplicitHyperVNodes) {
        foreach ($Node in @($Client.Exceptions.ExplicitHyperVNodes.Keys)) {
            $Cluster=[string]$Client.Exceptions.ExplicitHyperVNodes[$Node]
            if (-not $Client.Exceptions.ClusterSiteMap -or -not $Client.Exceptions.ClusterSiteMap.ContainsKey($Cluster)) { throw "Cluster sem ClusterSiteMap: $Node -> $Cluster" }
            $MappedSite=[string]$Client.Exceptions.ClusterSiteMap[$Cluster]
            if (@($Rules | Where-Object { [string]$_.Site -eq $MappedSite }).Count -eq 0) { throw "ClusterSiteMap aponta para site inexistente: $Cluster -> $MappedSite" }
        }
    }
}

function Assert-DDMCentralAcl([string]$Path) {
    $Acl=Get-Acl -LiteralPath $Path
    $Broad=@('S-1-1-0','S-1-5-11','S-1-5-32-545')
    foreach ($Rule in @($Acl.Access)) {
        if ([string]$Rule.AccessControlType -ne 'Allow') { continue }
        try { $Sid=$Rule.IdentityReference.Translate([System.Security.Principal.SecurityIdentifier]).Value } catch { continue }
        $IsBroad=($Broad -contains $Sid -or $Sid -match '-513$' -or $Sid -match '-515$')
        if (-not $IsBroad) { continue }
        $Rights=[System.Security.AccessControl.FileSystemRights]$Rule.FileSystemRights
        $WriteMask=[System.Security.AccessControl.FileSystemRights]::Write -bor [System.Security.AccessControl.FileSystemRights]::Modify -bor [System.Security.AccessControl.FileSystemRights]::FullControl -bor [System.Security.AccessControl.FileSystemRights]::CreateFiles -bor [System.Security.AccessControl.FileSystemRights]::CreateDirectories -bor [System.Security.AccessControl.FileSystemRights]::Delete
        if (($Rights -band $WriteMask) -ne 0) { throw "ACL insegura: $Sid possui escrita em $Path ($Rights). Contas de computador e usuarios amplos devem ter somente leitura." }
    }
}

function Assert-DDMShareAcl([string]$Path) {
    if ($Path -notmatch '^\\\\(?<server>[^\\]+)\\(?<share>[^\\]+)') { return }
    $Server=$Matches['server']; $Share=$Matches['share']
    if (-not (Get-Command Get-SmbShareAccess -ErrorAction SilentlyContinue)) {
        Write-CentralLog 'Get-SmbShareAccess indisponivel; permissao SMB deve ser validada pelo procedimento operacional.' 'WARN'
        return
    }
    try {
        $Rules=if ($Server -in @('.', 'localhost', $env:COMPUTERNAME)) { @(Get-SmbShareAccess -Name $Share -ErrorAction Stop) } else { @(Get-SmbShareAccess -Name $Share -CimSession $Server -ErrorAction Stop) }
        foreach ($Rule in $Rules) {
            if ([string]$Rule.AccessControlType -ne 'Allow') { continue }
            $Account=([string]$Rule.AccountName).ToUpperInvariant()
            $Broad=($Account -match '(^|\\)(EVERYONE|AUTHENTICATED USERS|USERS|DOMAIN USERS|DOMAIN COMPUTERS)$')
            if ($Broad -and [string]$Rule.AccessRight -ne 'Read') { throw "Permissao SMB insegura: $($Rule.AccountName) possui $($Rule.AccessRight) no share $Share." }
        }
    } catch {
        if ($_.Exception.Message -like 'Permissao SMB insegura:*') { throw }
        Write-CentralLog ("Nao foi possivel consultar ACL SMB de ${Server}\${Share}: " + $_.Exception.Message) 'WARN'
    }
}

function Test-DDMAuthenticodeStrong([string]$Path,[string]$ExpectedSigner) {
    $Sig=Get-AuthenticodeSignature -FilePath $Path
    if ($Sig.Status -ne 'Valid' -or $null -eq $Sig.SignerCertificate) { throw "Assinatura invalida: $Path ($($Sig.Status))" }
    $Subject=[string]$Sig.SignerCertificate.Subject
    if ($Subject -notmatch ('(?i)CN=' + [regex]::Escape($ExpectedSigner) + '(,|$)')) { throw "Assinante inesperado: $Subject" }
    $Chain=New-Object System.Security.Cryptography.X509Certificates.X509Chain
    $Chain.ChainPolicy.RevocationMode=[System.Security.Cryptography.X509Certificates.X509RevocationMode]::Online
    $Chain.ChainPolicy.RevocationFlag=[System.Security.Cryptography.X509Certificates.X509RevocationFlag]::ExcludeRoot
    if (-not $Chain.Build($Sig.SignerCertificate)) { throw "Cadeia do assinante nao validou: $Subject" }
}
