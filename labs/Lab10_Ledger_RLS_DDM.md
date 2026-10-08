# Lab 10 · Ledger, Row-Level Security, Dynamic Data Masking y roles granulares

**Sesión 5 · Duración: 50 minutos · Bases de datos: LegacyShop y LedgerLab**

Este laboratorio integra cuatro funcionalidades que responden a amenazas distintas. Ledger responde a "¿alguien ha manipulado estos datos?", Row-Level Security a "¿cada usuario ve solo lo suyo?", Dynamic Data Masking a "¿se exponen datos personales por accidente?", y los roles de servidor de 2022 a "¿esta cuenta necesita de verdad ser sysadmin?". Para simular usuarios usaremos `EXECUTE AS`, que permite probar permisos sin abrir conexiones nuevas.

## Parte 1 · Ledger (15 minutos)

### 1.1 Crear la tabla de precios con ledger y auditar cambios

```sql
USE LegacyShop;
CREATE TABLE dbo.PreciosProducto (
    ProductoID    int           NOT NULL PRIMARY KEY,
    Precio        decimal(10,2) NOT NULL,
    ModificadoPor sysname       NOT NULL DEFAULT SUSER_SNAME()
) WITH (SYSTEM_VERSIONING = ON, LEDGER = ON);

INSERT dbo.PreciosProducto (ProductoID, Precio)
SELECT ProductoID, PrecioBase FROM dbo.Productos;

-- Dos usuarios de prueba cambian precios
CREATE USER tarifas_ana WITHOUT LOGIN;
CREATE USER tarifas_luis WITHOUT LOGIN;
GRANT SELECT, UPDATE ON dbo.PreciosProducto TO tarifas_ana, tarifas_luis;

EXECUTE AS USER = 'tarifas_ana';
UPDATE dbo.PreciosProducto SET Precio = Precio * 1.05, ModificadoPor = USER_NAME() WHERE ProductoID <= 10;
REVERT;
EXECUTE AS USER = 'tarifas_luis';
UPDATE dbo.PreciosProducto SET Precio = 1.00, ModificadoPor = USER_NAME() WHERE ProductoID = 7;   -- sospechoso
REVERT;
```

Consultad la historia del producto 7 con la vista de ledger y la vista de transacciones:

```sql
SELECT l.ProductoID, l.Precio, l.ledger_operation_type_desc, l.ledger_transaction_id,
       t.principal_name, t.commit_time
FROM dbo.PreciosProducto_Ledger l
JOIN sys.database_ledger_transactions t ON t.transaction_id = l.ledger_transaction_id
WHERE l.ProductoID = 7
ORDER BY l.ledger_transaction_id, l.ledger_sequence_number;
```

Fijaos en que `principal_name` registra quién ejecutó la transacción según el motor, independientemente de lo que diga la columna `ModificadoPor`, que cualquiera podría rellenar con otro valor. Intentad también modificar el historial directamente:

```sql
SELECT name, type_desc FROM sys.tables WHERE name LIKE 'MSSQL_LedgerHistoryFor%';
-- UPDATE sobre esa tabla de historial: leed el error
```

### 1.2 Detectar una manipulación "por la puerta de atrás"

SQL Server no permite modificar las tablas de ledger ni su historial con instrucciones normales, así que vamos a simular el ataque más realista: un administrador que restaura un backup antiguo y reescribe la historia a partir de ahí. Para que sea rápido usaremos una base pequeña.

```sql
USE master;
CREATE DATABASE LedgerLab;
GO
USE LedgerLab;
CREATE TABLE dbo.Precios (ProductoID int PRIMARY KEY, Precio decimal(10,2) NOT NULL)
WITH (SYSTEM_VERSIONING = ON, LEDGER = ON);
INSERT dbo.Precios VALUES (1, 10.00), (2, 20.00), (3, 30.00);
BACKUP DATABASE LedgerLab TO DISK = 'LedgerLab_antes.bak' WITH INIT;   -- carpeta de backups por defecto

UPDATE dbo.Precios SET Precio = 12.00 WHERE ProductoID = 1;     -- cambio legítimo
EXEC sys.sp_generate_database_ledger_digest;                     -- COPIAD el JSON devuelto fuera de SQL Server
```

