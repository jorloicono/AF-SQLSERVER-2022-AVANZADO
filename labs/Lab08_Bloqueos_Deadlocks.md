# Lab 8 · Bloqueos, escalado de bloqueos y deadlocks

**Sesión 4 · Duración: 45 minutos · Base de datos: LegacyShop**

Los problemas de concurrencia solo se entienden viéndolos, así que en este laboratorio vais a trabajar con tres ventanas de SSMS abiertas a la vez, que llamaremos A, B y C. Colocadlas en paralelo (clic derecho en la pestaña, "New Vertical Tab Group") y conectad las tres a LegacyShop. Provocaréis una cadena de bloqueos con una transacción olvidada, observaréis el escalado de bloqueos y cómo evitarlo, provocaréis un deadlock y lo leeréis desde system_health, y comprobaréis el efecto de Read Committed Snapshot Isolation.

## Paso 1 · La transacción huérfana y la cabeza de la cadena (10 minutos)

**Ventana A**: abrid una transacción, modificad un pedido y **no** hagáis commit. Simula una aplicación que abre una transacción y se queda esperando la respuesta del usuario, o un DBA que se va a comer.

```sql
BEGIN TRAN;
UPDATE dbo.Pedidos SET Observaciones = 'Revisar' WHERE PedidoID = 1199990;
-- no hagáis COMMIT todavía
```

**Ventana B**: intentad leer ese pedido.

```sql
SELECT PedidoID, Estado, Total FROM dbo.Pedidos WHERE PedidoID = 1199990;
```

**Ventana C**: intentad modificar otro pedido y después leer un rango de pedidos que incluya el bloqueado.

```sql
UPDATE dbo.Pedidos SET Estado = 2 WHERE PedidoID = 1199991;                       -- ¿se bloquea?
SELECT SUM(Total) FROM dbo.Pedidos WHERE PedidoID BETWEEN 1199900 AND 1200000;     -- ¿y esto?
```

En una **cuarta ventana** ejecutad `scripts/cadenas_bloqueo.sql`. Identificad la cabeza: es la sesión de la ventana A, que aparece con estado `sleeping`, con una transacción abierta y sin ninguna petición en curso. Es la situación más típica en producción y la razón por la que no basta con mirar `sys.dm_exec_requests`.

Mirad los bloqueos que mantiene la ventana A (sustituid el spid):

```sql
SELECT resource_type, resource_description, request_mode, request_status
FROM sys.dm_tran_locks WHERE request_session_id = 57 AND resource_database_id = DB_ID();
```

Veréis un bloqueo `X` sobre una `KEY`, un `IX` sobre la `PAGE` y un `IX` sobre el `OBJECT`. Explicad por qué la actualización de la ventana C sobre otra fila no queda bloqueada, pero la suma por rango sí: el recorrido del índice agrupado tiene que pedir un bloqueo compartido sobre cada clave, y al llegar a la 1199990 se encuentra el exclusivo de A.

Resolved haciendo `ROLLBACK` en la ventana A y comprobad que B y C continúan.

## Paso 2 · Observar el escalado de bloqueos (10 minutos)

Cread una sesión de Extended Events para capturar escalados:

```sql
CREATE EVENT SESSION Lab8_Escalado ON SERVER
ADD EVENT sqlserver.lock_escalation (
    ACTION (sqlserver.sql_text, sqlserver.session_id)
    WHERE sqlserver.database_name = N'LegacyShop')
ADD TARGET package0.ring_buffer;
ALTER EVENT SESSION Lab8_Escalado ON SERVER STATE = START;
```

**Ventana A**: una actualización masiva dentro de una transacción abierta:

```sql
BEGIN TRAN;
UPDATE dbo.Pedidos SET Observaciones = 'Campaña 2022'
WHERE FechaPedido >= '2022-01-01' AND FechaPedido < '2022-03-01';   -- ≈ 40.000 filas
SELECT resource_type, request_mode, COUNT(*) AS n
FROM sys.dm_tran_locks WHERE request_session_id = @@SPID AND resource_database_id = DB_ID()
GROUP BY resource_type, request_mode;
```

En lugar de decenas de miles de bloqueos `KEY` veréis un único bloqueo `X` sobre el `OBJECT`: SQL Server ha escalado. **Ventana B**: intentad leer cualquier pedido, incluso uno de 2026:

```sql
SELECT Total FROM dbo.Pedidos WHERE PedidoID = 5;
```

Queda bloqueado. Consultad el evento capturado:

```sql
SELECT x.value('@timestamp', 'datetime2') AS fecha,
       x.value('(data[@name="escalated_lock_count"]/value)[1]', 'int') AS bloqueos_escalados,
       x.value('(data[@name="escalation_cause"]/text)[1]', 'varchar(50)') AS causa,
       x.value('(action[@name="sql_text"]/value)[1]', 'nvarchar(300)') AS texto
FROM (SELECT CAST(t.target_data AS xml) AS td FROM sys.dm_xe_session_targets t
      JOIN sys.dm_xe_sessions s ON s.address = t.event_session_address WHERE s.name = N'Lab8_Escalado') d
CROSS APPLY d.td.nodes('//event') AS e(x);
```

