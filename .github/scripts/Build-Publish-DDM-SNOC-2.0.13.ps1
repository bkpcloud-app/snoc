#requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$Repo,
    [Parameter(Mandatory=$true)][string]$Product,
    [Parameter(Mandatory=$true)][string]$Version,
    [Parameter(Mandatory=$true)][string]$Tag,
    [Parameter(Mandatory=$true)][string]$SourceCommit
)

$ErrorActionPreference='Stop'
$Dist=Join-Path $env:RUNNER_TEMP ('ddm-release-'+$Version+'-'+[guid]::NewGuid().ToString('N'))
$Motor=Join-Path $Dist ('DDM-SNOC-WINDOWS-MOTOR-'+$Version)
$Seed=Join-Path $Dist ('DDM-SNOC-WINDOWS-AD-SEED-'+$Version)

try {
    Write-Host '4.1/7 - Construindo MOTOR e AD-SEED'
    New-Item $Motor,$Seed -ItemType Directory -Force | Out-Null

    foreach($Name in @('Start-DDM-SNOC.ps1','CLIENTE.example.ps1','README.md','CHANGELOG.md')){
        Copy-Item (Join-Path $Product $Name) (Join-Path $Motor $Name) -Force
    }
    foreach($Name in @('config','lib','central','bootstrap','endpoint','engine','modules','templates','tools','docs','clients')){
        Copy-Item (Join-Path $Product $Name) (Join-Path $Motor $Name) -Recurse -Force
    }

    foreach($Name in @('ATUALIZAR-AD.cmd','VOLTAR-RELEASE.cmd')){
        Copy-Item (Join-Path $Product ('templates\central\'+$Name)) (Join-Path $Seed $Name) -Force
    }
    Copy-Item (Join-Path $Product 'CLIENTE.example.ps1') (Join-Path $Seed 'CLIENTE.example.ps1') -Force
    Copy-Item (Join-Path $Product 'docs\UPDATE-AD.md') (Join-Path $Seed 'LEIA-ME-UPDATE-AD.md') -Force
    Copy-Item (Join-Path $Product 'docs\AUDITORIA-300-PONTOS.md') (Join-Path $Seed 'AUDITORIA-300-PONTOS.md') -Force
    Copy-Item (Join-Path $Product 'docs\AUDITORIA-MIZU-ACL-40-PONTOS.md') (Join-Path $Seed 'AUDITORIA-MIZU-ACL-40-PONTOS.md') -Force

    $Updater=Join-Path $Seed 'CENTRAL-UPDATER'
    foreach($Rel in @(
        'central\Update-DDM-SNOC-Central.ps1',
        'central\lib\DDM-Central-Client.ps1',
        'central\lib\DDM-Central-Supply.ps1',
        'central\lib\Invoke-DDM-Central-Publish.ps1',
        'config\DDM-Product.ps1',
        'lib\DDM-Common.ps1'
    )){
        $Destination=Join-Path $Updater $Rel
        New-Item (Split-Path -Parent $Destination) -ItemType Directory -Force | Out-Null
        Copy-Item (Join-Path $Product $Rel) $Destination -Force
    }

    $Rollback=Join-Path $Seed 'CENTRAL-TOOLS\tools\Set-DDM-CentralRelease.ps1'
    New-Item (Split-Path -Parent $Rollback) -ItemType Directory -Force | Out-Null
    Copy-Item (Join-Path $Product 'tools\Set-DDM-CentralRelease.ps1') $Rollback -Force

    foreach($Required in @(
        'ATUALIZAR-AD.cmd',
        'VOLTAR-RELEASE.cmd',
        'CLIENTE.example.ps1',
        'CENTRAL-UPDATER\central\Update-DDM-SNOC-Central.ps1',
        'CENTRAL-TOOLS\tools\Set-DDM-CentralRelease.ps1'
    )){
        if(-not(Test-Path -LiteralPath (Join-Path $Seed $Required))){throw "AD-SEED incompleto: $Required"}
    }

    $MotorZip=Join-Path $Dist ('DDM-SNOC-WINDOWS-MOTOR-'+$Version+'.zip')
    $SeedZip=Join-Path $Dist ('DDM-SNOC-WINDOWS-AD-SEED-'+$Version+'.zip')
    Compress-Archive -Path $Motor -DestinationPath $MotorZip -CompressionLevel Optimal
    Compress-Archive -Path (Join-Path $Seed '*') -DestinationPath $SeedZip -CompressionLevel Optimal

    Write-Host '4.2/7 - Validando o MOTOR empacotado'
    $Expanded=Join-Path $env:RUNNER_TEMP ('ddm-expanded-'+$Version+'-'+[guid]::NewGuid().ToString('N'))
    Expand-Archive -LiteralPath $MotorZip -DestinationPath $Expanded -Force
    $ExpandedProduct=Join-Path $Expanded ('DDM-SNOC-WINDOWS-MOTOR-'+$Version)
    $ExpandedRepo=Split-Path -Parent (Split-Path -Parent $ExpandedProduct)
    $WorkflowRoot=Join-Path $ExpandedRepo '.github\workflows'
    New-Item $WorkflowRoot -ItemType Directory -Force | Out-Null
    Copy-Item (Join-Path $Repo '.github\workflows\ddm-snoc-windows-validation.yml') $WorkflowRoot -Force
    Copy-Item (Join-Path $Repo '.github\workflows\ddm-snoc-windows-release.yml') $WorkflowRoot -Force
    & (Join-Path $ExpandedProduct 'tools\Test-DDM-Repository.ps1') -ProductRoot $ExpandedProduct
    if($LASTEXITCODE -ne 0){throw "MOTOR empacotado retornou $LASTEXITCODE na validacao."}
    Remove-Item $Expanded -Recurse -Force -ErrorAction SilentlyContinue

    Write-Host '4.3/7 - Gerando hashes e manifesto'
    $Assets=@()
    foreach($Zip in @($MotorZip,$SeedZip)){
        $Hash=(Get-FileHash -LiteralPath $Zip -Algorithm SHA256).Hash.ToUpperInvariant()
        $HashPath=$Zip+'.sha256'
        Set-Content -LiteralPath $HashPath -Value ($Hash+' *'+(Split-Path -Leaf $Zip)) -Encoding ASCII
        $Assets+=New-Object PSObject -Property @{Name=(Split-Path -Leaf $Zip);Sha256=$Hash;Size=(Get-Item $Zip).Length}
    }

    $ManifestPath=Join-Path $Dist ('DDM-SNOC-WINDOWS-RELEASE-MANIFEST-'+$Version+'.json')
    $Manifest=New-Object PSObject -Property @{
        Product='DDM SNOC Windows'
        ProductVersion=$Version
        GitCommit=$SourceCommit
        GitTag=$Tag
        GeneratedAtUtc=(Get-Date).ToUniversalTime().ToString('o')
        Assets=$Assets
        Validation=@(
            'repository',
            'runtime-lexing',
            'acl',
            'all-seven-unc-cmds',
            'full-state-acl-recovery',
            'client-runtime-read',
            'desired-state-write',
            'manual-now-no-jitter',
            'full-central-pilot'
        )
        ExternalPilotsRequired=$false
    }
    $Manifest | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $ManifestPath -Encoding UTF8
    $ManifestHash=(Get-FileHash -LiteralPath $ManifestPath -Algorithm SHA256).Hash.ToUpperInvariant()
    Set-Content -LiteralPath ($ManifestPath+'.sha256') -Value ($ManifestHash+' *'+(Split-Path -Leaf $ManifestPath)) -Encoding ASCII

    $Files=@(
        $MotorZip,
        ($MotorZip+'.sha256'),
        $SeedZip,
        ($SeedZip+'.sha256'),
        $ManifestPath,
        ($ManifestPath+'.sha256')
    )
    if(@($Files | Where-Object {-not(Test-Path -LiteralPath $_)}).Count -ne 0){throw 'Um ou mais assets finais estao ausentes.'}

    Write-Host '4.4/7 - Publicando tag e seis assets'
    $ErrorActionPreference='Continue'
    & gh release delete $Tag --yes 2>$null
    git push --delete origin $Tag 2>$null
    git tag -d $Tag 2>$null
    $ErrorActionPreference='Stop'

    git tag -a $Tag $SourceCommit -m "DDM SNOC Windows $Version"
    if($LASTEXITCODE -ne 0){throw "git tag retornou $LASTEXITCODE"}
    git push origin $Tag
    if($LASTEXITCODE -ne 0){throw "git push da tag retornou $LASTEXITCODE"}

    & gh release create $Tag @Files --verify-tag --generate-notes --title "DDM SNOC Windows $Version"
    if($LASTEXITCODE -ne 0){throw "gh release create retornou $LASTEXITCODE"}

    $ReleaseJson=& gh release view $Tag --json tagName,isDraft,isPrerelease,assets
    if($LASTEXITCODE -ne 0){throw 'Nao foi possivel reler a release publicada.'}
    $Release=$ReleaseJson | ConvertFrom-Json
    if($Release.isDraft -or $Release.isPrerelease){throw 'Release publicada como draft ou prerelease.'}
    if(@($Release.assets).Count -ne 6){throw "Release possui $(@($Release.assets).Count) assets; esperado=6."}

    Write-Host 'SIX_RELEASE_ASSETS_PUBLISHED_OK' -ForegroundColor Green
}
finally {
    Remove-Item $Dist -Recurse -Force -ErrorAction SilentlyContinue
}
