# Lab 11 · Auditoría y hardening

**Sesión 5 · Duración: 40 minutos · Base de datos: LegacyShop**

En este laboratorio vais a montar una auditoría de SQL Server orientada a lo que de verdad importa en LegacyShop (quién accede a los datos de clientes, quién cambia permisos y quién intenta entrar sin éxito), a reconstruir una actividad sospechosa a partir del fichero de auditoría, a comprobar que ni siquiera un administrador puede apagar la auditoría sin dejar rastro, y a ejecutar un chequeo de hardening de la instancia. Terminaréis guardando los eventos de seguridad relevantes en una tabla de ledger de solo inserción.

Comprobad antes que existe la carpeta de auditoría con los permisos correctos (paso 1 de `setup/README.md`):

```bash
docker exec sql2022 ls -ld /var/opt/mssql/audit
```

## Paso 1 · Crear la auditoría (10 minutos)

```sql
USE master;
CREATE SERVER AUDIT Audit_LegacyShop
  TO FILE (FILEPATH = '/var/opt/mssql/audit/', MAXSIZE = 256 MB, MAX_ROLLOVER_FILES = 20)
  WITH (QUEUE_DELAY = 1000, ON_FAILURE = CONTINUE);
ALTER SERVER AUDIT Audit_LegacyShop WITH (STATE = ON);

CREATE SERVER AUDIT SPECIFICATION Spec_Servidor FOR SERVER AUDIT Audit_LegacyShop
  ADD (FAILED_LOGIN_GROUP),
  ADD (SERVER_ROLE_MEMBER_CHANGE_GROUP),
  ADD (AUDIT_CHANGE_GROUP),
  ADD (SERVER_PERMISSION_CHANGE_GROUP)
WITH (STATE = ON);
GO
USE LegacyShop;
CREATE DATABASE AUDIT SPECIFICATION Spec_DatosSensibles FOR SERVER AUDIT Audit_LegacyShop
  ADD (SELECT, UPDATE ON dbo.Clientes BY public),
  ADD (DATABASE_PERMISSION_CHANGE_GROUP),
  ADD (DATABASE_ROLE_MEMBER_CHANGE_GROUP)
WITH (STATE = ON);
```

`ON_FAILURE = CONTINUE` prioriza la disponibilidad: si no se puede escribir la auditoría, el servidor sigue funcionando. La alternativa `SHUTDOWN` detiene la instancia, y es lo que exigen algunos marcos regulatorios. En el laboratorio usamos `CONTINUE`; comentad en la puesta en común qué elegiríais para LegacyShop.

## Paso 2 · Generar actividad sospechosa y reconstruirla (10 minutos)

Simulad la secuencia de un atacante que ha conseguido las credenciales de un empleado:

```sql
-- 1. Intentos de login fallidos (ejecutadlo desde un terminal)
```
```bash
for i in 1 2 3; do docker exec sql2022 /opt/mssql-tools18/bin/sqlcmd -C -S localhost -U atencion99 -P 'mala' -Q "SELECT 1" ; done
```
```sql
-- 2. Un usuario de atención al cliente consulta datos masivamente
USE LegacyShop;
IF USER_ID('atencion03') IS NULL CREATE USER atencion03 WITHOUT LOGIN;
ALTER ROLE rol_atencion_cliente ADD MEMBER atencion03;
EXECUTE AS USER = 'atencion03';
SELECT ClienteID, Nombre, IBAN FROM dbo.Clientes WHERE Provincia = 'Madrid';
REVERT;

-- 3. Alguien se concede permisos adicionales
GRANT UNMASK TO rol_atencion_cliente;
ALTER ROLE db_datareader ADD MEMBER atencion03;
```

Esperad un par de segundos (el `QUEUE_DELAY`) y reconstruid la cronología:

```sql
SELECT event_time, action_id, succeeded, server_principal_name, database_principal_name,
       object_name, LEFT(statement, 150) AS sentencia, client_ip
FROM sys.fn_get_audit_file('/var/opt/mssql/audit/*.sqlaudit', DEFAULT, DEFAULT)
WHERE event_time > DATEADD(MINUTE, -15, SYSUTCDATETIME())
ORDER BY event_time;
```

Fijaos en que `event_time` está en UTC. Identificad los tres momentos del ataque y anotad qué columna os ha permitido saber quién consultó los IBAN aunque se ejecutara con `EXECUTE AS` (`server_principal_name` frente a `database_principal_name`, y la columna `session_server_principal_name`).

