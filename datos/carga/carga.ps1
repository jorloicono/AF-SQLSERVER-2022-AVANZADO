<#
.SYNOPSIS
  Carga simulada del TALLER INTEGRADOR (Sesion 6) para Windows.
  Cada trabajador ejecuta dbo.usp_Carga_Mezcla en bucle (host_name = LegacyShop-W1, W2...).
  Un trabajador adicional (LegacyShop-R) lanza el recalculo de totales cada 120 s.
  Los errores de la aplicacion (deadlocks 1205, timeouts...) quedan en dbo.CargaErrores.

.EJEMPLO
  powershell -ExecutionPolicy Bypass -File .\datos\carga\carga.ps1 -Sesiones 8 -Segundos 1800
  Dejad esta ventana abierta mientras dura la carga. Para pararla, desde otra ventana:
  powershell -ExecutionPolicy Bypass -File .\datos\carga\parar.ps1
#>
param(
    [int]$Sesiones = 8,
    [int]$Segundos = 1800,
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

Write-Host "Carga del taller: $Sesiones trabajadores + recalculo cada 120 s, durante $Segundos s" -ForegroundColor Cyan
$jobs = @()
for ($i = 1; $i -le $Sesiones; $i++) {
    $cadena = New-CadenaConexion $Servidor $BaseDatos $Usuario $Password "LegacyShop-W$i"
    $sql = "SET NOCOUNT ON; EXEC dbo.usp_Carga_Mezcla @Trabajador = $i, @Iteraciones = 25;"
    $jobs += Start-Job -ScriptBlock $trabajo -ArgumentList $cadena, $sql, $fin, $marca, 0
}
$cadenaR = New-CadenaConexion $Servidor $BaseDatos $Usuario $Password "LegacyShop-R"
$jobs += Start-Job -ScriptBlock $trabajo -ArgumentList $cadenaR, "SET NOCOUNT ON; EXEC dbo.usp_Carga_Recalculo;", $fin, $marca, 120

Write-Host ("Carga en marcha hasta las {0:HH:mm:ss}. Esta ventana queda ocupada." -f $fin)
$jobs | Wait-Job | Out-Null
$r = $jobs | Receive-Job
$jobs | Remove-Job
Write-Host ("Carga terminada: {0} lotes completados." -f ($r | Measure-Object Ejecuciones -Sum).Sum) -ForegroundColor Green
Write-Host "Errores de la aplicacion: SELECT Operacion, Numero, COUNT(*) FROM dbo.CargaErrores GROUP BY Operacion, Numero;"
