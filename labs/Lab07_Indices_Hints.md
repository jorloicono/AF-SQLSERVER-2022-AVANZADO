# Lab 7 · Índices y hints con criterio

**Sesión 4 · Duración: 45 minutos · Base de datos: LegacyShop**

En este laboratorio vais a diseñar índices a partir de la evidencia que habéis ido acumulando en los laboratorios anteriores y a medir, para cada uno, tanto lo que se gana en lectura como lo que se paga en escritura y espacio. Veréis además la trampa clásica de los índices filtrados con consultas parametrizadas y crearéis un índice columnar no agrupado para el informe analítico.

## Preparación

```sql
USE LegacyShop;
SET STATISTICS IO, TIME ON;
-- Tamaño de partida de cada índice
SELECT OBJECT_NAME(i.object_id) AS tabla, i.name, i.type_desc,
       SUM(ps.used_page_count) * 8 / 1024 AS mb
FROM sys.indexes i JOIN sys.dm_db_partition_stats ps ON ps.object_id = i.object_id AND ps.index_id = i.index_id
WHERE i.object_id IN (OBJECT_ID('dbo.Pedidos'), OBJECT_ID('dbo.LineasPedido'))
GROUP BY i.object_id, i.name, i.type_desc;
```

## Paso 1 · Convertir IX_Pedidos_ClienteID en cubriente (10 minutos)

Medid los dos clientes extremos con el índice actual:

```sql
ALTER DATABASE SCOPED CONFIGURATION CLEAR PROCEDURE_CACHE;
EXEC dbo.usp_PedidosPorCliente @ClienteID = 42;
EXEC dbo.usp_PedidosPorCliente @ClienteID = 1;
```

Ampliad el índice con las columnas que devuelve el procedimiento. Poned `FechaPedido` en la clave para que el índice entregue las filas ya ordenadas y el Sort desaparezca; el resto va en `INCLUDE`:

```sql
CREATE INDEX IX_Pedidos_ClienteID ON dbo.Pedidos (ClienteID, FechaPedido DESC)
INCLUDE (Estado, Canal, Total, Observaciones)
WITH (DROP_EXISTING = ON, ONLINE = ON);
```

`ONLINE = ON` está disponible en Developer y Enterprise; en Standard habría que quitarlo y hacer el cambio en una ventana de mantenimiento. Repetid las dos ejecuciones.

| Cliente | Plan antes | Lecturas antes | Plan después | Lecturas después |
|---|---|---|---|---|
| 42 | | | | |
| 1 | | | | |

Con el índice cubriente el sniffing deja de importar para este procedimiento: el mismo plan (Index Seek sin lookup y sin sort) es bueno para los dos clientes. Es la solución de fondo que mencionábamos en la sesión 1. Anotad el nuevo tamaño del índice: `Observaciones` lo engorda, y es una decisión consciente.

## Paso 2 · El índice que falta en LineasPedido (10 minutos)

Antes de crearlo, medid el coste de escritura de referencia insertando 2.000 pedidos:

```sql
DECLARE @t datetime2 = SYSDATETIME(), @i int = 0;
WHILE @i < 2000 BEGIN EXEC dbo.usp_AltaPedido @ClienteID = 42, @ComercialID = 7; SET @i += 1; END
SELECT DATEDIFF(MILLISECOND, @t, SYSDATETIME()) AS ms_2000_altas;
EXEC dbo.usp_DetallePedido @PedidoID = 600000;
```

Cread el índice y repetid ambas mediciones:

```sql
CREATE INDEX IX_LineasPedido_PedidoID ON dbo.LineasPedido (PedidoID)
INCLUDE (ProductoID, Cantidad, PrecioUnitario, Descuento)
WITH (ONLINE = ON);
```

| Medida | Sin índice | Con índice |
|---|---|---|
| Lecturas de usp_DetallePedido | | |
| ms de 2.000 altas | | |
| Tamaño del índice (MB) | — | |

Validad el efecto en todo el sistema, no solo en la consulta: volved a ejecutar `usp_UltimosPedidosLineaPrincipal` (el Index Spool del Lab 5B debería haber desaparecido) y `usp_RecalcularTotales` (cada iteración del cursor ya no recorre la tabla entera). Un buen índice suele arreglar varias cosas a la vez.

## Paso 3 · Índice filtrado: literal, parámetro y RECOMPILE (10 minutos)

Los pedidos pendientes son una fracción mínima de la tabla y se consultan constantemente. Es el caso de libro para un índice filtrado:

