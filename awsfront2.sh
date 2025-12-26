#!/bin/bash

# ==============================================================
# SCRIPT UNIFICADO: ADMIN CLOUDFRONT + VPS EC2 (CAPA GRATUITA)
# Versión 6.5.0 - INTEGRACIÓN COMPLETA
# ==============================================================

# --- VARIABLES DE ACTUALIZACIÓN (MANTENIDAS) ---
REMOTE_VERSION_URL="https://raw.githubusercontent.com/thefather12/WS-EPRO/refs/heads/main/Update.txt"
REMOTE_SCRIPT_URL="https://raw.githubusercontent.com/thefather12/WS-EPRO/refs/heads/main/awsfront.sh"
LOCAL_SCRIPT_PATH="$(realpath "$0")"
CURRENT_VERSION="5.9.6" 

# --- VARIABLES GLOBALES ---
AWS_CLI_URL="https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip"
INSTALL_DIR="/usr/local"
AWS_BIN_PATH="$INSTALL_DIR/bin"
CONFIG_FILE="/tmp/cloudfront_config_$$.json"
AWS_CLI=$(which aws 2>/dev/null)
JQ_CLI=$(which jq 2>/dev/null)

# ----------------------------------------------------------------------
# 1. FUNCIONES DE INSTALACIÓN Y REQUISITOS (ORIGINALES COMPLETAS)
# ----------------------------------------------------------------------

check_command() { command -v "$1" &> /dev/null; }

export_aws_path() {
    if [[ ":$PATH:" != *":$AWS_BIN_PATH:"* ]]; then
        export PATH="$PATH:$AWS_BIN_PATH"
        AWS_CLI=$(which aws 2>/dev/null)
    fi
}

instalar_jq() {
    if check_command "jq"; then JQ_CLI=$(which jq); return 0; fi
    echo -e "\e[1;33mInstalando JQ...\e[0m"
    sudo apt update > /dev/null 2>&1 && sudo apt install -y jq > /dev/null 2>&1
    JQ_CLI=$(which jq); return 0
}

instalar_aws_cli() {
    if check_command "aws"; then AWS_CLI=$(which aws); return 0; fi
    echo -e "\e[1;33mInstalando AWS CLI v2...\e[0m"
    sudo apt install -y unzip curl > /dev/null 2>&1
    curl -s "$AWS_CLI_URL" -o "/tmp/awscliv2.zip"
    unzip -q "/tmp/awscliv2.zip" -d /tmp
    sudo /tmp/aws/install --install-dir "$INSTALL_DIR/aws-cli" --bin-dir "$AWS_BIN_PATH" --update
    rm -rf "/tmp/awscliv2.zip" "/tmp/aws"
    export_aws_path
    return 0
}

configurar_aws_manual() {
    echo -e "\e[1;32mConfiguración de Credenciales de AWS\e[0m"
    "$AWS_CLI" configure
    verificar_region
}

verificar_region() {
    local REGION=$("$AWS_CLI" configure get region)
    if [ -z "$REGION" ]; then
        echo -e "\e[1;31m⚠️ Región no detectada.\e[0m"
        read -p "Introduce una región (ej: us-east-1): " NEW_REGION
        "$AWS_CLI" configure set region "$NEW_REGION"
    fi
}

configuracion_inicial_check() {
    if [ ! -f "$HOME/.aws/credentials" ]; then
        configurar_aws_manual
    else
        verificar_region
    fi
}

descargar_json_config() {
    local JSON_URL="https://raw.githubusercontent.com/thefather12/WS-EPRO/refs/heads/main/creacion.json"
    local TARGET_FILE="$HOME/creacion.json"
    if [ ! -f "$TARGET_FILE" ]; then
        echo -e "\e[1;33mDescargando creacion.json...\e[0m"
        curl -s -o "$TARGET_FILE" "$JSON_URL"
    fi
}

# ----------------------------------------------------------------------
# 2. FUNCIONES DE CLOUDFRONT (RESTABLECIDAS AL 100%)
# ----------------------------------------------------------------------

