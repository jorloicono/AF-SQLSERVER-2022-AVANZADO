/* Latencia de I/O por fichero en un intervalo (Sesión 2) */
SET NOCOUNT ON;
DECLARE @espera char(8) = '00:01:00';
DROP TABLE IF EXISTS #f1;
SELECT database_id, file_id, num_of_reads, num_of_bytes_read, io_stall_read_ms,
       num_of_writes, num_of_bytes_written, io_stall_write_ms
INTO #f1 FROM sys.dm_io_virtual_file_stats(NULL, NULL);
WAITFOR DELAY @espera;
SELECT DB_NAME(f2.database_id) AS bd, mf.name AS fichero, mf.type_desc,
       f2.num_of_reads - f1.num_of_reads AS lecturas,
       CAST((f2.io_stall_read_ms - f1.io_stall_read_ms) * 1.0
            / NULLIF(f2.num_of_reads - f1.num_of_reads, 0) AS decimal(10,2)) AS ms_por_lectura,
       f2.num_of_writes - f1.num_of_writes AS escrituras,
       CAST((f2.io_stall_write_ms - f1.io_stall_write_ms) * 1.0
            / NULLIF(f2.num_of_writes - f1.num_of_writes, 0) AS decimal(10,2)) AS ms_por_escritura,
       (f2.num_of_bytes_read - f1.num_of_bytes_read) / 1048576 AS mb_leidos,
       (f2.num_of_bytes_written - f1.num_of_bytes_written) / 1048576 AS mb_escritos
FROM sys.dm_io_virtual_file_stats(NULL, NULL) f2
JOIN #f1 f1 ON f1.database_id = f2.database_id AND f1.file_id = f2.file_id
JOIN sys.master_files mf ON mf.database_id = f2.database_id AND mf.file_id = f2.file_id
WHERE (f2.num_of_reads - f1.num_of_reads) + (f2.num_of_writes - f1.num_of_writes) > 0
ORDER BY (f2.io_stall_read_ms - f1.io_stall_read_ms) + (f2.io_stall_write_ms - f1.io_stall_write_ms) DESC;
/* Orientación: datos < 10-20 ms por lectura; log < 1-5 ms por escritura en SSD. */
