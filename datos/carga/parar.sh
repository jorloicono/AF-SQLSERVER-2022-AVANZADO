#!/bin/bash
# Detiene la carga: los bucles terminan al acabar la llamada en curso.
touch /tmp/carga_parar
echo "Señal de parada enviada. Las sesiones terminarán al completar su lote actual."
echo "Para cortar en seco desde SQL: KILL a las sesiones con host_name LIKE 'LegacyShop%'."
