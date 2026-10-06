#!/bin/bash
# Lanzador genérico de carga concurrente (sustituto de ostress en Linux)
# Uso: bash /datos/carga/concurrente.sh <sesiones> <segundos> "<T-SQL>" [base_de_datos]
# Ej.: bash /datos/carga/concurrente.sh 16 120 "EXEC dbo.usp_TempdbCarga" LegacyShop
N=${1:-8}; DUR=${2:-60}; SQL=${3:-"SELECT 1"}; DB=${4:-LegacyShop}
SQLCMD=/opt/mssql-tools18/bin/sqlcmd; [ -x "$SQLCMD" ] || SQLCMD=/opt/mssql-tools/bin/sqlcmd
PASS=${MSSQL_SA_PASSWORD:-'Curso_SQL2022!'}
FIN=$(( $(date +%s) + DUR )); rm -f /tmp/carga_parar
echo "Lanzando $N sesiones durante $DUR s: $SQL"
for i in $(seq 1 "$N"); do
  ( while [ "$(date +%s)" -lt "$FIN" ] && [ ! -f /tmp/carga_parar ]; do
      "$SQLCMD" -C -S localhost -U sa -P "$PASS" -d "$DB" -H "LegacyShop-C$i" -l 30 \
        -Q "SET NOCOUNT ON; $SQL" > /dev/null 2>&1
    done ) &
done
wait
echo "Carga concurrente terminada."
