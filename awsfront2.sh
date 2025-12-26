#!/bin/bash

# Auto-corrección de formato (Elimina caracteres de Windows si existen)
sed -i 's/\r$//' "$0" 2>/dev/null

# ==============================================================
# SCRIPT UNIFICADO: ADMIN CLOUDFRONT + VPS EC2 (CAPA GRATUITA)
# Versión: 6.5.0 (Full Integrado)
# ==============================================================

# --- VARIABLES DE ACTUALIZACIÓN ---
REMOTE_VERSION_URL="https://raw.githubusercontent.com/thefather12/WS-EPRO/refs/heads/main/Update.txt"
REMOTE_SCRIPT_URL="https://raw.githubusercontent.com/thefather12/WS-EPRO/refs/heads/main/awsfront.sh"
LOCAL_SCRIPT_PATH="$(realpath "$0")"
CURRENT_VERSION="5.9.6" # Mantengo tu versión original de referencia

# --- VARIABLES GLOBALES ---
AWS_CLI_URL="https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip"
INSTALL_DIR="/usr/local"
AWS_BIN_PATH="$INSTALL_DIR/bin"
CONFIG_FILE="/tmp/cloudfront_config_$$.json"

# ----------------------------------------------------------------------
# 1. FUNCIONES DE INSTALACIÓN Y REQUISITOS (ORIGINALES)
# ----------------------------------------------------------------------

check_command() { command -v "$1" &> /dev/null; }

export_aws_path() {
    if [[ ":$PATH:" != *":$AWS_BIN_PATH:"* ]]; then
        export PATH="$PATH:$AWS_BIN_PATH"
    fi
}

instalar_jq() {
    if check_command "jq"; then return 0; fi
    sudo apt update > /dev/null 2>&1 && sudo apt install -y jq > /dev/null 2>&1
}

instalar_aws_cli() {
    if check_command "aws"; then return 0; fi
    sudo apt install -y unzip curl > /dev/null 2>&1
    curl -s "$AWS_CLI_URL" -o "/tmp/awscliv2.zip"
    unzip -q "/tmp/awscliv2.zip" -d /tmp
    sudo /tmp/aws/install --install-dir "$INSTALL_DIR/aws-cli" --bin-dir "$AWS_BIN_PATH" --update
    rm -rf "/tmp/awscliv2.zip" "/tmp/aws"
    export_aws_path
}

verificar_region() {
    REGION=$(aws configure get region)
    if [ -z "$REGION" ]; then
        echo "⚠️ Región no detectada. Configurando us-east-1 por defecto..."
        aws configure set region us-east-1
        REGION="us-east-1"
    fi
}

configuracion_inicial_check() {
    if [ ! -f "$HOME/.aws/credentials" ]; then
        echo "Configuración de credenciales necesaria..."
        aws configure
    fi
    verificar_region
}

descargar_json_config() {
    local JSON_URL="https://raw.githubusercontent.com/thefather12/WS-EPRO/refs/heads/main/creacion.json"
    [ ! -f "$HOME/creacion.json" ] && curl -s -o "$HOME/creacion.json" "$JSON_URL"
}

# ----------------------------------------------------------------------
# 2. FUNCIONES ORIGINALES DE CLOUDFRONT (TU CÓDIGO RESTAURADO)
# ----------------------------------------------------------------------

get_config_and_etag() {
    local DIST_ID=$1
    aws cloudfront get-distribution --id "$DIST_ID" --output json > /tmp/temp_dist_info.json 2>/dev/null
    if [ $? -ne 0 ]; then return 1; fi
    CURRENT_ETAG=$(jq -r '.ETag' /tmp/temp_dist_info.json)
    jq '.Distribution.DistributionConfig' /tmp/temp_dist_info.json > "$CONFIG_FILE"
}

listar_distribuciones() {
    echo "--- Distribuciones CloudFront ---"
    aws cloudfront list-distributions --query 'DistributionList.Items[*].{ID:Id,Domain:DomainName,Status:Status,Enabled:Enabled}' --output table
}

ver_estado_distribucion() {
    read -p "ID de la Distribución: " DIST_ID
    aws cloudfront get-distribution --id "$DIST_ID" --query 'Distribution.{Id:Id,Status:Status,Enabled:Enabled,DomainName:DomainName}' --output table
}

editar_distribucion() {
    read -p "ID de la Distribución a editar: " DIST_ID
    if ! get_config_and_etag "$DIST_ID"; then echo "Error al obtener datos."; return; fi
    read -p "Nuevo Dominio de Origen: " NEW_ORIGIN
    jq ".Origins.Items[0].DomainName = \"$NEW_ORIGIN\"" "$CONFIG_FILE" > /tmp/updated.json
    aws cloudfront update-distribution --id "$DIST_ID" --distribution-config "file:///tmp/updated.json" --if-match "$CURRENT_ETAG"
    echo "✅ Origen actualizado."
}

toggle_distribucion() {
    read -p "ID de la Distribución: " DIST_ID
    if get_config_and_etag "$DIST_ID"; then
        STATUS=$(jq -r '.Enabled' "$CONFIG_FILE")
        NEW_S="true"; [ "$STATUS" == "true" ] && NEW_S="false"
        jq ".Enabled = $NEW_S" "$CONFIG_FILE" > /tmp/updated.json
        aws cloudfront update-distribution --id "$DIST_ID" --distribution-config "file:///tmp/updated.json" --if-match "$CURRENT_ETAG"
        echo "✅ Estado cambiado a $NEW_S"
    fi
}