get_config_and_etag() {
    local DIST_ID=$1
    echo -e "\e[1;34mObteniendo ETag y Configuración para: $DIST_ID...\e[0m"
    "$AWS_CLI" cloudfront get-distribution --id "$DIST_ID" --output json > /tmp/temp_dist_info.json 2>/dev/null
    if [ $? -ne 0 ]; then
        echo -e "\e[1;31mError: No se pudo obtener la información de la distribución $DIST_ID.\e[0m"
        return 1
    fi
    CURRENT_ETAG=$( "$JQ_CLI" -r '.ETag' /tmp/temp_dist_info.json )
    "$JQ_CLI" '.Distribution.DistributionConfig' /tmp/temp_dist_info.json > "$CONFIG_FILE"
    return 0
}

listar_distribuciones() {
    echo -e "\n\e[1;36m============================================================\e[0m"
    echo -e "\e[1;36m           LISTADO DE DISTRIBUCIONES CLOUDFRONT             \e[0m"
    echo -e "\e[1;36m============================================================\e[0m"
    "$AWS_CLI" cloudfront list-distributions --query 'DistributionList.Items[*].{ID:Id,DomainName:DomainName,Status:Status,Enabled:Enabled,Comment:Comment}' --output table
}

ver_estado_distribucion() {
    read -p "Introduce el ID de la Distribución: " DIST_ID
    echo -e "\n\e[1;34mConsultando estado de $DIST_ID...\e[0m"
    "$AWS_CLI" cloudfront get-distribution --id "$DIST_ID" --query 'Distribution.{Id:Id,Status:Status,Enabled:Enabled,DomainName:DomainName,LastModifiedTime:LastModifiedTime}' --output table
}

editar_distribucion() {
    read -p "Introduce el ID de la Distribución a EDITAR: " DIST_ID
    if ! get_config_and_etag "$DIST_ID"; then return; fi
    echo -e "\e[1;32mOrigen actual:\e[0m"
    "$JQ_CLI" -r '.Origins.Items[0].DomainName' "$CONFIG_FILE"
    read -p "Introduce el NUEVO Dominio de Origen: " NEW_ORIGIN
    "$JQ_CLI" ".Origins.Items[0].DomainName = \"$NEW_ORIGIN\"" "$CONFIG_FILE" > /tmp/updated_config.json
    echo -e "\e[1;33mActualizando distribución...\e[0m"
    "$AWS_CLI" cloudfront update-distribution --id "$DIST_ID" --distribution-config "file:///tmp/updated_config.json" --if-match "$CURRENT_ETAG"
    [ $? -eq 0 ] && echo -e "\e[1;32m✅ Distribución actualizada exitosamente.\e[0m"
}

toggle_distribucion() {
    read -p "Introduce el ID de la Distribución a Activar/Desactivar: " DIST_ID
    if ! get_config_and_etag "$DIST_ID"; then return; fi
    CURRENT_STATUS=$("$JQ_CLI" -r '.Enabled' "$CONFIG_FILE")
    NEW_STATUS="true"; [ "$CURRENT_STATUS" == "true" ] && NEW_STATUS="false"
    "$JQ_CLI" ".Enabled = $NEW_STATUS" "$CONFIG_FILE" > /tmp/updated_config.json
    "$AWS_CLI" cloudfront update-distribution --id "$DIST_ID" --distribution-config "file:///tmp/updated_config.json" --if-match "$CURRENT_ETAG"
    echo -e "\e[1;32m✅ Estado cambiado a: $NEW_STATUS\e[0m"
}

eliminar_distribucion() {
    read -p "Introduce el ID de la Distribución a ELIMINAR: " DIST_ID
    if ! get_config_and_etag "$DIST_ID"; then return; fi
    ENABLED=$("$JQ_CLI" -r '.Enabled' "$CONFIG_FILE")
    if [ "$ENABLED" == "true" ]; then
        echo -e "\e[1;31m❌ Error: Debes desactivar la distribución antes de eliminarla.\e[0m"
        return
    fi
    "$AWS_CLI" cloudfront delete-distribution --id "$DIST_ID" --if-match "$CURRENT_ETAG"
    [ $? -eq 0 ] && echo -e "\e[1;32m✅ Distribución eliminada.\e[0m"
}

