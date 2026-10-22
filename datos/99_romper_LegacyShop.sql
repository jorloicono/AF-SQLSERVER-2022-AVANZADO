/* =====================================================================
   Curso SQL Server 2022 Avanzado · TALLER INTEGRADOR (Sesión 6)
   99_romper_LegacyShop.sql — deja LegacyShop en el "estado incidente"
   ---------------------------------------------------------------------
   ¡ALUMNOS: no abráis este script antes del debrief! Contiene las
   soluciones implícitas del taller.

   Requisitos: ejecutar DESPUÉS de 01_crear_LegacyShop.sql (recomendado
   partir de una base recién creada, sobre todo si en el Lab 9 cifrasteis
   columnas con Always Encrypted). El script es idempotente: deshace los
   arreglos típicos de los laboratorios y reintroduce los problemas.

   Ejecutar en SSMS (Archivo > Abrir > este fichero, F5) conectado a vuestra
   instancia local con un login sysadmin, justo después de 01_crear_LegacyShop.sql.
   ===================================================================== */
SET NOCOUNT ON;
USE master;
GO
IF DB_ID(N'LegacyShop') IS NULL
BEGIN
    RAISERROR('LegacyShop no existe: ejecutad antes 01_crear_LegacyShop.sql', 16, 1);
    SET NOEXEC ON;
END
GO
-- Cortar conexiones y restaurar opciones de base de datos
ALTER DATABASE LegacyShop SET SINGLE_USER WITH ROLLBACK IMMEDIATE;
ALTER DATABASE LegacyShop SET READ_COMMITTED_SNAPSHOT OFF;
ALTER DATABASE LegacyShop SET ALLOW_SNAPSHOT_ISOLATION OFF;
ALTER DATABASE LegacyShop SET COMPATIBILITY_LEVEL = 160;
ALTER DATABASE LegacyShop SET MULTI_USER;
GO
USE LegacyShop;
GO
/* ---------------------------------------------------------------------
   R1. Deshacer arreglos de los laboratorios
   --------------------------------------------------------------------- */
PRINT 'R1. Eliminando políticas RLS, máscaras e índices añadidos en los labs...';
IF EXISTS (SELECT 1 FROM sys.security_policies WHERE name = N'PoliticaPedidos')
    DROP SECURITY POLICY Seguridad.PoliticaPedidos;
IF OBJECT_ID(N'Seguridad.fn_PedidosVisibles') IS NOT NULL
    DROP FUNCTION Seguridad.fn_PedidosVisibles;

DECLARE @sql nvarchar(max) = N'';
SELECT @sql += N'ALTER TABLE ' + QUOTENAME(SCHEMA_NAME(t.schema_id)) + N'.' + QUOTENAME(t.name)
             + N' ALTER COLUMN ' + QUOTENAME(c.name) + N' DROP MASKED;' + CHAR(10)
FROM sys.masked_columns c JOIN sys.tables t ON t.object_id = c.object_id;
EXEC sys.sp_executesql @sql;

-- Índices no agrupados que no forman parte del diseño "legacy"
SET @sql = N'';
SELECT @sql += N'DROP INDEX ' + QUOTENAME(i.name) + N' ON dbo.' + QUOTENAME(t.name) + N';' + CHAR(10)
FROM sys.indexes i JOIN sys.tables t ON t.object_id = i.object_id
WHERE t.name IN (N'Pedidos', N'LineasPedido', N'Clientes', N'Productos', N'LogActividad')
  AND i.type IN (2, 6)                      -- no agrupado y columnar no agrupado
  AND i.is_primary_key = 0 AND i.is_unique_constraint = 0;
EXEC sys.sp_executesql @sql;
GO
CREATE INDEX IX_Pedidos_ClienteID   ON dbo.Pedidos (ClienteID);
CREATE INDEX IX_Pedidos_FechaPedido ON dbo.Pedidos (FechaPedido);
CREATE INDEX IX_Clientes_Codigo     ON dbo.Clientes (CodigoCliente);
CREATE INDEX IX_Productos_Nombre    ON dbo.Productos (Nombre);
GO
-- Objetos creados en los laboratorios (si existen)
DROP PROCEDURE IF EXISTS dbo.usp_RecalcularTotales_Set, dbo.usp_InformeVentasMensual_v2,
                         dbo.usp_HistoricoCliente_v2;
