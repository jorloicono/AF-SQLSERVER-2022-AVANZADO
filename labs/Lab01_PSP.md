# Lab 1 · Parameter sniffing y Parameter Sensitive Plan Optimization

**Sesión 1 · Duración: 40 minutos · Base de datos: LegacyShop**

En este laboratorio vais a reproducir el problema clásico del parameter sniffing sobre una distribución de datos muy sesgada y a comprobar cómo SQL Server 2022 lo mitiga con Parameter Sensitive Plan Optimization (PSP). En LegacyShop el cliente 1 es un marketplace con 250.000 pedidos, mientras que un cliente normal tiene alrededor de diez. El procedimiento `dbo.usp_PedidosPorCliente` sirve a ambos con un único plan en caché, y eso es precisamente lo que vamos a romper y a arreglar.

Al terminar deberíais saber reconocer el sniffing en un plan real, localizar el dispatcher de PSP y sus variantes en Query Store, y explicar por qué PSP no actúa cuando el parámetro se copia en una variable local.

## Preparación

Abrid una ventana nueva en SSMS conectada a LegacyShop y activad el plan real (Ctrl+M). Dejad también activada la salida de estadísticas:

```sql
USE LegacyShop;
SET STATISTICS IO, TIME ON;
```

Mirad primero la distribución, para tener claro de qué estamos hablando:

```sql
SELECT TOP (5) ClienteID, COUNT(*) AS pedidos
FROM dbo.Pedidos GROUP BY ClienteID ORDER BY pedidos DESC;

SELECT AVG(n * 1.0) AS media_pedidos_por_cliente, MIN(n) AS minimo
FROM (SELECT COUNT(*) AS n FROM dbo.Pedidos GROUP BY ClienteID) x;
```

## Paso 1 · Reproducir el sniffing en compatibilidad 150 (10 minutos)

PSP solo existe a partir del nivel de compatibilidad 160, así que empezamos simulando un servidor de 2019.

```sql
ALTER DATABASE LegacyShop SET COMPATIBILITY_LEVEL = 150;
ALTER DATABASE SCOPED CONFIGURATION CLEAR PROCEDURE_CACHE;

EXEC dbo.usp_PedidosPorCliente @ClienteID = 42;   -- compila con un cliente pequeño
EXEC dbo.usp_PedidosPorCliente @ClienteID = 1;    -- reutiliza el plan
```

Apuntad en la tabla las lecturas lógicas de Pedidos y el tiempo transcurrido de la segunda ejecución. En el plan real del cliente 1 fijaos en el Key Lookup: el número de ejecuciones del operador debería rondar las 250.000, y las filas estimadas del Index Seek siguen siendo las del cliente 42.

Ahora invertid el orden:

```sql
ALTER DATABASE SCOPED CONFIGURATION CLEAR PROCEDURE_CACHE;
EXEC dbo.usp_PedidosPorCliente @ClienteID = 1;    -- compila con el cliente grande
EXEC dbo.usp_PedidosPorCliente @ClienteID = 42;   -- reutiliza un scan completo
```

| Escenario | Plan usado | Lecturas lógicas Pedidos | Tiempo (ms) |
|---|---|---|---|
| Compila con 42, ejecuta 1 | | | |
| Compila con 1, ejecuta 42 | | | |
| Cliente 1 con su plan óptimo | | | |
| Cliente 42 con su plan óptimo | | | |

Para las dos últimas filas usad `OPTION (RECOMPILE)` en una consulta equivalente o limpiad la caché antes de cada ejecución.

## Paso 2 · Subir a compatibilidad 160 y observar PSP (10 minutos)

```sql
ALTER DATABASE LegacyShop SET COMPATIBILITY_LEVEL = 160;
ALTER DATABASE SCOPED CONFIGURATION CLEAR PROCEDURE_CACHE;

EXEC dbo.usp_PedidosPorCliente @ClienteID = 42;
EXEC dbo.usp_PedidosPorCliente @ClienteID = 1;
EXEC dbo.usp_PedidosPorCliente @ClienteID = 42;
```

Abrid el XML del plan real del cliente 1 (clic derecho, "Show Execution Plan XML") y buscad el texto `option (PLAN PER VALUE`. Esa cláusula la añade el dispatcher: indica el identificador de la consulta padre, el predicado sensible y el rango de cardinalidad (cubo) al que pertenece este valor. Comparad con el plan del cliente 42: la cláusula tiene un `QueryVariantID` distinto.

