# Lab 2 · Feedback de memoria, feedback de DOP y Query Store hints

**Sesión 1 · Duración: 45 minutos · Base de datos: LegacyShop**

SQL Server 2022 aprende de las ejecuciones anteriores de una consulta y corrige tres cosas sin que nadie toque el código: la memoria que concede a sus operadores, el grado de paralelismo y, desde 2017, la estimación de cardinalidad. Además, a partir de 2022 esos aprendizajes se guardan en Query Store y sobreviven a un reinicio o a una limpieza de la caché. En este laboratorio vais a verlo funcionar con el informe de ventas por categoría, que tiene una concesión de memoria mal calculada, y vais a aplicar una Query Store hint, que es la forma moderna de corregir una consulta sin modificar la aplicación.

## Preparación

```sql
USE LegacyShop;
ALTER DATABASE LegacyShop SET COMPATIBILITY_LEVEL = 160;
ALTER DATABASE SCOPED CONFIGURATION SET MEMORY_GRANT_FEEDBACK_PERCENTILE_GRANT = ON;   -- ON por defecto
ALTER DATABASE SCOPED CONFIGURATION SET MEMORY_GRANT_FEEDBACK_PERSISTENCE = ON;       -- ON por defecto
ALTER DATABASE SCOPED CONFIGURATION CLEAR PROCEDURE_CACHE;
```

## Paso 1 · Una concesión que se queda corta (10 minutos)

Ejecutad el informe de 2024 con el plan real activado:

```sql
EXEC dbo.usp_InformeVentasCategoria @Anio = 2024;
```

En el operador SELECT del plan real, abrid las propiedades y buscad `MemoryGrantInfo`: apuntad `GrantedMemory`, `MaxUsedMemory` y, si aparece, `IsMemoryGrantFeedbackAdjusted`. Buscad también el triángulo amarillo de spill en el Hash Match o en el Sort. El filtro `YEAR(FechaPedido) = @Anio` no se puede evaluar con el histograma, así que el optimizador estima con una conjetura muy inferior a las 250.000 filas reales de un año, y la memoria se calcula a partir de esa estimación.

Ejecutadlo cuatro veces más y rellenad la tabla con los datos de cada ejecución. La consulta de la derecha os ahorra abrir el XML cada vez:

```sql
SELECT TOP (1) last_grant_kb, last_used_grant_kb, last_spills, execution_count
FROM sys.dm_exec_query_stats qs
CROSS APPLY sys.dm_exec_sql_text(qs.sql_handle) t
WHERE t.objectid = OBJECT_ID('dbo.usp_InformeVentasCategoria')
ORDER BY qs.last_execution_time DESC;
```

| Ejecución | Concedida (KB) | Usada (KB) | Spill (páginas) | IsMemoryGrantFeedbackAdjusted |
|---|---|---|---|---|
| 1 | | | | |
| 2 | | | | |
| 3 | | | | |
| 4 | | | | |
| 5 | | | | |

Deberíais ver cómo la concesión sube tras la primera ejecución y cómo el spill desaparece. Con el ajuste por percentil, la concesión no persigue a la última ejecución sino a un percentil alto del historial reciente, lo que evita la oscilación que tenía el feedback de 2017 y 2019.

## Paso 2 · Alternar valores: por qué hacía falta el percentil (5 minutos)

Alternad un año completo con un año con pocos datos (2021 solo tiene medio año):

```sql
EXEC dbo.usp_InformeVentasCategoria @Anio = 2021;
EXEC dbo.usp_InformeVentasCategoria @Anio = 2024;
EXEC dbo.usp_InformeVentasCategoria @Anio = 2021;
EXEC dbo.usp_InformeVentasCategoria @Anio = 2024;
```

Observad que la concesión se estabiliza en un valor alto en vez de subir y bajar en cada llamada. Ese es exactamente el comportamiento que queremos en una consulta con parámetros variables.

## Paso 3 · El ajuste sobrevive a la caché (5 minutos)

```sql
ALTER DATABASE SCOPED CONFIGURATION CLEAR PROCEDURE_CACHE;
EXEC dbo.usp_InformeVentasCategoria @Anio = 2024;
```

Comprobad la concesión de esta primera ejecución tras la limpieza. Si la persistencia funciona, arranca ya con el valor aprendido. Lo podéis ver en Query Store:

```sql
SELECT pf.plan_feedback_id, pf.plan_id, pf.feature_desc, pf.state_desc, pf.feedback_data
FROM sys.query_store_plan_feedback pf
JOIN sys.query_store_plan p ON p.plan_id = pf.plan_id
JOIN sys.query_store_query q ON q.query_id = p.query_id
WHERE q.object_id = OBJECT_ID('dbo.usp_InformeVentasCategoria');
```

