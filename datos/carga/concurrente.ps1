<#
.SYNOPSIS
  Lanzador de carga concurrente para Windows (sustituto de ostress).
  Abre N sesiones en paralelo que ejecutan en bucle la misma sentencia T-SQL.

.EJEMPLO
  powershell -ExecutionPolicy Bypass -File .\datos\carga\concurrente.ps1 -Sesiones 32 -Segundos 90 -Sql "EXEC dbo.usp_TempdbCarga"
  (Para una instancia con nombre: -Servidor ".\SQLEXPRESS". Con login SQL: -Usuario sa -Password "...")

  Las sesiones aparecen en sys.dm_exec_sessions con host_name = LegacyShop-C1, LegacyShop-C2...
  Para detenerla antes de tiempo, desde otra ventana: .\datos\carga\parar.ps1
#>
param(
    [int]$Sesiones = 8,
    [int]$Segundos = 60,
    [Parameter(Mandatory = $true)][string]$Sql,
    [string]$Servidor = "localhost",
    [string]$BaseDatos = "LegacyShop",
    [string]$Usuario,
    [string]$Password
)

function New-CadenaConexion {
    param([string]$Servidor, [string]$BaseDatos, [string]$Usuario, [string]$Password, [string]$Equipo)
    $auth = if ($Usuario) { "User ID=$Usuario;Password=$Password" } else { "Integrated Security=SSPI" }
    return "Server=$Servidor;Database=$BaseDatos;$auth;Workstation ID=$Equipo;Application Name=LegacyShop-Carga;TrustServerCertificate=True;Connect Timeout=30"
}

$trabajo = {
    param($Cadena, $Sql, $Fin, $Marca, $Pausa)
    $ejecuciones = 0; $errores = 0
    while ((Get-Date) -lt $Fin -and -not (Test-Path $Marca)) {
        if ($Pausa -gt 0) { Start-Sleep -Seconds $Pausa; if ((Get-Date) -ge $Fin -or (Test-Path $Marca)) { break } }
        $cn = New-Object System.Data.SqlClient.SqlConnection $Cadena
        try {
            $cn.Open()
            $cmd = $cn.CreateCommand(); $cmd.CommandText = $Sql; $cmd.CommandTimeout = 300
            [void]$cmd.ExecuteNonQuery(); $ejecuciones++
        } catch { $errores++ } finally { $cn.Dispose() }
    }
    [pscustomobject]@{ Ejecuciones = $ejecuciones; Errores = $errores }
}

$marca = Join-Path $env:TEMP "legacyshop_parar.flag"
Remove-Item $marca -ErrorAction SilentlyContinue
$fin = (Get-Date).AddSeconds($Segundos)
$sentencia = "SET NOCOUNT ON; " + $Sql

Write-Host "Lanzando $Sesiones sesiones durante $Segundos s contra $Servidor/$BaseDatos" -ForegroundColor Cyan
Write-Host "  $Sql"
$jobs = for ($i = 1; $i -le $Sesiones; $i++) {
    $cadena = New-CadenaConexion $Servidor $BaseDatos $Usuario $Password "LegacyShop-C$i"
    Start-Job -ScriptBlock $trabajo -ArgumentList $cadena, $sentencia, $fin, $marca, 0
}
$jobs | Wait-Job | Out-Null
$r = $jobs | Receive-Job
$jobs | Remove-Job
$total = ($r | Measure-Object Ejecuciones -Sum).Sum
$err   = ($r | Measure-Object Errores -Sum).Sum
Write-Host ("Carga terminada: {0} ejecuciones completadas, {1} errores de conexion/ejecucion." -f $total, $err) -ForegroundColor Green
