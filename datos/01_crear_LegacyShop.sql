/* =====================================================================
   Curso SQL Server 2022 Avanzado · Base de datos de prácticas LegacyShop
   ---------------------------------------------------------------------
   Crea desde cero la base de datos LegacyShop con datos sintéticos y
   todos los objetos "legacy" (con sus defectos intencionados) que se
   usan en los laboratorios 1 a 12.

   Volumen: Clientes 100.000 · Productos 2.000 · Comerciales 50
            Pedidos ≈ 1.200.000 (cliente 1 = 250.000) · LineasPedido ≈ 3.600.000
            LogActividad ≈ 200.000 (montículo)
   Duración aproximada: 3-6 minutos en un portátil con 4 núcleos / 8 GB.

   Ejecutar en SSMS (Archivo > Abrir > este fichero, F5) conectado a vuestra
   instancia local con un login sysadmin. Los ficheros se crean en las rutas
   por defecto de la instancia.

   AVISO: los defectos de rendimiento y seguridad son DELIBERADOS.
   No uséis este código como modelo en producción.
   ===================================================================== */
SET NOCOUNT ON;
USE master;
GO
PRINT CONCAT(SYSDATETIME(), '  Creando base de datos LegacyShop...');
IF DB_ID(N'LegacyShop') IS NOT NULL
BEGIN
    ALTER DATABASE LegacyShop SET SINGLE_USER WITH ROLLBACK IMMEDIATE;
    DROP DATABASE LegacyShop;
END
GO
-- Rutas por defecto de la instancia (válido en Windows y en Linux)
DECLARE @dat nvarchar(512) = CAST(SERVERPROPERTY('InstanceDefaultDataPath') AS nvarchar(512)),
        @log nvarchar(512) = CAST(SERVERPROPERTY('InstanceDefaultLogPath')  AS nvarchar(512));
DECLARE @sql nvarchar(max) = N'
CREATE DATABASE LegacyShop
    ON PRIMARY (NAME = LegacyShop_data, FILENAME = ''' + @dat + N'LegacyShop.mdf'',
                SIZE = 1536MB, FILEGROWTH = 512MB)
    LOG ON     (NAME = LegacyShop_log,  FILENAME = ''' + @log + N'LegacyShop_log.ldf'',
                SIZE = 1024MB, FILEGROWTH = 256MB)
    COLLATE SQL_Latin1_General_CP1_CI_AS;';   -- intercalación SQL: clave para el lab de conversiones implícitas
EXEC (@sql);
GO
ALTER DATABASE LegacyShop SET RECOVERY SIMPLE;
ALTER DATABASE LegacyShop SET COMPATIBILITY_LEVEL = 160;
ALTER DATABASE LegacyShop SET READ_COMMITTED_SNAPSHOT OFF;
ALTER DATABASE LegacyShop SET AUTO_UPDATE_STATISTICS ON;
GO
USE LegacyShop;
GO
/* ---------------------------------------------------------------------
   1. Tablas
   --------------------------------------------------------------------- */
CREATE TABLE dbo.Comerciales (
    ComercialID int           NOT NULL CONSTRAINT PK_Comerciales PRIMARY KEY,
    Login       sysname       NOT NULL,
    Nombre      nvarchar(100) NOT NULL,
    Region      varchar(20)   NOT NULL
);

CREATE TABLE dbo.Clientes (
    ClienteID       int           NOT NULL CONSTRAINT PK_Clientes PRIMARY KEY,
    CodigoCliente   varchar(20)   NOT NULL,          -- VARCHAR (la aplicación envía NVARCHAR: conversión implícita)
    Nombre          nvarchar(100) NOT NULL,
    Email           varchar(120)  NOT NULL,
    Telefono        varchar(20)   NULL,
    Pais            char(2)       NOT NULL,
    Provincia       varchar(30)   NOT NULL,
    FechaAlta       date          NOT NULL,
    Segmento        varchar(12)   NOT NULL,
    Activo          bit           NOT NULL,
    IBAN            varchar(34)   NULL,              -- dato sensible en claro (Módulo 4)
    FechaNacimiento date          NULL               -- dato sensible en claro (Módulo 4)
);

