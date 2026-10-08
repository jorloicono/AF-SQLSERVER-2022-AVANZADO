# Lab 4 · Cuellos de botella de I/O con wait stats

**Sesión 2 · Duración: 50 minutos · Base de datos: LegacyShop**

En este laboratorio vais a provocar deliberadamente las tres familias de esperas de I/O que más aparecen en sistemas reales y a aprender a distinguirlas: `PAGEIOLATCH_*`, cuando el motor espera a leer páginas de datos del disco; `WRITELOG`, cuando espera a que el log se escriba para confirmar una transacción; y `ASYNC_IO_COMPLETION` / `IO_COMPLETION`, típicas de backups, crecimientos de ficheros y spills. Para cada escenario mediréis con un delta, no con los contadores acumulados desde el arranque, y redactaréis el diagnóstico en tres líneas, como lo haríais en un informe.

Tened a mano dos scripts del repositorio: `scripts/delta_esperas.sql` e `scripts/io_delta.sql`. En los pasos siguientes usamos una versión corta del delta de esperas para no alargar los tiempos.

## Preparación

```sql
USE LegacyShop;
DROP TABLE IF EXISTS #w;
-- Foto inicial reutilizable: ejecutad este bloque antes de cada escenario
SELECT wait_type, waiting_tasks_count, wait_time_ms INTO #w FROM sys.dm_os_wait_stats;
```

Y este bloque, al terminar cada escenario, os da el delta de las esperas que nos interesan:

```sql
SELECT s.wait_type, s.waiting_tasks_count - w.waiting_tasks_count AS esperas,
       s.wait_time_ms - w.wait_time_ms AS espera_ms,
       CAST((s.wait_time_ms - w.wait_time_ms) * 1.0 / NULLIF(s.waiting_tasks_count - w.waiting_tasks_count, 0) AS decimal(10,2)) AS ms_por_espera
FROM sys.dm_os_wait_stats s JOIN #w w ON w.wait_type = s.wait_type
WHERE s.wait_type IN ('PAGEIOLATCH_SH','PAGEIOLATCH_EX','WRITELOG','ASYNC_IO_COMPLETION','IO_COMPLETION','PREEMPTIVE_OS_WRITEFILEGATHER','BACKUPIO')
  AND s.wait_time_ms > w.wait_time_ms
ORDER BY espera_ms DESC;
```

## Paso 1 · Latencia por fichero (5 minutos)

Lanzad `scripts/io_delta.sql` con `@espera = '00:00:30'` mientras en otra ventana ejecutáis `EXEC dbo.usp_InformeVentasCategoria @Anio = 2024;` dos veces. Apuntad la latencia media de lectura del fichero de datos de LegacyShop y la de escritura del log. En un portátil con SSD veréis valores bajos; lo importante es aprender a leerlos y a compararlos con las referencias orientativas: por debajo de 10-20 ms por lectura en datos y de 1-5 ms por escritura en log.

## Paso 2 · PAGEIOLATCH: leer lo que no hace falta (15 minutos)

Vaciar la caché de datos obliga a leer de disco. Es algo que **nunca** se hace en producción, pero en el laboratorio nos permite simular un servidor con poca memoria.

```sql
-- Foto inicial (bloque de preparación) y después:
CHECKPOINT;
DBCC DROPCLEANBUFFERS;
SET STATISTICS IO ON;
DECLARE @i int = 0;
WHILE @i < 5
BEGIN
    DECLARE @p int = 1 + ABS(CHECKSUM(NEWID()) % 1200000);
    EXEC dbo.usp_DetallePedido @PedidoID = @p;
    SET @i += 1;
END
```

Apuntad las lecturas lógicas y físicas (y las de read-ahead) de `LineasPedido` y el delta de `PAGEIOLATCH_SH`. Cada consulta de detalle recorre las 3,6 millones de líneas porque no hay índice por `PedidoID`.

Cread ahora el índice que falta, repetid exactamente la misma prueba (con `DROPCLEANBUFFERS` incluido) y comparad:

```sql
CREATE INDEX IX_LineasPedido_PedidoID ON dbo.LineasPedido (PedidoID)
    INCLUDE (ProductoID, Cantidad, PrecioUnitario, Descuento);
```

| Escenario | Lecturas lógicas por detalle | Lecturas físicas + read-ahead | Espera PAGEIOLATCH_SH (ms) |
|---|---|---|---|
| Sin índice | | | |
| Con índice | | | |

Al terminar, **eliminad el índice**, porque lo crearéis de nuevo con más criterio en el Lab 7:

```sql
DROP INDEX IX_LineasPedido_PedidoID ON dbo.LineasPedido;
SET STATISTICS IO OFF;
```

