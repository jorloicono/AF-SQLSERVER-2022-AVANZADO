# Lab 12 · Taller integrador: el rescate de LegacyShop

**Sesión 6 · Duración: 150 minutos de trabajo + 5 minutos de presentación por equipo · Equipos de 3-4 personas**

Este laboratorio no tiene pasos guiados. Tiene un escenario, unas reglas, unas plantillas y todas las herramientas que habéis usado durante el curso. Vuestro trabajo es diagnosticar con evidencias, arreglar lo más rentable, medir el antes y el después, auditar la seguridad y convencer al comité de dirección de vuestro plan.

## El escenario

Es lunes, las 9:15. Durante el fin de semana se han desplegado cambios sin revisar en LegacyShop y el equipo de sistemas ha recibido estos tickets:

1. **Atención al cliente**: "Buscar un cliente por su código tarda 3-4 segundos y a veces da timeout."
2. **Dirección comercial**: "El informe mensual de ventas no termina; lo lanzamos a las 8 y a las 9 seguía."
3. **Logística**: "Abrir el detalle de un pedido es lentísimo y el disco del servidor está al 100 %."
4. **Grandes cuentas**: "Los pedidos de nuestro mayor cliente van bien un día y fatal al siguiente."
5. **Operaciones**: "El recálculo de totales de las 7:00 bloquea la web y ha habido errores 1205."
6. **Seguridad (CISO)**: "Queremos una auditoría antes del comité; hay dudas sobre quién ve los datos bancarios."

Puede haber problemas que no aparezcan en ningún ticket. Si los encontráis, cuentan.

## Roles

**Líder de incidente**: prioriza, controla el tiempo, decide qué se cambia y mantiene el registro de cambios. **Analista de rendimiento**: esperas, Query Store y planes; aporta la evidencia. **Ingeniero de cambios**: escribe y aplica los cambios con su marcha atrás y mide el después. **Auditor de seguridad**: permisos, configuración, datos sensibles y auditoría; puede trabajar en paralelo desde el principio. Con tres personas, el líder asume la auditoría.

## Reglas

Nada se cambia sin evidencia previa (una espera, un operador de un plan, una métrica de Query Store). Todo cambio tiene script de marcha atrás y queda en el registro. Se mide antes y después con la misma carga. Está prohibido "arreglar" con `DBCC FREEPROCCACHE`, reinicios o `NOLOCK` generalizado. Se puede cambiar código, índices y configuración de base de datos, pero no el hardware del contenedor. Si un cambio empeora algo, se deshace y se documenta: también es un resultado.

## Preparación del entorno (todos a la vez, 10 minutos)

```bash
cd setup
docker compose up -d
docker exec -it sql2022 /opt/mssql-tools18/bin/sqlcmd -C -S localhost -U sa -P 'Curso_SQL2022!' -i /datos/01_crear_LegacyShop.sql
docker exec -it sql2022 /opt/mssql-tools18/bin/sqlcmd -C -S localhost -U sa -P 'Curso_SQL2022!' -i /datos/99_romper_LegacyShop.sql
docker exec -d sql2022 bash /datos/carga/carga.sh 8 1800
```

El instructor os entregará el script `99_romper_LegacyShop.sql` al empezar la sesión: copiadlo en la carpeta `datos/` del repositorio antes de ejecutar el segundo comando, y no lo abráis hasta el debrief. Comprobad que la carga está viva:

```sql
SELECT r.session_id, r.status, r.command, r.wait_type, r.blocking_session_id, s.host_name
FROM sys.dm_exec_requests r JOIN sys.dm_exec_sessions s ON s.session_id = r.session_id
WHERE s.host_name LIKE 'LegacyShop%';

SELECT Operacion, Numero, COUNT(*) AS errores, MAX(Fecha) AS ultimo
FROM LegacyShop.dbo.CargaErrores GROUP BY Operacion, Numero ORDER BY errores DESC;   -- "logs de la aplicación"
```

Para parar la carga (por ejemplo antes de crear un índice grande) y relanzarla para medir:

```bash
docker exec sql2022 bash /datos/carga/parar.sh
docker exec -d sql2022 bash /datos/carga/carga.sh 8 600
```

## Fase 1 · Diagnóstico (45 minutos)

Con la carga en marcha y estabilizada (dos o tres minutos), capturad la línea base:

1. `scripts/delta_esperas.sql` con 60 segundos.
2. `scripts/top_query_store.sql` (por duración total y por lecturas).
3. `scripts/cadenas_bloqueo.sql` varias veces a lo largo de la fase.
4. `scripts/deadlocks_system_health.sql`.
5. `scripts/io_delta.sql` con 60 segundos.
6. El plan real de las consultas sospechosas (ejecutadas a mano o recuperadas de Query Store).

