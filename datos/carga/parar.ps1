<#
.SYNOPSIS
  Detiene la carga (concurrente.ps1 o carga.ps1). Las sesiones terminan al completar su lote actual.
.EJEMPLO
  powershell -ExecutionPolicy Bypass -File .\datos\carga\parar.ps1
#>
$marca = Join-Path $env:TEMP "legacyshop_parar.flag"
New-Item -ItemType File -Path $marca -Force | Out-Null
Write-Host "Senal de parada enviada. Las sesiones terminaran al completar su lote actual." -ForegroundColor Yellow
Write-Host "Para cortar en seco desde SSMS: KILL a las sesiones con host_name LIKE 'LegacyShop%'."
