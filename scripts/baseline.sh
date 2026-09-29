#!/bin/sh
# BC-250 Baseline — coleta números de referência ANTES de qualquer build
# Rodar no sistema stock (Alpine padrão ou Ubuntu temporário)
# Salva resultados em docs/baseline.md

set -eu

OUTPUT_DIR="${1:-.}"
BASELINE_FILE="$OUTPUT_DIR/baseline.md"
MODEL_PATH="${MODEL_PATH:-/data/models/model.gguf}"

log() {
    echo "$*"
}

collect_system() {
    log "=== Informações do sistema ==="
    echo "## Sistema" >> "$BASELINE_FILE"
    echo "" >> "$BASELINE_FILE"
    echo "\`\`\`" >> "$BASELINE_FILE"
    echo "Data: $(date -u '+%Y-%m-%d %H:%M:%S UTC')" >> "$BASELINE_FILE"
    echo "Kernel: $(uname -r)" >> "$BASELINE_FILE"
    echo "Distro: $(cat /etc/os-release 2>/dev/null | grep PRETTY_NAME | cut -d= -f2 | tr -d '\"')" >> "$BASELINE_FILE"
    echo "CPU: $(grep 'model name' /proc/cpuinfo | head -1 | cut -d: -f2 | xargs)" >> "$BASELINE_FILE"
    echo "RAM total: $(free -h | awk 'NR==2{print $2}')" >> "$BASELINE_FILE"
    echo "\`\`\`" >> "$BASELINE_FILE"
    echo "" >> "$BASELINE_FILE"
}

collect_firmware() {
    log "=== Firmware e BIOS ==="
    echo "## BIOS / Firmware" >> "$BASELINE_FILE"
    echo "" >> "$BASELINE_FILE"
    echo "\`\`\`" >> "$BASELINE_FILE"
    echo "BIOS: $(dmidecode -s bios-version 2>/dev/null || echo 'N/A')" >> "$BASELINE_FILE"
    echo "VRAM: $(grep -i 'VRAM\|memory' /var/log/bios* 2>/dev/null | head -1 || echo 'verificar manualmente')" >> "$BASELINE_FILE"
    echo "IOMMU: $(dmesg | grep -i iommu | head -1 || echo 'N/A')" >> "$BASELINE_FILE"
    echo "\`\`\`" >> "$BASELINE_FILE"
    echo "" >> "$BASELINE_FILE"
}

collect_gpu() {
    log "=== GPU ==="
    echo "## GPU" >> "$BASELINE_FILE"
    echo "" >> "$BASELINE_FILE"
    echo "\`\`\`" >> "$BASELINE_FILE"

    # PCI ID
    lspci -d 0x13fe: -v 2>/dev/null || echo "PCI 0x13fe não encontrado"

    # Driver
    lsmod | grep amdgpu >> "$BASELINE_FILE" 2>/dev/null || echo "amdgpu não carregado"

    # Vulkan
    if command -v vulkaninfo >/dev/null 2>&1; then
        vulkaninfo --summary 2>/dev/null | grep -E 'deviceName|driverName|driverInfo|apiVersion|num_cu' >> "$BASELINE_FILE" || true
    else
        echo "vulkaninfo não instalado" >> "$BASELINE_FILE"
    fi

    # CUs ativos
    if dmesg | grep -q 'active_cu_number'; then
        dmesg | grep 'active_cu_number' | tail -1 >> "$BASELINE_FILE"
    else
        echo "active_cu_number não encontrado (24 CUs stock)" >> "$BASELINE_FILE"
    fi

    # Clock atual
    if [ -f /sys/class/drm/card0/device/pp_dpm_sclk ]; then
        echo "GPU clocks: $(cat /sys/class/drm/card0/device/pp_dpm_sclk)" >> "$BASELINE_FILE"
    fi

    echo "\`\`\`" >> "$BASELINE_FILE"
    echo "" >> "$BASELINE_FILE"
}

collect_memory() {
    log "=== Memória ==="
    echo "## Memória" >> "$BASELINE_FILE"
    echo "" >> "$BASELINE_FILE"
    echo "\`\`\`" >> "$BASELINE_FILE"
    free -h >> "$BASELINE_FILE"
    echo "" >> "$BASELINE_FILE"

    # GTT / TTM
    dmesg | grep -iE 'gtt|ttm|VRAM' | tail -5 >> "$BASELINE_FILE" 2>/dev/null || true

    # VRAM visível
    if command -v vulkaninfo >/dev/null 2>&1; then
        vulkaninfo 2>/dev/null | grep -A5 'memoryHeaps' | head -10 >> "$BASELINE_FILE" || true
    fi

    echo "\`\`\`" >> "$BASELINE_FILE"
    echo "" >> "$BASELINE_FILE"
}