Rellenad la tabla de diagnóstico. Una fila por problema, incluidos los que no estén en ningún ticket:

| # | Ticket / síntoma | Evidencia (espera, plan, métrica) | Hipótesis de causa | Impacto (alto/medio/bajo) | Riesgo del arreglo |
|---|---|---|---|---|---|
| 1 | | | | | |
| 2 | | | | | |
| 3 | | | | | |
| 4 | | | | | |
| 5 | | | | | |
| 6 | | | | | |

**Línea base de medición** (se repetirá en la fase 2 con la misma carga):

| Métrica | Antes | Después |
|---|---|---|
| Espera dominante y ms/s en 60 s | | |
| Top 3 consultas por duración total (ms en la ventana) | | |
| Lecturas lógicas totales del top 3 | | |
| Errores en CargaErrores en 10 minutos (por número) | | |
| Deadlocks en 10 minutos | | |
| Duración de usp_RecalcularTotales | | |

## Descanso (15 minutos)

## Fase 2 · Remediación (75 minutos)

Priorizad por impacto y riesgo, y aplicad los cambios **de uno en uno**. Tras cada cambio, relanzad la carga el tiempo suficiente para medir (5 minutos suele bastar) y actualizad la tabla. A mitad de la fase el instructor pedirá a cada equipo que diga en voz alta su prioridad número 1.

**Registro de cambios**

| Hora | Cambio | Evidencia que lo justifica | Script de marcha atrás | Resultado medido | ¿Se mantiene? |
|---|---|---|---|---|---|
| | | | | | |

Para guardar la definición original de un procedimiento antes de modificarlo:

```sql
SELECT OBJECT_DEFINITION(OBJECT_ID('dbo.NombreDelProcedimiento'));
```

## Fase 3 · Auditoría de seguridad (30 minutos)

Ejecutad `scripts/check_hardening.sql` y completad con vuestra propia revisión (quién puede leer `IBAN` y `FechaNacimiento`, qué logins existen y con qué roles, qué configuración de base de datos es peligrosa, si hay auditoría). Aplicad las correcciones inmediatas de menor riesgo y documentad las planificadas.

**Informe de hallazgos de seguridad**

| # | Hallazgo | Severidad | Evidencia | Corrección | Inmediata / planificada | Estado |
|---|---|---|---|---|---|---|
| | | | | | | |

Recordad que el comité no quiere una lista: quiere una priorización razonada y un calendario.

## Presentación al comité (5 minutos por equipo)

Estructura recomendada, una diapositiva o una pizarra por punto:

1. **Situación**: qué encontramos, en una frase por ticket.
2. **Qué hicimos**: los cambios aplicados, con su evidencia.
3. **Resultado medido**: la tabla antes/después, en lenguaje de negocio ("la búsqueda de clientes pasa de 3 s a instantánea").
4. **Riesgos pendientes**: lo que no dio tiempo a arreglar y lo que requiere cambios en la aplicación.
5. **Plan**: qué haríamos esta semana, este mes y este trimestre.

**Criterios de valoración**: evidencia (30 %), resultado medido (30 %), criterio y gestión del riesgo (20 %), seguridad y comunicación (20 %).

## Anexo · Recordatorio de herramientas por síntoma

| Síntoma | Dónde mirar primero | Sesión |
|---|---|---|
| Consulta concreta lenta | Plan real: estimadas frente a reales, avisos, lookups, spills | 3 |
| Lenta "a veces" | Query Store: varios planes por consulta, `query_variant` de PSP | 1 |
| Todo lento con disco alto | Delta de esperas (PAGEIOLATCH) + `io_delta.sql` + top por lecturas | 2 |
| Bloqueos y 1205 | `cadenas_bloqueo.sql`, `deadlocks_system_health.sql`, `sys.dm_tran_locks` | 4 |
| Presión en tempdb | PAGELATCH en tempdb, `sys.dm_db_page_info`, spills | 2 |
| Datos sensibles expuestos | Permisos efectivos (`sys.fn_my_permissions` con `EXECUTE AS`), DDM, AE | 5 |
| Configuración peligrosa | `check_hardening.sql` | 5 |

Permisos efectivos de un usuario sobre una tabla:

```sql
EXECUTE AS USER = 'atencion01';
SELECT * FROM sys.fn_my_permissions('dbo.Clientes', 'OBJECT');
REVERT;
```

## Al terminar

Detened la carga, guardad vuestras tablas y registro de cambios, y **no** borréis nada hasta después del debrief: compararemos vuestras soluciones en común.

```bash
docker exec sql2022 bash /datos/carga/parar.sh
```
