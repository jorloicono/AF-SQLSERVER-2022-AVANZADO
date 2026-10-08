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
datos/    Script de creación de LegacyShop y scripts de carga concurrente en PowerShell
scripts/  Consultas de diagnóstico reutilizables (esperas, I/O, Query Store, bloqueos, deadlocks, hardening)
setup/    Guía de preparación del entorno
```

## Antes de la primera sesión

Necesitáis SQL Server 2022 (recomendada la edición Developer, gratuita) instalado en Windows y SSMS 21 o posterior. Seguid `setup/README.md` para comprobar la instancia y crear LegacyShop: basta con abrir `datos/01_crear_LegacyShop.sql` en SSMS y pulsar F5. Llegad a la primera sesión con la base creada, porque tarda unos minutos y conviene no perder tiempo de clase en ello.

Los laboratorios que necesitan muchas sesiones concurrentes usan los scripts de PowerShell de `datos/carga/`, que funcionan en cualquier Windows sin instalar nada más.

## Aviso

LegacyShop contiene defectos de rendimiento y de seguridad deliberados, y algunos laboratorios crean logins con contraseñas débiles y amplían la superficie de ataque de la instancia. Usad este material solo en vuestra instancia local de prácticas, nunca en un servidor compartido o de producción.