Guardad el JSON en un fichero de texto de vuestro portátil: en la vida real iría a un almacenamiento inmutable gestionado por otro equipo. Ahora el "atacante" restaura el backup y hace otro cambio en lugar del legítimo:

```sql
USE master;
RESTORE DATABASE LedgerLab FROM DISK = 'LedgerLab_antes.bak' WITH REPLACE;
GO
USE LedgerLab;
UPDATE dbo.Precios SET Precio = 1.00 WHERE ProductoID = 1;       -- historia falsificada
EXEC sys.sp_generate_database_ledger_digest;                     -- cierra el bloque con la historia nueva
```

Verificad con el digest que guardasteis antes (pegad el JSON completo):

```sql
EXEC sys.sp_verify_database_ledger N'{"database_name":"LedgerLab","block_id":0,"hash":"0x...","last_transaction_commit_time":"...","digest_time":"..."}';
```

La verificación debe fallar indicando que el hash del bloque no coincide con el del digest. La base de datos es perfectamente consistente por dentro: solo la evidencia guardada fuera permite saber que su historia no es la que era. Esa es exactamente la garantía de ledger, y también su límite: **detecta, no impide**, y sin digests custodiados fuera del alcance del DBA no protege de nada.

## Parte 2 · Row-Level Security (15 minutos)

```sql
USE LegacyShop;
GO
CREATE SCHEMA Seguridad;
GO
CREATE FUNCTION Seguridad.fn_PedidosVisibles (@ComercialID int)
RETURNS TABLE WITH SCHEMABINDING AS
RETURN SELECT 1 AS permitido
       WHERE @ComercialID = CAST(SESSION_CONTEXT(N'ComercialID') AS int)
          OR IS_MEMBER('rol_direccion') = 1;
GO
CREATE SECURITY POLICY Seguridad.PoliticaPedidos
  ADD FILTER PREDICATE Seguridad.fn_PedidosVisibles(ComercialID) ON dbo.Pedidos,
  ADD BLOCK  PREDICATE Seguridad.fn_PedidosVisibles(ComercialID) ON dbo.Pedidos AFTER INSERT
WITH (STATE = ON);
GO
CREATE USER comercial07 WITHOUT LOGIN;
CREATE USER comercial12 WITHOUT LOGIN;
CREATE USER director01  WITHOUT LOGIN;
CREATE ROLE rol_comerciales;
ALTER ROLE rol_comerciales ADD MEMBER comercial07;
ALTER ROLE rol_comerciales ADD MEMBER comercial12;
ALTER ROLE rol_direccion   ADD MEMBER director01;
GRANT SELECT, INSERT ON dbo.Pedidos TO rol_comerciales;
```

Probad con los tres usuarios. La aplicación fija el contexto de sesión tras autenticar al usuario; aquí lo hacemos a mano:

```sql
EXECUTE AS USER = 'comercial07';
EXEC sp_set_session_context @key = N'ComercialID', @value = 7;
SELECT COUNT(*) AS visibles, MIN(ComercialID) AS min_c, MAX(ComercialID) AS max_c FROM dbo.Pedidos;
INSERT dbo.Pedidos (ClienteID, FechaPedido, Estado, Canal, Total, ComercialID)
VALUES (42, SYSDATETIME(), 1, 'WEB', 0, 12);        -- intenta insertar un pedido de otro comercial
REVERT;
EXEC sp_set_session_context @key = N'ComercialID', @value = NULL;

EXECUTE AS USER = 'director01';
SELECT COUNT(*) AS visibles FROM dbo.Pedidos;
REVERT;
```

| Usuario | Pedidos visibles | ¿Puede insertar para otro comercial? |
|---|---|---|
| comercial07 | | |
| comercial12 | | |
| director01 | | |

Dos observaciones importantes. La primera: si la aplicación usa un pool de conexiones y no fija `@read_only = 1`, un error de código podría dejar el contexto de un usuario en la conexión del siguiente. La segunda: mirad el plan de `SELECT COUNT(*) FROM dbo.Pedidos` como comercial07; el predicado se añade a la consulta y puede cambiar el plan, así que conviene tener índices que empiecen por la columna de seguridad si las tablas son grandes.

Desactivad la política antes de seguir, para que no interfiera con los laboratorios siguientes:

