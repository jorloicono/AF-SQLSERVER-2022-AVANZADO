/* Top de consultas en Query Store (última hora). Ejecutar en LegacyShop. */
DECLARE @desde datetimeoffset = DATEADD(HOUR, -1, SYSDATETIMEOFFSET());
SELECT TOP (15) q.query_id, OBJECT_NAME(q.object_id) AS objeto,
       COUNT(DISTINCT p.plan_id) AS planes,
       SUM(rs.count_executions) AS ejecuciones,
       CAST(SUM(rs.avg_duration * rs.count_executions) / 1000.0 AS decimal(18,0)) AS duracion_total_ms,
       CAST(SUM(rs.avg_cpu_time * rs.count_executions) / 1000.0 AS decimal(18,0)) AS cpu_total_ms,
       CAST(SUM(rs.avg_logical_io_reads * rs.count_executions) AS decimal(18,0)) AS lecturas_totales,
       CAST(MAX(rs.max_duration) / 1000.0 AS decimal(18,0)) AS duracion_max_ms,
       LEFT(qt.query_sql_text, 150) AS texto
FROM sys.query_store_runtime_stats rs
JOIN sys.query_store_runtime_stats_interval i ON i.runtime_stats_interval_id = rs.runtime_stats_interval_id
JOIN sys.query_store_plan p  ON p.plan_id = rs.plan_id
JOIN sys.query_store_query q ON q.query_id = p.query_id
JOIN sys.query_store_query_text qt ON qt.query_text_id = q.query_text_id
WHERE i.start_time >= @desde
GROUP BY q.query_id, q.object_id, qt.query_sql_text
ORDER BY duracion_total_ms DESC;      -- cambiar a lecturas_totales o cpu_total_ms

/* Esperas por consulta (categorías de Query Store) */
SELECT TOP (15) q.query_id, OBJECT_NAME(q.object_id) AS objeto, ws.wait_category_desc,
       SUM(ws.total_query_wait_time_ms) AS espera_total_ms
FROM sys.query_store_wait_stats ws
JOIN sys.query_store_runtime_stats_interval i ON i.runtime_stats_interval_id = ws.runtime_stats_interval_id
JOIN sys.query_store_plan p ON p.plan_id = ws.plan_id
JOIN sys.query_store_query q ON q.query_id = p.query_id
WHERE i.start_time >= @desde
GROUP BY q.query_id, q.object_id, ws.wait_category_desc
ORDER BY espera_total_ms DESC;