DROP TABLE IF EXISTS dbo.Pedidos_Copia;
GO
-- Pedidos pendientes con total a 0 (trabajo para el recálculo)
UPDATE dbo.Pedidos SET Total = 0 WHERE Estado IN (1, 2);
GO
/* ---------------------------------------------------------------------
   R3. Funciones escalares legacy (restaurar)
   --------------------------------------------------------------------- */
-- Inlineable (Scalar UDF Inlining, 2019+)
CREATE OR ALTER FUNCTION dbo.fn_ImporteConIVA (@Importe decimal(12,2))
RETURNS decimal(12,2)
AS
BEGIN
    RETURN @Importe * 1.21;
END;
GO
-- NO inlineable: usa GETDATE() (función dependiente del tiempo)
CREATE OR ALTER FUNCTION dbo.fn_EdadCliente (@FechaNacimiento date)
RETURNS int
AS
BEGIN
    DECLARE @hoy date = GETDATE();
    RETURN DATEDIFF(YEAR, @FechaNacimiento, @hoy)
         - CASE WHEN DATEADD(YEAR, DATEDIFF(YEAR, @FechaNacimiento, @hoy), @FechaNacimiento) > @hoy
                THEN 1 ELSE 0 END;
END;
GO
-- Inlineable
CREATE OR ALTER FUNCTION dbo.fn_TramoEdad (@Edad int)
RETURNS varchar(10)
AS
BEGIN
    RETURN CASE WHEN @Edad < 30 THEN '<30' WHEN @Edad < 45 THEN '30-44'
                WHEN @Edad < 65 THEN '45-64' ELSE '65+' END;
END;
GO
/* ---------------------------------------------------------------------
   R4. Procedimientos legacy (restaurar) (defectos deliberados indicados en comentario)
   --------------------------------------------------------------------- */
-- Parameter sniffing con distribución sesgada (Lab 1, Lab 7, ticket 4)
CREATE OR ALTER PROCEDURE dbo.usp_PedidosPorCliente @ClienteID int
AS
SET NOCOUNT ON;
SELECT p.PedidoID, p.FechaPedido, p.Estado, p.Canal, p.Total, p.Observaciones
FROM dbo.Pedidos p
WHERE p.ClienteID = @ClienteID
ORDER BY p.FechaPedido DESC;
GO
-- "Arreglo" antiguo del sniffing con variable local: estimación por densidad (Lab 1)
CREATE OR ALTER PROCEDURE dbo.usp_PedidosPorCliente_Legacy @ClienteID int
AS
SET NOCOUNT ON;
DECLARE @c int = @ClienteID;
SELECT p.PedidoID, p.FechaPedido, p.Estado, p.Canal, p.Total, p.Observaciones
FROM dbo.Pedidos p
WHERE p.ClienteID = @c
ORDER BY p.FechaPedido DESC;
GO
-- Conversión implícita: parámetro NVARCHAR frente a columna VARCHAR (Lab 5A, ticket 1)
CREATE OR ALTER PROCEDURE dbo.usp_BuscarClientePorCodigo @Codigo nvarchar(20)
AS
SET NOCOUNT ON;
SELECT ClienteID, CodigoCliente, Nombre, Email, Telefono, Segmento
FROM dbo.Clientes
WHERE CodigoCliente = @Codigo;
GO
-- Detalle de pedido: scan de LineasPedido por falta de índice (Lab 4, Lab 7, ticket 3)
CREATE OR ALTER PROCEDURE dbo.usp_DetallePedido @PedidoID int
AS
SET NOCOUNT ON;
SELECT l.LineaID, l.ProductoID, pr.SKU, pr.Nombre, l.Cantidad, l.PrecioUnitario, l.Descuento,
       CAST(l.Cantidad * l.PrecioUnitario * (1 - l.Descuento / 100) AS decimal(12,2)) AS Importe
