# Lab 5A · Leer planes y cazar conversiones implícitas

**Sesión 3 · Duración: 55 minutos · Base de datos: LegacyShop**

Este laboratorio entrena el método de lectura de planes en cinco pasadas que vimos en la sesión: forma general y coste, avisos, estimadas frente a reales, operadores caros y propiedades del SELECT. Lo aplicaréis a tres consultas de LegacyShop, reproduciréis el famoso "en SSMS va rápido pero en la aplicación va lento", y cazaréis y corregiréis una conversión implícita que está costando miles de lecturas por segundo en producción.

Trabajad siempre con el plan real (Ctrl+M) y con `SET STATISTICS IO, TIME ON`.

## Paso 1 · Cinco pasadas sobre tres planes (20 minutos)

Ejecutad cada consulta, guardad el plan (clic derecho, "Save Execution Plan As...") y rellenad la ficha.

```sql
USE LegacyShop;
SET STATISTICS IO, TIME ON;

-- Plan A
EXEC dbo.usp_InformeVentasMensual @Anio = 2025;
-- Plan B
EXEC dbo.usp_HistoricoCliente @ClienteID = 42;
-- Plan C
EXEC dbo.usp_UltimosPedidosLineaPrincipal @ClienteID = 42;
```

| Pasada | Plan A | Plan B | Plan C |
|---|---|---|---|
| 1 · Forma y operador más costoso | | | |
| 2 · Avisos (triángulos amarillos) | | | |
| 3 · Mayor diferencia estimadas / reales (operador y factor) | | | |
| 4 · Operadores caros (scans, lookups, sorts, spools) | | | |
| 5 · SELECT: concesión de memoria, DOP, CompileTime, razón de no paralelismo | | | |

Pista para el plan A: el procedimiento tiene dos sentencias; el `INSERT` en la variable de tabla siempre es serie. Mirad la propiedad `NonParallelPlanReason` del segundo `SELECT`: una función escalar no inlineable lo impide.

## Paso 2 · "En SSMS va rápido" (10 minutos)

La aplicación se conecta con `ARITHABORT OFF` (valor por defecto de ADO.NET y ODBC), mientras que SSMS usa `ARITHABORT ON`. Como es una opción que forma parte de la clave de la caché de planes, cada uno obtiene su propio plan, compilado con valores de parámetro distintos.

```sql
ALTER DATABASE SCOPED CONFIGURATION CLEAR PROCEDURE_CACHE;
ALTER DATABASE LegacyShop SET COMPATIBILITY_LEVEL = 150;    -- sin PSP, para que el efecto sea nítido

-- "La aplicación" compila con el cliente 1
SET ARITHABORT OFF;
EXEC dbo.usp_PedidosPorCliente @ClienteID = 1;
EXEC dbo.usp_PedidosPorCliente @ClienteID = 42;   -- en la app va lento: plan de scan

-- "El DBA en SSMS"
SET ARITHABORT ON;
EXEC dbo.usp_PedidosPorCliente @ClienteID = 42;   -- en SSMS va rápido: compila su propio plan
```

Comprobad que hay dos planes en caché para el mismo procedimiento y que difieren en los atributos de sesión:

```sql
SELECT cp.plan_handle, cp.usecounts, pa.value AS set_options
FROM sys.dm_exec_cached_plans cp
CROSS APPLY sys.dm_exec_plan_attributes(cp.plan_handle) pa
CROSS APPLY sys.dm_exec_sql_text(cp.plan_handle) t
WHERE t.objectid = OBJECT_ID('dbo.usp_PedidosPorCliente') AND pa.attribute = 'set_options';
```

La lección: para reproducir un problema de la aplicación en SSMS hay que usar sus mismas opciones de sesión, o mejor, obtener el plan que está usando la aplicación desde la caché o desde Query Store en lugar de ejecutar la consulta a mano.

```sql
SET ARITHABORT ON;
ALTER DATABASE LegacyShop SET COMPATIBILITY_LEVEL = 160;
```

## Paso 3 · Localizar la conversión implícita en la caché (10 minutos)

Generad algo de actividad de búsqueda de clientes tal como la enviaría la aplicación, con un literal Unicode:

```sql
DECLARE @i int = 0, @c nvarchar(20);
WHILE @i < 200
BEGIN
    SET @c = CONCAT(N'CLI-', RIGHT(N'0000000' + CAST(1 + ABS(CHECKSUM(NEWID()) % 100000) AS nvarchar(7)), 7));
    EXEC dbo.usp_BuscarClientePorCodigo @Codigo = @c;
    SET @i += 1;
END
```

Ejecutad `scripts/conversiones_implicitas_cache.sql`. Deberíais ver `usp_BuscarClientePorCodigo` con el aviso `Seek Plan` y la expresión `CONVERT_IMPLICIT(nvarchar(20),[LegacyShop].[dbo].[Clientes].[CodigoCliente],0)`. Fijaos en que la conversión se aplica a la **columna**, no al parámetro: es la columna la que pierde por precedencia de tipos.

## Paso 4 · Corregir y medir (10 minutos)

Medid primero:

```sql
EXEC dbo.usp_BuscarClientePorCodigo @Codigo = N'CLI-0004242';
```

Apuntad lecturas lógicas de `Clientes`, tiempo de CPU y el operador que accede a `IX_Clientes_Codigo` (Index Scan). Corregid el tipo del parámetro:

```sql
CREATE OR ALTER PROCEDURE dbo.usp_BuscarClientePorCodigo @Codigo varchar(20)
AS
SET NOCOUNT ON;
SELECT ClienteID, CodigoCliente, Nombre, Email, Telefono, Segmento
FROM dbo.Clientes
WHERE CodigoCliente = @Codigo;
GO
EXEC dbo.usp_BuscarClientePorCodigo @Codigo = N'CLI-0004242';   -- la app sigue enviando NVARCHAR
```

Aunque la aplicación siga enviando un valor Unicode, ahora la conversión se hace una sola vez sobre el parámetro al entrar en el procedimiento y la búsqueda es un Index Seek.

| Versión | Operador sobre IX_Clientes_Codigo | Lecturas lógicas | CPU (ms) |
|---|---|---|---|
| Parámetro NVARCHAR(20) | | | |
| Parámetro VARCHAR(20) | | | |

Multiplicad la diferencia de lecturas por las búsquedas por hora que haría la atención al cliente (supongamos 20.000) para dimensionar el impacto.


## Paso 5 · ¿Dónde nace el error de estimación? (5 minutos)

Volved al plan B (`usp_HistoricoCliente` con el cliente 1 esta vez) y recorred el plan de derecha a izquierda comparando filas estimadas y reales en cada operador. Identificad el primer operador donde el error supera un factor de 10. Ese es el punto donde hay que actuar; los errores de los operadores a su izquierda son consecuencia de él.

```sql
EXEC dbo.usp_HistoricoCliente @ClienteID = 1;   -- puede tardar: detenedlo a los 60 s si hace falta
```

Si la consulta no termina en un tiempo razonable, usad el plan estimado (Ctrl+L) o Live Query Statistics para ver el flujo. Este procedimiento lo reescribiréis con funciones de ventana en el Lab 6.

## Para la puesta en común

¿Por qué la conversión implícita no impediría el seek si la base usara una intercalación Windows como `Latin1_General_CI_AS`? ¿Cómo encontraríais conversiones implícitas en Query Store en vez de en la caché? ¿Qué le diríais al equipo de desarrollo sobre los tipos de parámetros de su ORM?