collect_sensors() {
    log "=== Sensores ==="
    echo "## Sensores (idle)" >> "$BASELINE_FILE"
    echo "" >> "$BASELINE_FILE"
    echo "\`\`\`" >> "$BASELINE_FILE"
    sensors 2>/dev/null | grep -E 'edge|Tctl|Tdie|Package|VRM|fan|in' | head -20 >> "$BASELINE_FILE" || echo "lm-sensors não configurado"
    echo "\`\`\`" >> "$BASELINE_FILE"
    echo "" >> "$BASELINE_FILE"
}

run_benchmark() {
    log "=== Benchmark (llama-bench) ==="
    echo "## Benchmark" >> "$BASELINE_FILE"
    echo "" >> "$BASELINE_FILE"

    if [ ! -f "$MODEL_PATH" ]; then
        echo "Modelo não encontrado: $MODEL_PATH" >> "$BASELINE_FILE"
        echo "Defina MODEL_PATH ou coloque o modelo em /data/models/" >> "$BASELINE_FILE"
        return 0
    fi

    if ! command -v llama-bench >/dev/null 2>&1; then
        echo "llama-bench não instalado" >> "$BASELINE_FILE"
        echo "Instale llama.cpp primeiro" >> "$BASELINE_FILE"
        return 0
    fi

    echo "\`\`\`" >> "$BASELINE_FILE"
    echo "Modelo: $MODEL_PATH" >> "$BASELINE_FILE"
    echo "Comando: llama-bench -m $MODEL_PATH -ngl 99 -fa" >> "$BASELINE_FILE"
    echo "" >> "$BASELINE_FILE"

    # pp512
    echo "### pp512 (prompt processing)" >> "$BASELINE_FILE"
    llama-bench -m "$MODEL_PATH" -ngl 99 -fa -p 512 -n 0 2>/dev/null | tail -20 >> "$BASELINE_FILE" || true

    echo "" >> "$BASELINE_FILE"

    # tg (token generation)
    echo "### tg (token generation)" >> "$BASELINE_FILE"
    llama-bench -m "$MODEL_PATH" -ngl 99 -fa -p 512 -n 128 2>/dev/null | tail -20 >> "$BASELINE_FILE" || true

    echo "\`\`\`" >> "$BASELINE_FILE"
    echo "" >> "$BASELINE_FILE"
}

run_thermal_test() {
    log "=== Teste térmico (10 min de carga) ==="
    echo "## Teste térmico" >> "$BASELINE_FILE"
    echo "" >> "$BASELINE_FILE"
    echo "\`\`\`" >> "$BASELINE_FILE"

    if [ ! -f "$MODEL_PATH" ] || ! command -v llama-bench >/dev/null 2>&1; then
        echo "Teste térmico pulado (modelo ou llama-bench ausente)" >> "$BASELINE_FILE"
        echo "\`\`\`" >> "$BASELINE_FILE"
        return 0
    fi

    echo "Iniciando 10 min de llama-bench contínuo..." >> "$BASELINE_FILE"
    echo "Temperatura a cada 30s:" >> "$BASELINE_FILE"

    for i in $(seq 1 20); do
        temp=$(sensors 2>/dev/null | grep -E 'edge|Tctl|Tdie|Package' | head -1 | grep -oP '[+-]?\d+\.\d+' | cut -d. -f1 || echo "?")
        echo "  ${i}0s: ${temp}°C" >> "$BASELINE_FILE"
        sleep 30
    done

    echo "\`\`\`" >> "$BASELINE_FILE"
    echo "" >> "$BASELINE_FILE"
}

# === Main ===
log "=== BC-250 Baseline Collection ==="
log "Saída: $BASELINE_FILE"
log ""

# Header
cat > "$BASELINE_FILE" <<EOF
# BC-250 Baseline
> Coletado em $(date -u '+%Y-%m-%d %H:%M:%S UTC')
> Use estes números para comparar após builds otimizados

EOF

collect_system
collect_firmware
collect_gpu
collect_memory
collect_sensors
run_benchmark
run_thermal_test

log ""
log "=== Baseline salvo em $BASELINE_FILE ==="
log "Próximos passos:"
log "  1. Verificar que Vulkan mostra RADV (não llvmpipe)"
log "  2. Salvar tok/s pp512 e tg como referência"
log "  3. Monitorar temperatura durante 10 min de carga"
log "  4. Anotar RAM livre em idle"