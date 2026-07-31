# Exemplo sanitizado. Nao use valores reais neste arquivo publico.
$DDMClientProfile = @{
    SchemaVersion   = 1
    ClientId        = 'CLIENTE'

    # Vazio apenas para testes publicos. Perfis reais devem listar os dominios aceitos.
    AcceptedDomains = @()
    ServersOnly     = $true
    DefaultSite     = 'DC'
    Proxy           = '192.0.2.10'
    ProxyActive     = '192.0.2.10'

    # Modulos comuns que podem ser ativados pela funcao de identidade.
    DefaultModules  = @('CORE')

    # Campos livres para a logica especifica do cliente.
    Settings = @{
        HostnamePattern = 'SRV-CLIENTE-{COMPUTER}'
        MetadataPrefix  = 'CLIENTE'
    }
}
