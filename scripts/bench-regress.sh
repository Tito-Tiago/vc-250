#!/bin/sh
# BC-250 Regression Benchmark
# Rode após cada bump de kernel/Mesa/llama.cpp/governor
# Compara contra baseline e falha se queda > 5%

set -eu

BASELINE_DIR="${BASELINE_DIR:-/var/lib/bc250-bench}"
CURRENT_FILE="$BASELINE_DIR/current.md"
THRESHOLD="${THRESHOLD:-5}"  # % máximo de queda permitida

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"
}

die() {
    log "FALHA: $*"
    exit 1
}

check_environment() {
    log "=== Ambiente ==="

    # GPU
    if ! lspci -d 0x13fe: >/dev/null 2>&1; then
        die "BC-250 GPU (PCI 0x13fe) não encontrada"
    fi

    # amdgpu
    if [ ! -d /sys/module/amdgpu ]; then
        die "amdgpu não carregado"
    fi

    # 40 CU check
    cu_count=$(dmesg | grep 'active_cu_number' | tail -1 | grep -oP '\d+$' || echo "24")
    log "CUs ativos: $cu_count"

    # Vulkan
    if ! command -v vulkaninfo >/dev/null 2>&1; then
        die "vulkaninfo não instalado"
    fi

    vulkan_device=$(vulkaninfo --summary 2>/dev/null | grep 'deviceName' | head -1 || true)
    if echo "$vulkan_device" | grep -qi 'llvmpipe\|software'; then
        die "Vulkan caiu para software (llvmpipe) — verificar grupo render e driver"
    fi
    log "Vulkan device: $vulkan_device"

    # Governor
    if rc-service cyan-skillfish-governor-smu status >/dev/null 2>&1; then
        log "Governor SMU: ativo"
    else
        log "AVISO: Governor SMU inativo — performance pode ser menor"
    fi

    echo "## Ambiente" >> "$CURRENT_FILE"
    echo "\`\`\`" >> "$CURRENT_FILE"
    echo "Data: $(date -u '+%Y-%m-%d %H:%M:%S UTC')" >> "$CURRENT_FILE"
    echo "Kernel: $(uname -r)" >> "$CURRENT_FILE"
    echo "CUs: $cu_count" >> "$CURRENT_FILE"
    echo "GPU: $vulkan_device" >> "$CURRENT_FILE"
    echo "Governor: $(rc-service cyan-skillfish-governor-smu status 2>&1 | head -1)" >> "$CURRENT_FILE"
    echo "\`\`\`" >> "$CURRENT_FILE"
    echo "" >> "$CURRENT_FILE"
}

run_bench() {
    model="$1"
    label="$2"
    pp_size="${3:-512}"
    tg_size="${4:-128}"

    if [ ! -f "$model" ]; then
        log "Modelo não encontrado: $model (pulando $label)"
        return 0
    fi

    if ! command -v llama-bench >/dev/null 2>&1; then
        die "llama-bench não instalado"
    fi

    log "Bench: $label (pp$pp_size, tg$tg_size)"

    echo "### $label" >> "$CURRENT_FILE"
    echo "\`\`\`" >> "$CURRENT_FILE"
    echo "Modelo: $model" >> "$CURRENT_FILE"

    # pp
    pp_result=$(llama-bench -m "$model" -ngl 99 -fa -p "$pp_size" -n 0 2>/dev/null | tail -20)
    echo "$pp_result" >> "$CURRENT_FILE"

    # tg
    tg_result=$(llama-bench -m "$model" -ngl 99 -fa -p "$pp_size" -n "$tg_size" 2>/dev/null | tail -20)
    echo "$tg_result" >> "$CURRENT_FILE"

    echo "\`\`\`" >> "$CURRENT_FILE"
    echo "" >> "$CURRENT_FILE"

    # Extrai tok/s para comparação
    pp_tps=$(echo "$pp_result" | grep -oP '\d+\.\d+(?= t/s)' | head -1 || echo "0")
    tg_tps=$(echo "$tg_result" | grep -oP '\d+\.\d+(?= t/s)' | head -1 || echo "0")

    echo "${label}_pp_tps=$pp_tps" >> "$CURRENT_DIR/results.env"
    echo "${label}_tg_tps=$tg_tps" >> "$CURRENT_DIR/results.env"

    log "  pp=$pp_tps t/s, tg=$tg_tps t/s"
}