CREATE TABLE dbo.Productos (
    ProductoID int           NOT NULL CONSTRAINT PK_Productos PRIMARY KEY,
    SKU        varchar(20)   NOT NULL,
    Nombre     nvarchar(120) NOT NULL,
    Categoria  varchar(30)   NOT NULL,
    PrecioBase decimal(10,2) NOT NULL,
    Activo     bit           NOT NULL
);

CREATE TABLE dbo.Pedidos (
    PedidoID      int IDENTITY(1,1) NOT NULL CONSTRAINT PK_Pedidos PRIMARY KEY,
    ClienteID     int           NOT NULL,
    FechaPedido   datetime2(0)  NOT NULL,
    Estado        tinyint       NOT NULL,   -- 1 pendiente, 2 en preparación, 3 enviado, 4 entregado, 5 cancelado
    Canal         varchar(10)   NOT NULL,
    Total         decimal(12,2) NOT NULL,
    ComercialID   int           NOT NULL,
    Observaciones varchar(500)  NULL
);

CREATE TABLE dbo.LineasPedido (
    LineaID        bigint IDENTITY(1,1) NOT NULL CONSTRAINT PK_LineasPedido PRIMARY KEY,
    PedidoID       int           NOT NULL,   -- SIN índice: deliberado (tickets de logística)
    ProductoID     int           NOT NULL,
    Cantidad       smallint      NOT NULL,
    PrecioUnitario decimal(10,2) NOT NULL,
    Descuento      decimal(5,2)  NOT NULL    -- porcentaje (0-100)
);

CREATE TABLE dbo.LogActividad (          -- montículo sin índices: deliberado
    Fecha   datetime2(3)  NOT NULL,
    Usuario sysname       NOT NULL,
    Accion  varchar(50)   NOT NULL,
    Detalle nvarchar(400) NULL
);

CREATE TABLE dbo.CargaErrores (          -- "logs de la aplicación" para el taller
    Fecha      datetime2(3)   NOT NULL DEFAULT SYSDATETIME(),
    Trabajador int            NULL,
    Operacion  varchar(40)    NULL,
    Numero     int            NULL,
    Mensaje    nvarchar(2048) NULL
);
GO
/* ---------------------------------------------------------------------
   2. Datos
   --------------------------------------------------------------------- */
PRINT CONCAT(SYSDATETIME(), '  Comerciales y productos...');
INSERT dbo.Comerciales (ComercialID, Login, Nombre, Region)
SELECT g.value,
       CONCAT('comercial', RIGHT('0' + CAST(g.value AS varchar(2)), 2)),
       CONCAT(N'Comercial ', g.value),
       CHOOSE(g.value % 5 + 1, 'Norte', 'Sur', 'Este', 'Oeste', 'Centro')
FROM GENERATE_SERIES(1, 50) AS g;

INSERT dbo.Productos (ProductoID, SKU, Nombre, Categoria, PrecioBase, Activo)
SELECT g.value,
       CONCAT('SKU-', RIGHT('00000' + CAST(g.value AS varchar(5)), 5)),
       CONCAT(CHOOSE(g.value % 6 + 1, N'Kit ', N'Pack ', N'Set ', N'Modelo ', N'Serie ', N'Edición '),
              CHOOSE(g.value % 12 + 1, N'Hogar', N'Oficina', N'Jardín', N'Cocina', N'Deporte', N'Viaje',
                     N'Infantil', N'Mascotas', N'Electrónica', N'Iluminación', N'Baño', N'Taller'),
              N' ', g.value),
       CHOOSE(g.value % 12 + 1, 'Hogar', 'Oficina', 'Jardín', 'Cocina', 'Deporte', 'Viaje',
              'Infantil', 'Mascotas', 'Electrónica', 'Iluminación', 'Baño', 'Taller'),
       CAST(5 + (g.value * 37 % 995) + (g.value % 100) / 100.0 AS decimal(10,2)),
       CASE WHEN g.value % 25 = 0 THEN 0 ELSE 1 END
