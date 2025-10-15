#!/bin/bash

# ==============================================================
# SCRIPT UNIFICADO: INSTALACIÓN DE DEPENDENCIAS + ADMIN CLOUDFRONT
# Versión 5.0: Solución de desbordamiento de JSON en 'Crear Distribución' (Opción 5) 
# y 'Activar/Desactivar Distribución' (Opción 3).
# ==============================================================

# --- VARIABLES GLOBALES ---
AWS_CLI_URL="https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip"
INSTALL_DIR="/usr/local"
AWS_BIN_PATH="$INSTALL_DIR/bin"
# Variables del panel CloudFront
CONFIG_FILE="/tmp/cloudfront_config_$$.json"
# Inicializa las variables de ruta para que se re-evalúen después de la instalación
AWS_CLI=$(which aws 2>/dev/null)
JQ_CLI=$(which jq 2>/dev/null)

# ----------------------------------------------------------------------
# FUNCIONES DE INSTALACIÓN Y CHEQUEO DE REQUISITOS
# ----------------------------------------------------------------------

# Función para verificar si un comando existe
check_command() {
    command -v "$1" &> /dev/null
}

# Función para verificar y exportar el PATH de AWS
export_aws_path() {
    if [[ ":$PATH:" != *":$AWS_BIN_PATH:"* ]]; then
        export PATH="$PATH:$AWS_BIN_PATH"
        AWS_CLI=$(which aws 2>/dev/null) # Re-evaluar la ruta de AWS CLI
    fi
}

# Función para instalar JQ
instalar_jq() {
    echo "========================================="
    echo "  -> Instalando jq (Procesador de JSON)  "
    echo "========================================="
    
    if check_command "jq"; then
        echo "✅ jq ya está instalado. Omitiendo instalación."
        JQ_CLI=$(which jq)
        return 0
    fi

    if command -v apt &> /dev/null; then
        echo "🔧 Ejecutando 'sudo apt update' e 'install jq'..."
        sudo apt update > /dev/null 2>&1
        sudo apt install -y jq
        if [ $? -eq 0 ]; then
            echo -e "✅ jq se instaló correctamente."
            JQ_CLI=$(which jq)
            return 0
        fi
    fi
    echo -e "❌ Error al instalar jq. Se requiere intervención manual."
    return 1
}

# Función para instalar AWS CLI v2
instalar_aws_cli() {
    echo "========================================="
    echo "  -> Instalando AWS CLI v2 (Linux/x64)  "
    echo "========================================="
    
    if check_command "aws"; then
        echo "✅ AWS CLI ya está instalado. Omitiendo instalación."
        AWS_CLI=$(which aws)
        return 0
    fi
    
    # Requerir unzip
    if ! check_command "unzip"; then
        echo "⚠️ 'unzip' no está instalado. Instalándolo..."
        sudo apt install -y unzip || { echo "❌ No se pudo instalar 'unzip'. Abortando."; return 1; }
    fi

    local temp_zip="/tmp/awscliv2.zip"
    local temp_dir="/tmp/aws"
    
    echo "Descargando AWS CLI..."
    curl -s "$AWS_CLI_URL" -o "$temp_zip"
    
    if [ $? -ne 0 ]; then
        echo "❌ Error al descargar AWS CLI."
        return 1
    fi
    
    unzip -q "$temp_zip" -d /tmp
    sudo "$temp_dir/install" --install-dir "$INSTALL_DIR/aws-cli" --bin-dir "$AWS_BIN_PATH"
    
    rm -rf "$temp_zip" "$temp_dir"

    if [ $? -eq 0 ]; then
        export_aws_path
        echo -e "✅ AWS CLI v2 se instaló correctamente."
        return 0
    else
        echo "❌ Error durante la instalación de AWS CLI."
        return 1
    fi
}