| Momento | action_id | Quién | Qué |
|---|---|---|---|
| Intentos de acceso | | | |
| Consulta masiva de IBAN | | | |
| Cambio de permisos | | | |

## Paso 3 · Intentar apagar la auditoría (5 minutos)

```sql
USE master;
ALTER SERVER AUDIT Audit_LegacyShop WITH (STATE = OFF);
-- ... el "atacante" haría aquí sus consultas ...
ALTER SERVER AUDIT Audit_LegacyShop WITH (STATE = ON);

SELECT event_time, action_id, server_principal_name, statement
FROM sys.fn_get_audit_file('/var/opt/mssql/audit/*.sqlaudit', DEFAULT, DEFAULT)
WHERE action_id IN ('AUSC', 'AL', 'CR', 'DR') ORDER BY event_time DESC;
```

El cambio de estado de la auditoría queda registrado (acción `AUSC`, audit session changed) gracias a `AUDIT_CHANGE_GROUP`. Un administrador puede apagar la auditoría, pero no sin dejar constancia, y si los ficheros se envían a un sistema externo (un SIEM) nada más escribirse, tampoco puede borrar esa constancia.

## Paso 4 · Chequeo de hardening (10 minutos)

Ejecutad `scripts/check_hardening.sql`. Devuelve una fila por control con su severidad y una recomendación. Para cada fila en estado `REVISAR` decidid si la corregís ahora o si requiere planificación, y aplicad al menos las correcciones inmediatas de menor riesgo. Por ejemplo:

```sql
-- Superficie de ataque
EXEC sp_configure 'show advanced options', 1; RECONFIGURE;
EXEC sp_configure 'Ad Hoc Distributed Queries', 0; RECONFIGURE;
EXEC sp_configure 'clr strict security', 1; RECONFIGURE;

-- Permisos concedidos en el paso 2
USE LegacyShop;
REVOKE UNMASK TO rol_atencion_cliente;
ALTER ROLE db_datareader DROP MEMBER atencion03;
REVOKE CONNECT FROM guest;
```

Volved a ejecutar el chequeo y comparad el número de filas `REVISAR`.

| Control | Antes | Después | ¿Inmediato o planificado? |
|---|---|---|---|
| | | | |

En el contenedor habrá controles que no podéis resolver sin romper el laboratorio, como la cuenta `sa` habilitada. Documentadlos como riesgo aceptado del entorno de formación.

## Paso 5 · Eventos de seguridad en una tabla ledger de solo inserción (5 minutos)

```sql
USE LegacyShop;
CREATE TABLE dbo.EventosSeguridad (
    Fecha   datetime2     NOT NULL DEFAULT SYSUTCDATETIME(),
    Usuario sysname       NOT NULL DEFAULT SUSER_SNAME(),
    Evento  nvarchar(400) NOT NULL
) WITH (LEDGER = ON (APPEND_ONLY = ON));

INSERT dbo.EventosSeguridad (Evento)
SELECT CONCAT(action_id, N' · ', server_principal_name, N' · ', LEFT(statement, 300))
FROM sys.fn_get_audit_file('/var/opt/mssql/audit/*.sqlaudit', DEFAULT, DEFAULT)
WHERE action_id IN ('LGIF', 'AUSC', 'G', 'APRL', 'SL')
  AND event_time > DATEADD(HOUR, -1, SYSUTCDATETIME());

SELECT * FROM dbo.EventosSeguridad ORDER BY Fecha;
UPDATE dbo.EventosSeguridad SET Evento = N'nada que ver aquí';   -- leed el error
DELETE dbo.EventosSeguridad;                                      -- y este
```

Una tabla de solo inserción no admite `UPDATE` ni `DELETE` ni siquiera para sysadmin, y la cadena de hashes del ledger permitiría detectar cualquier manipulación a bajo nivel. Es un buen destino para registros que alguien podría tener interés en borrar.

## Limpieza

Dejad la auditoría activa: en el taller comprobaréis si sigue ahí (el script del taller la elimina). Si queréis apagarla:

```sql
USE LegacyShop;
ALTER DATABASE AUDIT SPECIFICATION Spec_DatosSensibles WITH (STATE = OFF);
USE master;
ALTER SERVER AUDIT SPECIFICATION Spec_Servidor WITH (STATE = OFF);
ALTER SERVER AUDIT Audit_LegacyShop WITH (STATE = OFF);
```

## Para la puesta en común

¿`ON_FAILURE = CONTINUE` o `SHUTDOWN` para LegacyShop? ¿Qué eventos enviaríais a un SIEM y cuáles no, por volumen? ¿Qué controles del chequeo habéis dejado como planificados y por qué?