```sql
CREATE INDEX IX_Pedidos_Pendientes ON dbo.Pedidos (FechaPedido)
INCLUDE (ClienteID, Total)
WHERE Estado IN (1, 2);
```

Probad las tres formas de consultar:

```sql
-- A · literal: usa el índice filtrado
SELECT PedidoID, FechaPedido, ClienteID, Total FROM dbo.Pedidos WHERE Estado = 1;

-- B · parámetro: NO puede usarlo (el plan debe valer para cualquier valor de @e)
DECLARE @e tinyint = 1;
SELECT PedidoID, FechaPedido, ClienteID, Total FROM dbo.Pedidos WHERE Estado = @e;

-- C · parámetro con RECOMPILE: el optimizador ve el valor y puede usarlo
SELECT PedidoID, FechaPedido, ClienteID, Total FROM dbo.Pedidos WHERE Estado = @e OPTION (RECOMPILE);
```

En la variante B buscad el aviso `UnmatchedIndexes` en las propiedades del SELECT. Pensad en qué solución es mejor para la aplicación: ¿un procedimiento específico para pendientes con el literal, o `RECOMPILE`?

## Paso 4 · Columnstore no agrupado para el informe por categoría (10 minutos)

```sql
EXEC dbo.usp_InformeVentasCategoria @Anio = 2024;   -- referencia

CREATE NONCLUSTERED COLUMNSTORE INDEX NCCI_LineasPedido
ON dbo.LineasPedido (PedidoID, ProductoID, Cantidad, PrecioUnitario, Descuento);

EXEC dbo.usp_InformeVentasCategoria @Anio = 2024;
```

Mirad en el plan si el acceso a `LineasPedido` usa el columnstore y en modo batch (propiedad `Actual Execution Mode = Batch`). Probad también una agregación pura, que es donde el columnstore brilla:

```sql
SELECT ProductoID, SUM(Cantidad * PrecioUnitario) FROM dbo.LineasPedido GROUP BY ProductoID;
```

Revisad los grupos de filas y su compresión:

```sql
SELECT state_desc, COUNT(*) AS grupos, SUM(total_rows) AS filas, SUM(size_in_bytes) / 1048576 AS mb
FROM sys.dm_db_column_store_row_group_physical_stats
WHERE object_id = OBJECT_ID('dbo.LineasPedido') GROUP BY state_desc;
```

| Consulta | Sin columnstore (ms) | Con columnstore (ms) | Modo de ejecución |
|---|---|---|---|
| Informe por categoría 2024 | | | |
| Agregación por producto | | | |

Anotad el tamaño del columnstore comparado con el índice agrupado: la compresión suele ser espectacular.

## Paso 5 · Consolidar sugerencias y detectar índices sin uso (5 minutos)

```sql
-- Sugerencias del optimizador
SELECT mid.statement, mid.equality_columns, mid.inequality_columns, mid.included_columns,
       migs.user_seeks, migs.avg_user_impact
FROM sys.dm_db_missing_index_details mid
JOIN sys.dm_db_missing_index_groups mig ON mig.index_handle = mid.index_handle
JOIN sys.dm_db_missing_index_group_stats migs ON migs.group_handle = mig.index_group_handle
WHERE mid.database_id = DB_ID()
ORDER BY migs.user_seeks * migs.avg_user_impact DESC;

-- Índices que se escriben pero no se leen
SELECT OBJECT_NAME(i.object_id) AS tabla, i.name, us.user_seeks, us.user_scans, us.user_lookups, us.user_updates
FROM sys.indexes i
LEFT JOIN sys.dm_db_index_usage_stats us ON us.object_id = i.object_id AND us.index_id = i.index_id AND us.database_id = DB_ID()
WHERE OBJECTPROPERTY(i.object_id, 'IsUserTable') = 1 AND i.index_id > 1
ORDER BY ISNULL(us.user_seeks + us.user_scans + us.user_lookups, 0), us.user_updates DESC;
```

Agrupad las sugerencias que comparten columnas de igualdad y escribid, como máximo, dos índices que las cubran. Recordad que estas vistas se reinician con el servicio: en un sistema real no se elimina un índice sin haber observado un ciclo de negocio completo (fin de mes, cierre trimestral).

## Limpieza

Dejad los índices creados: forman parte de la solución y el script del taller los elimina.

```sql
SET STATISTICS IO, TIME OFF;
```

## Para la puesta en común

¿Qué coste de escritura habéis medido para el índice de LineasPedido y lo aceptaríais? ¿Por qué el índice cubriente resuelve el sniffing de `usp_PedidosPorCliente`? ¿Cuándo no crearíais un columnstore en una tabla transaccional?