Rellenad de nuevo las lecturas del cliente 1 y del 42. Si PSP ha actuado, cada uno debería tener un plan adecuado a su volumen.

## Paso 3 · Encontrar las variantes en Query Store (10 minutos)

```sql
SELECT qv.parent_query_id, qv.dispatcher_plan_id, qv.query_variant_query_id,
       qt.query_sql_text, p.plan_id,
       rs.count_executions, rs.avg_logical_io_reads, rs.avg_duration / 1000.0 AS avg_ms
FROM sys.query_store_query_variant qv
JOIN sys.query_store_query q        ON q.query_id = qv.query_variant_query_id
JOIN sys.query_store_query_text qt  ON qt.query_text_id = q.query_text_id
JOIN sys.query_store_plan p         ON p.query_id = q.query_id
JOIN sys.query_store_runtime_stats rs ON rs.plan_id = p.plan_id
ORDER BY qv.parent_query_id, qv.query_variant_query_id;
```

Contestad: ¿cuántas variantes hay? ¿Qué plan tiene cada una? ¿Por qué la consulta padre no tiene estadísticas de ejecución propias?

> Si la consulta no devuelve filas, esperad un minuto (Query Store vuelca de forma asíncrona) o ejecutad `EXEC sys.sp_query_store_flush_db;`. Si sigue vacía, PSP no ha considerado el predicado suficientemente sesgado en vuestra máquina: pasad al paso 4, que os dirá por qué.

## Paso 4 · ¿Por qué PSP no actúa sobre la versión legacy? (10 minutos)

Cread una sesión de Extended Events que capture los motivos por los que PSP descarta una consulta:

```sql
CREATE EVENT SESSION PSP_Descartes ON SERVER
ADD EVENT sqlserver.parameter_sensitive_plan_optimization_skipped_reason (
    ACTION (sqlserver.sql_text, sqlserver.database_name)
    WHERE sqlserver.database_name = N'LegacyShop')
ADD TARGET package0.ring_buffer;
ALTER EVENT SESSION PSP_Descartes ON SERVER STATE = START;

ALTER DATABASE SCOPED CONFIGURATION CLEAR PROCEDURE_CACHE;
EXEC dbo.usp_PedidosPorCliente_Legacy @ClienteID = 1;
EXEC dbo.usp_PedidosPorCliente_Legacy @ClienteID = 42;

SELECT x.value('(data[@name="reason"]/text)[1]', 'nvarchar(100)') AS motivo,
       x.value('(action[@name="sql_text"]/value)[1]', 'nvarchar(400)') AS texto
FROM (SELECT CAST(t.target_data AS xml) AS td
      FROM sys.dm_xe_session_targets t JOIN sys.dm_xe_sessions s ON s.address = t.event_session_address
      WHERE s.name = N'PSP_Descartes') d
CROSS APPLY d.td.nodes('//event') AS e(x);
```

Mirad el plan de la versión legacy: el Index Seek estima unas doce filas para ambos clientes. Con la variable local el optimizador no conoce el valor en tiempo de compilación y usa la densidad media de la columna, así que no hay nada a lo que PSP pueda asociar un cubo de cardinalidad. El "arreglo" histórico del sniffing desactiva también su solución moderna.

Limpieza:

```sql
ALTER EVENT SESSION PSP_Descartes ON SERVER STATE = STOP;
DROP EVENT SESSION PSP_Descartes ON SERVER;
SET STATISTICS IO, TIME OFF;
```

## Para la puesta en común

Preparad una respuesta de dos o tres frases para cada pregunta. ¿En qué condiciones PSP no os va a salvar? ¿Qué haríais con la versión legacy en un sistema real? Si una consulta tiene tres predicados sesgados, ¿cuántas variantes puede generar PSP como máximo?

## Si os sobra tiempo

Forzad desde Query Store el plan con scan para la consulta de la versión legacy (`sys.sp_query_store_force_plan`) y medid qué pierden los clientes pequeños. Después retirad el forzado con `sys.sp_query_store_unforce_plan`. Es un buen ejemplo de por qué forzar planes es una decisión con coste.
