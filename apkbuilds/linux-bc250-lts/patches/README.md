# BC-250 40-CU Unlock Patch (vendored)

## Origem

Repositório: `https://github.com/duggasco/bc250-40cu-unlock`
Arquivado em: 2026-09-17 (read-only)
Arquivo: `patch/bc250-40cu-amdgpu.patch`

## Como vendor o patch

```sh
# Da raiz do repositório
sh apkbuilds/linux-bc250-lts/patches/fetch-patch.sh
```

O script clona o repo do duggasco, copia o patch para este diretório e limpa.

## O que o patch faz

Dois registradores de hardware controlam a disponibilidade de CUs:

| Registrador | Stock | Unlocked |
|---|---|---|
| `CC_GC_SHADER_ARRAY_CONFIG` | `0xfff80000` (24 CU) | `0xffe00000` (40 CU) |
| `SPI_PG_ENABLE_STATIC_WGP_MASK` | `0x07` (WGP 0-2) | `0x1F` (WGP 0-4) |

Ambos devem ser modificados juntos. O patch escreve os dois durante init do `amdgpu`,
gated por PCI ID `0x13FE` (BC-250 only) e pelo parâmetro `bc250_cc_write_mode`
(default off).

## Uso

```sh
# Ativar 40 CUs
echo 'options amdgpu bc250_cc_write_mode=3' > /etc/modprobe.d/bc250-40cu.conf

# Desativar (volta para 24 CUs)
rm /etc/modprobe.d/bc250-40cu.conf
```

## Verificação

```sh
cat /sys/module/amdgpu/parameters/bc250_cc_write_mode  # deve ser 3
dmesg | grep -E 'bc250-40cu|active_cu_number'           # deve mostrar 40
RADV_DEBUG=info vulkaninfo --summary | grep num_cu       # deve ser 40
```

## Segurança

Nem toda placa desbloqueia limpo. Antes de confiar em 40 CUs:

1. `./scripts/cu_map.sh` — mapa de harvest (contíguo = bom, espalhado = cautela)
2. `./scripts/bc250-cu-health-test.sh start` — teste por WGP
3. `./scripts/bc250-cu-mask.sh --install` — máscara se CUs defeituosas

## Alternativa: runtime UMR (sem rebuild)

`https://github.com/WinnieLV/bc250-cu-live-manager` — escreve os mesmos registradores
via `umr` em userspace, com TUI e persistência por boot. Útil para:
- A/B testing de layouts WGP
- Sistemas onde rebuild de kernel não é possível (Bazzite/ostree)
- Fallback se o patch do kernel quebrar após bump de versão