eliminar_distribucion() {
    read -p "ID de la Distribución a ELIMINAR: " DIST_ID
    if get_config_and_etag "$DIST_ID"; then
        aws cloudfront delete-distribution --id "$DIST_ID" --if-match "$CURRENT_ETAG"
        echo "✅ Solicitud de eliminación enviada."
    fi
}

crear_distribucion() {
    read -p "Introduce el Dominio de Origen (ej: mi.web.com): " ORIGIN_DOMAIN
    CALLER_REF="CREACION-$(date +%s)"
    sed "s/nueva.multiservicio.xyz/$ORIGIN_DOMAIN/g" "$HOME/creacion.json" > /tmp/new_dist.json
    sed -i "s/\"CallerReference\": \".*\"/\"CallerReference\": \"$CALLER_REF\"/" /tmp/new_dist.json
    aws cloudfront create-distribution --distribution-config "file:///tmp/new_dist.json"
}

# ----------------------------------------------------------------------
# 3. NUEVA SECCIÓN: VPS EC2 (CAPA GRATUITA)
# ----------------------------------------------------------------------

crear_vps_ec2() {
    clear
    echo "--- CREACIÓN DE VPS EC2 (Free Tier) ---"
    echo "1) Amazon Linux | 2) Ubuntu | 3) Windows"
    read -p "SO: " SO_TYPE
    REGION=$(aws configure get region)

    case $SO_TYPE in
        1) AMI=$(aws ec2 describe-images --region "$REGION" --owners amazon --filters "Name=name,Values=al2023-ami-*-x86_64" --query 'sort_by(Images, &CreationDate)[-1].ImageId' --output text) ;;
        2) AMI=$(aws ec2 describe-images --region "$REGION" --owners 099720109477 --filters "Name=name,Values=ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-*" --query 'sort_by(Images, &CreationDate)[-1].ImageId' --output text) ;;
        3) AMI=$(aws ec2 describe-images --region "$REGION" --owners amazon --filters "Name=name,Values=Windows_Server-2022-English-Full-Base-*" --query 'sort_by(Images, &CreationDate)[-1].ImageId' --output text) ;;
        *) return ;;
    esac

    K_NAME="KEY_$(date +%s)"
    aws ec2 create-key-pair --key-name "$K_NAME" --query 'KeyMaterial' --output text > "$HOME/$K_NAME.pem"
    chmod 400 "$HOME/$K_NAME.pem"

    echo "Lanzando t2.micro en $REGION..."
    INST=$(aws ec2 run-instances --image-id "$AMI" --count 1 --instance-type t2.micro --key-name "$K_NAME" --block-device-mappings '[{"DeviceName":"/dev/xvda","Ebs":{"VolumeSize":30,"VolumeType":"gp3"}}]' --output json)
    ID=$(echo "$INST" | jq -r '.Instances[0].InstanceId')
    
    sleep 20
    IP=$(aws ec2 describe-instances --instance-ids "$ID" --query 'Reservations[0].Instances[0].PublicIpAddress' --output text)
    echo "✅ VPS LISTA. IP: $IP | Llave: $HOME/$K_NAME.pem"
}

# ----------------------------------------------------------------------
# 4. ORQUESTACIÓN DE MENÚS
# ----------------------------------------------------------------------

menu_vps() {
    while true; do
        clear
        echo "--- ADMINISTRACIÓN DE VPS ---"
        echo "1. Crear VPS (Capa Gratuita)"
        echo "2. Listar Instancias"
        echo "3. Password Windows"
        echo "0. Volver"
        read -p "Opción: " OV
        case $OV in
            1) crear_vps_ec2 ;;
            2) aws ec2 describe-instances --query 'Reservations[*].Instances[*].{ID:InstanceId,Status:State.Name,IP:PublicIpAddress}' --output table ;;
            3) read -p "ID: " IDW; read -p "Ruta PEM: " RPW; aws ec2 get-password-data --instance-id "$IDW" --priv-launch-key "$RPW" ;;
            0) break ;;
        esac
        read -p "ENTER..."
    done
}

menu_principal() {
    clear
    echo "========================================="
    echo "   AWS MANAGER v$CURRENT_VERSION"
    echo "========================================="
    echo "1. 🌐 CLOUDFRONT"
    echo "2. 🖥️ VPS EC2"
    echo "6. 🔑 Configurar AWS"
    echo "0. 🚪 Salir"
    read -p "Selecciona: " CAT
    case $CAT in
        1)
            echo "1. Listar | 2. Ver Estado | 3. On/Off | 4. Eliminar | 5. Crear"
            read -p "Opción: " CF_O
            case $CF_O in
                1) listar_distribuciones ;;
                2) ver_estado_distribucion ;;
                3) toggle_distribucion ;;
                4) eliminar_distribucion ;;
                5) crear_distribucion ;;
            esac ;;
        2) menu_vps ;;
        6) aws configure ;;
        0) exit 0 ;;
    esac
    read -p "Presiona ENTER..."
}

# Inicio del script
instalar_jq
instalar_aws_cli
configuracion_inicial_check
descargar_json_config
while true; do menu_principal; done

