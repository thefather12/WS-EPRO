#!/bin/bash

# Auto-corrección de formato (Elimina caracteres de Windows si existen)
sed -i 's/\r$//' "$0" 2>/dev/null

# ==============================================================
# SCRIPT UNIFICADO: ADMIN CLOUDFRONT + VPS EC2 (CAPA GRATUITA)
# Versión 6.1.0
# ==============================================================

# --- VARIABLES GLOBALES ---
CURRENT_VERSION="6.1.0"
AWS_CLI_URL="https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip"
INSTALL_DIR="/usr/local"
AWS_BIN_PATH="$INSTALL_DIR/bin"
CONFIG_FILE="/tmp/cloudfront_config_$$.json"

# ----------------------------------------------------------------------
# FUNCIONES DE INSTALACIÓN Y REQUISITOS
# ----------------------------------------------------------------------

export_aws_path() {
    if [[ ":$PATH:" != *":$AWS_BIN_PATH:"* ]]; then
        export PATH="$PATH:$AWS_BIN_PATH"
    fi
}

instalar_dependencias() {
    if ! command -v jq &> /dev/null; then
        echo "Instalando jq..."
        sudo apt update > /dev/null 2>&1 && sudo apt install -y jq > /dev/null 2>&1
    fi
    if ! command -v aws &> /dev/null; then
        echo "Instalando AWS CLI v2..."
        sudo apt update > /dev/null 2>&1 && sudo apt install -y unzip curl > /dev/null 2>&1
        curl -s "$AWS_CLI_URL" -o "/tmp/awscliv2.zip"
        unzip -q "/tmp/awscliv2.zip" -d /tmp
        sudo /tmp/aws/install --install-dir "$INSTALL_DIR/aws-cli" --bin-dir "$AWS_BIN_PATH" --update
        rm -rf "/tmp/awscliv2.zip" "/tmp/aws"
    fi
    export_aws_path
}

configuracion_inicial_check() {
    if [ ! -f "$HOME/.aws/credentials" ]; then
        echo "⚠️ No se detectaron credenciales de AWS."
        aws configure
    fi
}

# ----------------------------------------------------------------------
# SECCIÓN: CLOUDFRONT (FUNCIONES RESTAURADAS)
# ----------------------------------------------------------------------

get_config_and_etag() {
    local DIST_ID=$1
    echo "Obteniendo configuración de la distribución $DIST_ID..."
    aws cloudfront get-distribution --id "$DIST_ID" --output json > /tmp/temp_dist_info.json 2>/dev/null
    if [ $? -ne 0 ]; then echo "❌ Error: ID no encontrado."; return 1; fi
    CURRENT_ETAG=$(jq -r '.ETag' /tmp/temp_dist_info.json)
    jq '.Distribution.DistributionConfig' /tmp/temp_dist_info.json > "$CONFIG_FILE"
}

listar_distribuciones() {
    echo "Buscando distribuciones en tu cuenta..."
    aws cloudfront list-distributions --query 'DistributionList.Items[*].{ID:Id,Domain:DomainName,Status:Status,Enabled:Enabled}' --output table
}

editar_distribucion() {
    read -p "Introduce el ID de la Distribución a editar: " DIST_ID
    if ! get_config_and_etag "$DIST_ID"; then return; fi
    read -p "Introduce el NUEVO Dominio de Origen (ej: mi.nuevo.dominio.com): " NEW_ORIGIN
    jq ".Origins.Items[0].DomainName = \"$NEW_ORIGIN\"" "$CONFIG_FILE" > /tmp/updated.json
    aws cloudfront update-distribution --id "$DIST_ID" --distribution-config "file:///tmp/updated.json" --if-match "$CURRENT_ETAG"
    echo "✅ Origen actualizado correctamente."
}

toggle_distribucion() {
    read -p "ID de la Distribución a Activar/Desactivar: " DIST_ID
    if get_config_and_etag "$DIST_ID"; then
        STATUS=$(jq -r '.Enabled' "$CONFIG_FILE")
        NEW_STATUS="true"; [ "$STATUS" == "true" ] && NEW_STATUS="false"
        jq ".Enabled = $NEW_STATUS" "$CONFIG_FILE" > /tmp/updated.json
        aws cloudfront update-distribution --id "$DIST_ID" --distribution-config "file:///tmp/updated.json" --if-match "$CURRENT_ETAG"
        echo "✅ Estado cambiado a: $NEW_STATUS"
    fi
}

