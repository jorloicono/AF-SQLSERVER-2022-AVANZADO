# Preparación del entorno de prácticas

El curso se imparte sobre SQL Server 2022 Developer Edition en un contenedor Docker oficial de Microsoft. Es la forma más rápida de que todos los alumnos tengan exactamente el mismo motor, la misma base de datos y los mismos scripts, sea cual sea su sistema operativo. Las pocas funcionalidades que no existen en SQL Server sobre Linux (Buffer Pool Extension, enclaves VBS de Always Encrypted, xp_cmdshell) se tratan de forma teórica y, para quien quiera probarlas, se explica al final cómo hacerlo en una máquina virtual Windows.

## Requisitos

Hace falta Docker Desktop (Windows o macOS) o Docker Engine (Linux) con al menos 4 GB de memoria asignados, idealmente 6 GB, y unos 12 GB libres en disco. Como cliente se recomienda SQL Server Management Studio 21 o posterior en Windows, porque los planes de ejecución, el visor de deadlocks, los informes de Query Store y el asistente de Always Encrypted se ven mejor ahí. En macOS o Linux se puede usar Visual Studio Code con la extensión MSSQL; en ese caso el Lab 9 (Always Encrypted) se hace en pareja con alguien que tenga SSMS en Windows.

En Mac con Apple Silicon la imagen x64 funciona mediante emulación (Rosetta en Docker Desktop). Es más lenta; conviene activar "Use Rosetta for x86/amd64 emulation" en la configuración de Docker Desktop.

## Paso 1 · Levantar el contenedor

Desde la carpeta `setup/` del repositorio:

```bash
docker compose up -d
docker logs -f sql2022        # esperar a "SQL Server is now ready for client connections" y salir con Ctrl+C
```

Crea las carpetas de auditoría y backups con los permisos del usuario `mssql` (se usan en los labs 4 y 11):

```bash
docker exec -u root sql2022 bash -c "mkdir -p /var/opt/mssql/audit /var/opt/mssql/backup && chown -R mssql /var/opt/mssql/audit /var/opt/mssql/backup"
```

## Paso 2 · Crear LegacyShop

```bash
docker exec -it sql2022 /opt/mssql-tools18/bin/sqlcmd -C -S localhost -U sa -P 'Curso_SQL2022!' -i /datos/01_crear_LegacyShop.sql
```

Tarda entre 3 y 6 minutos. Al final muestra una tabla de comprobación que debe indicar 100.000 clientes, 1.200.000 pedidos (250.000 del cliente 1), unos 2.000 pedidos pendientes y 3.600.000 líneas. Si en algún momento queréis volver al punto de partida, basta con relanzar este script: borra y recrea la base de datos.

## Paso 3 · Conectar el cliente

Servidor `localhost,1433`, autenticación SQL Server, usuario `sa`, contraseña `Curso_SQL2022!`. En SSMS 21 marcad "Trust server certificate" (el contenedor usa un certificado autofirmado). En VS Code, `"trustServerCertificate": true`.

Comprobación rápida:

```sql
SELECT @@VERSION;
SELECT name, compatibility_level, is_query_store_on FROM sys.databases WHERE name = 'LegacyShop';
```

## Carga concurrente

Varios laboratorios necesitan muchas sesiones a la vez. En Linux no hay ostress, así que el repositorio incluye un lanzador en bash que abre N sesiones de sqlcmd dentro del contenedor:

```bash
docker exec sql2022 bash /datos/carga/concurrente.sh 16 60 "EXEC dbo.usp_TempdbCarga"
docker exec sql2022 bash /datos/carga/parar.sh
```

Las sesiones se identifican con `host_name` que empieza por `LegacyShop`, de modo que se pueden localizar en `sys.dm_exec_sessions`.

## Sesión 6 · Taller integrador

Antes del taller se recrea la base y se pasa al "estado incidente" con el script `99_romper_LegacyShop.sql`, que el instructor entrega ese mismo día (copiadlo en `datos/`):

```bash
docker exec -it sql2022 /opt/mssql-tools18/bin/sqlcmd -C -S localhost -U sa -P 'Curso_SQL2022!' -i /datos/01_crear_LegacyShop.sql
docker exec -it sql2022 /opt/mssql-tools18/bin/sqlcmd -C -S localhost -U sa -P 'Curso_SQL2022!' -i /datos/99_romper_LegacyShop.sql
docker exec -d sql2022 bash /datos/carga/carga.sh 8 1800
```

## Opcional · VM Windows para BPE y enclaves VBS

Para practicar Buffer Pool Extension y Always Encrypted con enclaves VBS hace falta SQL Server 2022 sobre Windows Server 2019/2022 o Windows 10/11 (Developer Edition es gratuita). Tras instalar, el enclave se activa con `sp_configure 'column encryption enclave type', 1; RECONFIGURE;` y un reinicio del servicio, y se conecta con atestación `None` (solo pruebas; en producción se usa Host Guardian Service). BPE se activa con `ALTER SERVER CONFIGURATION SET BUFFER POOL EXTENSION ON (FILENAME = 'E:\bpe\bpe.bpe', SIZE = 16 GB);`. Nada de esto es necesario para seguir el curso.

## Problemas frecuentes

Si el contenedor se para nada más arrancar, casi siempre es memoria insuficiente (SQL Server exige al menos 2 GB) o una contraseña de `sa` que no cumple la complejidad mínima. Si `sqlcmd` no existe en `/opt/mssql-tools18/bin`, las imágenes antiguas lo tienen en `/opt/mssql-tools/bin` (sin `-C`); los scripts de carga detectan ambas rutas. Si el puerto 1433 está ocupado por una instancia local, cambiad el mapeo a `"14333:1433"` y conectad a `localhost,14333`.
