/* Deadlocks recientes desde la sesión system_health (Sesión 4 y taller) */
SELECT x.value('(@timestamp)[1]', 'datetime2') AS fecha_utc,
       x.query('(data/value/deadlock)[1]') AS grafo_xml   -- guardar como .xdl para verlo en SSMS
FROM (SELECT CAST(event_data AS xml) AS ev
      FROM sys.fn_xe_file_target_read_file('system_health*.xel', NULL, NULL, NULL)
      WHERE object_name = 'xml_deadlock_report') d
CROSS APPLY d.ev.nodes('/event') AS e(x)
ORDER BY fecha_utc DESC;

/* Resumen: víctima y procedimientos implicados */
WITH dl AS (
  SELECT CAST(event_data AS xml) AS ev
  FROM sys.fn_xe_file_target_read_file('system_health*.xel', NULL, NULL, NULL)
  WHERE object_name = 'xml_deadlock_report')
SELECT ev.value('(event/@timestamp)[1]', 'datetime2') AS fecha_utc,
       p.value('@id', 'varchar(50)') AS proceso,
       CASE WHEN p.value('@id', 'varchar(50)') = ev.value('(event/data/value/deadlock/victim-list/victimProcess/@id)[1]', 'varchar(50)')
            THEN 'VÍCTIMA' ELSE '' END AS victima,
       p.value('@hostname', 'sysname') AS host,
       p.value('(executionStack/frame/@procname)[1]', 'nvarchar(300)') AS procedimiento,
       p.value('(inputbuf)[1]', 'nvarchar(400)') AS buffer_entrada
FROM dl CROSS APPLY ev.nodes('event/data/value/deadlock/process-list/process') AS pl(p)
ORDER BY fecha_utc DESC;
