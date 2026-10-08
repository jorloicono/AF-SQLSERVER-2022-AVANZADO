/* Comprobación de hardening de la instancia y de LegacyShop (Lab 11 y taller)
   Devuelve una fila por control: RESULTADO = OK / REVISAR, con severidad y recomendación. */
SET NOCOUNT ON;
DROP TABLE IF EXISTS #h;
CREATE TABLE #h (Control nvarchar(120), Severidad varchar(10), Resultado varchar(8),
                 Detalle nvarchar(400), Recomendacion nvarchar(400));

-- 1. Miembros de sysadmin distintos de sa y cuentas de sistema
INSERT #h
SELECT N'Miembro de sysadmin: ' + p.name, 'CRÍTICA', 'REVISAR', p.type_desc,
       N'Quitar sysadmin; para monitorización usar ##MS_ServerPerformanceStateReader## y ##MS_DefinitionReader##'
FROM sys.server_role_members rm
JOIN sys.server_principals r ON r.principal_id = rm.role_principal_id AND r.name = N'sysadmin'
JOIN sys.server_principals p ON p.principal_id = rm.member_principal_id
WHERE p.name NOT IN (N'sa') AND p.name NOT LIKE N'NT SERVICE\%' AND p.name NOT LIKE N'NT AUTHORITY\%'
  AND p.name NOT LIKE N'##%';

-- 2. Cuenta sa habilitada con su nombre original
INSERT #h
SELECT N'Cuenta sa', 'ALTA', CASE WHEN is_disabled = 1 OR name <> N'sa' THEN 'OK' ELSE 'REVISAR' END,
       CONCAT(N'nombre=', name, N', deshabilitada=', is_disabled),
       N'Deshabilitar o renombrar sa tras crear un administrador nominal (en el laboratorio se mantiene)'
FROM sys.sql_logins WHERE principal_id = 1;

-- 3. Logins SQL sin política de contraseñas
INSERT #h
SELECT N'Login sin CHECK_POLICY: ' + name, 'CRÍTICA', 'REVISAR',
       CONCAT(N'check_policy=', is_policy_checked, N', check_expiration=', is_expiration_checked),
       N'ALTER LOGIN ... WITH CHECK_POLICY = ON y rotar la contraseña'
FROM sys.sql_logins WHERE is_policy_checked = 0 AND name NOT LIKE N'##%';

-- 4. Contraseñas triviales (igual al nombre, vacía o de diccionario corto)
INSERT #h
SELECT N'Contraseña débil: ' + name, 'CRÍTICA', 'REVISAR', N'Coincide con una contraseña trivial',
       N'Cambiar la contraseña y activar CHECK_POLICY'
FROM sys.sql_logins
WHERE PWDCOMPARE(name, password_hash) = 1 OR PWDCOMPARE(N'', password_hash) = 1
   OR PWDCOMPARE(N'legacy123', password_hash) = 1 OR PWDCOMPARE(N'123456', password_hash) = 1
   OR PWDCOMPARE(N'password', password_hash) = 1;

-- 5. Opciones de superficie de ataque
INSERT #h
SELECT N'sp_configure: ' + name,
       CASE WHEN name IN (N'xp_cmdshell', N'clr strict security') THEN 'CRÍTICA' ELSE 'ALTA' END,
       CASE WHEN (name = N'clr strict security' AND CAST(value_in_use AS int) = 1)
              OR (name <> N'clr strict security' AND CAST(value_in_use AS int) = 0) THEN 'OK' ELSE 'REVISAR' END,
       CONCAT(N'value_in_use=', CAST(value_in_use AS int)),
       CASE WHEN name = N'clr strict security' THEN N'Debe valer 1 (valor por defecto desde 2017)'
            ELSE N'Desactivar salvo necesidad documentada' END
FROM sys.configurations
WHERE name IN (N'xp_cmdshell', N'Ole Automation Procedures', N'Ad Hoc Distributed Queries',
               N'clr strict security', N'cross db ownership chaining', N'Database Mail XPs');

-- 6. Bases de datos TRUSTWORTHY
INSERT #h
SELECT N'TRUSTWORTHY ON: ' + d.name, 'ALTA', 'REVISAR', N'Propietario: ' + SUSER_SNAME(d.owner_sid),
       N'ALTER DATABASE ... SET TRUSTWORTHY OFF (con propietario sysadmin permite escalar privilegios)'
FROM sys.databases d WHERE d.is_trustworthy_on = 1 AND d.name <> N'msdb';