## Paso 4 · Feedback del grado de paralelismo (15 minutos)

El feedback de DOP está desactivado por defecto en SQL Server 2022, así que hay que activarlo. Necesita además Query Store en modo lectura-escritura y una consulta repetitiva que se ejecute en paralelo.

```sql
ALTER DATABASE SCOPED CONFIGURATION SET DOP_FEEDBACK = ON;
ALTER DATABASE SCOPED CONFIGURATION CLEAR PROCEDURE_CACHE;
```

Usaremos una agregación que recorre toda la tabla de líneas y que el optimizador paraleliza:

```sql
SELECT pr.Categoria, SUM(l.Cantidad * l.PrecioUnitario) AS Importe
FROM dbo.LineasPedido l JOIN dbo.Productos pr ON pr.ProductoID = l.ProductoID
GROUP BY pr.Categoria
OPTION (RECOMPILE);   -- quitad RECOMPILE: el feedback necesita reutilizar el plan
```

Quitad el `OPTION (RECOMPILE)` y lanzad la consulta muchas veces seguidas. Desde otra ventana o desde el contenedor podéis usar el lanzador concurrente con una sola sesión:

```bash
docker exec sql2022 bash /datos/carga/concurrente.sh 1 180 "SELECT pr.Categoria, SUM(l.Cantidad * l.PrecioUnitario) AS Importe FROM dbo.LineasPedido l JOIN dbo.Productos pr ON pr.ProductoID = l.ProductoID GROUP BY pr.Categoria;"
```

Mientras corre, consultad el estado del feedback:

```sql
SELECT pf.plan_id, pf.feature_desc, pf.state_desc, pf.feedback_data
FROM sys.query_store_plan_feedback pf
WHERE pf.feature_desc = N'DOP Feedback';
```

Los estados que podéis ver son `PENDING_VALIDATION`, `VERIFICATION_PASSED`, `VERIFICATION_REGRESSED` y `NO_RECOMMENDATION`, entre otros. En un contenedor con pocos núcleos es posible que el feedback no encuentre mejora y termine en `NO_RECOMMENDATION`: también es un resultado válido y sirve para explicar que el mecanismo solo reduce el DOP cuando la consulta no pierde rendimiento. Anotad lo que veáis y cuántos núcleos tiene vuestro contenedor (`SELECT cpu_count FROM sys.dm_os_sys_info;`).

## Paso 5 · Aplicar y retirar una Query Store hint (10 minutos)

Imaginad que el informe por categoría no se puede tocar porque viene de un producto de terceros, y que queréis que nunca use más de dos hilos y que recompile en cada ejecución. Primero localizad el `query_id` de la sentencia:

```sql
SELECT q.query_id, LEFT(qt.query_sql_text, 120) AS texto
FROM sys.query_store_query q
JOIN sys.query_store_query_text qt ON qt.query_text_id = q.query_text_id
WHERE q.object_id = OBJECT_ID('dbo.usp_InformeVentasCategoria');
```

Aplicad la hint (sustituid 123 por vuestro query_id):

```sql
EXEC sys.sp_query_store_set_hints @query_id = 123, @query_hints = N'OPTION (MAXDOP 2, RECOMPILE)';

SELECT query_hint_id, query_id, query_hint_text, last_query_hint_failure_reason_desc
FROM sys.query_store_query_hints;

EXEC dbo.usp_InformeVentasCategoria @Anio = 2024;
```

Comprobad en el plan real (propiedad `DegreeOfParallelism` del SELECT) que la hint se aplica sin haber modificado el procedimiento. Después retiradla:

```sql
EXEC sys.sp_query_store_clear_hints @query_id = 123;
```

## Limpieza

```sql
ALTER DATABASE SCOPED CONFIGURATION SET DOP_FEEDBACK = OFF;
```

## Para la puesta en común

¿Por qué el feedback de memoria no es la solución de fondo del informe por categoría? ¿Qué consultas no se benefician nunca del feedback? ¿Qué ventaja tiene una Query Store hint frente a una plan guide?

## Si os sobra tiempo

Activad el feedback de CE (`CE_FEEDBACK`, activado por defecto en compatibilidad 160) y buscad en `sys.query_store_plan_feedback` filas con `feature_desc = 'CE Feedback'` tras ejecutar muchas veces `usp_HistoricoCliente` con el cliente 1.
