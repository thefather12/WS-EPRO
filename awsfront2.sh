#!/bin/bash

# ==============================================================
# SCRIPT UNIFICADO: CLOUDFRONT + VPS EC2 (CAPA GRATUITA)
# Versión 6.0.0: Integración de VPS y Gestión de Keys
# ==============================================================

# --- VARIABLES DE ACTUALIZACIÓN ---
REMOTE_VERSION_URL="https://raw.githubusercontent.com/thefather12/WS-EPRO/refs/heads/main/Update.txt"
REMOTE_SCRIPT_URL="https://raw.githubusercontent.com/thefather12/WS-EPRO/refs/heads/main/awsfront.sh"
LOCAL_SCRIPT_PATH="$(realpath "$0")"
CURRENT_VERSION="6.0.0" 

# --- VARIABLES GLOBALES ---
AWS_CLI_URL="https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip"
INSTALL_DIR="/usr/local"
AWS_BIN_PATH="$INSTALL_DIR/bin"
CONFIG_FILE="/tmp/cloudfront_config_$$.json"

# ----------------------------------------------------------------------
# FUNCIONES DE INSTALACIÓN Y REQUISITOS
# ----------------------------------------------------------------------

check_command() { command -v "$1" &> /dev/null; }

export_aws_path() {
    if [[ ":$PATH:" != *":$AWS_BIN_PATH:"* ]]; then
        export PATH="$PATH:$AWS_BIN_PATH"
    fi
    AWS_CLI=$(which aws 2>/dev/null)
    JQ_CLI=$(which jq 2>/dev/null)
}

instalar_jq() {
    if check_command "jq"; then return 0; fi
    echo "Instalando jq..."
    sudo apt update > /dev/null 2>&1 && sudo apt install -y jq > /dev/null 2>&1
}

instalar_aws_cli() {
    if check_command "aws"; then return 0; fi
    echo "Instalando AWS CLI v2..."
    sudo apt update > /dev/null 2>&1 && sudo apt install -y unzip curl > /dev/null 2>&1
    curl -s "$AWS_CLI_URL" -o "/tmp/awscliv2.zip"
    unzip -q "/tmp/awscliv2.zip" -d /tmp
    sudo /tmp/aws/install --install-dir "$INSTALL_DIR/aws-cli" --bin-dir "$AWS_BIN_PATH" --update
    rm -rf "/tmp/awscliv2.zip" "/tmp/aws"
    export_aws_path
}

configurar_aws_manual() {
    echo "--- Configuración de Credenciales AWS ---"
    aws configure
}

configuracion_inicial_check() {
    if [ ! -f "$HOME/.aws/credentials" ] && [ ! -f "$HOME/.aws/config" ]; then
        echo "⚠️ No se detectaron credenciales."
        configurar_aws_manual
    fi
}

descargar_json_config() {
    local JSON_URL="https://raw.githubusercontent.com/thefather12/WS-EPRO/refs/heads/main/creacion.json"
    local TARGET_FILE="$HOME/creacion.json"
    if [ ! -f "$TARGET_FILE" ]; then
        curl -s -o "$TARGET_FILE" "$JSON_URL"
    fi
}

# ----------------------------------------------------------------------
# SECCIÓN: GESTIÓN DE VPS EC2 (NUEVO)
# ----------------------------------------------------------------------

crear_vps_ec2() {
    clear
    echo "========================================="
    echo "   🚀 CREACIÓN DE VPS (CAPA GRATUITA)   "
    echo "========================================="
    echo "Selecciona el Sistema Operativo:"
    echo "1) Amazon Linux 2023"
    echo "2) Ubuntu Server 22.04 LTS"
    echo "3) Windows Server 2022 (Base)"
    read -p "Opción: " SO_TYPE

    case $SO_TYPE in
        1) AMI_ID=$(aws ec2 describe-images --owners amazon --filters "Name=name,Values=al2023-ami-*-x86_64" --query 'sort_by(Images, &CreationDate)[-1].ImageId' --output text) ;;
        2) AMI_ID=$(aws ec2 describe-images --owners 099720109477 --filters "Name=name,Values=ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-*" --query 'sort_by(Images, &CreationDate)[-1].ImageId' --output text) ;;
        3) AMI_ID=$(aws ec2 describe-images --owners amazon --filters "Name=name,Values=Windows_Server-2022-English-Full-Base-*" --query 'sort_by(Images, &CreationDate)[-1].ImageId' --output text) ;;
        *) echo "Opción inválida"; return ;;
    esac

    KEY_NAME="KEY_AWS_$(date +%s)"
    echo "Generando llave: $KEY_NAME.pem"
    aws ec2 create-key-pair --key-name "$KEY_NAME" --query 'KeyMaterial' --output text > "$HOME/$KEY_NAME.pem"
    chmod 400 "$HOME/$KEY_NAME.pem"

    echo "Lanzando instancia t2.micro (Free Tier)..."
    INSTANCE_INFO=$(aws ec2 run-instances --image-id "$AMI_ID" --count 1 --instance-type t2.micro --key-name "$KEY_NAME" --block-device-mappings '[{"DeviceName":"/dev/xvda","Ebs":{"VolumeSize":30,"VolumeType":"gp3"}}]' --output json)
    
    INSTANCE_ID=$(echo "$INSTANCE_INFO" | jq -r '.Instances[0].InstanceId')
    echo "⏳ Esperando IP Pública (aprox 15 seg)..."
    sleep 20
    PUBLIC_IP=$(aws ec2 describe-instances --instance-ids "$INSTANCE_ID" --query 'Reservations[0].Instances[0].PublicIpAddress' --output text)

    echo "========================================="
    echo "✅ VPS LISTA"
    echo "ID: $INSTANCE_ID"
    echo "IP: $PUBLIC_IP"
    echo "Llave guardada en: $HOME/$KEY_NAME.pem"
    if [ "$SO_TYPE" == "3" ]; then
        echo "Contraseña: Usa la opción 3 del menú VPS en 4 minutos."
    else
        echo "Comando SSH: ssh -i \"$HOME/$KEY_NAME.pem\" ec2-user@$PUBLIC_IP"
    fi
    echo "========================================="
}

