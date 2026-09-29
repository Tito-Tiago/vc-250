#!/bin/sh
# BC-250 LLM Alpine — instalação dual-boot idempotente
# NÃO formata a ESP existente. NÃO toca no outro Linux.
#
# Uso: setup.sh [--check | --install | --configure | --grub | --all]
#
# Pré-requisitos:
#   - Alpine instalado no modo "disk" (setup-alpine já rodou)
#   - Partição Alpine formatada (ext4) com /boot dentro de /
#   - ESP existente montada ou detectável
#   - Espaço livre confirmado

set -eu

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
CONFIG_DIR="$REPO_DIR/configs"
OPENRC_DIR="$REPO_DIR/openrc"
LOG_FILE="/var/log/bc250-setup.log"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG_FILE"
}

die() {
    log "ERRO: $*"
    exit 1
}

check_esp() {
    log "=== Verificando ESP existente ==="

    # Procura partição ESP por PARTLABEL ou filesystem vfat com flag boot
    ESP_PART=""
    for part in /dev/sd*[0-9] /dev/nvme*n*p[0-9]; do
        [ -b "$part" ] || continue
        # Verifica se é vfat com flag boot (EFI)
        if blkid "$part" 2>/dev/null | grep -qi 'vfat'; then
            if sfdisk --dump "$(echo "$part" | sed 's/p[0-9]*$//;s/[0-9]*$//')" 2>/dev/null | grep -q 'type=U,.*bootable\|type=U'; then
                ESP_PART="$part"
                break
            fi
        fi
    done

    # Fallback: procura por /boot/efi já montado
    if [ -z "$ESP_PART" ] && mountpoint -q /boot/efi 2>/dev/null; then
        ESP_PART=$(findmnt -n -o SOURCE /boot/efi 2>/dev/null || true)
    fi

    if [ -z "$ESP_PART" ]; then
        die "ESP não encontrada. Formate manualmente uma partição vfat ou verifique o particionamento."
    fi

    log "ESP encontrada: $ESP_PART"

    # Verifica que NÃO vamos formatar
    if ! blkid "$ESP_PART" 2>/dev/null | grep -qi 'vfat\|fat32'; then
        die "Partição $ESP_PART não é vfat. Não vou formatar — abortando por segurança."
    fi

    # Mostra conteúdo atual da ESP
    log "Conteúdo atual da ESP:"
    mkdir -p /mnt/esp-check
    mount "$ESP_PART" /mnt/esp-check 2>/dev/null || true
    ls -la /mnt/esp-check/EFI/ 2>/dev/null || log "  (diretório EFI não encontrado ou vazio)"
    umount /mnt/esp-check 2>/dev/null || true

    echo "$ESP_PART"
}

check_disk() {
    log "=== Verificando layout de disco ==="

    log "Partições atuais:"
    lsblk -f
    echo ""

    log "Partições montadas:"
    df -h | grep -v tmpfs
    echo ""

    # Verifica que /boot está dentro de / (não é partição separada)
    if mountpoint -q /boot 2>/dev/null; then
        boot_source=$(findmnt -n -o SOURCE /boot 2>/dev/null)
        root_source=$(findmnt -n -o SOURCE / 2>/dev/null)
        if [ "$boot_source" != "$root_source" ]; then
            log "AVISO: /boot está em partição separada ($boot_source)"
            log "Para dual-boot, o ideal é /boot dentro de /"
            log "Considere reinstalar com /boot dentro de /"
        fi
    fi

    # Verifica espaço livre
    root_free=$(df -h / | awk 'NR==2{print $4}')
    log "Espaço livre em /: $root_free"

    # Verifica partição de modelos
    if mountpoint -q /data/models 2>/dev/null; then
        models_free=$(df -h /data/models | awk 'NR==2{print $4}')
        log "Espaço livre em /data/models: $models_free"
    else
        log "AVISO: /data/models não montado — criar partição para modelos"
    fi
}