# Función para configurar credenciales AWS (solo si no están)
configurar_aws() {
    # Comprobar si ya existen credenciales básicas
    if [ -f "$HOME/.aws/credentials" ] && grep -q '^\[default\]' "$HOME/.aws/credentials"; then
        echo "✅ Archivos de configuración/credenciales de AWS existentes. Omitiendo configuración."
        return 0
    fi
    
    echo "======================================================"
    echo "  -> Configuración de Credenciales de AWS (necesaria)  "
    echo "======================================================"
    
    echo "Ingrese sus credenciales (Access Key ID y Secret Key). Serán guardadas en ~/.aws/."
    
    export_aws_path 
    "$AWS_CLI" configure
    
    if [ $? -eq 0 ]; then
        echo "✅ Configuración inicial completada."
    else
        echo "⚠️ Hubo un problema con la configuración. Verifique los datos ingresados."
    fi
}

# ----------------------------------------------------------------------
# FUNCIONES DE CLOUDFRONT 
# ----------------------------------------------------------------------

# Función para obtener la configuración y el ETag de una distribución
get_config_and_etag() {
    local DIST_ID=$1
    echo "Obteniendo configuración y ETag para $DIST_ID..."
    
    "$AWS_CLI" cloudfront get-distribution --id "$DIST_ID" --output json > /tmp/temp_dist_info.json
    
    if [ $? -ne 0 ]; then
        echo "Error: No se pudo obtener la configuración. Verifica el ID."
        return 1
    fi
    
    # Extraer el ETag y guardar solo DistributionConfig en el archivo de configuración
    export CURRENT_ETAG=$(cat /tmp/temp_dist_info.json | "$JQ_CLI" -r '.ETag')
    cat /tmp/temp_dist_info.json | "$JQ_CLI" '.Distribution.DistributionConfig' > "$CONFIG_FILE"
    rm -f /tmp/temp_dist_info.json
    
    if [ -z "$CURRENT_ETAG" ]; then
        echo "Error: No se pudo obtener el ETag."
        return 1
    fi
    return 0
}

# 1. Listar distribuciones
listar_distribuciones() {
    echo "--- Listado y Estado de Distribuciones de CloudFront ---"
    
    "$AWS_CLI" cloudfront list-distributions \
        --query 'DistributionList.Items[*].{ID:Id,Domain:DomainName,Status:Status,Enabled:Enabled}' \
        --output table
    
    if [ $? -ne 0 ]; then
        echo "Error al listar. Verifica tus permisos IAM."
    fi
}

# 2. Ver estado de distribución
ver_estado_distribucion() {
    read -p "Introduce el ID de la Distribución: " DIST_ID
    
    if get_config_and_etag "$DIST_ID"; then
        echo "--- Estado de la Distribución $DIST_ID ---"
        # Usamos jq para mostrar datos clave
        cat "$CONFIG_FILE" | "$JQ_CLI" '{
            ID: "'"$DIST_ID"'", 
            Domain: .Aliases.Items[0], 
            Status: .Status, 
            Enabled: .Enabled, 
            Origin: .Origins.Items[0].DomainName
        }'
    fi
}

