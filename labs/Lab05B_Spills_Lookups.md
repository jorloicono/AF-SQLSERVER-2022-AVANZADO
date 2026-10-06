# Lab 5B · Spills, lookups y funciones escalares

**Sesión 3 · Duración: 55 minutos · Base de datos: LegacyShop**

En este laboratorio vais a medir el coste real de tres patrones que casi siempre se malinterpretan como "falta de hardware": los spills a tempdb, los Key Lookups masivos y las funciones escalares que se ejecutan fila a fila. En los tres casos veréis que la raíz está en la estimación o en el diseño de índices y del código, no en la cantidad de memoria o de CPU.

## Preparación

```sql
USE LegacyShop;
ALTER DATABASE SCOPED CONFIGURATION SET MEMORY_GRANT_FEEDBACK_PERCENTILE_GRANT = OFF;  -- para ver el spill siempre
ALTER DATABASE SCOPED CONFIGURATION SET MEMORY_GRANT_FEEDBACK_PERSISTENCE = OFF;
ALTER DATABASE SCOPED CONFIGURATION CLEAR PROCEDURE_CACHE;
SET STATISTICS IO, TIME ON;
```

Desactivamos temporalmente el feedback de memoria para que el spill se repita en cada ejecución; al final lo volveremos a activar. Crearemos también una sesión de Extended Events para capturar los avisos:

```sql
CREATE EVENT SESSION Lab5B_Spills ON SERVER
ADD EVENT sqlserver.sort_warning (ACTION (sqlserver.sql_text) WHERE sqlserver.database_name = N'LegacyShop'),
ADD EVENT sqlserver.hash_spill_details (ACTION (sqlserver.sql_text) WHERE sqlserver.database_name = N'LegacyShop')
ADD TARGET package0.ring_buffer;
ALTER EVENT SESSION Lab5B_Spills ON SERVER STATE = START;
```

## Paso 1 · Provocar y leer el spill (10 minutos)

```sql
EXEC dbo.usp_InformeVentasCategoria @Anio = 2024;
```

En el plan real localizad el operador con el triángulo amarillo. Pasad el ratón por encima: el aviso indica que el operador usó tempdb para volcar datos, con su nivel de spill y el número de páginas escritas y leídas. Apuntad el operador, el nivel y las páginas. En las propiedades del SELECT apuntad `GrantedMemory` y `MaxUsedMemory`: si la memoria usada es igual o muy cercana a la concedida, el operador se quedó sin sitio.

```sql
SELECT x.value('@name', 'varchar(50)') AS evento, x.value('@timestamp', 'datetime2') AS fecha, x.query('.') AS detalle
FROM (SELECT CAST(t.target_data AS xml) AS td FROM sys.dm_xe_session_targets t
      JOIN sys.dm_xe_sessions s ON s.address = t.event_session_address WHERE s.name = N'Lab5B_Spills') d
CROSS APPLY d.td.nodes('//event') AS e(x);
```

## Paso 2 · Relacionar el spill con la estimación (10 minutos)

La concesión de memoria se calcula aproximadamente como filas estimadas por tamaño estimado de fila en cada operador que necesita memoria. Rellenad la tabla leyendo el plan real en el operador Hash Match (o Sort) con el aviso:

| Dato | Valor |
|---|---|
| Filas estimadas en la entrada del operador | |
| Filas reales | |
| Factor de error | |
| Tamaño estimado de fila (`EstimatedRowSize`, bytes) | |
| Memoria concedida (KB) | |

Ahora comprobad los dos factores. Primero la estimación de filas: reescribid el filtro de forma SARGable en una consulta equivalente y comparad.

```sql
DECLARE @Anio int = 2024;
DECLARE @d datetime2(0) = DATEFROMPARTS(@Anio, 1, 1), @h datetime2(0) = DATEFROMPARTS(@Anio + 1, 1, 1);
SELECT pr.Categoria, p.PedidoID, p.FechaPedido, p.Canal, p.Observaciones,
       SUM(l.Cantidad * l.PrecioUnitario * (1 - l.Descuento / 100)) AS Importe
FROM dbo.Pedidos p
JOIN dbo.LineasPedido l ON l.PedidoID = p.PedidoID
JOIN dbo.Productos pr   ON pr.ProductoID = l.ProductoID
WHERE p.FechaPedido >= @d AND p.FechaPedido < @h
GROUP BY pr.Categoria, p.PedidoID, p.FechaPedido, p.Canal, p.Observaciones
ORDER BY pr.Categoria, Importe DESC
OPTION (RECOMPILE);
```

Después el tamaño de fila: repetid la consulta anterior quitando `p.Observaciones` del `SELECT` y del `GROUP BY`. `Observaciones` es `varchar(500)` y el optimizador supone que una columna de longitud variable ocupa, de media, la mitad de su tamaño declarado, lo que infla el tamaño de fila aunque la mayoría de valores sean nulos. Comparad `EstimatedRowSize` y `GrantedMemory`.

| Variante | Filas estimadas | Tamaño fila (B) | Concedida (KB) | Spill |
|---|---|---|---|---|
| Original (YEAR) | | | | |
| Rango SARGable | | | | |
| Rango SARGable sin Observaciones | | | | |

