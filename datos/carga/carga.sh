#!/bin/bash
# Carga simulada del TALLER INTEGRADOR (Sesión 6)
# Uso: bash /datos/carga/carga.sh <sesiones> <segundos>
#   docker exec -d sql2022 bash /datos/carga/carga.sh 8 1800
# Cada trabajador ejecuta dbo.usp_Carga_Mezcla en bucle (host_name = LegacyShop-Wn).
# Un trabajador adicional (LegacyShop-R) lanza el recálculo de totales cada 120 s.
# Los errores (deadlocks 1205, timeouts...) quedan en dbo.CargaErrores.
N=${1:-8}; DUR=${2:-1800}
SQLCMD=/opt/mssql-tools18/bin/sqlcmd; [ -x "$SQLCMD" ] || SQLCMD=/opt/mssql-tools/bin/sqlcmd
PASS=${MSSQL_SA_PASSWORD:-'Curso_SQL2022!'}
FIN=$(( $(date +%s) + DUR )); rm -f /tmp/carga_parar
echo $$ > /tmp/carga_legacyshop.pid
LOG=/tmp/carga_legacyshop.log; echo "$(date) inicio: $N trabajadores, $DUR s" > $LOG
for i in $(seq 1 "$N"); do
  ( while [ "$(date +%s)" -lt "$FIN" ] && [ ! -f /tmp/carga_parar ]; do
      "$SQLCMD" -C -S localhost -U sa -P "$PASS" -d LegacyShop -H "LegacyShop-W$i" -l 30 \
        -Q "SET NOCOUNT ON; EXEC dbo.usp_Carga_Mezcla @Trabajador = $i, @Iteraciones = 25;" > /dev/null 2>>$LOG
    done ) &
done
( while [ "$(date +%s)" -lt "$FIN" ] && [ ! -f /tmp/carga_parar ]; do
    sleep 120
    "$SQLCMD" -C -S localhost -U sa -P "$PASS" -d LegacyShop -H "LegacyShop-R" -l 30 \
      -Q "SET NOCOUNT ON; EXEC dbo.usp_Carga_Recalculo;" > /dev/null 2>>$LOG
  done ) &
wait
echo "$(date) fin" >> $LOG