FROM GENERATE_SERIES(1, 2000) AS g;
GO
PRINT CONCAT(SYSDATETIME(), '  Clientes (100.000)...');
INSERT dbo.Clientes (ClienteID, CodigoCliente, Nombre, Email, Telefono, Pais, Provincia,
                     FechaAlta, Segmento, Activo, IBAN, FechaNacimiento)
SELECT g.value,
       CONCAT('CLI-', RIGHT('0000000' + CAST(g.value AS varchar(7)), 7)),
       CASE WHEN g.value = 1 THEN N'Marketplace Global S.L.'
            ELSE CONCAT(CHOOSE(g.value % 10 + 1, N'Lucía', N'Hugo', N'Martina', N'Mateo', N'Sofía',
                                N'Leo', N'Julia', N'Daniel', N'Paula', N'Álvaro'), N' ',
                        CHOOSE(g.value % 13 + 1, N'García', N'Fernández', N'González', N'Rodríguez',
                                N'López', N'Martínez', N'Sánchez', N'Pérez', N'Gómez', N'Martín',
                                N'Jiménez', N'Ruiz', N'Hernández')) END,
       CONCAT(CHOOSE(g.value % 10 + 1, 'lucia', 'hugo', 'martina', 'mateo', 'sofia',
                     'leo', 'julia', 'daniel', 'paula', 'alvaro'), '.', g.value, '@example.com'),
       CONCAT('6', RIGHT('00000000' + CAST(ABS(CHECKSUM(g.value * 7919) % 100000000) AS varchar(8)), 8)),
       CASE WHEN g.value % 50 = 0 THEN 'PT' ELSE 'ES' END,
       CHOOSE(g.value % 10 + 1, 'Madrid', 'Barcelona', 'Valencia', 'Sevilla', 'Bizkaia',
              'Málaga', 'Zaragoza', 'Asturias', 'A Coruña', 'Murcia'),
       DATEADD(DAY, -(g.value * 37 % 5000), CAST('2026-06-30' AS date)),
       CASE WHEN g.value = 1 THEN 'Empresa'
            ELSE CHOOSE(g.value % 4 + 1, 'Particular', 'Pyme', 'Empresa', 'VIP') END,
       CASE WHEN g.value % 20 = 0 THEN 0 ELSE 1 END,
       CONCAT('ES', RIGHT('00' + CAST(g.value % 97 AS varchar(2)), 2),
              RIGHT('0000000000' + CAST(ABS(CHECKSUM(CAST(g.value AS bigint) * 104729) % 1000000000) AS varchar(10)), 10),
              RIGHT('0000000000' + CAST(ABS(CHECKSUM(CAST(g.value AS bigint) * 1299709) % 1000000000) AS varchar(10)), 10)),
       DATEADD(DAY, -(6570 + g.value * 131 % 20000), CAST('2026-01-01' AS date))
FROM GENERATE_SERIES(1, 100000) AS g;
GO
/* Pedidos: distribución deliberadamente sesgada
   - residuo 0-4 de 24  -> cliente 1 (250.000 pedidos, "marketplace")
   - residuo 5, k%5 = 0 -> clientes 90.001-100.000, un pedido cada uno
   - resto              -> clientes 2-90.000, ≈ 10 pedidos cada uno          */
PRINT CONCAT(SYSDATETIME(), '  Pedidos (1.200.000)...');
SET IDENTITY_INSERT dbo.Pedidos ON;
INSERT dbo.Pedidos WITH (TABLOCK)
       (PedidoID, ClienteID, FechaPedido, Estado, Canal, Total, ComercialID, Observaciones)
