# Lab 3 · tempdb: configuración y contención

**Sesión 2 · Duración: 45 minutos · Base de datos: tempdb y LegacyShop**

tempdb es el recurso compartido por excelencia de una instancia: todas las bases de datos, todas las sesiones y buena parte de los operadores internos del motor la usan a la vez. En este laboratorio vais a auditar cómo está configurada en vuestra instancia, a provocar contención creando tablas temporales desde muchas sesiones concurrentes, a identificar qué páginas están en disputa y a medir el efecto de las dos medidas clásicas: más ficheros de datos y metadatos de tempdb en memoria.

## Paso 1 · Auditar la configuración (10 minutos)

```sql
SELECT name, physical_name, type_desc, size * 8 / 1024 AS size_mb,
       CASE is_percent_growth WHEN 1 THEN CONCAT(growth, ' %') ELSE CONCAT(growth * 8 / 1024, ' MB') END AS crecimiento
FROM tempdb.sys.database_files;

SELECT cpu_count, scheduler_count, softnuma_configuration_desc FROM sys.dm_os_sys_info;

SELECT SERVERPROPERTY('IsTempdbMetadataMemoryOptimized') AS metadatos_en_memoria;
```

Responded por escrito: ¿cuántos ficheros de datos tiene tempdb y cuántos núcleos lógicos ve SQL Server? ¿Tienen todos los ficheros el mismo tamaño y el mismo crecimiento? ¿Crecen en MB fijos o en porcentaje? Recordad la recomendación: tantos ficheros como núcleos hasta ocho, del mismo tamaño y crecimiento, y a partir de ahí añadir de cuatro en cuatro solo si sigue habiendo contención.

## Paso 2 · Preparar una carga que castigue tempdb (5 minutos)

El procedimiento siguiente reproduce un patrón muy común en código heredado: crear una tabla temporal, crearle un índice después, llenarla y consultarla. Crear índices sobre una tabla temporal después de crearla impide que SQL Server la guarde en caché, así que cada ejecución genera asignaciones y metadatos nuevos.

```sql
USE LegacyShop;
GO
CREATE OR ALTER PROCEDURE dbo.usp_TempdbCarga
AS
SET NOCOUNT ON;
CREATE TABLE #t (PedidoID int, Total decimal(12,2), Relleno char(200));
CREATE CLUSTERED INDEX cx ON #t (PedidoID);              -- DDL posterior: sin caché de temporales
INSERT #t (PedidoID, Total, Relleno)
SELECT TOP (200) PedidoID, Total, 'x' FROM dbo.Pedidos WHERE PedidoID > ABS(CHECKSUM(NEWID()) % 1000000);
SELECT COUNT(*), SUM(Total) FROM #t;
DROP TABLE #t;
GO
```

## Paso 3 · Provocar la contención y medir (10 minutos)

Limpiad las estadísticas de esperas, lanzad 32 sesiones durante 90 segundos desde una ventana de PowerShell abierta en la carpeta del repositorio y, mientras tanto, observad las esperas en SSMS:

```sql
DBCC SQLPERF ('sys.dm_os_wait_stats', CLEAR);
```

```powershell
powershell -ExecutionPolicy Bypass -File .\datos\carga\concurrente.ps1 -Sesiones 32 -Segundos 90 -Sql "EXEC dbo.usp_TempdbCarga"
```

Si vuestra instancia tiene nombre (por ejemplo SQL Server Express), añadid `-Servidor ".\SQLEXPRESS"`. Si os conectáis con un login SQL en lugar de con vuestro usuario de Windows, añadid `-Usuario sa -Password "..."`.

```sql
-- Qué páginas se disputan ahora mismo (repetid varias veces durante la carga)
SELECT r.session_id, r.wait_type, r.wait_resource, pi.page_type_desc, pi.object_id,
       OBJECT_NAME(pi.object_id, pi.database_id) AS objeto
FROM sys.dm_exec_requests r
CROSS APPLY sys.fn_PageResCracker(r.page_resource) prc
CROSS APPLY sys.dm_db_page_info(prc.db_id, prc.file_id, prc.page_id, 'LIMITED') pi
WHERE r.wait_type LIKE 'PAGELATCH%';
```

Si veis `PFS_PAGE`, `GAM_PAGE` o `SGAM_PAGE`, la contención es de asignación y se reduce con más ficheros. Si veis páginas de objetos como `sysschobjs`, `sysobjvalues` o `sysseobjvalues`, la contención es de metadatos y se reduce con los metadatos en memoria. Al terminar la carga, ejecutad `scripts/delta_esperas.sql` con un intervalo corto o consultad directamente las esperas acumuladas:

```sql
SELECT wait_type, waiting_tasks_count, wait_time_ms
FROM sys.dm_os_wait_stats WHERE wait_type LIKE 'PAGELATCH%' ORDER BY wait_time_ms DESC;
```