## Paso 3 · El coste real de los Key Lookups (15 minutos)

```sql
ALTER DATABASE SCOPED CONFIGURATION CLEAR PROCEDURE_CACHE;
SELECT PedidoID, FechaPedido, Estado, Canal, Total, Observaciones
FROM dbo.Pedidos WITH (INDEX (IX_Pedidos_ClienteID))
WHERE ClienteID = 1;
```

Forzamos el índice para medir lo que ocurre cuando el plan de seek + lookup se usa con el cliente grande. Apuntad lecturas lógicas y tiempo, y en el plan real el número de ejecuciones del Key Lookup. Después ejecutad sin la sugerencia y comparad con el Clustered Index Scan:

```sql
SELECT PedidoID, FechaPedido, Estado, Canal, Total, Observaciones
FROM dbo.Pedidos
WHERE ClienteID = 1;
```

| Plan | Lecturas lógicas | CPU (ms) | Transcurrido (ms) |
|---|---|---|---|
| Seek + 250.000 lookups | | | |
| Clustered Index Scan | | | |

Calculad las lecturas por lookup (lecturas totales entre 250.000) y relacionadlo con la profundidad del índice agrupado:

```sql
SELECT index_id, index_depth, page_count
FROM sys.dm_db_index_physical_stats(DB_ID(), OBJECT_ID('dbo.Pedidos'), NULL, NULL, 'DETAILED')
WHERE index_level = 0;
```

La solución de fondo, un índice cubriente, la construiréis en el Lab 7.

## Paso 4 · ¿Qué funciones admiten inlining? (10 minutos)

```sql
SELECT OBJECT_NAME(object_id) AS funcion, is_inlineable, inline_type
FROM sys.sql_modules
WHERE object_id IN (OBJECT_ID('dbo.fn_ImporteConIVA'), OBJECT_ID('dbo.fn_EdadCliente'), OBJECT_ID('dbo.fn_TramoEdad'));
```

`fn_EdadCliente` no es inlineable porque llama a `GETDATE()`. Medid su coste:

```sql
-- Con la UDF no inlineable
SELECT COUNT(*) FROM dbo.Clientes WHERE dbo.fn_EdadCliente(FechaNacimiento) >= 65;

-- Con una versión inlineable que recibe la fecha de referencia
CREATE OR ALTER FUNCTION dbo.fn_EdadClienteRef (@FechaNacimiento date, @Hoy date)
RETURNS int AS
BEGIN
    RETURN DATEDIFF(YEAR, @FechaNacimiento, @Hoy)
         - CASE WHEN DATEADD(YEAR, DATEDIFF(YEAR, @FechaNacimiento, @Hoy), @FechaNacimiento) > @Hoy THEN 1 ELSE 0 END;
END;
GO
DECLARE @hoy date = GETDATE();
SELECT COUNT(*) FROM dbo.Clientes WHERE dbo.fn_EdadClienteRef(FechaNacimiento, @hoy) >= 65;

-- Y la misma consulta con inlining desactivado, para aislar el efecto
DECLARE @hoy2 date = GETDATE();
SELECT COUNT(*) FROM dbo.Clientes WHERE dbo.fn_EdadClienteRef(FechaNacimiento, @hoy2) >= 65
OPTION (USE HINT ('DISABLE_TSQL_SCALAR_UDF_INLINING'));
```

| Variante | CPU (ms) | Transcurrido (ms) | ¿Paralelo? |
|---|---|---|---|
| fn_EdadCliente (no inlineable) | | | |
| fn_EdadClienteRef (inlineada) | | | |
| fn_EdadClienteRef sin inlining | | | |

Mirad también `sys.dm_exec_function_stats` para ver cuántas veces se ha ejecutado cada función: la inlineada no aparece, porque ya no se ejecuta como función.

## Paso 5 · Detectar un Index Spool (5 minutos)

```sql
EXEC dbo.usp_UltimosPedidosLineaPrincipal @ClienteID = 1;
```

Buscad un operador **Index Spool (Eager Spool)** sobre `LineasPedido`. Significa que el optimizador ha decidido construir un índice temporal en tempdb en cada ejecución porque le falta uno permanente. Las columnas de la clave del spool (`Seek Predicate`) y las columnas que devuelve os dicen exactamente qué índice proponer. Escribid la sentencia `CREATE INDEX` que lo eliminaría, pero no la ejecutéis: la aplicaréis en el Lab 7.

## Limpieza

```sql
ALTER EVENT SESSION Lab5B_Spills ON SERVER STATE = STOP;
DROP EVENT SESSION Lab5B_Spills ON SERVER;
ALTER DATABASE SCOPED CONFIGURATION SET MEMORY_GRANT_FEEDBACK_PERCENTILE_GRANT = ON;
ALTER DATABASE SCOPED CONFIGURATION SET MEMORY_GRANT_FEEDBACK_PERSISTENCE = ON;
SET STATISTICS IO, TIME OFF;
```

## Para la puesta en común

¿Por qué un spill no se arregla aumentando la memoria del servidor? ¿A partir de cuántas filas deja de compensar el lookup frente al scan en esta tabla? ¿Qué otros elementos, además de `GETDATE()`, impiden el inlining de una función escalar?
