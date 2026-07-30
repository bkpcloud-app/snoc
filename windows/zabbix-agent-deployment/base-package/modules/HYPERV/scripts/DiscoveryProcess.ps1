# NOTA
# Formas de execução do script 
#
# DiscoveryProcess.ps1
#
#
# 1 - Abra o Powershell como Administrador e execute o comando Set-ExecutionPolicy Unrestricted e confirme;
# 2 - Caso já tenha feito o procedimento acima no Host, desconsidere e pule para o próximo requerimento; 
# 3 - Inserir o arquivo DiscoveryProcess.ps1 no diretorio de sua escolha;
# 4 - Abra o powershell e navegue até o diretorio do script; 
#
# TESTES
#
# Parâmetro DISCOVERY - Realiza o discovery dos processos e monta o JSON.
#
# EX:    .\DiscoveryProcess.ps1 DISCOVERY
#
#
# Parâmetro PROCESSCPU + ID - coleta os 20 processos Top/Down com alto tempo de CPU.
#
#
# EX:    .\DiscoveryProcess.ps1 PROCESSCPU 1112
#
#
# Parâmetro PROCESSMEMORY + ID - coleta os 20 processos Top/Down com alto consumo de Memória.
#
#
# BACKLOG
#
# 
# 2 - Coletar Total de Memória  e CPU por Usuário conectado via TS
#  
#
###############################################################################################

# Inicio do Script DiscoveryProvess.ps1;

# Para entrar na condição de Discovery o script aguarda uma passagem de parâmetros;

Param(
  [string]$processo,
  [string]$2
)

# (Se Parâmetro igual DISCOVERY - Execute);

if ( $processo -eq 'DISCOVERY' ) 
{

$line = Get-Process |Sort-Object -Property CPU | Select-Object -Last 150
$compara = 1
write-host "{"
write-host " `"data`":[`n"

# Montagem do JSON com dois itens.

foreach ($cpu in Get-Process -Id $line.Id) {
    
     if ($compara -ge $cpu.length) {
     
 $JSON = "{ `"{#NAME}`":`"" + $cpu.Name + "`",`"{#PID}`":`"" + $cpu.Id + "`"},"
           
           write-host $JSON
}
}

# Necessario a inserção de uma linha ao final para fechar o JSON.

Write-Host '{ "{#NAME}":"filtro","{#PID}":"00000"}'
write-host
write-host " ]"
write-host "}"
}


#FUNÇÃO PARA COLETAR TEMPO DE CPU DO PROCESSO

if ( $processo -eq 'PROCESSCPU' )
{
$execute = Get-Process | Where-Object { $_.Id -eq $2 } | Select-Object CPU |select-object -ExpandProperty CPU

foreach ($cpuprocess in $execute)
{
 
# Estrutura de validação caso coleta vazia
 
 if ($cpuprocess -ne $null)
 {
 $multi = $cpuprocess -replace ",[0-9]+",''
  Write-Host $multi
 } 
 else
 {
 $out = $cpuprocess.length
 }

}
}

#FUNÇÃO PARA COLETAR UTILIZACAO DE MEMÓRIA DO PROCESSO

if ( $processo -eq 'PROCESSMEMORY' )
{
Get-Process | Where-Object { $_.Id -eq $2 } | Select-Object WS |select-object -ExpandProperty WS
}


#FUNÇÃO PARA COLETAR PORCENTAGEM CPU UTILIZADA

if ( $processo -eq 'CPUPERCENT' )
{

(get-wmiobject Win32_PerfFormattedData_PerfProc_Process | ? { $_.IDProcess -eq $2 } | Select).PercentProcessorTime

}