FROM dbo.LineasPedido l
JOIN dbo.Productos pr ON pr.ProductoID = l.ProductoID
WHERE l.PedidoID = @PedidoID;
GO
-- RBAR: cursor global dentro de una transacción larga (Lab 6, Lab 8, ticket 5)
CREATE OR ALTER PROCEDURE dbo.usp_RecalcularTotales
AS
SET NOCOUNT ON;
DECLARE @id int, @total decimal(12,2);
BEGIN TRANSACTION;
DECLARE c CURSOR FOR SELECT PedidoID FROM dbo.Pedidos WHERE Estado IN (1, 2);
OPEN c;
FETCH NEXT FROM c INTO @id;
WHILE @@FETCH_STATUS = 0
BEGIN
    SELECT @total = SUM(Cantidad * PrecioUnitario * (1 - Descuento / 100))
    FROM dbo.LineasPedido WHERE PedidoID = @id;
    UPDATE dbo.Pedidos SET Total = ISNULL(@total, 0) WHERE PedidoID = @id;
    FETCH NEXT FROM c INTO @id;
END
CLOSE c;
DEALLOCATE c;
COMMIT TRANSACTION;
GO
-- Informe mensual: YEAR() no SARGable + variable de tabla + UDF no inlineable (Lab 6, ticket 2)
CREATE OR ALTER PROCEDURE dbo.usp_InformeVentasMensual @Anio int
AS
SET NOCOUNT ON;
DECLARE @Ventas TABLE (PedidoID int, ClienteID int, FechaPedido datetime2(0), Total decimal(12,2));

INSERT @Ventas (PedidoID, ClienteID, FechaPedido, Total)
SELECT PedidoID, ClienteID, FechaPedido, Total
FROM dbo.Pedidos
WHERE YEAR(FechaPedido) = @Anio AND Estado <> 5;

SELECT MONTH(v.FechaPedido)                               AS Mes,
       c.Segmento,
       dbo.fn_TramoEdad(dbo.fn_EdadCliente(c.FechaNacimiento)) AS TramoEdad,
       COUNT(*)                                           AS NumPedidos,
       SUM(v.Total)                                       AS Ventas,
       SUM(dbo.fn_ImporteConIVA(v.Total))                 AS VentasConIVA
FROM @Ventas v
JOIN dbo.Clientes c ON c.ClienteID = v.ClienteID
GROUP BY MONTH(v.FechaPedido), c.Segmento, dbo.fn_TramoEdad(dbo.fn_EdadCliente(c.FechaNacimiento))
ORDER BY Mes, c.Segmento, TramoEdad;
GO
-- Informe por categoría: estimación por conjetura (YEAR) -> concesión corta -> spill (Lab 2, Lab 5B)
CREATE OR ALTER PROCEDURE dbo.usp_InformeVentasCategoria @Anio int
AS
SET NOCOUNT ON;
SELECT pr.Categoria, p.PedidoID, p.FechaPedido, p.Canal, p.Observaciones,
       SUM(l.Cantidad * l.PrecioUnitario * (1 - l.Descuento / 100)) AS Importe
FROM dbo.Pedidos p
JOIN dbo.LineasPedido l ON l.PedidoID = p.PedidoID
JOIN dbo.Productos pr   ON pr.ProductoID = l.ProductoID
WHERE YEAR(p.FechaPedido) = @Anio
GROUP BY pr.Categoria, p.PedidoID, p.FechaPedido, p.Canal, p.Observaciones
ORDER BY pr.Categoria, Importe DESC;
GO
-- Subconsulta correlada para acumulados (Lab 6: sustituir por funciones de ventana)
CREATE OR ALTER PROCEDURE dbo.usp_HistoricoCliente @ClienteID int
AS
SET NOCOUNT ON;
SELECT p.PedidoID, p.FechaPedido, p.Total,
       (SELECT SUM(p2.Total) FROM dbo.Pedidos p2
         WHERE p2.ClienteID = p.ClienteID AND p2.FechaPedido <= p.FechaPedido) AS Acumulado,
       (SELECT COUNT(*) FROM dbo.Pedidos p3
         WHERE p3.ClienteID = p.ClienteID AND p3.FechaPedido <= p.FechaPedido) AS NumeroPedido