`ROLLBACK` en la ventana A.

## Paso 3 · Evitarlo con lotes (5 minutos)

Repetid la misma actualización en lotes de 4.000 filas, cada uno en su propia transacción, usando la clave del índice agrupado para avanzar:

```sql
DECLARE @desde int = 0, @n int = 1;
DECLARE @ini int = (SELECT MIN(PedidoID) FROM dbo.Pedidos WHERE FechaPedido >= '2022-01-01');
DECLARE @fin int = (SELECT MAX(PedidoID) FROM dbo.Pedidos WHERE FechaPedido < '2022-03-01');
SET @desde = @ini;
WHILE @desde <= @fin
BEGIN
    UPDATE dbo.Pedidos SET Observaciones = 'Campaña 2022'
    WHERE PedidoID >= @desde AND PedidoID < @desde + 4000 AND PedidoID <= @fin;
    SET @desde += 4000;
END
```

Mientras se ejecuta, lanzad la lectura de la ventana B varias veces: debería responder de inmediato. Comprobad que el evento `lock_escalation` no ha vuelto a dispararse. El avance por clave es importante: un bucle con `UPDATE TOP (4000) ... WHERE Observaciones <> 'Campaña 2022'` tendría que buscar en cada vuelta las filas pendientes y, sin un índice adecuado, recorrería la tabla una y otra vez.

## Paso 4 · Provocar y leer un deadlock (10 minutos)

Dos procesos acceden a las mismas tablas en orden inverso. Seguid el orden exacto de los pasos:

| Orden | Ventana A | Ventana B |
|---|---|---|
| 1 | `BEGIN TRAN; UPDATE dbo.Pedidos SET Estado = Estado WHERE PedidoID = 1199995;` | |
| 2 | | `BEGIN TRAN; UPDATE dbo.LineasPedido SET Cantidad = Cantidad WHERE LineaID = 3599990;` |
| 3 | `UPDATE dbo.LineasPedido SET Cantidad = Cantidad WHERE LineaID = 3599990;` (queda esperando) | |
| 4 | | `UPDATE dbo.Pedidos SET Estado = Estado WHERE PedidoID = 1199995;` |

En menos de cinco segundos el monitor de deadlocks elegirá una víctima, que recibirá el error 1205. Haced `ROLLBACK` en la ventana superviviente. Después leed el deadlock desde system_health con `scripts/deadlocks_system_health.sql`. Copiad el XML del grafo en un fichero con extensión `.xdl` y abridlo en SSMS para ver el diagrama: dos procesos, dos recursos y las flechas de propietario y de espera. Identificad en el XML el `inputbuf` de cada proceso, el modo de bloqueo que cada uno tenía y el que pedía, y por qué fue elegida la víctima (`deadlockpriority` y `logused`).

Si activasteis el índice por `PedidoID` en el Lab 7, este ejemplo usa `LineaID` a propósito para que el deadlock sea de orden de acceso puro. Como experimento adicional, eliminad temporalmente ese índice y repetid usando `WHERE PedidoID = 1199995` en `LineasPedido`: el `UPDATE` recorre la tabla y los bloqueos que toca durante el recorrido amplían enormemente la superficie de conflicto.

## Paso 5 · Read Committed Snapshot Isolation (5 minutos)

Repetid el paso 1 (ventana A con la transacción abierta, ventana B leyendo) y observad que B espera. Activad RCSI:

```sql
ALTER DATABASE LegacyShop SET READ_COMMITTED_SNAPSHOT ON WITH ROLLBACK IMMEDIATE;
```

Repetid: ahora B lee la última versión confirmada sin esperar, mientras que C, que escribe, sigue esperando a A, porque RCSI no elimina los conflictos entre escritores. Mirad el almacén de versiones:

```sql
SELECT DB_NAME(database_id) AS bd, reserved_page_count * 8 / 1024 AS version_store_mb
FROM sys.dm_tran_version_store_space_usage;
```

## Limpieza

```sql
-- En todas las ventanas: ROLLBACK si queda alguna transacción abierta
ALTER EVENT SESSION Lab8_Escalado ON SERVER STATE = STOP;
DROP EVENT SESSION Lab8_Escalado ON SERVER;
ALTER DATABASE LegacyShop SET READ_COMMITTED_SNAPSHOT OFF WITH ROLLBACK IMMEDIATE;
```

Desactivamos RCSI para que los laboratorios siguientes y el taller partan de la configuración heredada.

## Para la puesta en común

¿Por qué la cabeza de una cadena suele estar dormida? ¿Qué cambia en el comportamiento de la aplicación al activar RCSI y qué habría que comprobar antes de hacerlo en producción? ¿Qué dos cambios de código evitarían el deadlock del paso 4?
