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
AWS_CLI=$(which aws 2>/dev/null)
JQ_CLI=$(which jq 2>/dev/null)

# ----------------------------------------------------------------------
# FUNCIONES DE INSTALACIÓN Y REQUISITOS (MANTENIDAS)
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
    sudo apt update > /dev/null 2>&1 && sudo apt install -y jq
    JQ_CLI=$(which jq); return 0
}

instalar_aws_cli() {
    if check_command "aws"; then AWS_CLI=$(which aws); return 0; fi
    sudo apt install -y unzip curl
    curl -s "$AWS_CLI_URL" -o "/tmp/awscliv2.zip"
    unzip -q "/tmp/awscliv2.zip" -d /tmp
    sudo /tmp/aws/install --install-dir "$INSTALL_DIR/aws-cli" --bin-dir "$AWS_BIN_PATH"
    rm -rf "/tmp/awscliv2.zip" "/tmp/aws"
    export_aws_path
    return 0
}

configurar_aws_manual() {
    export_aws_path 
    "$AWS_CLI" configure
}

configuracion_inicial_check() {
    if [ ! -f "$HOME/.aws/credentials" ]; then configurar_aws_manual; fi
}

# ----------------------------------------------------------------------
# SECCIÓN NUEVA: GESTIÓN DE VPS EC2 (CAPA GRATUITA)
# ----------------------------------------------------------------------

crear_vps_ec2() {
    echo "========================================="
    echo "   🚀 CREACIÓN DE VPS (CAPA GRATUITA)   "
    echo "========================================="
    
    # 1. Selección de Sistema Operativo
    echo "Selecciona el SO:"
    echo "1) Amazon Linux 2023 (Recomendado)"
    echo "2) Ubuntu Server 22.04 LTS"
    echo "3) Windows Server 2022 (Requiere descifrar pass)"
    read -p "Opción: " SO_TYPE

    case $SO_TYPE in
        1) AMI_ID=$("$AWS_CLI" ec2 describe-images --owners amazon --filters "Name=name,Values=al2023-ami-*-x86_64" --query 'sort_by(Images, &CreationDate)[-1].ImageId' --output text) ;;
        2) AMI_ID=$("$AWS_CLI" ec2 describe-images --owners 099720109477 --filters "Name=name,Values=ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-*" --query 'sort_by(Images, &CreationDate)[-1].ImageId' --output text) ;;
        3) AMI_ID=$("$AWS_CLI" ec2 describe-images --owners amazon --filters "Name=name,Values=Windows_Server-2022-English-Full-Base-*" --query 'sort_by(Images, &CreationDate)[-1].ImageId' --output text) ;;
        *) echo "Opción inválida"; return ;;
    esac

    # 2. Configurar Llaves SSH
    KEY_NAME="AWS_KEY_$(date +%s)"
    echo "Generando par de llaves: $KEY_NAME.pem"
    "$AWS_CLI" ec2 create-key-pair --key-name "$KEY_NAME" --query 'KeyMaterial' --output text > "$HOME/$KEY_NAME.pem"
    chmod 400 "$HOME/$KEY_NAME.pem"
    echo "✅ Llave guardada en: $HOME/$KEY_NAME.pem"

    # 3. Lanzar Instancia (t2.micro es capa gratuita en la mayoría de regiones)
    echo "Lanzando instancia t2.micro..."
    INSTANCE_INFO=$("$AWS_CLI" ec2 run-instances \
        --image-id "$AMI_ID" \
        --count 1 \
        --instance-type t2.micro \
        --key-name "$KEY_NAME" \
        --block-device-mappings '[{"DeviceName":"/dev/xvda","Ebs":{"VolumeSize":30,"VolumeType":"gp3"}}]' \
        --output json)

    INSTANCE_ID=$(echo "$INSTANCE_INFO" | "$JQ_CLI" -r '.Instances[0].InstanceId')
    
    echo "⏳ Esperando a que la instancia esté activa e IP asignada..."
    sleep 15
    PUBLIC_IP=$("$AWS_CLI" ec2 describe-instances --instance-ids "$INSTANCE_ID" --query 'Reservations[0].Instances[0].PublicIpAddress' --output text)

    echo "========================================="
    echo "✅ VPS CREADA EXITOSAMENTE"
    echo "ID: $INSTANCE_ID"
    echo "IP Pública: $PUBLIC_IP"
    echo "Llave: $HOME/$KEY_NAME.pem"
    
    if [ "$SO_TYPE" == "3" ]; then
        echo "⏳ Para Windows, espera 4 minutos y usa la opción 'Obtener Contraseña' en el menú."
    else
        echo "Para entrar desde terminal:"
        echo "ssh -i \"$HOME/$KEY_NAME.pem\" ec2-user@$PUBLIC_IP"
    fi
    echo "========================================="
}