FROM dbo.Pedidos p
WHERE p.ClienteID = @ClienteID
ORDER BY p.FechaPedido;
GO
-- Línea principal de cada pedido: el optimizador construye un Index Spool (Lab 5B)
CREATE OR ALTER PROCEDURE dbo.usp_UltimosPedidosLineaPrincipal @ClienteID int
AS
SET NOCOUNT ON;
SELECT TOP (200) p.PedidoID, p.FechaPedido, lp.ProductoID, lp.Cantidad
FROM dbo.Pedidos p
CROSS APPLY (SELECT TOP (1) l.ProductoID, l.Cantidad
             FROM dbo.LineasPedido l
             WHERE l.PedidoID = p.PedidoID
             ORDER BY l.Cantidad DESC) AS lp
WHERE p.ClienteID = @ClienteID
ORDER BY p.FechaPedido DESC;
GO
-- Alta de pedido (usada por la carga del taller)
CREATE OR ALTER PROCEDURE dbo.usp_AltaPedido @ClienteID int, @ComercialID int
AS
SET NOCOUNT ON;
DECLARE @id int;
BEGIN TRANSACTION;
INSERT dbo.Pedidos (ClienteID, FechaPedido, Estado, Canal, Total, ComercialID)
VALUES (@ClienteID, SYSDATETIME(), 1, 'WEB', 0, @ComercialID);
SET @id = SCOPE_IDENTITY();
INSERT dbo.LineasPedido (PedidoID, ProductoID, Cantidad, PrecioUnitario, Descuento)
SELECT @id, pr.ProductoID, 1 + ABS(CHECKSUM(NEWID()) % 4), pr.PrecioBase, 0
FROM (SELECT TOP (3) ProductoID, PrecioBase FROM dbo.Productos
      WHERE Activo = 1 AND ProductoID % 97 = @ClienteID % 97) AS pr;
COMMIT TRANSACTION;
GO
/* ---------------------------------------------------------------------
   R5. Disparador legacy (restaurar): solo audita UNA fila en operaciones multifila
   --------------------------------------------------------------------- */
CREATE OR ALTER TRIGGER dbo.trg_Pedidos_Auditoria ON dbo.Pedidos
AFTER INSERT, UPDATE
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @id int;
    SELECT @id = PedidoID FROM inserted;          -- defecto: se queda con una fila cualquiera
    INSERT dbo.LogActividad (Fecha, Usuario, Accion, Detalle)
    VALUES (SYSDATETIME(), SUSER_SNAME(),
            CASE WHEN EXISTS (SELECT 1 FROM deleted) THEN 'MODIF_PEDIDO' ELSE 'ALTA_PEDIDO' END,
            CONCAT(N'PedidoID=', @id));
END;
GO
/* ---------------------------------------------------------------------
   R6. Procedimientos de la carga simulada (NO forman parte del "sistema")
   --------------------------------------------------------------------- */
