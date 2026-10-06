/* Cadenas de bloqueo: quién bloquea a quién y quién es la cabeza (Sesión 4) */
SELECT r.session_id, r.blocking_session_id, r.wait_type, r.wait_time / 1000.0 AS espera_s,
       r.wait_resource, DB_NAME(r.database_id) AS bd, s.host_name,
       SUBSTRING(t.text, r.statement_start_offset / 2 + 1,
         (CASE r.statement_end_offset WHEN -1 THEN DATALENGTH(t.text) ELSE r.statement_end_offset END
          - r.statement_start_offset) / 2 + 1) AS sentencia
FROM sys.dm_exec_requests r
JOIN sys.dm_exec_sessions s ON s.session_id = r.session_id
CROSS APPLY sys.dm_exec_sql_text(r.sql_handle) t
WHERE r.blocking_session_id <> 0
ORDER BY espera_s DESC;

/* Cabezas: bloquean a otros pero no esperan a nadie (pueden estar "sleeping") */
SELECT s.session_id, s.status, s.host_name, s.login_name, s.open_transaction_count,
       s.last_request_end_time, t.text AS ultima_sentencia,
       (SELECT COUNT(*) FROM sys.dm_exec_requests b WHERE b.blocking_session_id = s.session_id) AS bloqueados
FROM sys.dm_exec_sessions s
JOIN sys.dm_exec_connections c ON c.session_id = s.session_id
CROSS APPLY sys.dm_exec_sql_text(c.most_recent_sql_handle) t
WHERE s.session_id IN (SELECT blocking_session_id FROM sys.dm_exec_requests WHERE blocking_session_id <> 0)
  AND s.session_id NOT IN (SELECT session_id FROM sys.dm_exec_requests WHERE blocking_session_id <> 0);

/* Bloqueos mantenidos por una sesión (resumen por recurso y modo) */
-- SELECT resource_type, request_mode, request_status, COUNT(*) AS n
-- FROM sys.dm_tran_locks WHERE request_session_id = <spid> GROUP BY resource_type, request_mode, request_status;