```sql
ALTER SECURITY POLICY Seguridad.PoliticaPedidos WITH (STATE = OFF);
```

## Parte 3 · Dynamic Data Masking y UNMASK granular (10 minutos)

```sql
ALTER TABLE dbo.Clientes ALTER COLUMN Email           ADD MASKED WITH (FUNCTION = 'email()');
ALTER TABLE dbo.Clientes ALTER COLUMN Telefono        ADD MASKED WITH (FUNCTION = 'partial(0,"XXX-XXX-",3)');
ALTER TABLE dbo.Clientes ALTER COLUMN FechaNacimiento ADD MASKED WITH (FUNCTION = 'datetime("Y")');
ALTER TABLE dbo.Clientes ALTER COLUMN IBAN            ADD MASKED WITH (FUNCTION = 'partial(4,"****************",4)');

CREATE USER atencion02 WITHOUT LOGIN;
ALTER ROLE rol_atencion_cliente ADD MEMBER atencion02;
GRANT UNMASK ON dbo.Clientes(Telefono) TO rol_atencion_cliente;     -- novedad de 2022: por columna

EXECUTE AS USER = 'atencion02';
SELECT TOP (5) ClienteID, Email, Telefono, FechaNacimiento, IBAN FROM dbo.Clientes;
REVERT;
```

Ahora el ataque de inferencia. El filtro se evalúa sobre el valor real aunque el resultado salga enmascarado:

```sql
EXECUTE AS USER = 'atencion02';
SELECT ClienteID, FechaNacimiento FROM dbo.Clientes
WHERE ClienteID = 42 AND FechaNacimiento BETWEEN '1980-01-01' AND '1980-12-31';   -- ¿devuelve la fila?
SELECT COUNT(*) FROM dbo.Clientes WHERE IBAN LIKE 'ES91%';
REVERT;
```

Con unas pocas consultas se puede reconstruir cualquier valor enmascarado. Por eso DDM es una medida de reducción de exposición para usuarios de aplicación, nunca una frontera de seguridad frente a quien puede lanzar consultas libres.

## Parte 4 · Quitar sysadmin al usuario de monitorización (10 minutos)

```sql
USE master;
SELECT p.name, r.name AS rol FROM sys.server_role_members rm
JOIN sys.server_principals r ON r.principal_id = rm.role_principal_id
JOIN sys.server_principals p ON p.principal_id = rm.member_principal_id
WHERE p.name = N'legacy_monitor';

ALTER SERVER ROLE sysadmin DROP MEMBER legacy_monitor;
ALTER SERVER ROLE ##MS_ServerPerformanceStateReader## ADD MEMBER legacy_monitor;
ALTER SERVER ROLE ##MS_DefinitionReader##             ADD MEMBER legacy_monitor;
```

Comprobad qué puede y qué no puede hacer:

```sql
EXECUTE AS LOGIN = 'legacy_monitor';
SELECT TOP (5) wait_type, wait_time_ms FROM sys.dm_os_wait_stats ORDER BY wait_time_ms DESC;   -- debe funcionar
SELECT session_id, status FROM sys.dm_exec_requests;                                          -- debe funcionar
SELECT TOP (1) IBAN FROM LegacyShop.dbo.Clientes;                                              -- debe fallar
ALTER DATABASE LegacyShop SET RECOVERY FULL;                                                   -- debe fallar
REVERT;
```

Si la herramienta de monitorización necesita leer Query Store u otras vistas de base de datos, se le concede `VIEW DATABASE PERFORMANCE STATE` en cada base, que también es un permiso de solo lectura introducido en 2022.

## Limpieza

```sql
USE master;
DROP DATABASE IF EXISTS LedgerLab;
```

Dejad en LegacyShop la tabla `PreciosProducto` (no se puede eliminar sin dejar rastro: probad `DROP TABLE` y buscadla en `sys.tables` con el nombre `MSSQL_DroppedLedgerTable...`), las máscaras y la política desactivada. El script del taller retira máscaras y política.

## Para la puesta en común

¿Qué habría que hacer con los digests en un sistema real? ¿Por qué RLS no protege frente a un db_owner? ¿Qué combinación de estas cuatro funcionalidades propondríais para los datos bancarios de LegacyShop?
