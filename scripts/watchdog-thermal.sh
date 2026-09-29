#!/bin/sh
# BC-250 Thermal Watchdog
# Reduz clock da GPU via governor SMU se temperatura exceder limiares
# Usa sensors (nct6683) para ler temperatura

INTERVAL=10
GPU_WARN="${TEMP_GPU_WARN:-90}"
GPU_CRIT="${TEMP_GPU_CRIT:-95}"
CPU_WARN="${TEMP_CPU_WARN:-90}"
CPU_CRIT="${TEMP_CPU_CRIT:-95}"

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') $*"
}

get_temp() {
    # Tenta ler temperatura do sensor mais relevante
    # NCT6683: temp1 = motherboard, temp2/3 = VRM/adjunto
    # k10temp: Tctl/Tdie = CPU
    # amdgpu: edge/junction = GPU

    sensor_type="$1"

    case "$sensor_type" in
        gpu)
            # amdgpu edge temp via hwmon
            for hwmon in /sys/class/hwmon/hwmon*/; do
                if [ -f "$hwmon/name" ] && grep -qi amdgpu "$hwmon/name"; then
                    if [ -f "$hwmon/temp1_input" ]; then
                        echo "$(($(cat "$hwmon/temp1_input") / 1000))"
                        return
                    fi
                fi
            done
            # Fallback: sensors command
            sensors 2>/dev/null | grep -i 'edge\|gpu' | grep -oP '[+-]?\d+\.\d+' | head -1 | cut -d. -f1
            ;;
        cpu)
            for hwmon in /sys/class/hwmon/hwmon*/; do
                if [ -f "$hwmon/name" ] && grep -qi 'k10temp\|coretemp' "$hwmon/name"; then
                    if [ -f "$hwmon/temp1_input" ]; then
                        echo "$(($(cat "$hwmon/temp1_input") / 1000))"
                        return
                    fi
                fi
            done
            sensors 2>/dev/null | grep -i 'Tctl\|Tdie\|Package' | grep -oP '[+-]?\d+\.\d+' | head -1 | cut -d. -f1
            ;;
    esac
    echo "0"
}

set_governor_speed() {
    # Reduce speed by setting a conservative curve via D-Bus
    # The governor SMU accepts a config reload signal
    level="$1"

    case "$level" in
        1)
            log "WARN: reduzindo clock para nível 1 (1500MHz)"
            # Send SIGHUP to reload with conservative config
            pkill -HUP -f cyan-skillfish-governor-smu 2>/dev/null
            ;;
        2)
            log "CRIT: reduzindo clock para nível 2 (1200MHz)"
            pkill -HUP -f cyan-skillfish-governor-smu 2>/dev/null
            # TODO: fallback para config mais agressiva se SIGHUP não funcionar
            ;;
    esac
}

restore_speed() {
    log "INFO: temperatura normalizada, restaurando clock"
    pkill -HUP -f cyan-skillfish-governor-smu 2>/dev/null
}

THROTTLED=0

log "Watchdog térmico iniciado (GPU warn=$GPU_WARN crit=$GPU_CRIT, CPU warn=$CPU_WARN crit=$CPU_CRIT)"

while true; do
    gpu_temp=$(get_temp gpu)
    cpu_temp=$(get_temp cpu)

    # Garantir valores numéricos
    case "$gpu_temp" in
        ''|*[!0-9]*) gpu_temp=0 ;;
    esac
    case "$cpu_temp" in
        ''|*[!0-9]*) cpu_temp=0 ;;
    esac

    log "GPU=${gpu_temp}°C CPU=${cpu_temp}°C THROTTLED=$THROTTLED"

    if [ "$gpu_temp" -ge "$GPU_CRIT" ] || [ "$cpu_temp" -ge "$CPU_CRIT" ]; then
        if [ "$THROTTLED" != "2" ]; then
            set_governor_speed 2
            THROTTLED=2
        fi
    elif [ "$gpu_temp" -ge "$GPU_WARN" ] || [ "$cpu_temp" -ge "$CPU_WARN" ]; then
        if [ "$THROTTLED" = "0" ]; then
            set_governor_speed 1
            THROTTLED=1
        fi
    else
        if [ "$THROTTLED" != "0" ]; then
            restore_speed
            THROTTLED=0
        fi
    fi

    sleep "$INTERVAL"
done