SELECT g.value,
       CASE WHEN g.value % 24 < 5 THEN 1
            WHEN g.value % 24 = 5 AND (g.value / 24) % 5 = 0 THEN 90001 + (g.value / 120) % 10000
            ELSE 2 + CAST((CAST(g.value AS bigint) * 7919) % 89999 AS int) END,
       DATEADD(SECOND, g.value * 131, CAST('2021-07-01T08:00:00' AS datetime2(0))),
       CASE WHEN g.value > 1198000 THEN 1 + g.value % 2          -- ≈ 2.000 pedidos pendientes
            WHEN g.value % 50 = 0 THEN 5
            WHEN g.value > 1190000 THEN 3
            ELSE 4 END,
       CHOOSE(g.value % 3 + 1, 'WEB', 'TIENDA', 'TELEFONO'),
       0,
       1 + g.value % 50,
       CASE WHEN g.value % 10 = 0 THEN 'Entregar en horario de mañana. Llamar antes de subir.'
            WHEN g.value % 37 = 0 THEN REPLICATE('Incidencia registrada por atención al cliente. ', 6)
            ELSE NULL END
FROM GENERATE_SERIES(1, 1200000) AS g;
SET IDENTITY_INSERT dbo.Pedidos OFF;
GO
PRINT CONCAT(SYSDATETIME(), '  LineasPedido (3.600.000)...');
INSERT dbo.LineasPedido WITH (TABLOCK) (PedidoID, ProductoID, Cantidad, PrecioUnitario, Descuento)
SELECT x.PedidoID, x.ProductoID, x.Cantidad, pr.PrecioBase, x.Descuento
FROM (
    SELECT g.value AS PedidoID,
           1 + (g.value * 31 + n.n * 17) % 2000 AS ProductoID,
           CAST(1 + (g.value + n.n) % 5 AS smallint) AS Cantidad,
           CAST(CASE WHEN (g.value + n.n) % 10 = 0 THEN 10 ELSE 0 END AS decimal(5,2)) AS Descuento,
           n.n
    FROM GENERATE_SERIES(1, 1200000) AS g
    CROSS JOIN (VALUES (1), (2), (3)) AS n(n)
) AS x
JOIN dbo.Productos pr ON pr.ProductoID = x.ProductoID
ORDER BY x.PedidoID, x.n
OPTION (MAXDOP 1);   -- conserva las líneas de cada pedido contiguas
GO
PRINT CONCAT(SYSDATETIME(), '  Totales de pedidos (excepto pendientes)...');
UPDATE p SET p.Total = t.Total
FROM dbo.Pedidos p
JOIN (SELECT PedidoID, SUM(Cantidad * PrecioUnitario * (1 - Descuento / 100)) AS Total
      FROM dbo.LineasPedido GROUP BY PedidoID) t ON t.PedidoID = p.PedidoID
WHERE p.Estado NOT IN (1, 2);      -- los pendientes quedan a 0: trabajo para usp_RecalcularTotales
GO
PRINT CONCAT(SYSDATETIME(), '  LogActividad (200.000)...');
INSERT dbo.LogActividad WITH (TABLOCK) (Fecha, Usuario, Accion, Detalle)
SELECT DATEADD(SECOND, g.value * 787, CAST('2022-01-01' AS datetime2(3))),
       CHOOSE(g.value % 4 + 1, N'app_web', N'app_tienda', N'batch_nocturno', N'soporte'),
       CHOOSE(g.value % 5 + 1, 'LOGIN', 'CONSULTA', 'ALTA_PEDIDO', 'MODIF_PEDIDO', 'EXPORT'),
       CONCAT(N'Operación de ejemplo ', g.value)
FROM GENERATE_SERIES(1, 200000) AS g;
GO
/* ---------------------------------------------------------------------
   3. Índices (IX_Pedidos_ClienteID se crea el primero: stats_id = 2)
   --------------------------------------------------------------------- */