obtener_pass_windows() {
    read -p "ID de la instancia: " INST_ID
    read -p "Ruta del archivo .pem (ej: /root/key.pem): " PEM_PATH
    aws ec2 get-password-data --instance-id "$INST_ID" --priv-launch-key "$PEM_PATH"
}

listar_vps() {
    echo "--- Instancias Actuales ---"
    aws ec2 describe-instances --query 'Reservations[*].Instances[*].{ID:InstanceId,Status:State.Name,IP:PublicIpAddress,Type:InstanceType}' --output table
}

# ----------------------------------------------------------------------
# FUNCIONES ORIGINALES CLOUDFRONT (ADAPTADAS)
# ----------------------------------------------------------------------

get_config_and_etag() {
    local DIST_ID=$1
    aws cloudfront get-distribution --id "$DIST_ID" --output json > /tmp/temp_dist_info.json 2>/dev/null
    if [ $? -ne 0 ]; then echo "Error al obtener info."; return 1; fi
    export CURRENT_ETAG=$(jq -r '.ETag' /tmp/temp_dist_info.json)
    jq '.Distribution.DistributionConfig' /tmp/temp_dist_info.json > "$CONFIG_FILE"
}

listar_distribuciones() {
    echo "Buscando distribuciones..."
    aws cloudfront list-distributions --query 'DistributionList.Items[*].{ID:Id,Domain:DomainName,Status:Status,Enabled:Enabled}' --output table
}

editar_distribucion() {
    read -p "ID de la Distribución: " DIST_ID
    if ! get_config_and_etag "$DIST_ID"; then return 1; fi
    read -p "Nuevo Dominio de Origen: " NEW_ORIGIN
    jq ".Origins.Items[0].DomainName = \"$NEW_ORIGIN\"" "$CONFIG_FILE" > /tmp/updated.json
    aws cloudfront update-distribution --id "$DIST_ID" --distribution-config "file:///tmp/updated.json" --if-match "$CURRENT_ETAG"
}

toggle_distribucion() {
    read -p "ID de la Distribución: " DIST_ID
    if get_config_and_etag "$DIST_ID"; then
        STATUS=$(jq -r '.Enabled' "$CONFIG_FILE")
        NEW_STATUS="true"; [ "$STATUS" == "true" ] && NEW_STATUS="false"
        jq ".Enabled = $NEW_STATUS" "$CONFIG_FILE" > /tmp/updated.json
        aws cloudfront update-distribution --id "$DIST_ID" --distribution-config "file:///tmp/updated.json" --if-match "$CURRENT_ETAG"
    fi
}

# ----------------------------------------------------------------------
# MENÚS PRINCIPALES
# ----------------------------------------------------------------------

menu_vps() {
    while true; do
        clear
        echo "--- GESTIÓN DE VPS EC2 ---"
        echo "1) Crear VPS (Capa Gratuita)"
        echo "2) Listar VPS e IPs"
        echo "3) Obtener Password Windows"
        echo "0) Volver"
        read -p "Opción: " OV
        case $OV in
            1) crear_vps_ec2 ;;
            2) listar_vps ;;
            3) obtener_pass_windows ;;
            0) break ;;
        esac
        read -p "ENTER para continuar..."
    done
}

menu_principal() {
    clear
    echo "========================================="
    echo " AWS MANAGER EPRO v$CURRENT_VERSION"
    echo "========================================="
    echo "1. 🌐 CLOUDFRONT (Distribuciones)"
    echo "2. 🖥️ VPS EC2 (Instancias)"
    echo "-----------------------------------"
    echo "6. 🔑 Configurar AWS"
    echo "7. 🔄 Actualizar Script"
    echo "0. 🚪 Salir"
    echo "-----------------------------------------"
    read -p "Selecciona: " OPC
    case $OPC in
        1)
            echo "1. Listar | 2. Editar | 3. On/Off | 4. Crear"
            read -p "Opción: " CF_O
            case $CF_O in
                1) listar_distribuciones ;;
                2) editar_distribucion ;;
                3) toggle_distribucion ;;
                4) echo "Usa la función original de creación." ;;
            esac ;;
        2) menu_vps ;;
        6) configurar_aws_manual ;;
        0) exit 0 ;;
    esac
    read -p "Presiona ENTER..."
}

# --- INICIO ---
export_aws_path
instalar_jq
instalar_aws_cli
configuracion_inicial_check
descargar_json_config
while true; do menu_principal; done

