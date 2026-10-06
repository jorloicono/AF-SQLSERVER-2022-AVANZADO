# SQL Server 2022 Avanzado

Material del alumno del curso **SQL Server 2022 (Avanzado)**: 24 horas en seis sesiones de cuatro.

Todo el curso gira en torno a LegacyShop, una tienda online ficticia con quince años de código heredado, 1,2 millones de pedidos y 3,6 millones de líneas. En ella se han sembrado a propósito los problemas de rendimiento, concurrencia y seguridad más habituales en sistemas reales. Cada sesión combina teoría con laboratorios guiados en los que mediréis el antes y el después de cada cambio, y la última sesión es un taller por equipos para rescatar LegacyShop bajo una carga simulada.

## Temario

| Sesión | Contenido | Laboratorios |
|---|---|---|
| 1 · Novedades del motor y rendimiento | Intelligent Query Processing, Parameter Sensitive Plan Optimization, feedback de memoria, DOP y CE, Query Store | Lab 1, Lab 2 |
| 2 · Disco y almacenamiento | Arquitectura de I/O, tempdb, Buffer Pool Extension, Hybrid Buffer Pool, esperas de I/O | Lab 3, Lab 4 |
| 3 · Queries lentas (I) | Planes de ejecución, estimación, conversiones implícitas, spills, lookups, funciones escalares | Lab 5A, Lab 5B |
| 4 · Queries lentas (II) | De RBAR a conjuntos, CTEs, ventanas, temporales, índices, hints, bloqueos y deadlocks | Lab 6, Lab 7, Lab 8 |
| 5 · Seguridad avanzada | Always Encrypted, Ledger, RLS, Dynamic Data Masking, roles de 2022, auditoría y hardening | Lab 9, Lab 10, Lab 11 |
| 6 · Taller integrador | Troubleshooting, refactorización y auditoría de seguridad por equipos | Lab 12 |

## Contenido del repositorio

```
slides/   Presentaciones de cada sesión en PDF
labs/     Laboratorios guiados (Lab01 … Lab12)
datos/    Script de creación de LegacyShop y scripts de carga concurrente
scripts/  Consultas de diagnóstico reutilizables (esperas, I/O, Query Store, bloqueos, deadlocks, hardening)
setup/    docker-compose.yml y guía de preparación del entorno
```

## Antes de la primera sesión

Seguid `setup/README.md` para levantar SQL Server 2022 en Docker y crear LegacyShop. Llegad a la primera sesión con el contenedor funcionando: la creación de la base tarda unos minutos y conviene no perder tiempo de clase en ello.

```bash
cd setup
docker compose up -d
docker exec -u root sql2022 bash -c "mkdir -p /var/opt/mssql/audit /var/opt/mssql/backup && chown -R mssql /var/opt/mssql/audit /var/opt/mssql/backup"
docker exec -it sql2022 /opt/mssql-tools18/bin/sqlcmd -C -S localhost -U sa -P 'Curso_SQL2022!' -i /datos/01_crear_LegacyShop.sql
```

Como cliente se recomienda SSMS 21 o posterior en Windows. En macOS o Linux sirve Visual Studio Code con la extensión MSSQL; en ese caso, el Lab 9 (Always Encrypted) se hace en pareja con alguien que tenga SSMS en Windows.

## Aviso

LegacyShop contiene defectos de rendimiento y de seguridad deliberados, y la contraseña de `sa` del entorno es pública. Usad este material solo en vuestro entorno local de prácticas.