PRINT CONCAT(SYSDATETIME(), '  Índices...');
CREATE INDEX IX_Pedidos_ClienteID    ON dbo.Pedidos (ClienteID);        -- estrecho, no cubriente (Lab 7)
CREATE INDEX IX_Pedidos_FechaPedido  ON dbo.Pedidos (FechaPedido);      -- estrecho
CREATE INDEX IX_Clientes_Codigo      ON dbo.Clientes (CodigoCliente);
CREATE INDEX IX_Productos_Nombre     ON dbo.Productos (Nombre);
GO
UPDATE STATISTICS dbo.Pedidos  WITH FULLSCAN;
UPDATE STATISTICS dbo.Clientes WITH FULLSCAN;
UPDATE STATISTICS dbo.Productos WITH FULLSCAN;
GO
/* ---------------------------------------------------------------------
   4. Funciones escalares
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
   5. Procedimientos legacy (defectos deliberados indicados en comentario)
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
   6. Disparador legacy: solo audita UNA fila en operaciones multifila
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
   7. Seguridad "heredada" (Módulo 4)
   --------------------------------------------------------------------- */
CREATE ROLE rol_direccion;
CREATE ROLE rol_atencion_cliente;
GRANT SELECT ON SCHEMA::dbo TO rol_direccion;
GRANT SELECT ON dbo.Clientes TO rol_atencion_cliente;      -- incluye IBAN y FechaNacimiento
GRANT SELECT ON dbo.Pedidos  TO rol_atencion_cliente;
GRANT EXECUTE ON dbo.usp_BuscarClientePorCodigo TO rol_atencion_cliente;
GO
USE master;
GO
-- Usuario de la herramienta de monitorización con sysadmin (Lab 10, taller)
IF SUSER_ID(N'legacy_monitor') IS NULL
    CREATE LOGIN legacy_monitor WITH PASSWORD = N'Monitor_2015!', CHECK_POLICY = OFF;
ALTER SERVER ROLE sysadmin ADD MEMBER legacy_monitor;
GO
/* ---------------------------------------------------------------------
   8. Query Store (intervalos de 5 min para ver resultados en clase)
   --------------------------------------------------------------------- */
ALTER DATABASE LegacyShop SET QUERY_STORE = ON;
ALTER DATABASE LegacyShop SET QUERY_STORE (
    OPERATION_MODE = READ_WRITE,
    QUERY_CAPTURE_MODE = ALL,
    INTERVAL_LENGTH_MINUTES = 5,
    MAX_STORAGE_SIZE_MB = 1024,
    WAIT_STATS_CAPTURE_MODE = ON);
ALTER DATABASE LegacyShop SET QUERY_STORE CLEAR;
GO
USE LegacyShop;
GO
CHECKPOINT;
PRINT CONCAT(SYSDATETIME(), '  Comprobación final:');
SELECT 'Clientes' AS Tabla, COUNT_BIG(*) AS Filas FROM dbo.Clientes
UNION ALL SELECT 'Productos', COUNT_BIG(*) FROM dbo.Productos
UNION ALL SELECT 'Pedidos', COUNT_BIG(*) FROM dbo.Pedidos
UNION ALL SELECT 'Pedidos cliente 1', COUNT_BIG(*) FROM dbo.Pedidos WHERE ClienteID = 1
UNION ALL SELECT 'Pedidos pendientes (1,2)', COUNT_BIG(*) FROM dbo.Pedidos WHERE Estado IN (1, 2)
UNION ALL SELECT 'LineasPedido', COUNT_BIG(*) FROM dbo.LineasPedido
UNION ALL SELECT 'LogActividad', COUNT_BIG(*) FROM dbo.LogActividad;
PRINT CONCAT(SYSDATETIME(), '  LegacyShop creada.');
GO