crear_distribucion() {
    if [ ! -f "$HOME/creacion.json" ]; then echo "Error: creacion.json no encontrado."; return; fi
    read -p "Introduce el Dominio de Origen (ej: miweb.com): " ORIGIN_DOMAIN
    CALLER_REF="CREACION-$(date +%s)"
    sed "s/nueva.multiservicio.xyz/$ORIGIN_DOMAIN/g" "$HOME/creacion.json" > /tmp/new_dist.json
    sed -i "s/\"CallerReference\": \".*\"/\"CallerReference\": \"$CALLER_REF\"/" /tmp/new_dist.json
    "$AWS_CLI" cloudfront create-distribution --distribution-config "file:///tmp/new_dist.json"
}

actualizar_script() {
    echo -e "\e[1;33mVerificando actualizaciones...\e[0m"
    REMOTE_VERSION=$(curl -s "$REMOTE_VERSION_URL" | tr -d '\r' | xargs)
    if [ "$REMOTE_VERSION" != "$CURRENT_VERSION" ]; then
        curl -s "$REMOTE_SCRIPT_URL" -o "$LOCAL_SCRIPT_PATH"
        chmod +x "$LOCAL_SCRIPT_PATH"
        echo -e "\e[1;32mActualizado a v$REMOTE_VERSION. Reiniciando...\e[0m"
        exit 0
    else
        echo "Ya estás en la última versión."
    fi
}

remover_panel() {
    read -p "¿Estás seguro de eliminar el script? (s/n): " confirm
    if [ "$confirm" == "s" ]; then rm "$LOCAL_SCRIPT_PATH" && echo "Script eliminado."; exit 0; fi
}

# ----------------------------------------------------------------------
# 3. NUEVAS FUNCIONES: VPS EC2 (COMPLETAS)
# ----------------------------------------------------------------------

crear_vps_ec2() {
    clear
    echo -e "\e[1;35m=========================================\e[0m"
    echo -e "\e[1;35m      CREACIÓN VPS CAPA GRATUITA         \e[0m"
    echo -e "\e[1;35m=========================================\e[0m"
    echo "Selecciona SO:"
    echo "1) Amazon Linux 2023"
    echo "2) Ubuntu 22.04 LTS"
    echo "3) Windows Server 2022"
    read -p "Opción: " SO_OPC
    
    local REGION=$("$AWS_CLI" configure get region)

    case $SO_OPC in
        1) AMI_ID=$("$AWS_CLI" ec2 describe-images --owners amazon --filters "Name=name,Values=al2023-ami-*-x86_64" --query 'sort_by(Images, &CreationDate)[-1].ImageId' --output text) ;;
        2) AMI_ID=$("$AWS_CLI" ec2 describe-images --owners 099720109477 --filters "Name=name,Values=ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-*" --query 'sort_by(Images, &CreationDate)[-1].ImageId' --output text) ;;
        3) AMI_ID=$("$AWS_CLI" ec2 describe-images --owners amazon --filters "Name=name,Values=Windows_Server-2022-English-Full-Base-*" --query 'sort_by(Images, &CreationDate)[-1].ImageId' --output text) ;;
        *) return ;;
    esac

    KEY_NAME="AWS_KEY_$(date +%s)"
    "$AWS_CLI" ec2 create-key-pair --key-name "$KEY_NAME" --query 'KeyMaterial' --output text > "$HOME/$KEY_NAME.pem"
    chmod 400 "$HOME/$KEY_NAME.pem"

    echo "Lanzando instancia t2.micro..."
    INSTANCE=$("$AWS_CLI" ec2 run-instances --image-id "$AMI_ID" --count 1 --instance-type t2.micro --key-name "$KEY_NAME" --block-device-mappings '[{"DeviceName":"/dev/xvda","Ebs":{"VolumeSize":30,"VolumeType":"gp3"}}]' --output json)
    ID=$("$JQ_CLI" -r '.Instances[0].InstanceId' <<< "$INSTANCE")
    
    echo "Esperando IP..."
    sleep 20
    IP=$("$AWS_CLI" ec2 describe-instances --instance-ids "$ID" --query 'Reservations[0].Instances[0].PublicIpAddress' --output text)
    
    echo -e "\e[1;32m✅ VPS CREADA\e[0m"
    echo "ID: $ID"
    echo "IP: $IP"
    echo "Llave: $HOME/$KEY_NAME.pem"
}

