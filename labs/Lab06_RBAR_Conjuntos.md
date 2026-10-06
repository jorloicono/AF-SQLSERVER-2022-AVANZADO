# Lab 6 · De RBAR a operaciones basadas en conjuntos

**Sesión 4 · Duración: 50 minutos · Base de datos: LegacyShop**

Este es un laboratorio de reescritura, y la regla más importante no es que la nueva versión vaya más rápida, sino que devuelva exactamente el mismo resultado que la antigua. Por eso cada ejercicio termina con una verificación. Vais a reescribir el recálculo de totales con cursor como una sola sentencia, a corregir el disparador de auditoría para que funcione con operaciones multifila, a sustituir subconsultas correladas por funciones de ventana y a comparar el informe mensual con variable de tabla frente a tabla temporal.

## Preparación

```sql
USE LegacyShop;
SET STATISTICS IO, TIME ON;
-- Copia de trabajo para comparar resultados (solo las columnas necesarias)
DROP TABLE IF EXISTS dbo.Pedidos_Copia;
SELECT PedidoID, Estado, Total INTO dbo.Pedidos_Copia FROM dbo.Pedidos;
ALTER TABLE dbo.Pedidos_Copia ADD CONSTRAINT PK_Pedidos_Copia PRIMARY KEY (PedidoID);
SELECT COUNT(*) AS pendientes FROM dbo.Pedidos WHERE Estado IN (1, 2);
```

## Paso 1 · Medir el cursor (10 minutos)

```sql
UPDATE dbo.Pedidos SET Total = 0 WHERE Estado IN (1, 2);   -- punto de partida conocido
DECLARE @t datetime2 = SYSDATETIME();
EXEC dbo.usp_RecalcularTotales;
SELECT DATEDIFF(MILLISECOND, @t, SYSDATETIME()) AS ms_cursor;
```

Con `STATISTICS IO` activado la salida es enorme (dos sentencias por pedido). Para medir las lecturas totales sin ahogar la pestaña de mensajes, desactivadlo y usad `sys.dm_exec_procedure_stats`:

```sql
SELECT execution_count, total_logical_reads, total_worker_time / 1000 AS cpu_ms, total_elapsed_time / 1000 AS ms
FROM sys.dm_exec_procedure_stats WHERE object_id = OBJECT_ID('dbo.usp_RecalcularTotales');
```

Guardad el resultado de referencia:

```sql
DROP TABLE IF EXISTS #ref;
SELECT PedidoID, Total INTO #ref FROM dbo.Pedidos WHERE Estado IN (1, 2);
```

Mientras el cursor se ejecuta podéis mirar, desde otra ventana, cuántos bloqueos mantiene su transacción. Lo aprovecharemos en el Lab 8.

## Paso 2 · Reescribir como una sola sentencia (10 minutos)

```sql
CREATE OR ALTER PROCEDURE dbo.usp_RecalcularTotales_Set
AS
SET NOCOUNT ON;
UPDATE p SET p.Total = ISNULL(l.Total, 0)
FROM dbo.Pedidos p
LEFT JOIN (SELECT PedidoID, SUM(Cantidad * PrecioUnitario * (1 - Descuento / 100)) AS Total
           FROM dbo.LineasPedido GROUP BY PedidoID) l ON l.PedidoID = p.PedidoID
WHERE p.Estado IN (1, 2) AND p.Total <> ISNULL(l.Total, 0);
GO
UPDATE dbo.Pedidos SET Total = 0 WHERE Estado IN (1, 2);
DECLARE @t datetime2 = SYSDATETIME();
EXEC dbo.usp_RecalcularTotales_Set;
SELECT DATEDIFF(MILLISECOND, @t, SYSDATETIME()) AS ms_set;
```

Verificad que el resultado es idéntico. Las dos consultas deben devolver cero filas:

```sql
SELECT PedidoID, Total FROM #ref
EXCEPT
SELECT PedidoID, Total FROM dbo.Pedidos WHERE Estado IN (1, 2);

SELECT PedidoID, Total FROM dbo.Pedidos WHERE Estado IN (1, 2)
EXCEPT
SELECT PedidoID, Total FROM #ref;
```

¿Hay alguna diferencia de redondeo? El cursor guarda cada suma en una variable `decimal(12,2)` antes del `UPDATE`, y la versión de conjunto asigna la suma directamente a la columna `decimal(12,2)`. En ambos casos el redondeo se produce en la misma asignación, así que no debería haber diferencias; si las hubiera, sería la primera pista de un cambio de semántica.

| Versión | Tiempo (ms) | Lecturas lógicas | Sentencias ejecutadas | Filas escritas en LogActividad |
|---|---|---|---|---|
| Cursor | | | | |
| Conjunto | | | | |

Para la última columna contad las filas que se añaden a `LogActividad` en cada caso (`SELECT COUNT(*) ...` antes y después). Veréis que con la versión de conjunto el disparador solo registra **una** fila. Eso no es una mejora: es un error del disparador que la versión con cursor escondía.

## Paso 3 · Disparador multifila (10 minutos)

```sql
CREATE OR ALTER TRIGGER dbo.trg_Pedidos_Auditoria ON dbo.Pedidos
AFTER INSERT, UPDATE
AS
BEGIN
    SET NOCOUNT ON;
    IF NOT EXISTS (SELECT 1 FROM inserted) RETURN;
    INSERT dbo.LogActividad (Fecha, Usuario, Accion, Detalle)
    SELECT SYSDATETIME(), SUSER_SNAME(),
           CASE WHEN EXISTS (SELECT 1 FROM deleted) THEN 'MODIF_PEDIDO' ELSE 'ALTA_PEDIDO' END,
           CONCAT(N'PedidoID=', i.PedidoID)
    FROM inserted i;
END;
GO
```