-- Acceso Pedidos -> LineasPedido
CREATE OR ALTER PROCEDURE dbo.usp_Carga_AjustarPedido
AS
SET NOCOUNT ON;
DECLARE @id int = (SELECT MAX(PedidoID) FROM dbo.Pedidos) - ABS(CHECKSUM(NEWID()) % 40);
BEGIN TRANSACTION;
UPDATE dbo.Pedidos SET Observaciones = 'Ajustado por logística' WHERE PedidoID = @id;
WAITFOR DELAY '00:00:00.200';
UPDATE dbo.LineasPedido SET Cantidad = Cantidad WHERE PedidoID = @id;
COMMIT TRANSACTION;
GO
-- Acceso LineasPedido -> Pedidos (orden inverso: deadlocks)
CREATE OR ALTER PROCEDURE dbo.usp_Carga_CancelarLinea
AS
SET NOCOUNT ON;
DECLARE @id int = (SELECT MAX(PedidoID) FROM dbo.Pedidos) - ABS(CHECKSUM(NEWID()) % 40);
BEGIN TRANSACTION;
UPDATE dbo.LineasPedido SET Descuento = Descuento WHERE PedidoID = @id;
WAITFOR DELAY '00:00:00.200';
UPDATE dbo.Pedidos SET Total = Total WHERE PedidoID = @id;
COMMIT TRANSACTION;
GO
-- Mezcla de operaciones de la aplicación
CREATE OR ALTER PROCEDURE dbo.usp_Carga_Mezcla @Trabajador int, @Iteraciones int = 25
AS
SET NOCOUNT ON;
DECLARE @i int = 0, @r int, @op varchar(40), @cli int, @cod nvarchar(20), @ped int;
DECLARE @maxPed int = (SELECT MAX(PedidoID) FROM dbo.Pedidos);
WHILE @i < @Iteraciones
BEGIN
    SET @i += 1;
    SET @r = ABS(CHECKSUM(NEWID()) % 100);
    SET @cli = 2 + ABS(CHECKSUM(NEWID()) % 99999);
    BEGIN TRY
        IF @r < 30
        BEGIN
            SET @op = 'BuscarCliente';                 -- ticket 1 (la app envía NVARCHAR)
            SET @cod = CONCAT(N'CLI-', RIGHT(N'0000000' + CAST(@cli AS nvarchar(7)), 7));
            EXEC dbo.usp_BuscarClientePorCodigo @Codigo = @cod;
        END
        ELSE IF @r < 42
        BEGIN
            SET @op = 'PedidosPorCliente';             -- ticket 4
            IF @r % 4 = 0 SET @cli = 1;
            EXEC dbo.usp_PedidosPorCliente @ClienteID = @cli;
        END
        ELSE IF @r < 47
        BEGIN
            SET @op = 'PortalGrandesCuentas';          -- ticket 4 (versión legacy)
            IF @r % 2 = 0 SET @cli = 1;
            EXEC dbo.usp_PedidosPorCliente_Legacy @ClienteID = @cli;
        END
        ELSE IF @r < 62
        BEGIN
            SET @op = 'DetallePedido';                 -- ticket 3
            SET @ped = 1 + ABS(CHECKSUM(NEWID()) % @maxPed);
            EXEC dbo.usp_DetallePedido @PedidoID = @ped;
        END
        ELSE IF @r < 80
        BEGIN
            SET @op = 'AltaPedido';
            EXEC dbo.usp_AltaPedido @ClienteID = @cli, @ComercialID = @Trabajador;
        END
        ELSE IF @r < 88
        BEGIN
            SET @op = 'AjustarPedido';                 -- ticket 5 (deadlocks)
            EXEC dbo.usp_Carga_AjustarPedido;
        END
        ELSE IF @r < 96
        BEGIN
            SET @op = 'CancelarLinea';                 -- ticket 5 (deadlocks)
            EXEC dbo.usp_Carga_CancelarLinea;
        END
        ELSE IF @r < 98
        BEGIN
            SET @op = 'InformeCategoria';              -- spill oculto
            EXEC dbo.usp_InformeVentasCategoria @Anio = 2025;
        END
        ELSE
        BEGIN
            SET @op = 'InformeMensual';                -- ticket 2
            EXEC dbo.usp_InformeVentasMensual @Anio = 2025;
        END
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        INSERT dbo.CargaErrores (Trabajador, Operacion, Numero, Mensaje)
        VALUES (@Trabajador, @op, ERROR_NUMBER(), ERROR_MESSAGE());
    END CATCH
END
GO
-- Proceso de recálculo lanzado periódicamente por la carga
CREATE OR ALTER PROCEDURE dbo.usp_Carga_Recalculo
AS
SET NOCOUNT ON;
BEGIN TRY
    EXEC dbo.usp_RecalcularTotales;
END TRY
BEGIN CATCH
    IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
    INSERT dbo.CargaErrores (Trabajador, Operacion, Numero, Mensaje)
    VALUES (0, 'RecalcularTotales', ERROR_NUMBER(), ERROR_MESSAGE());
END CATCH
GO
/* ---------------------------------------------------------------------
   R7. Seguridad deliberadamente débil (ticket 6)
   --------------------------------------------------------------------- */
