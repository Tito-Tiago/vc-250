# bc250-llm-alpine — matrizes e benchmarks de referência
# Atualizar a cada bump e rodar bench-regress.sh

## Matriz de versões fixadas

| Componente        | Versão/Commit           | Fonte                                      |
|-------------------|-------------------------|--------------------------------------------|
| linux-bc250-lts   | 6.18.53-r0              | Alpine linux-lts + patch 40CU vendored     |
| Mesa / RADV       | >= 25.1.3 (alvo 25.3.x) | mesa-vulkan-ati do Alpine                  |
| firmware-amdgpu   | alpine linux-firmware   | main                                       |
| governor-smu      | smu branch @ commit     | filippor/cyan-skillfish-governor (smu)     |
| llama.cpp-bc250   | upstream b9265+ ou fork b8819 | TechMakesArt/llama.cpp-bc250         |
| UMR (opt-in)      | HEAD                    | WinnieLV/bc250-cu-live-manager             |

## Valores de referência (baseline F0)

| Config | Modelo | Quant | pp512 tok/s | tg tok/s | RAM livre | Temp 10min | PPT |
|--------|--------|-------|-------------|----------|-----------|------------|-----|
| stock 24CU @1500MHz | Qwen9B | Q4_K_M | 230 | ? | ? | ? | 95W |
| unlocked 40CU @1500MHz/900mV | Qwen9B | Q4_K_M | 371.6 | ? | ? | 83°C | 125W |
| unlocked 40CU @2GHz | Qwen9B | Q4_K_M | 466 | ? | ? | 96°C | 181W |

> Referência duggasco (llama-bench pp512, Vulkan, 1500MHz/881mV stock vs 874mV unlocked).
> Reproduzir na sua placa na Fase 0 antes de comparar qualquer resultado.

## Perfis de tuning

### Denso Q4_K_M (padrão)
```
llama-server --model /data/models/<model>.gguf \
  -ngl 99 -fa \
  --ctx-size 8192 \
  --kv-cache-type q8_0
```

### Contexto longo
```
llama-server --model /data/models/<model>.gguf \
  -ngl 99 -fa \
  --ctx-size 32768 \
  --kv-cache-type q4_0
```

### MoE (ex. Gemma 4 26B-A3B Q3_K_M)
```
llama-server --model /data/models/<model>.gguf \
  -ngl 99 -fa \
  --ctx-size 24576 \
  --kv-cache-type q8_0
```
> MoE via llama-server direto é ~2.4x mais rápido que via Ollama (b9265).

## Valores de kernel cmdline

```
ttm.pages_limit=4194304 mitigations=off
```
> `amdgpu.gttsize` é obsoleto em kernels novos — não usar.
> `nomodeset` só durante instalação, remover depois.

## Variáveis de ambiente

```
GGML_VK_FORCE_MAX_ALLOCATION_SIZE=2000000000
RADV_DEBUG=nohiz          # se artefatos visuais
```