obtener_pass_windows() {
    read -p "Introduce el ID de la instancia Windows: " INST_ID
    read -p "Ruta completa del archivo .pem: " PEM_PATH
    echo "Descifrando contraseña..."
    "$AWS_CLI" ec2 get-password-data --instance-id "$INST_ID" --priv-launch-key "$PEM_PATH"
}

listar_vps() {
    echo "--- Tus Instancias EC2 ---"
    "$AWS_CLI" ec2 describe-instances --query 'Reservations[*].Instances[*].{ID:InstanceId,Status:State.Name,IP:PublicIpAddress,Type:InstanceType}' --output table
}

# ----------------------------------------------------------------------
# MENÚS Y ORQUESTACIÓN (MODIFICADO)
# ----------------------------------------------------------------------

menu_vps() {
    clear
    echo "========================================="
    echo "       ADMINISTRACIÓN DE VPS EC2        "
    echo "========================================="
    echo "1. 🚀 Crear Nueva VPS (Capa Gratuita)"
    echo "2. 📋 Listar mis Instancias e IPs"
    echo "3. 🔑 Obtener Contraseña Windows"
    echo "4. 🛑 Detener/Eliminar Instancia"
    echo "0. ⬅️ Volver al Menú Principal"
    echo "-----------------------------------------"
    read -p "Selecciona una opción: " OPC_VPS
    case $OPC_VPS in
        1) crear_vps_ec2 ;;
        2) listar_vps ;;
        3) obtener_pass_windows ;;
        4) echo "Usa: aws ec2 terminate-instances --instance-ids <ID>" ;;
        0) return ;;
    esac
    read -p "Presiona ENTER para continuar..."
}

# (Aquí irían todas tus funciones originales de CloudFront que ya tienes)
# ... [Omitido por brevedad, mantén tus funciones listar_distribuciones, editar, etc.] ...

menu_principal() {
    clear
    echo "========================================="
    echo " AWS ADMIN TOOL ALL-IN-ONE (v$CURRENT_VERSION)"
    echo "========================================="
    echo "1. 🌐 GESTIONAR CLOUDFRONT"
    echo "2. 🖥️ GESTIONAR VPS (EC2)"
    echo "-----------------------------------"
    echo "6. 🔑 Configurar Credenciales AWS" 
    echo "7. 🔄 Actualizar Script" 
    echo "0. 🚪 Salir"
    echo "-----------------------------------------"
    read -p "Selecciona una categoría: " CAT
    
    case $CAT in
        1) # Submenú CloudFront (Tus opciones originales)
            echo "1. Listar | 2. Editar | 3. Activar/Desactivar | 4. Eliminar | 5. Crear"
            read -p "Opción: " CF_OPC
            case $CF_OPC in
                1) listar_distribuciones ;;
                2) editar_distribucion ;;
                3) toggle_distribucion ;;
                4) eliminar_distribucion ;;
                5) crear_distribucion ;;
            esac ;;
        2) menu_vps ;;
        6) configurar_aws_manual ;; 
        7) actualizar_script ;; 
        0) exit 0 ;;
    esac
    read -p "Presiona ENTER..."
}

start_script() {
    instalar_jq
    instalar_aws_cli
    configuracion_inicial_check
    while true; do menu_principal; done
}

start_script
