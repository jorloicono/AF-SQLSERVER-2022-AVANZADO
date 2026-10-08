# Lab 9 · Always Encrypted en LegacyShop

**Sesión 5 · Duración: 40 minutos · Base de datos: LegacyShop**

Always Encrypted es la única funcionalidad de SQL Server que protege los datos frente a quien administra el servidor, porque el cifrado y el descifrado ocurren en el controlador del cliente y las claves nunca llegan al motor. En este laboratorio vais a cifrar el IBAN y la fecha de nacimiento de los clientes, a comprobar qué ve cada tipo de conexión y qué consultas dejan de funcionar, y a demostrar que un sysadmin sin acceso a la clave maestra no puede leer los datos.

## Requisitos y organización

El asistente de cifrado y el almacén de certificados de Windows exigen **SSMS en Windows**. Como trabajáis con SQL Server instalado en Windows, tenéis todo lo necesario en vuestro propio equipo.

Con la configuración por defecto la instancia **no tiene ningún enclave habilitado**, así que trabajaremos con Always Encrypted sin enclaves. Las operaciones con enclave (comparaciones de rango, `LIKE` y ordenación sobre datos cifrados con cifrado aleatorio) requieren activar el enclave VBS de la instancia; en el paso 4 veréis precisamente el error que lo demuestra. Al final de `setup/README.md` tenéis cómo activarlo si queréis probarlo por vuestra cuenta.

Antes de empezar, comprobad que no hay máscaras en las columnas que vais a cifrar (Dynamic Data Masking no es compatible con columnas cifradas):

```sql
USE LegacyShop;
SELECT c.name FROM sys.masked_columns c WHERE c.object_id = OBJECT_ID('dbo.Clientes');
```

## Paso 1 · Crear las claves con el asistente (10 minutos)

En el Explorador de objetos de SSMS: `LegacyShop` → clic derecho sobre la tabla `dbo.Clientes` → **Encrypt Columns...**

1. En la pantalla de selección de columnas marcad `IBAN` con tipo **Deterministic** y `FechaNacimiento` con tipo **Randomized**. Dejad que el asistente genere una nueva clave de cifrado de columna (CEK) para ambas.
2. En la configuración de la clave maestra (CMK) elegid **Auto generate column master key**, almacén **Windows certificate store - Current User**. El asistente creará un certificado autofirmado en vuestro perfil de Windows.
3. Elegid **Proceed to finish now** y completad. El asistente descarga los datos al cliente, los cifra y los vuelve a subir: con 100.000 clientes tarda uno o dos minutos.

Mientras termina, observad qué ha quedado en el servidor:

```sql
SELECT name, key_store_provider_name, key_path FROM sys.column_master_keys;
SELECT name FROM sys.column_encryption_keys;
SELECT c.name, c.encryption_type_desc, c.encryption_algorithm_name, k.name AS cek, c.collation_name
FROM sys.columns c LEFT JOIN sys.column_encryption_keys k ON k.column_encryption_key_id = c.column_encryption_key_id
WHERE c.object_id = OBJECT_ID('dbo.Clientes') AND c.encryption_type IS NOT NULL;
```

El servidor solo guarda la **ruta** de la CMK (`CurrentUser/My/<huella>`) y el valor de la CEK **cifrado** con esa CMK. La intercalación de las columnas de texto cifradas ha pasado a ser `*_BIN2`, que es un requisito.

## Paso 2 · Lo que ve cada conexión (10 minutos)

Abrid dos conexiones a LegacyShop:

- **Conexión 1 (normal)**: la que ya teníais.
- **Conexión 2 (con cifrado)**: nueva conexión → **Options >>** → pestaña **Always Encrypted** → marcad **Enable Always Encrypted (column encryption)**. En SSMS 21 también se puede añadir `Column Encryption Setting=Enabled` en *Additional Connection Parameters*.

Ejecutad en ambas:

```sql
SELECT TOP (5) ClienteID, CodigoCliente, IBAN, FechaNacimiento FROM dbo.Clientes ORDER BY ClienteID;
```

En la conexión 1 veréis valores binarios `0x01...`; en la 2, el IBAN y la fecha en claro, porque el controlador ha descifrado usando el certificado de vuestro almacén de Windows.

| Conexión | IBAN | FechaNacimiento |
|---|---|---|
| Sin Column Encryption Setting | | |
| Con Column Encryption Setting | | |