-- 7. Propietario de base de datos distinto de sa
INSERT #h
SELECT N'Propietario de ' + name, 'MEDIA', CASE WHEN SUSER_SNAME(owner_sid) = N'sa' THEN 'OK' ELSE 'REVISAR' END,
       N'Propietario: ' + ISNULL(SUSER_SNAME(owner_sid), N'(huérfano)'),
       N'ALTER AUTHORIZATION ON DATABASE::... TO sa (o a un login deshabilitado dedicado)'
FROM sys.databases WHERE database_id > 4;

-- 8. Auditoría activa
INSERT #h
SELECT N'SQL Server Audit activa', 'MEDIA',
       CASE WHEN EXISTS (SELECT 1 FROM sys.dm_server_audit_status WHERE status_desc = N'STARTED') THEN 'OK' ELSE 'REVISAR' END,
       CONCAT(N'Auditorías iniciadas: ', (SELECT COUNT(*) FROM sys.dm_server_audit_status WHERE status_desc = N'STARTED')),
       N'Crear auditoría de servidor con FAILED_LOGIN_GROUP y cambios de permisos/roles';

-- 9. Cifrado de conexiones forzado
INSERT #h
SELECT N'Conexiones sin cifrar', 'MEDIA',
       CASE WHEN SUM(CASE WHEN encrypt_option = 'FALSE' THEN 1 ELSE 0 END) = 0 THEN 'OK' ELSE 'REVISAR' END,
       CONCAT(SUM(CASE WHEN encrypt_option = 'FALSE' THEN 1 ELSE 0 END), N' conexiones sin cifrar ahora mismo'),
       N'Forzar cifrado (Configuration Manager > Protocolos > Force Encryption; en Linux mssql-conf network.forceencryption=1) con certificado válido'
FROM sys.dm_exec_connections;

-- 10-13. Controles dentro de LegacyShop
IF DB_ID(N'LegacyShop') IS NOT NULL
BEGIN
    INSERT #h
    SELECT N'LegacyShop: guest con CONNECT', 'ALTA', 'REVISAR', N'guest puede conectarse',
           N'REVOKE CONNECT FROM guest'
    FROM LegacyShop.sys.database_permissions
    WHERE grantee_principal_id = DATABASE_PRINCIPAL_ID(N'guest') AND permission_name = N'CONNECT' AND state = 'G';

    INSERT #h
    SELECT N'LegacyShop: db_owner ' + m.name, 'ALTA', 'REVISAR', m.type_desc,
           N'Sustituir db_owner por permisos mínimos (EXECUTE sobre esquema, roles propios)'
    FROM LegacyShop.sys.database_role_members rm
    JOIN LegacyShop.sys.database_principals r ON r.principal_id = rm.role_principal_id AND r.name = N'db_owner'
    JOIN LegacyShop.sys.database_principals m ON m.principal_id = rm.member_principal_id
    WHERE m.name <> N'dbo';

    INSERT #h
    SELECT N'LegacyShop: columna sensible sin protección ' + c.name, 'ALTA',
           CASE WHEN mc.column_id IS NOT NULL OR c.encryption_type IS NOT NULL THEN 'OK' ELSE 'REVISAR' END,
           CONCAT(N'enmascarada=', CASE WHEN mc.column_id IS NULL THEN 0 ELSE 1 END,
                  N', cifrada=', CASE WHEN c.encryption_type IS NULL THEN 0 ELSE 1 END),
           N'DDM a corto plazo; Always Encrypted si la amenaza incluye administradores o backups'
    FROM LegacyShop.sys.columns c
    LEFT JOIN LegacyShop.sys.masked_columns mc ON mc.object_id = c.object_id AND mc.column_id = c.column_id
    WHERE c.object_id = OBJECT_ID(N'LegacyShop.dbo.Clientes') AND c.name IN (N'IBAN', N'FechaNacimiento', N'Email', N'Telefono');

    INSERT #h
    SELECT N'LegacyShop: Row-Level Security en Pedidos', 'MEDIA',
           CASE WHEN EXISTS (SELECT 1 FROM LegacyShop.sys.security_policies WHERE is_enabled = 1) THEN 'OK' ELSE 'REVISAR' END,
           N'Políticas activas: ' + CAST((SELECT COUNT(*) FROM LegacyShop.sys.security_policies WHERE is_enabled = 1) AS nvarchar(5)),
           N'Filtrar pedidos por comercial con SESSION_CONTEXT';
END

SELECT * FROM #h
ORDER BY CASE Resultado WHEN 'REVISAR' THEN 0 ELSE 1 END,
         CASE Severidad WHEN 'CRÍTICA' THEN 0 WHEN 'ALTA' THEN 1 ELSE 2 END, Control;