## Paso 3 · WRITELOG: el coste de cada commit (15 minutos)

Cread una tabla de trabajo y comparad tres formas de insertar 20.000 filas:

```sql
DROP TABLE IF EXISTS dbo.LabLog;
CREATE TABLE dbo.LabLog (ID int IDENTITY PRIMARY KEY, Dato char(100));
```

Escenario A, un commit por fila (el patrón de muchas aplicaciones heredadas):

```sql
-- Foto inicial y después:
DECLARE @i int = 0, @t datetime2 = SYSDATETIME();
WHILE @i < 20000 BEGIN INSERT dbo.LabLog (Dato) VALUES ('fila'); SET @i += 1; END
SELECT DATEDIFF(MILLISECOND, @t, SYSDATETIME()) AS ms;
```

Escenario B, commits por lotes de 1.000 filas:

```sql
DECLARE @i int = 0, @t datetime2 = SYSDATETIME();
BEGIN TRAN;
WHILE @i < 20000
BEGIN
    INSERT dbo.LabLog (Dato) VALUES ('fila'); SET @i += 1;
    IF @i % 1000 = 0 BEGIN COMMIT; BEGIN TRAN; END
END
COMMIT;
SELECT DATEDIFF(MILLISECOND, @t, SYSDATETIME()) AS ms;
```

Escenario C, commit por fila pero con durabilidad diferida:

```sql
ALTER DATABASE LegacyShop SET DELAYED_DURABILITY = FORCED;
-- repetid el escenario A
ALTER DATABASE LegacyShop SET DELAYED_DURABILITY = DISABLED;
```

| Escenario | Tiempo (ms) | Esperas WRITELOG | ms por espera |
|---|---|---|---|
| A · commit por fila | | | |
| B · lotes de 1.000 | | | |
| C · delayed durability | | | |

La durabilidad diferida elimina casi toda la espera, pero a cambio una caída del servidor puede perder las últimas transacciones confirmadas que aún estaban en el búfer del log. Es una decisión de negocio, no de rendimiento.

## Paso 4 · ASYNC_IO_COMPLETION: backups y crecimientos (10 minutos)

Un backup completo genera esperas `ASYNC_IO_COMPLETION` en la sesión que lo lanza y `BACKUPIO` en los hilos de lectura y escritura:

```sql
-- Foto inicial y después:
BACKUP DATABASE LegacyShop TO DISK = 'LegacyShop_lab4.bak'   -- sin ruta: va a la carpeta de backups por defecto
WITH INIT, COMPRESSION, STATS = 20;
```

Después provocad crecimientos pequeños y repetidos del log. Tradicionalmente el log se inicializaba siempre con ceros; SQL Server 2022 permite inicialización instantánea en crecimientos del log de hasta 64 MB, así que con incrementos de 1 MB la espera de cada crecimiento será pequeña, y lo que vais a observar sobre todo es la cantidad de crecimientos y de VLF que genera una mala configuración:

```sql
ALTER DATABASE LegacyShop MODIFY FILE (NAME = LegacyShop_log, FILEGROWTH = 1MB);
-- Foto inicial y después: una transacción grande que obligue a crecer
BEGIN TRAN;
UPDATE dbo.LineasPedido SET Descuento = Descuento WHERE LineaID <= 1500000;
ROLLBACK;
SELECT name, size * 8 / 1024 AS size_mb FROM sys.database_files;
ALTER DATABASE LegacyShop MODIFY FILE (NAME = LegacyShop_log, FILEGROWTH = 256MB);
```

Si el log ya era suficientemente grande y no ha crecido, reducidlo antes con `DBCC SHRINKFILE (LegacyShop_log, 64);` (solo en el laboratorio) y repetid. Consultad los crecimientos registrados en la traza por defecto o en `sys.dm_db_log_info` (número de VLF).

## Paso 5 · Redactar el diagnóstico (5 minutos)

Para cada uno de los tres escenarios escribid tres líneas: qué espera domina y con qué valores, cuál es la causa y cuál es la corrección (con su coste). Por ejemplo: "PAGEIOLATCH_SH domina con X ms por espera; la consulta de detalle de pedido recorre 3,6 M de líneas por falta de índice por PedidoID; un índice no agrupado cubriente reduce las lecturas de X a Y a cambio de un coste de mantenimiento en las inserciones".

## Limpieza

```sql
DROP TABLE IF EXISTS dbo.LabLog;
```

## Para la puesta en común

¿Por qué no se debe diagnosticar con `sys.dm_os_wait_stats` sin calcular un delta? ¿Qué relación hay entre PAGEIOLATCH y la memoria del servidor? ¿En qué casos aceptaríais delayed durability?
