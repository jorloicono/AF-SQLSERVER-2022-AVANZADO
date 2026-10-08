# Preparación del entorno de prácticas (Windows)

El curso se hace sobre SQL Server 2022 instalado en vuestro propio Windows, con SSMS como cliente. Todo lo que necesitáis para los laboratorios (la base de datos de prácticas, los scripts de diagnóstico y los lanzadores de carga concurrente) está en este repositorio y funciona sin Docker ni herramientas adicionales.

## Requisitos

Necesitáis Windows 10/11 o Windows Server con al menos 8 GB de RAM y unos 12 GB libres en disco, una instancia de **SQL Server 2022** y **SSMS 21** o posterior.

La edición recomendada es **Developer**, que es gratuita y tiene todas las funcionalidades de Enterprise. Con **Express** se pueden seguir casi todos los laboratorios, pero hay dos limitaciones: los índices `ONLINE` del Lab 7 no están disponibles (quitad `ONLINE = ON`) y su límite de 10 GB por base y de memoria hace que algunas cifras de rendimiento sean muy distintas.

Para la autenticación sirven tanto vuestro usuario de Windows (si es sysadmin de la instancia) como el login `sa`. Algunos laboratorios crean logins SQL, así que conviene que la instancia esté en **modo mixto** (SSMS → clic derecho en el servidor → Propiedades → Seguridad → "Modo de autenticación de SQL Server y Windows", y reiniciar el servicio).

## Paso 1 · Comprobar la instancia

Conectad SSMS a vuestra instancia (`localhost` para la instancia por defecto, `.\SQLEXPRESS` o `.\NOMBRE` para una instancia con nombre). Si SSMS muestra un error de certificado, marcad **Trust server certificate**. Después ejecutad:

```sql
SELECT @@VERSION;                                  -- debe indicar SQL Server 2022
SELECT SERVERPROPERTY('Edition') AS edicion,
       SERVERPROPERTY('InstanceDefaultDataPath')   AS carpeta_datos,
       SERVERPROPERTY('InstanceDefaultBackupPath') AS carpeta_backups;
SELECT IS_SRVROLEMEMBER('sysadmin') AS soy_sysadmin;  -- debe devolver 1
```

## Paso 2 · Crear LegacyShop

En SSMS: Archivo → Abrir → Archivo, abrid `datos/01_crear_LegacyShop.sql` y pulsad F5. Tarda entre 3 y 6 minutos y crea los ficheros en las carpetas por defecto de vuestra instancia. Al final muestra una tabla de comprobación que debe indicar 100.000 clientes, 1.200.000 pedidos (250.000 del cliente 1), unos 2.000 pedidos pendientes y 3.600.000 líneas. Si en algún momento queréis volver al punto de partida, basta con relanzar este script: borra y recrea la base de datos.

## Carga concurrente

Varios laboratorios necesitan muchas sesiones ejecutando consultas a la vez. Para eso el repositorio incluye tres scripts de PowerShell en `datos/carga/` que no necesitan instalar nada (usan el cliente de SQL Server que ya trae Windows):

- `concurrente.ps1` abre N sesiones que repiten la misma sentencia durante un tiempo.
- `carga.ps1` lanza la carga simulada del taller de la sesión 6.
- `parar.ps1` detiene cualquiera de las dos.

Se ejecutan desde una ventana de PowerShell abierta en la carpeta del repositorio (en el Explorador de archivos, Shift + clic derecho dentro de la carpeta → "Abrir ventana de PowerShell aquí"):

```powershell
powershell -ExecutionPolicy Bypass -File .\datos\carga\concurrente.ps1 -Sesiones 16 -Segundos 60 -Sql "EXEC dbo.usp_TempdbCarga"
powershell -ExecutionPolicy Bypass -File .\datos\carga\parar.ps1
```

El `-ExecutionPolicy Bypass` evita tener que cambiar la política de ejecución de scripts del equipo. Por defecto los scripts se conectan a `localhost`, a la base `LegacyShop`, con vuestro usuario de Windows. Se puede cambiar con estos parámetros:

- `-Servidor ".\SQLEXPRESS"` para una instancia con nombre.
- `-Usuario sa -Password "vuestra_contraseña"` para entrar con un login SQL.
- `-BaseDatos` para usar otra base.

La ventana que lanza la carga queda ocupada hasta que termina. Las sesiones se identifican en SQL Server por `host_name`, que empieza por `LegacyShop`, así que se pueden localizar en `sys.dm_exec_sessions`. Cerrar esa ventana de PowerShell también detiene la carga.

## Sesión 6 · Taller integrador

Antes del taller, el instructor os entregará `99_romper_LegacyShop.sql`. Copiadlo en `datos/` y seguid el apartado "Preparación del entorno" de `labs/Lab12_Taller_Integrador.md`: recrear la base con el script 01, ejecutar el 99 y arrancar `carga.ps1`.

## Opcional · Enclave VBS para Always Encrypted

El Lab 9 se hace sin enclave. Si queréis probar las operaciones con enclave (rangos, `LIKE` y ordenación sobre datos cifrados), en vuestra instancia de Windows podéis activarlo con `EXEC sp_configure 'column encryption enclave type', 1; RECONFIGURE;`, reiniciar el servicio y conectaros desde SSMS con el protocolo de atestación **None**. Ese protocolo solo sirve para pruebas; en producción se usa Host Guardian Service. No es necesario para seguir el curso.

## Problemas frecuentes

**No conecta.** Comprobad en SQL Server Configuration Manager que el servicio está iniciado y usad el nombre exacto de la instancia. Para Express suele ser `.\SQLEXPRESS`.

**Error de certificado al conectar.** Marcad "Trust server certificate" en SSMS. Los scripts de PowerShell ya lo llevan.

**Error 18456 con `sa`.** La instancia está en modo solo Windows o `sa` está deshabilitado. Activad el modo mixto (ver Requisitos) y habilitad `sa` en Seguridad → Inicios de sesión.

**El script de PowerShell no se ejecuta.** Lanzadlo siempre con `powershell -ExecutionPolicy Bypass -File ...`, no con doble clic. Si estáis en PowerShell 7 (`pwsh`), funciona igual.

**"No tiene permiso" en los labs de servidor (tempdb, auditoría, roles).** Vuestro login necesita ser sysadmin.
