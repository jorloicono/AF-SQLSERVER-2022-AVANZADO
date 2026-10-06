/* Planes en caché con conversiones implícitas que afectan a búsquedas (Sesión 3) */
WITH XMLNAMESPACES (DEFAULT 'http://schemas.microsoft.com/sqlserver/2004/07/showplan')
SELECT TOP (20) DB_NAME(t.dbid) AS bd, OBJECT_NAME(t.objectid, t.dbid) AS objeto,
       qs.execution_count, qs.total_logical_reads,
       w.value('@ConvertIssue', 'varchar(60)') AS problema,
       w.value('@Expression', 'nvarchar(400)') AS expresion
FROM sys.dm_exec_query_stats qs
CROSS APPLY sys.dm_exec_query_plan(qs.plan_handle) qp
CROSS APPLY sys.dm_exec_sql_text(qs.sql_handle) t
CROSS APPLY qp.query_plan.nodes('//Warnings/PlanAffectingConvert') AS c(w)
WHERE w.value('@ConvertIssue', 'varchar(60)') = 'Seek Plan'
ORDER BY qs.total_logical_reads DESC;