compare_with_baseline() {
    log "=== Comparação com baseline ==="

    if [ ! -f "$BASELINE_DIR/baseline.env" ]; then
        log "Baseline não encontrado — este é o primeiro run"
        log "Copiando resultados como baseline"
        cp "$CURRENT_DIR/results.env" "$BASELINE_DIR/baseline.env"
        return 0
    fi

    # Compara cada métrica
    failed=0
    while IFS='=' read -r key current_val; do
        baseline_val=$(grep "^$key=" "$BASELINE_DIR/baseline.env" 2>/dev/null | cut -d= -f2 || echo "0")

        if [ "$baseline_val" = "0" ] || [ -z "$baseline_val" ]; then
            log "  $key: sem baseline para comparar"
            continue
        fi

        # Calcula diferença percentual
        diff=$(awk "BEGIN {
            if ($baseline_val == 0) { print 0; exit }
            pct = ($current_val - $baseline_val) / $baseline_val * 100
            printf \"%.1f\", pct
        }")

        if [ "$diff" = "0" ]; then
            log "  $key: $current_val (sem baseline)"
        else
            status="OK"
            if awk "BEGIN { exit !($diff < -$THRESHOLD) }"; then
                status="REGRESSÃO"
                failed=1
            fi
            log "  $key: $current_val vs baseline $baseline_val ($diff%) $status"
        fi
    done < "$CURRENT_DIR/results.env"

    if [ "$failed" = "1" ]; then
        die "Regressão detectada (> ${THRESHOLD}% de queda)"
    else
        log "OK: sem regressões significativas"
    fi
}

check_integrity() {
    log "=== Verificação de integridade ==="

    # CUs não devem ter voltado a 24 silenciosamente
    cu_count=$(dmesg | grep 'active_cu_number' | tail -1 | grep -oP '\d+$' || echo "24")
    if [ "$cu_count" != "40" ]; then
        log "AVISO: CUs ativos=$cu_count (esperado 40)"
        log "  Verificar: cat /sys/module/amdgpu/parameters/bc250_cc_write_mode"
        log "  Verificar: dmesg | grep bc250-40cu"
    fi

    # Temas de memória
    total_ram=$(free -m | awk 'NR==2{print $2}')
    log "RAM total: ${total_ram}MB"

    # Modelo carregável
    if [ -f /data/models/model.gguf ]; then
        model_size=$(stat -c%s /data/models/model.gguf 2>/dev/null || echo 0)
        model_gb=$(awk "BEGIN { printf \"%.1f\", $model_size / 1073741824 }")
        log "Modelo: ${model_gb}GB"
    fi
}

# === Main ===
CURRENT_DIR=$(mktemp -d)
trap "rm -rf $CURRENT_DIR" EXIT

mkdir -p "$BASELINE_DIR"

log "=== BC-250 Regression Benchmark ==="

# Header
cat > "$CURRENT_FILE" <<EOF
# BC-250 Regression Benchmark
> $(date -u '+%Y-%m-%d %H:%M:%S UTC')

EOF

check_environment
check_integrity

# Benchmarks — ajustar caminhos dos modelos conforme seu setup
run_bench "/data/models/model.gguf" "default" 512 128

# Se houver modelos específicos de regressão
for model in /data/models/bench/*.gguf; do
    [ -f "$model" ] || continue
    name=$(basename "$model" .gguf)
    run_bench "$model" "$name" 512 128
done

compare_with_baseline

log ""
log "=== Resultados salvos em $CURRENT_FILE ==="
log "Baseline em $BASELINE_DIR/baseline.env"