PRINT 'R7. Configuración de seguridad heredada...';
USE master;
GO
IF SUSER_ID(N'legacy_monitor') IS NULL
    CREATE LOGIN legacy_monitor WITH PASSWORD = N'Monitor_2015!', CHECK_POLICY = OFF;
ALTER SERVER ROLE sysadmin ADD MEMBER legacy_monitor;

IF SUSER_ID(N'app_legacy') IS NOT NULL DROP LOGIN app_legacy;
CREATE LOGIN app_legacy WITH PASSWORD = N'legacy123', CHECK_POLICY = OFF, CHECK_EXPIRATION = OFF,
       DEFAULT_DATABASE = LegacyShop;

IF SUSER_ID(N'atencion01') IS NULL
    CREATE LOGIN atencion01 WITH PASSWORD = N'Atencion_2026!';

-- Superficie de ataque ampliada
EXEC sp_configure 'show advanced options', 1;  RECONFIGURE;
EXEC sp_configure 'clr enabled', 1;            RECONFIGURE;
EXEC sp_configure 'clr strict security', 0;    RECONFIGURE;
EXEC sp_configure 'Ad Hoc Distributed Queries', 1; RECONFIGURE;
BEGIN TRY
    EXEC sp_configure 'xp_cmdshell', 1; RECONFIGURE;   -- en Linux puede no estar disponible
END TRY
BEGIN CATCH
    PRINT 'xp_cmdshell no configurable en esta plataforma (normal en Linux).';
END CATCH

-- Sin auditoría
IF EXISTS (SELECT 1 FROM sys.server_audit_specifications WHERE name = N'Spec_Servidor')
BEGIN
    ALTER SERVER AUDIT SPECIFICATION Spec_Servidor WITH (STATE = OFF);
    DROP SERVER AUDIT SPECIFICATION Spec_Servidor;
END
GO
USE LegacyShop;
GO
IF EXISTS (SELECT 1 FROM sys.database_audit_specifications WHERE name = N'Spec_DatosSensibles')
BEGIN
    ALTER DATABASE AUDIT SPECIFICATION Spec_DatosSensibles WITH (STATE = OFF);
    DROP DATABASE AUDIT SPECIFICATION Spec_DatosSensibles;
END
GO
USE master;
GO
IF EXISTS (SELECT 1 FROM sys.server_audits WHERE name = N'Audit_LegacyShop')
BEGIN
    ALTER SERVER AUDIT Audit_LegacyShop WITH (STATE = OFF);
    DROP SERVER AUDIT Audit_LegacyShop;
END
-- Propietario con privilegios + TRUSTWORTHY: vía de escalada conocida
ALTER AUTHORIZATION ON DATABASE::LegacyShop TO legacy_monitor;
ALTER DATABASE LegacyShop SET TRUSTWORTHY ON;
GO
USE LegacyShop;
GO
IF USER_ID(N'app_legacy') IS NOT NULL DROP USER app_legacy;
CREATE USER app_legacy FOR LOGIN app_legacy;
ALTER ROLE db_owner ADD MEMBER app_legacy;

IF USER_ID(N'atencion01') IS NULL CREATE USER atencion01 FOR LOGIN atencion01;
ALTER ROLE rol_atencion_cliente ADD MEMBER atencion01;
GRANT SELECT ON dbo.Clientes TO rol_atencion_cliente;     -- IBAN y FechaNacimiento visibles
GRANT CONNECT TO guest;
GO
/* ---------------------------------------------------------------------
   R8. Punto de partida limpio para medir
   --------------------------------------------------------------------- */
TRUNCATE TABLE dbo.CargaErrores;
ALTER DATABASE LegacyShop SET QUERY_STORE CLEAR;
DBCC SQLPERF ('sys.dm_os_wait_stats', CLEAR);
CHECKPOINT;
PRINT CONCAT(SYSDATETIME(), '  LegacyShop en estado incidente. Arrancad la carga con:');
PRINT '  powershell -ExecutionPolicy Bypass -File .\datos\carga\carga.ps1 -Sesiones 8 -Segundos 1800';
GO