# 3. Crear una distribución (CORREGIDA)
crear_distribucion() {
    echo "--- Crear Nueva Distribución (Requiere un archivo de configuración) ---"
    echo "Necesitas un archivo JSON que contenga la estructura completa de 'DistributionConfig'."
    read -p "Introduce la ruta al archivo JSON de configuración (ej: ~/mi_config.json): " INPUT_FILE

    if [ ! -f "$INPUT_FILE" ]; then
        echo "ERROR: Archivo no encontrado."
        return
    fi
    
    echo "Creando distribución..."
    
    # Capturar la salida en un archivo temporal para que no inunde la terminal
    local TEMP_OUTPUT="/tmp/create_dist_output_$$.json"
    
    # Ejecutar el comando, capturando la salida y el código de retorno
    "$AWS_CLI" cloudfront create-distribution --distribution-config "file://$INPUT_FILE" > "$TEMP_OUTPUT"
    local EXIT_CODE=$?

    if [ $EXIT_CODE -eq 0 ]; then
        # Extraer el nuevo ID de la distribución
        local NEW_DIST_ID=$(cat "$TEMP_OUTPUT" | "$JQ_CLI" -r '.Distribution.Id')
        
        echo "✅ Distribución creada con éxito."
        echo "=========================================================="
        echo "ID de Distribución: $NEW_DIST_ID"
        echo "El estado inicial es 'InProgress' (tardará unos minutos)."
        echo "=========================================================="
    else
        echo "❌ Error al crear la distribución. Revisa el formato JSON y los permisos."
        # Mostrar el error de AWS si el archivo temporal tiene contenido (el error JSON)
        if [ -s "$TEMP_OUTPUT" ]; then
            echo "Detalle del error (verifique los permisos o el JSON):"
            cat "$TEMP_OUTPUT"
        fi
    fi
    
    rm -f "$TEMP_OUTPUT"
}

# 4. Activar/Desactivar Distribución (CORREGIDA)
toggle_distribucion() {
    # Si se llama desde la función eliminar_distribucion, toma el ID del argumento $1
    # Si se llama desde el menú, pide el ID
    if [ -z "$1" ]; then
        read -p "Introduce el ID de la Distribución a modificar: " DIST_ID
    else
        DIST_ID=$1
    fi
    
    if get_config_and_etag "$DIST_ID"; then
        CURRENT_STATUS=$(cat "$CONFIG_FILE" | "$JQ_CLI" -r '.Enabled')
        
        if [ "$CURRENT_STATUS" = "true" ]; then
            NEW_STATUS="false"
            ACTION="Desactivando"
        else
            NEW_STATUS="true"
            ACTION="Activando"
        fi
        
        echo "$ACTION distribución $DIST_ID (Estado actual: $CURRENT_STATUS)..."
        
        # Modificar el campo 'Enabled' en el archivo de configuración
        "$JQ_CLI" ".Enabled = $NEW_STATUS" "$CONFIG_FILE" > /tmp/updated_config.json && mv /tmp/updated_config.json "$CONFIG_FILE"
        
        # Actualizar la distribución
        local TEMP_OUTPUT_TOGGLE="/tmp/update_dist_output_$$.json"
        
        "$AWS_CLI" cloudfront update-distribution \
            --id "$DIST_ID" \
            --distribution-config "file://$CONFIG_FILE" \
            --if-match "$CURRENT_ETAG" > "$TEMP_OUTPUT_TOGGLE"

        local EXIT_CODE=$?

        if [ $EXIT_CODE -eq 0 ]; then
            echo "✅ $ACTION completada. El estado de 'Deployed' cambiará pronto."
        else
            echo "❌ Error al modificar la distribución. El estado de la distribución debe ser 'Deployed' para actualizarla."
            if [ -s "$TEMP_OUTPUT_TOGGLE" ]; then
                echo "Detalle del error (verifique el ETag o el estado):"
                cat "$TEMP_OUTPUT_TOGGLE"
            fi
        fi
        rm -f "$TEMP_OUTPUT_TOGGLE"
    fi
}