## Paso 3 · Filtrar por un valor cifrado (5 minutos)

En la conexión 2 activad **Query → Query Options → Execution → Advanced → Enable Parameterization for Always Encrypted**. Sin esta opción, SSMS enviaría el literal en claro y el motor no podría compararlo.

```sql
DECLARE @iban varchar(34) = 'ES42...';   -- copiad un IBAN real del paso 2
SELECT ClienteID, Nombre FROM dbo.Clientes WHERE IBAN = @iban;
```

SSMS subraya la variable y, al pasar el ratón, indica que se parametrizará y cifrará antes de enviarla. Funciona porque el IBAN está cifrado de forma **determinista**: el mismo valor en claro produce siempre el mismo valor cifrado, así que el motor puede comparar igualdades. Probad ahora con un literal directo (`WHERE IBAN = 'ES42...'`) y leed el error.

## Paso 4 · Lo que deja de funcionar (5 minutos)

En la conexión 2, con parametrización activada:

```sql
DECLARE @d date = '1980-01-01';
SELECT COUNT(*) FROM dbo.Clientes WHERE FechaNacimiento < @d;       -- rango sobre cifrado aleatorio

SELECT TOP (5) ClienteID FROM dbo.Clientes ORDER BY FechaNacimiento; -- ordenación

SELECT COUNT(*) FROM dbo.Clientes WHERE IBAN LIKE 'ES9%';           -- LIKE sobre determinista

EXEC dbo.usp_InformeVentasMensual @Anio = 2025;                     -- calcula la edad en el servidor
```

Anotad cada error. Con cifrado aleatorio el servidor no puede hacer nada con el valor salvo devolverlo; con cifrado determinista solo igualdades, agrupaciones y joins. Estas operaciones son exactamente las que un enclave seguro permitiría hacer dentro de una región protegida de memoria, y por eso decíamos en la teoría que "sin perder capacidad de cálculo" es cierto solo en parte y solo con enclaves. Pensad qué implicaría esto para el informe mensual de LegacyShop: calcular la edad tendría que hacerse en la aplicación.

## Paso 5 · Un sysadmin sin la CMK (5 minutos)

En vuestro equipo el certificado de la CMK está en vuestro almacén de Windows, así que para simular a un administrador que no lo tiene lo vamos a retirar temporalmente. Abrid `certmgr.msc` → Personal → Certificados, localizad "Always Encrypted Auto Certificate...", **exportadlo primero** (clic derecho → Todas las tareas → Exportar → *Sí, exportar la clave privada* → guardad el `.pfx` con una contraseña) y después eliminadlo del almacén.

Ahora, en la conexión con `Column Encryption Setting=Enabled`, conectado como `sa` o como vuestro usuario sysadmin:

```sql
SELECT TOP (3) ClienteID, IBAN FROM dbo.Clientes;
```

El controlador devuelve un error del estilo "Failed to decrypt a column encryption key... certificate not found", y en la conexión sin cifrado solo se ve el binario. Ser sysadmin no da acceso a los datos: da acceso a los metadatos y a los valores cifrados. Tampoco sirve un backup: la base restaurada en otro servidor sigue sin la CMK.

Volved a importar el certificado (doble clic en el `.pfx` → Usuario actual → almacén Personal) y comprobad que la conexión con cifrado vuelve a ver los datos en claro. **Sin este paso no podréis descifrar las columnas en la limpieza.**

## Limpieza (obligatoria antes del Lab 10)

Descifrad las columnas con el mismo asistente: **Encrypt Columns...** → para `IBAN` y `FechaNacimiento` elegid **Plaintext** → **Proceed to finish now**. Comprobad con la consulta del paso 1 que ya no hay columnas cifradas. Si el asistente falla o no tenéis tiempo, relanzad `datos/01_crear_LegacyShop.sql` (unos 5 minutos).

Opcionalmente, una vez descifradas las columnas, eliminad el certificado de vuestro almacén y las claves del servidor (`DROP COLUMN ENCRYPTION KEY ...; DROP COLUMN MASTER KEY ...;`).

## Para la puesta en común

¿Qué pasaría si perdierais el certificado de la CMK? ¿Dónde lo guardaríais en producción? ¿Por qué el IBAN determinista revela información aunque esté cifrado (pensad en cuántos clientes comparten un valor)? ¿Qué cambios necesitaría la aplicación de LegacyShop para adoptar Always Encrypted?
