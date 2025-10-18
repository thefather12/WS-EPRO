#!/bin/bash
# Script de Administración Avanzada de Distribuciones de CloudFront
# Implementación: Seguridad por Licencia (Panel PHP/MySQL) y Dominio Dinámico.

# ====================================================================
# CONFIGURACIÓN DE RUTAS Y DEPENDENCIAS
# ====================================================================

# Ruta para la AWS CLI y JQ 
AWS_CLI="aws"
JQ_CLI="jq"
TEMP_DOWNLOAD_DIR="/tmp/aws-cli-install"

# Variables del Panel de Licencias (¡¡¡IMPORTANTE!!! ACTUALIZA ESTAS URLs CON TU HOSTING)
GENERATED_KEY_FILE="$HOME/.script_key.txt"
PANEL_URL_REGISTER="https://panelhtv.store/licensing/register.php" # Endpoint para registrar la clave
PANEL_URL_VALIDATE="https://panelhtv.store/licensing/validate.php" # Endpoint para verificar el estado

# Variables de Estado
SCRIPT_KEY=""
VERIFICACION_OK=false

# ====================================================================
# 1. FUNCIONES DE UTILIDAD Y SEGURIDAD
# ====================================================================

# Función para verificar e instalar dependencias (AWS CLI y JQ)
check_dependencies() {
    echo "Verificando dependencias..."
    
    # Check JQ
    if ! command -v "$JQ_CLI" &> /dev/null; then
        echo "⚠️ JQ no encontrado. Instalando..."
        sudo apt update > /dev/null 2>&1
        sudo apt install -y jq > /dev/null 2>&1
        if ! command -v "$JQ_CLI" &> /dev/null; then
            echo "❌ ERROR: Falló la instalación de JQ. Necesitas instalarlo manualmente."
            exit 1
        fi
        echo "✅ JQ instalado."
    fi

    # Check AWS CLI
    if ! command -v "$AWS_CLI" &> /dev/null; then
        echo "⚠️ AWS CLI no encontrado. Necesitas instalarlo manualmente y configurarlo."
    else
        echo "✅ AWS CLI encontrado."
    fi
}

# Función para generar o cargar la Key
get_or_generate_key() {
    if [ -f "$GENERATED_KEY_FILE" ]; then
        # Cargar clave existente
        export SCRIPT_KEY=$(cat "$GENERATED_KEY_FILE")
        echo "✅ Clave de licencia existente cargada."
    else
        # Generar nueva clave única (32 caracteres hexadecimales)
        export SCRIPT_KEY=$(date +%s%N | md5sum | head -c 32)
        echo "$SCRIPT_KEY" > "$GENERATED_KEY_FILE"
        chmod 600 "$GENERATED_KEY_FILE"
        echo "🔑 Nueva clave generada y guardada en $GENERATED_KEY_FILE"
    fi
}