Repetid la ejecución de `usp_RecalcularTotales_Set` (con el `UPDATE ... SET Total = 0` previo) y comprobad que ahora se registran tantas filas como pedidos modificados. El `IF NOT EXISTS` evita trabajo cuando una sentencia no afecta a ninguna fila, porque los disparadores se disparan igualmente.

## Paso 4 · Subconsultas correladas frente a funciones de ventana (10 minutos)

```sql
EXEC dbo.usp_HistoricoCliente @ClienteID = 42;
```

Apuntad lecturas y tiempo. Escribid la versión con ventanas:

```sql
CREATE OR ALTER PROCEDURE dbo.usp_HistoricoCliente_v2 @ClienteID int
AS
SET NOCOUNT ON;
SELECT p.PedidoID, p.FechaPedido, p.Total,
       SUM(p.Total) OVER (ORDER BY p.FechaPedido, p.PedidoID ROWS UNBOUNDED PRECEDING) AS Acumulado,
       ROW_NUMBER() OVER (ORDER BY p.FechaPedido, p.PedidoID)                          AS NumeroPedido
FROM dbo.Pedidos p
WHERE p.ClienteID = @ClienteID
ORDER BY p.FechaPedido, p.PedidoID;
GO
EXEC dbo.usp_HistoricoCliente_v2 @ClienteID = 42;
```

Verificad la equivalencia con `EXCEPT` en los dos sentidos, insertando la salida de cada procedimiento en una tabla temporal (`INSERT #a EXEC ...`). Ojo con un detalle: la versión original usa `<=` sobre la fecha, así que dos pedidos con la misma fecha y hora comparten acumulado; la versión con ventana desempata por `PedidoID`. En LegacyShop no hay fechas repetidas para un mismo cliente, pero en un sistema real tendríais que decidir cuál de los dos comportamientos es el correcto. Por eso usamos `ROWS` explícitamente: el marco por defecto, `RANGE`, reproduciría el comportamiento del original a cambio de un spool en disco mucho más caro.

Probad después con el cliente 1 las dos versiones (la original, como mucho 60 segundos) y anotad la diferencia.

## Paso 5 · Variable de tabla frente a tabla temporal (10 minutos)

```sql
EXEC dbo.usp_InformeVentasMensual @Anio = 2025;
```

Cread la versión con tabla temporal y filtro SARGable, manteniendo por ahora las funciones escalares para aislar el efecto de la tabla:

```sql
CREATE OR ALTER PROCEDURE dbo.usp_InformeVentasMensual_v2 @Anio int
AS
SET NOCOUNT ON;
DECLARE @d datetime2(0) = DATEFROMPARTS(@Anio, 1, 1), @h datetime2(0) = DATEFROMPARTS(@Anio + 1, 1, 1);
CREATE TABLE #Ventas (PedidoID int, ClienteID int, FechaPedido datetime2(0), Total decimal(12,2));

INSERT #Ventas WITH (TABLOCK) (PedidoID, ClienteID, FechaPedido, Total)
SELECT PedidoID, ClienteID, FechaPedido, Total
FROM dbo.Pedidos
WHERE FechaPedido >= @d AND FechaPedido < @h AND Estado <> 5;

SELECT MONTH(v.FechaPedido) AS Mes, c.Segmento,
       dbo.fn_TramoEdad(dbo.fn_EdadCliente(c.FechaNacimiento)) AS TramoEdad,
       COUNT(*) AS NumPedidos, SUM(v.Total) AS Ventas, SUM(dbo.fn_ImporteConIVA(v.Total)) AS VentasConIVA
FROM #Ventas v JOIN dbo.Clientes c ON c.ClienteID = v.ClienteID
GROUP BY MONTH(v.FechaPedido), c.Segmento, dbo.fn_TramoEdad(dbo.fn_EdadCliente(c.FechaNacimiento))
ORDER BY Mes, c.Segmento, TramoEdad;
GO
EXEC dbo.usp_InformeVentasMensual_v2 @Anio = 2025;
```

Comparad los dos planes: en la inserción (¿es paralela?), en las filas estimadas del join y en las estadísticas creadas sobre `#Ventas`. Después dad el último paso: sustituid `dbo.fn_EdadCliente(c.FechaNacimiento)` por la expresión en línea con una fecha de referencia y medid de nuevo. Lo comentaremos en la puesta en común.

| Versión | Tiempo (ms) | CPU (ms) | ¿INSERT paralelo? | ¿SELECT paralelo? |
|---|---|---|---|---|
| Original (variable de tabla + YEAR) | | | | |
| #temporal + rango SARGable | | | | |
| + edad en línea (sin UDF no inlineable) | | | | |

## Limpieza

Dejad creados los procedimientos `_Set` y `_v2` y el nuevo disparador: los compararemos en la puesta en común. El script del taller los retira.

```sql
SET STATISTICS IO, TIME OFF;
```

## Para la puesta en común

¿Qué error de corrección escondía el disparador? ¿Por qué `ROWS` y no `RANGE`? ¿En qué caso volveríais a procesar por bloques en lugar de con una única sentencia?