install_packages() {
    log "=== Instalando pacotes BC-250 ==="

    # Repositório local (APKs compilados)
    if [ -d "$REPO_DIR/packages/x86_64" ]; then
        log "Adicionando repositório local de APKs"
        echo "$REPO_DIR/packages/x86_64" >> /etc/apk/repositories
        apk update
    fi

    # Pacotes base
    log "Instalando firmware e drivers GPU"
    apk add linux-firmware-amdgpu mesa mesa-gl mesa-dri-gallium mesa-vulkan-ati \
        vulkan-loader vulkan-tools mesa-demos

    # Kernel BC-250 (se compilado) ou linux-lts padrão
    if apk info -e linux-bc250-lts 2>/dev/null; then
        log "linux-bc250-lts já instalado"
    elif apk search -q linux-bc250-lts 2>/dev/null | grep -q linux-bc250-lts; then
        log "Instalando linux-bc250-lts"
        apk add linux-bc250-lts
    else
        log "linux-bc250-lts não disponível — usando linux-lts padrão"
        apk add linux-lts
    fi

    # Governor SMU
    if apk search -q cyan-skillfish-governor-smu 2>/dev/null | grep -q cyan-skillfish; then
        log "Instalando governor SMU"
        apk add cyan-skillfish-governor-smu
    else
        log "AVISO: governor SMU não disponível no repositório local"
        log "Compilar primeiro: make governor"
    fi

    # llama.cpp
    if apk search -q llama.cpp-bc250 2>/dev/null | grep -q llama; then
        log "Instalando llama.cpp-bc250"
        apk add llama.cpp-bc250
    else
        log "AVISO: llama.cpp-bc250 não disponível — compilar: make llama"
    fi

    # Sensores
    apk add lm-sensors

    # Ferramentas de rede e utilitários
    apk add openssh curl wget htop

    # Usuário de serviço para llama-server
    if ! id llama >/dev/null 2>&1; then
        adduser -D -s /sbin/nologin -h /var/lib/llama llama
    fi
    addgroup llama render 2>/dev/null || true
    addgroup llama video 2>/dev/null || true

    log "Pacotes instalados"
}

configure_system() {
    log "=== Configurando sistema ==="

    # Modprobe configs
    install -Dm644 "$CONFIG_DIR/modprobe.d/bc250-40cu.conf" \
        /etc/modprobe.d/bc250-40cu.conf
    install -Dm644 "$CONFIG_DIR/modprobe.d/nct6683.conf" \
        /etc/modprobe.d/nct6683.conf

    # Sysctl
    install -Dm644 "$CONFIG_DIR/sysctl/90-bc250-llm.conf" \
        /etc/sysctl.d/90-bc250-llm.conf
    sysctl --system 2>/dev/null || true

    # Config do llama-server
    mkdir -p /etc/llama-server/profiles
    cp -a "$CONFIG_DIR/llama-server/profiles/"* /etc/llama-server/profiles/
    if [ ! -f /etc/conf.d/llama-server ]; then
        cp "$CONFIG_DIR/llama-server.conf" /etc/conf.d/llama-server
    fi

    # Config do governor
    mkdir -p /etc/cyan-skillfish-governor-smu
    if [ ! -f /etc/cyan-skillfish-governor-smu/config.toml ]; then
        cp "$CONFIG_DIR/governor/config.toml" \
            /etc/cyan-skillfish-governor-smu/config.toml
    fi

    # D-Bus policy para governor
    install -Dm644 "$REPO_DIR/apkbuilds/cyan-skillfish-governor-smu/com.cyan.skillfishgovernor.conf" \
        /etc/dbus-1/system.d/com.cyan.skillfishgovernor.conf

    # OpenRC services
    for svc in llama-server bc250-thermal-watchdog; do
        [ -f "$OPENRC_DIR/$svc.initd" ] && \
            install -Dm755 "$OPENRC_DIR/$svc.initd" "/etc/init.d/$svc"
    done

    # Governor service (do APK ou manual)
    if [ ! -f /etc/init.d/cyan-skillfish-governor-smu ]; then
        install -Dm755 "$REPO_DIR/apkbuilds/cyan-skillfish-governor-smu/cyan-skillfish-governor-smu.initd" \
            /etc/init.d/cyan-skillfish-governor-smu
    fi

    # Habilitar serviços
    rc-update add dbus default 2>/dev/null || true
    rc-update add sshd default 2>/dev/null || true
    rc-update add cyan-skillfish-governor-smu default 2>/dev/null || true
    rc-update add llama-server default 2>/dev/null || true
    rc-update add bc250-thermal-watchdog default 2>/dev/null || true

    # Atualizar initramfs
    mkinitfs

    log "Sistema configurado"
}