# 5. Eliminar una Distribución 
eliminar_distribucion() {
    read -p "Introduce el ID de la Distribución a ELIMINAR: " DIST_ID
    
    if get_config_and_etag "$DIST_ID"; then
        CURRENT_STATUS=$(cat "$CONFIG_FILE" | "$JQ_CLI" -r '.Enabled')
        
        if [ "$CURRENT_STATUS" = "true" ]; then
            echo "⛔ ERROR: La distribución debe estar DESACTIVADA para poder eliminarla."
            read -p "¿Desactivar ahora? (s/N): " DEACTIVATE_CONFIRM
            if [[ "$DEACTIVATE_CONFIRM" =~ ^[sS]$ ]]; then
                # Llamada a la función toggle, pasándole el ID como argumento
                toggle_distribucion "$DIST_ID"
                echo "Intenta eliminar de nuevo cuando el estado esté en 'Deployed' (tardará unos minutos)."
            fi
            return
        fi

        echo "🚨 ADVERTENCIA: Esta acción es irreversible."
        echo "La distribución $DIST_ID está DESACTIVADA. Confirmar eliminación."
        read -p "¿Estás ABSOLUTAMENTE seguro de ELIMINAR? Escribe 'ELIMINAR': " FINAL_CONFIRM
        
        if [ "$FINAL_CONFIRM" = "ELIMINAR" ]; then
            # Captura la salida de delete-distribution (que también puede ser verbosa)
            "$AWS_CLI" cloudfront delete-distribution \
                --id "$DIST_ID" \
                --if-match "$CURRENT_ETAG"
            
            if [ $? -eq 0 ]; then
                echo "✅ Distribución eliminada (el proceso de borrado comenzará pronto)."
            else
                echo "❌ Error al eliminar la distribución."
            fi
        else
            echo "Operación cancelada."
        fi
    fi
}

# 6. Remover el Panel (Script)
remover_panel() {
    echo "Eliminando el script '$0'..."
    rm -- "$0"
    if [ $? -eq 0 ]; then
        echo "✅ Script eliminado con éxito. Saliendo..."
        exit 0
    else
        echo "❌ Error al eliminar el script. Por favor, borra el archivo manualmente."
    fi
}

# 7. Función del menú principal
menu_principal() {
    clear
    echo "========================================="
    echo " CloudFront VPS Administration Tool (v2) "
    echo "========================================="
    echo "--- Administrar Distribuciones ---"
    echo "1. Listar Distribuciones y Estado General"
    echo "2. Ver Estado Detallado (por ID)"
    echo "3. Activar/Desactivar Distribución (Toggle Enabled)"
    echo "4. Eliminar Distribución (Requiere estar Desactivada)"
    echo "-----------------------------------"
    echo "5. Crear Nueva Distribución (Avanzado)"
    echo "-----------------------------------"
    echo "9. Remover este Panel (Script)"
    echo "0. Salir del Script"
    echo "-----------------------------------------"
    read -p "Selecciona una opción: " OPCION
    
    case $OPCION in
        1) listar_distribuciones ;;
        2) ver_estado_distribucion ;;
        3) toggle_distribucion ;;
        4) eliminar_distribucion ;;
        5) crear_distribucion ;;
        9) remover_panel ;;
        0) echo "Saliendo del script. ¡Adiós!"; exit 0 ;;
        *) echo "Opción no válida. Inténtalo de nuevo." ;;
    esac
    
    # Esta línea asegura que el script pausa antes de volver a dibujar el menú
    read -p "Presiona ENTER para continuar..."
}

# ----------------------------------------------------------------------
# FUNCIÓN DE INICIO (Orquestador de Requisitos)
# ----------------------------------------------------------------------
start_script() {
    clear
    echo "********************************************************"
    echo "* Verificando e Instalando Dependencias Necesarias (JQ y AWS CLI) *"
    echo "********************************************************"
    
    # 1. Instalar JQ
    instalar_jq
    if [ $? -ne 0 ]; then
        echo "ERROR FATAL: No se pudo instalar jq. Abortando."
        exit 1
    fi
    
    # 2. Instalar AWS CLI
    instalar_aws_cli
    if [ $? -ne 0 ]; then
        echo "ERROR FATAL: No se pudo instalar AWS CLI. Abortando."
        exit 1
    fi

    # 3. Configurar Credenciales
    configurar_aws

    # 4. Iniciar Bucle Principal del Menú
    while true; do
        menu_principal
    done
}

# Ejecutar la función de inicio
start_script