# ----------------------------------------------------------------------
# 4. MENÚS Y ARRANQUE
# ----------------------------------------------------------------------

menu_cloudfront() {
    while true; do
        clear
        echo -e "\e[1;34m=========================================\e[0m"
        echo -e "\e[1;34m      ADMINISTRACIÓN CLOUDFRONT          \e[0m"
        echo -e "\e[1;34m=========================================\e[0m"
        echo "1) Listar Distribuciones"
        echo "2) Ver Estado Detallado"
        echo "3) Editar Origen"
        echo "4) Activar/Desactivar"
        echo "5) Eliminar Distribución"
        echo "6) Crear Nueva Distribución"
        echo "0) Volver"
        read -p "Selecciona: " OPC
        case $OPC in
            1) listar_distribuciones ;;
            2) ver_estado_distribucion ;;
            3) editar_distribucion ;;
            4) toggle_distribucion ;;
            5) eliminar_distribucion ;;
            6) crear_distribucion ;;
            0) break ;;
        esac
        read -p "Presiona ENTER para continuar..."
    done
}

menu_vps() {
    while true; do
        clear
        echo -e "\e[1;35m=========================================\e[0m"
        echo -e "\e[1;35m          ADMINISTRACIÓN VPS             \e[0m"
        echo -e "\e[1;35m=========================================\e[0m"
        echo "1) Crear VPS EC2 (Capa Gratuita)"
        echo "2) Listar mis VPS"
        echo "3) Obtener Password Windows"
        echo "0) Volver"
        read -p "Selecciona: " OPC
        case $OPC in
            1) crear_vps_ec2 ;;
            2) "$AWS_CLI" ec2 describe-instances --query 'Reservations[*].Instances[*].{ID:InstanceId,IP:PublicIpAddress,State:State.Name}' --output table ;;
            3) read -p "ID Instancia: " IDW; read -p "Ruta PEM: " RPW; "$AWS_CLI" ec2 get-password-data --instance-id "$IDW" --priv-launch-key "$RPW" ;;
            0) break ;;
        esac
        read -p "Presiona ENTER para continuar..."
    done
}

menu_principal() {
    clear
    echo -e "\e[1;32m=========================================\e[0m"
    echo -e "\e[1;32m    AWS ADMIN MASTER TOOL v$CURRENT_VERSION   \e[0m"
    echo -e "\e[1;32m=========================================\e[0m"
    echo "1. 🌐 GESTIONAR CLOUDFRONT"
    echo "2. 🖥️ GESTIONAR VPS (EC2)"
    echo "-----------------------------------------"
    echo "6. 🔑 Configurar AWS CLI"
    echo "7. 🔄 Actualizar Script"
    echo "9. ❌ Remover Panel"
    echo "0. 🚪 Salir"
    read -p "Selecciona Categoría: " CAT
    case $CAT in
        1) menu_cloudfront ;;
        2) menu_vps ;;
        6) configurar_aws_manual ;;
        7) actualizar_script ;;
        9) remover_panel ;;
        0) exit 0 ;;
    esac
}

start_script() {
    instalar_jq
    instalar_aws_cli
    configuracion_inicial_check
    descargar_json_config
    while true; do menu_principal; done
}

start_script

