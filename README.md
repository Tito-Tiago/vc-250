# bc250-llm-alpine

OS Alpine otimizado para LLM na AMD BC-250 (Cyan Skillfish / gfx1013), dual-boot com outro Linux no mesmo NVMe.

## Pre-requisitos

- BC-250 com BIOS P3.00 modificado, IOMMU OFF, VRAM 512 MB dynamic
- Cooling adequado (repasta + airflow; fans direto na fonte)
- Secure Boot desligado
- Espaço livre no NVMe (15–25 GB root + resto para modelos)
- Outro Linux instalado com ESP própria — **não formatar**

## Comece por

1. **`docs/INSTALL-BAZZITE.md` — passo a passo para BC-250 com Bazzite já instalado**
2. `docs/bc250-llm-alpine.md` — plano completo por fases (F0–F7)
3. `scripts/baseline.sh` — coleta baseline antes de qualquer build
4. `scripts/setup.sh` — instalação idempotente que reusa a ESP

## Estrutura

```
apkbuilds/            APKBUILDs dos pacotes próprios
  linux-bc250-lts/    kernel LTS 6.18 com patch 40CU + config enxuta
  cyan-skillfish-governor-smu/  governor SMU (sem patch de kernel)
  llama.cpp-bc250/    llama.cpp com Vulkan+RPC, commit fixado
configs/              modprobe.d, sysctl, perfis do llama-server
openrc/               serviços (llama-server, governor, watchdog térmico)
scripts/              setup.sh, baseline.sh, bench-regress.sh
ci/                   build reprodutível de APKs
docs/                 plano e documentação
```

## Build rápido

```sh
make deps     # instala alpine-sdk, abuild, deps de build
make packages # compila todos os APKBUILDs
make bench    # roda bench-regress.sh na máquina local
```

## Dual-boot

- A ESP existente é montada em `/boot/efi` **sem formatação**
- `/boot` fica dentro de `/` para coexistência
- Cmdline BC-250 (`ttm.pages_limit=4194304`) só na entrada Alpine
- Dono da ESP = outro Linux; `os-prober` detecta o Alpine
- Rollback = APK anterior no cache + entrada GRUB fallback

## Links

- [Docs BC-250](https://elektricm.github.io/amd-bc250-docs/)
- [Governor SMU](https://github.com/filippor/cyan-skillfish-governor/tree/smu)
- [40 CU Unlock](https://github.com/duggasco/bc250-40cu-unlock)
- [llama.cpp-bc250 fork](https://github.com/TechMakesArt/llama.cpp-bc250)