# --- FUNCIÓN DE VERIFICACIÓN DE CLAVE (VERSIÓN DE DEPURACIÓN) ---
verificar_licencia() {
    clear
    echo "========================================="
    echo "   PROTECCIÓN DE ACCESO: LICENCIA REQUERIDA  "
    echo "========================================="
    
    # 1. Obtener la Key
    get_or_generate_key
    echo "Clave de Licencia Actual: $SCRIPT_KEY"
    echo "--------------------------------------------------------"

    # 2. Intentar validar la Key (Llama a validate.php)
    echo "Paso 1/2: Verificando estado de aprobación en el servidor..."
    
    # Usamos '-v' (verbose) para ver detalles de la conexión
    local TEMP_VALIDATE_OUTPUT="/tmp/validate_output_$$.json"
    
    # Ejecuta curl de forma detallada, guardando la respuesta del servidor en el archivo temporal
    local VALIDATE_CODE=$(curl -s -v -o "$TEMP_VALIDATE_OUTPUT" -w "%{http_code}" \
        -H "Authorization: Bearer $SCRIPT_KEY" \
        "$PANEL_URL_VALIDATE" 2>&1) 
    
    echo "--- DEBUG ---"
    echo "Código HTTP de Validación: $VALIDATE_CODE"
    echo "Respuesta del Servidor (Cuerpo):"
    cat "$TEMP_VALIDATE_OUTPUT"
    echo "------------- "
    
    # Manejar los resultados de la validación
    if [ "$VALIDATE_CODE" = "200" ]; then
        echo "✅ Licencia APROBADA. Acceso concedido."
        VERIFICACION_OK=true
        rm -f "$TEMP_VALIDATE_OUTPUT"
        return 0 # <--- Regresa código 0 (Éxito), permitiendo el acceso
    elif [ "$VALIDATE_CODE" = "403" ]; then
        echo "❌ Licencia PENDIENTE O DENEGADA (403). Procediendo a registrar/re-registrar..."
    else
        echo "⚠️ Error inesperado en la validación. Código HTTP: $VALIDATE_CODE"
        echo "   (Revise la URL y el servidor PHP: $PANEL_URL_VALIDATE)"
        rm -f "$TEMP_VALIDATE_OUTPUT"
        exit 1 # <--- Salida Forzada
    fi
    
    rm -f "$TEMP_VALIDATE_OUTPUT"
    
    # 3. Si la clave no está aprobada (403), intentar registrar/re-registrar (Llama a register.php)
    echo "Paso 2/2: Enviando solicitud de registro al panel..."
    
    local TEMP_REGISTER_OUTPUT="/tmp/register_output_$$.json"
    local REGISTER_CODE=$(curl -s -v -o "$TEMP_REGISTER_OUTPUT" -w "%{http_code}" \
        --data "key=$SCRIPT_KEY" \
        "$PANEL_URL_REGISTER" 2>&1)

    echo "--- DEBUG ---"
    echo "Código HTTP de Registro: $REGISTER_CODE"
    echo "Respuesta del Servidor (Cuerpo):"
    cat "$TEMP_REGISTER_OUTPUT"
    echo "------------- "

    rm -f "$TEMP_REGISTER_OUTPUT"

    if [ "$REGISTER_CODE" = "201" ] || [ "$REGISTER_CODE" = "409" ]; then
        echo ""
        echo "=========================================================="
        echo "⏳ SOLICITUD ENVIADA CON ÉXITO. Tu clave está PENDIENTE."
        echo "   ID de Solicitud: $SCRIPT_KEY"
        echo "   **DEBES CONTACTAR AL ADMINISTRADOR PARA APROBARLA.**"
        echo "=========================================================="
        exit 1 # <--- Salida Forzada
    else
        echo "❌ ERROR FATAL al intentar registrar la clave. Código HTTP: $REGISTER_CODE"
        exit 1 # <--- Salida Forzada
    fi
}

# Función genérica para pausar
pausa() {
    read -p "Presiona ENTER para continuar..."
}

# ====================================================================
# 2. FUNCIONES DE ADMINISTRACIÓN DE CLOUDFRONT
# ====================================================================