Apuntad también cuántas ejecuciones se completaron. Añadid al procedimiento un contador (por ejemplo una tabla `dbo.ContadorTempdb` con un `INSERT` por ejecución) o usad `sys.dm_exec_procedure_stats`:

```sql
SELECT execution_count, total_elapsed_time / execution_count / 1000.0 AS ms_medio
FROM sys.dm_exec_procedure_stats WHERE object_id = OBJECT_ID('LegacyShop.dbo.usp_TempdbCarga');
```

| Configuración | Ficheros | Metadatos en memoria | Ejecuciones en 90 s | ms medio | Espera PAGELATCH dominante |
|---|---|---|---|---|---|
| Inicial | | No | | | |
| Ficheros ajustados | | No | | | |
| Ficheros + metadatos | | Sí | | | |

## Paso 4 · Ajustar ficheros y metadatos (15 minutos)

Si tempdb tiene menos ficheros que núcleos (hasta 8), añadid los que falten con el mismo tamaño que los existentes, en la misma carpeta que el fichero principal. Este bloque calcula la carpeta por vosotros; ajustad el tamaño a lo que visteis en el paso 1 y repetid la línea `EXEC` cambiando el nombre para cada fichero que falte:

```sql
DECLARE @dir nvarchar(400) = (SELECT TOP (1) LEFT(physical_name, LEN(physical_name) - CHARINDEX('\', REVERSE(physical_name)) + 1)
                              FROM tempdb.sys.database_files WHERE file_id = 1);
DECLARE @sql nvarchar(max);
SET @sql = N'ALTER DATABASE tempdb ADD FILE (NAME = tempdev_c2, FILENAME = ''' + @dir + N'tempdb_c2.ndf'', SIZE = 8MB, FILEGROWTH = 64MB);';
EXEC (@sql);
SET @sql = N'ALTER DATABASE tempdb ADD FILE (NAME = tempdev_c3, FILENAME = ''' + @dir + N'tempdb_c3.ndf'', SIZE = 8MB, FILEGROWTH = 64MB);';
EXEC (@sql);
-- ... hasta igualar núcleos (máx. 8). Igualad también el crecimiento del fichero original:
ALTER DATABASE tempdb MODIFY FILE (NAME = tempdev, FILEGROWTH = 64MB);
```

Repetid la carga del paso 3 (limpiando antes esperas y estadísticas del procedimiento con `DBCC FREEPROCCACHE` solo en este laboratorio) y rellenad la segunda fila.

Después activad los metadatos de tempdb en memoria, que requieren reiniciar el servicio:

```sql
ALTER SERVER CONFIGURATION SET MEMORY_OPTIMIZED TEMPDB_METADATA = ON;
```

Reiniciad el servicio de SQL Server desde SQL Server Configuration Manager (o, en una ventana de PowerShell como administrador, `Restart-Service MSSQLSERVER -Force`; para una instancia con nombre, `MSSQL$SQLEXPRESS`).

Comprobad `SERVERPROPERTY('IsTempdbMetadataMemoryOptimized')`, repetid la carga y rellenad la tercera fila.

## Paso 5 · La caché de tablas temporales (5 minutos)

Cambiad el procedimiento para declarar el índice dentro del `CREATE TABLE`, con lo que la tabla temporal vuelve a ser apta para la caché:

```sql
CREATE OR ALTER PROCEDURE dbo.usp_TempdbCarga
AS
SET NOCOUNT ON;
CREATE TABLE #t (PedidoID int INDEX cx CLUSTERED, Total decimal(12,2), Relleno char(200));
INSERT #t (PedidoID, Total, Relleno)
SELECT TOP (200) PedidoID, Total, 'x' FROM dbo.Pedidos WHERE PedidoID > ABS(CHECKSUM(NEWID()) % 1000000);
SELECT COUNT(*), SUM(Total) FROM #t;
GO
```

Medid la tasa de creación de tablas temporales antes y después con los contadores de rendimiento:

```sql
SELECT counter_name, cntr_value FROM sys.dm_os_performance_counters
WHERE counter_name IN ('Temp Tables Creation Rate', 'Temp Tables For Destruction');
```

`Temp Tables Creation Rate` es acumulativo: tomad el valor antes y después de una carga de 30 segundos y comparad el incremento entre la versión con índice posterior y la versión con índice en línea.

## Limpieza

Los ficheros añadidos y los metadatos en memoria pueden quedarse: son la configuración recomendada. Si queréis volver al estado inicial, `ALTER DATABASE tempdb REMOVE FILE tempdev_c2;` (requiere que el fichero esté vacío, normalmente tras un reinicio) y `ALTER SERVER CONFIGURATION SET MEMORY_OPTIMIZED TEMPDB_METADATA = OFF;` más reinicio.

## Para la puesta en común

¿Qué tipo de contención habéis visto en cada fase? ¿Por qué la mejora del paso 4 puede ser pequeña en un equipo con pocos núcleos? ¿Qué patrones de código de vuestra empresa impiden la caché de temporales?