configure_grub() {
    log "=== Configurando GRUB ==="

    # Detecta qual Linux dono da ESP
    # Regra: se Alpine tem grub-install, é dono senão configura o do outro

    if command -v grub-mkconfig >/dev/null 2>&1; then
        log "GRUB encontrado — gerando configuração"

        # Detecta outros sistemas
        if command -v os-prober >/dev/null 2>&1; then
            log "Rode os-prober para detectar outros sistemas:"
            echo "  os-prober"
            echo "  grub-mkconfig -o /boot/grub/grub.cfg"
        fi

        # Configuração padrão do GRUB para BC-250
        if [ -f /etc/default/grub ]; then
            if ! grep -q 'ttm.pages_limit' /etc/default/grub; then
                log "Adicionando cmdline BC-250 ao GRUB"
                sed -i 's/GRUB_CMDLINE_LINUX_DEFAULT="\(.*\)"/GRUB_CMDLINE_LINUX_DEFAULT="\1 mitigations=off ttm.pages_limit=4194304"/' \
                    /etc/default/grub
            fi
        fi

        log "Execute: grub-mkconfig -o /boot/grub/grub.cfg"
    else
        log "GRUB não encontrado no Alpine"
        log "Se o outro Linux é dono da ESP:"
        log "  1. Boot no outro Linux"
        log "  2. apt install os-prober (ou dnf install os-prober)"
        log "  3. os-prober"
        log "  4. grub-mkconfig -o /boot/grub/grub.cfg"
        log ""
        log "Entrada GRUB manual para o Alpine:"
        cat <<'GRUB_ENTRY'
menuentry "Alpine BC-250 LLM" {
    search --no-floppy --set=root --label ALPINE_BOT
    linux /boot/vmlinuz-bc250-lts root=UUID=<UUID_DA_PARTICAO_ALPINE> mitigations=off ttm.pages_limit=4194304 quiet
    initrd /boot/initramfs-bc250-lts
}
GRUB_ENTRY
    fi

    # Entrada EFI para firmware (se Alpine é dono da ESP)
    if [ -d /boot/efi/EFI ]; then
        log "Entradas EFI atuais:"
        efibootmgr -v 2>/dev/null | grep -i alpine || log "  (nenhuma entrada Alpine encontrada)"
    fi
}

check_status() {
    log "=== Status do sistema ==="

    log "Kernel:"
    uname -r

    log "GPU:"
    if [ -d /sys/module/amdgpu ]; then
        log "  amdgpu carregado"
        if [ -f /sys/module/amdgpu/parameters/bc250_cc_write_mode ]; then
            log "  bc250_cc_write_mode=$(cat /sys/module/amdgpu/parameters/bc250_cc_write_mode)"
        fi
    else
        log "  amdgpu NÃO carregado"
    fi

    log "Vulkan:"
    if command -v vulkaninfo >/dev/null 2>&1; then
        vulkaninfo --summary 2>/dev/null | grep -E 'deviceName|driverName|num_cu' || true
    fi

    log "Serviços:"
    for svc in cyan-skillfish-governor-smu llama-server bc250-thermal-watchdog; do
        if rc-service "$svc" status >/dev/null 2>&1; then
            log "  $svc: ativo"
        else
            log "  $svc: inativo"
        fi
    done

    log "Memória:"
    free -h

    log "Sensores:"
    sensors 2>/dev/null | grep -E 'edge|Tctl|Tdie|Package' || true
}

case "${1:---check}" in
    --check)
        check_esp
        check_disk
        check_status
        ;;
    --install)
        install_packages
        ;;
    --configure)
        configure_system
        ;;
    --grub)
        configure_grub
        ;;
    --status)
        check_status
        ;;
    --all)
        check_esp
        check_disk
        install_packages
        configure_system
        configure_grub
        check_status
        ;;
    *)
        echo "Uso: $0 [--check | --install | --configure | --grub | --status | --all]"
        exit 1
        ;;
esac