# Crear una distribución (Con Dominio Dinámico y Corrección de JQ)
crear_distribucion() {
    echo "--- Crear Nueva Distribución (Avanzado) ---"
    echo "Necesitas un archivo JSON base para 'DistributionConfig'."
    
    read -p "Introduce la ruta al archivo JSON de configuración (ej: ~/mi_config_crear.json): " INPUT_FILE

    if [ ! -f "$INPUT_FILE" ]; then
        echo "ERROR: Archivo no encontrado."
        return
    fi
    
    echo "--------------------------------------------------------"
    read -p "Introduce el **Dominio de Origen** (ej: api.servidor.com): " ORIGIN_DOMAIN
    echo "--------------------------------------------------------"
    
    if [ -z "$ORIGIN_DOMAIN" ]; then
        echo "ERROR: El Dominio de Origen no puede estar vacío. Abortando."
        return
    fi
    
    # Crear una nueva CallerReference única
    NEW_CALLER_REF="SCRIPT-CREACION-$(date +%Y%m%d%H%M%S)"
    
    # Inyectar CallerReference y el nuevo Dominio en el archivo JSON
    "$JQ_CLI" ".CallerReference = \"$NEW_CALLER_REF\" | .Origins.Items[0].DomainName = \"$ORIGIN_DOMAIN\"" "$INPUT_FILE" > /tmp/temp_create_config_$$.json
    
    echo "Creando distribución con CallerReference: $NEW_CALLER_REF..."
    echo "Origen de destino configurado a: $ORIGIN_DOMAIN"
    
    local TEMP_OUTPUT="/tmp/create_dist_output_$$.json"
    
    # Ejecutar el comando usando el archivo temporal modificado
    "$AWS_CLI" cloudfront create-distribution --distribution-config "file:///tmp/temp_create_config_$$.json" > "$TEMP_OUTPUT"
    local EXIT_CODE=$?

    # Limpiar el archivo temporal de configuración modificado
    rm -f /tmp/temp_create_config_$$.json

    if [ $EXIT_CODE -eq 0 ]; then
        # Solución robusta para extraer el ID
        local NEW_DIST_ID=$("$JQ_CLI" -r '.Distribution.Id' "$TEMP_OUTPUT")
        
        if [ $? -ne 0 ] || [ -z "$NEW_DIST_ID" ]; then
            echo "✅ Distribución creada con éxito, pero falló la lectura del ID. Busque la última distribución creada en la consola AWS."
            echo "=========================================================="
            return
        fi

        echo "✅ Distribución creada con éxito."
        echo "=========================================================="
        echo "ID de Distribución: $NEW_DIST_ID"
        echo "El dominio de origen es: $ORIGIN_DOMAIN"
        echo "El estado inicial es 'InProgress'."
        echo "=========================================================="
    else
        echo "❌ Error al crear la distribución. Revisa el formato JSON y los permisos."
        if [ -s "$TEMP_OUTPUT" ]; then
            echo "Detalle del error (verifique los permisos o el JSON):"
            cat "$TEMP_OUTPUT"
        fi
    fi
    
    rm -f "$TEMP_OUTPUT"
}

# (Aquí irían otras funciones como actualizar_distribucion, listar_distribuciones, etc.)

# ====================================================================
# 3. MENÚ PRINCIPAL
# ====================================================================

menu_principal() {
    clear
    echo "=========================================================="
    echo "         ADMINISTRACIÓN DE CLOUDFRONT (AWS CLI)         "
    echo "=========================================================="
    echo "Selecciona una opción:"
    echo "1. Crear Nueva Distribución (Con Dominio Dinámico)"
    echo "2. Listar Distribuciones"
    echo "3. Actualizar Distribución Existente"
    echo "0. Salir"
    echo "----------------------------------------------------------"
    read -p "Opción: " opcion

    case $opcion in
        1) crear_distribucion; pausa ;;
        2) # (Aquí iría la función de listar)
            echo "Función Listar aún no implementada."
            pausa ;;
        3) # (Aquí iría la función de actualizar)
            echo "Función Actualizar aún no implementada."
            pausa ;;
        0) echo "Saliendo del script. ¡Adiós!"; exit 0 ;;
        *) echo "Opción no válida. Intenta de nuevo."; pausa ;;
    esac
}

# ====================================================================
# 4. INICIO DEL SCRIPT (ORQUESTADOR)
# ====================================================================

start_script() {
    
    # 0. ¡PRIMERA VERIFICACIÓN DE SEGURIDAD! 🚨
    verificar_licencia 
    
    clear
    echo "********************************************************"
    echo "* Verificando e Instalando Dependencias Necesarias (JQ y AWS CLI) *"
    echo "********************************************************"
    check_dependencies
    
    # Iniciar Bucle Principal del Menú
    while true; do
        menu_principal
    done
}

# Llamada inicial que ejecuta todo
start_script