# ----------------------------------------------------------------------
# SECCIÓN: VPS EC2 (NUEVO)
# ----------------------------------------------------------------------

crear_vps_ec2() {
    clear
    echo "--- CREACIÓN DE VPS (CAPA GRATUITA) ---"
    echo "1) Amazon Linux 2023 | 2) Ubuntu 22.04 | 3) Windows 2022"
    read -p "Opción: " SO_TYPE
    case $SO_TYPE in
        1) AMI_ID=$(aws ec2 describe-images --owners amazon --filters "Name=name,Values=al2023-ami-*-x86_64" --query 'sort_by(Images, &CreationDate)[-1].ImageId' --output text) ;;
        2) AMI_ID=$(aws ec2 describe-images --owners 099720109477 --filters "Name=name,Values=ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-*" --query 'sort_by(Images, &CreationDate)[-1].ImageId' --output text) ;;
        3) AMI_ID=$(aws ec2 describe-images --owners amazon --filters "Name=name,Values=Windows_Server-2022-English-Full-Base-*" --query 'sort_by(Images, &CreationDate)[-1].ImageId' --output text) ;;
        *) return ;;
    esac

    KEY_NAME="KEY_$(date +%s)"
    aws ec2 create-key-pair --key-name "$KEY_NAME" --query 'KeyMaterial' --output text > "$HOME/$KEY_NAME.pem"
    chmod 400 "$HOME/$KEY_NAME.pem"

    INSTANCE_INFO=$(aws ec2 run-instances --image-id "$AMI_ID" --count 1 --instance-type t2.micro --key-name "$KEY_NAME" --block-device-mappings '[{"DeviceName":"/dev/xvda","Ebs":{"VolumeSize":30,"VolumeType":"gp3"}}]' --output json)
    INSTANCE_ID=$(echo "$INSTANCE_INFO" | jq -r '.Instances[0].InstanceId')
    
    echo "Lanzando VPS... Esperando IP..."
    sleep 20
    PUBLIC_IP=$(aws ec2 describe-instances --instance-ids "$INSTANCE_ID" --query 'Reservations[0].Instances[0].PublicIpAddress' --output text)
    
    echo "✅ VPS CREADA. IP: $PUBLIC_IP"
    echo "🔑 Llave: $HOME/$KEY_NAME.pem"
}

listar_vps() {
    aws ec2 describe-instances --query 'Reservations[*].Instances[*].{ID:InstanceId,Status:State.Name,IP:PublicIpAddress,Type:InstanceType}' --output table
}

# ----------------------------------------------------------------------
# MENÚS
# ----------------------------------------------------------------------

menu_vps() {
    while true; do
        clear
        echo "--- MENÚ VPS EC2 ---"
        echo "1) Crear VPS | 2) Listar | 3) Password Windows | 0) Volver"
        read -p "Opción: " OV
        case $OV in
            1) crear_vps_ec2 ;;
            2) listar_vps ;;
            3) read -p "ID Instancia: " IDW; read -p "Ruta PEM: " RPW; aws ec2 get-password-data --instance-id "$IDW" --priv-launch-key "$RPW" ;;
            0) break ;;
        esac
        read -p "ENTER..."
    done
}

menu_principal() {
    clear
    echo "========================================="
    echo "    AWS ADMIN TOOL v$CURRENT_VERSION"
    echo "========================================="
    echo "1. 🌐 GESTIONAR CLOUDFRONT"
    echo "2. 🖥️ GESTIONAR VPS (EC2)"
    echo "6. 🔑 Configurar AWS CLI"
    echo "0. 🚪 Salir"
    read -p "Selecciona: " CAT
    case $CAT in
        1)
            echo "1. Listar | 2. Editar | 3. On/Off"
            read -p "Opción: " CF_O
            case $CF_O in
                1) listar_distribuciones ;;
                2) editar_distribucion ;;
                3) toggle_distribucion ;;
            esac ;;
        2) menu_vps ;;
        6) aws configure ;;
        0) exit 0 ;;
    esac
    read -p "Presiona ENTER..."
}

# --- INICIO ---
instalar_dependencias
configuracion_inicial_check
while true; do menu_principal; done
