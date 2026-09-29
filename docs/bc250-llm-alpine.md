# BC-250 LLM Alpine — Roteiro de Projeto (dual-boot)

> Base: outro Linux no mesmo NVMe, Alpine normal + APKs próprios (sem squashfs A/B, sem `.img` dd).
> Caminho compute: só Vulkan/RADV + llama.cpp. ROCm não é viável como padrão (gfx1013 sem Tensile oficial).
> Docs base: https://elektricm.github.io/amd-bc250-docs/

## 0. Decisões congeladas

- [ ] Base: Alpine 3.24.x, `linux-lts` 6.18.x (ex.: 6.18.53 validado em set/2026), Mesa 25.1.3+ mínimo, alvo 25.3.x
- [ ] Governor padrão: `cyan-skillfish-governor-smu` (sem patch de kernel, serviço `cyan-skillfish-governor-smu`)
- [ ] Unlock 40 CUs: patch kernel `duggasco` vendored no repo + opt-in com health-test; fallback runtime `bc250-cu-live-manager` via UMR
- [ ] llama.cpp: compilar com `-DGGML_VULKAN=ON -DGGML_RPC=ON`, fixar commit; comparar fork `TechMakesArt/llama.cpp-bc250` (b8819) vs upstream (b9265+)
- [ ] VRAM BIOS inicial: P3.00 + 512MB dynamic; testar split fixo 8/12GB só se GTT não cobrir
- [ ] Kernel cmdline Alpine: `ttm.pages_limit=4194304 mitigations=off` (sem `amdgpu.gttsize`, sem `nomodeset` após Fase 1)
- [ ] Secure Boot: OFF (afeta os dois OSes)

## Layout dual-boot mesmo disco (não destruir)

```
ESP existente FAT32 (~512M, NÃO FORMATAR) -> /boot/efi só durante install
/ outro Linux (intocado)
/ Alpine / ext4 15-25GB com /boot DENTRO de /  <- regra de coexistência
/data/models ext4 resto, montável pelos dois (mesmo UID/GID se reusar GGUF)
```

- [ ] Dono da ESP: outro Linux (padrão). Alpine instala `grub-efi efibootmgr os-prober grub-mount` mas não reinstala por cima sem motivo
- [ ] Cmdline BC-250 só na entrada Alpine, não global

---

## Fase 0 — Baseline (nada de código antes disso)

Objetivo: número para comparar. Sem isso não dá para provar ganho.

- [ ] Preparar hardware: BIOS mod P3.00, IOMMU OFF, clear CMOS após flash, VRAM 512MB dynamic
- [ ] Cooling: repasta + airflow, fans na fonte; anotar RPM e temp idle
- [ ] Backup: `lsblk -f; blkid; efibootmgr -v; df -h; cp -a /boot/efi/EFI backup-esp/` (a ESP será reusada)
- [ ] Instalar Alpine stock ou Ubuntu temporário + Mesa RADV
- [ ] Medir e anotar:
  - [ ] `uname -r; apk list mesa mesa-vulkan-ati linux-lts` ou `mesa --version`
  - [ ] `vulkaninfo --summary | grep -i radv` (tem que ser `RADV GFX1013`, não llvmpipe)
  - [ ] `llama-bench -m <Qwen9B-Q4_K_M.gguf> -ngl 99 -fa` -> tok/s pp512 + tg
  - [ ] RAM livre: `free -m`
  - [ ] Carga 10-15min: temp (`sensors`), PPT/potência, throttling observado
- [ ] Critério saída: tabela baseline salva no repo (`docs/baseline.md`)

## Fase 1 — Boot mínimo com GPU

- [ ] Instalar Alpine modo manual: partição Alpine nova, montar ESP existente em `/boot/efi`, NÃO formatar ESP, `/boot` dentro de `/`
- [ ] Boot install com `nomodeset` se display não inicializar; remover depois
- [ ] `apk add linux-lts linux-firmware-amdgpu mesa mesa-gl mesa-dri-gallium mesa-vulkan-ati vulkan-loader vulkan-tools mesa-demos`
- [ ] GRUB: `apk add grub-efi efibootmgr os-prober grub-mount`
  - [ ] Se Alpine é dono temporário: `grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=alpine`
  - [ ] Se dono é outro Linux: bootar nele e `grub-mkconfig -o /boot/grub/grub.cfg` (com `os-prober` ativo) para detectar Alpine
- [ ] Adicionar cmdline só na entrada Alpine: `quiet mitigations=off ttm.pages_limit=4194304`
- [ ] Verificar:
  - [ ] `lsmod | grep amdgpu`
  - [ ] `dmesg | grep -i amdgpu`
  - [ ] `vulkaninfo --summary` -> RADV GFX1013
  - [ ] `llama-bench` iguala baseline (±5%)
- [ ] Critério saída: boot dual com seleção funcional, Vulkan OK nos dois? No mínimo no Alpine

## Fase 2 — Kernel próprio `linux-bc250-lts`

- [ ] Criar repo `apkbuilds/linux-bc250-lts/` a partir de `linux-lts` 6.18.x, `provides=linux-lts`
- [ ] Vendar patch `duggasco/bc250-40cu-unlock/patch/bc250-40cu-amdgpu.patch` no repo (upstream arquivado 17/set/2026, não depender de fetch)
- [ ] Config enxuta: sem áudio/BT/wifi, sem DRM outras GPUs, sem FS desnecessários, amdgpu embutido; manter display core ligado por padrão (hipótese headless-sem-DC não provada)
- [ ] `/etc/modprobe.d/bc250-40cu.conf`: `options amdgpu bc250_cc_write_mode=3` (opt-in, documentar `disable` para voltar a 24CU)
- [ ] Antes de habilitar 40CU:
  - [ ] `./scripts/cu_map.sh` (contíguo vs espalhado = contexto, não veredito)
  - [ ] `./scripts/bc250-cu-health-test.sh start` + `bc250-cu-mask.sh --install` se precisar máscara `amdgpu.disable_cu`
- [ ] Verificar:
  - [ ] `cat /sys/module/amdgpu/parameters/bc250_cc_write_mode` -> 3
  - [ ] `dmesg | grep -E 'bc250-40cu|active_cu_number'` -> `active_cu_number 40` nos 4 arrays + `CC 0xfff80000->0xffe00000 SPI 0x07->0x1F`
  - [ ] `RADV_DEBUG=info vulkaninfo --summary | grep num_cu` -> 40
- [ ] Garantir sobrevivência a upgrade: APK versionado + hook que avisa se `amdgpu.ko` stock sobrescreveu; documentar `restore` a partir de backup `.bc250-backup-*`
- [ ] Critério saída: 40CU após reboot frio, sem módulo externo

## Fase 3 — Userspace Alpine/OpenRC

- [ ] Base: OpenRC, `sshd`, sem NetworkManager pesado (`dhcpcd`/`iwd` ou estático)
- [ ] `apk add cyan-skillfish-governor-smu` (do seu repo, branch `smu`, `cargo build --release`)
  - [ ] `rc-update add dbus default; rc-service dbus start`
  - [ ] policy `/etc/dbus-1/system.d/com.cyan.skillfishgovernor.conf` antes do primeiro run
  - [ ] config `/etc/cyan-skillfish-governor-smu/config.toml` conservadora inicial: 350MHz/700mV, 1500MHz/900mV, 2000MHz/1000mV, 2200MHz/1000mV; min >=700mV
  - [ ] OpenRC `/etc/init.d/cyan-skillfish-governor-smu` com `need dbus`, `command_background=true`
- [ ] llama.cpp: build `-DGGML_VULKAN=ON -DGGML_RPC=ON`, fixar commit; `llama-server` como serviço OpenRC com config em `/etc/llama-server/`
  - [ ] Env: `GGML_VK_FORCE_MAX_ALLOCATION_SIZE=2000000000`, `RADV_DEBUG=nohiz` se artefatos
  - [ ] Usuário `llama` nos grupos `render,video` (sem isso cai para CPU silenciosamente)
  - [ ] Localizar GPU por PCI `0x13fe`, não `cardN`
- [ ] `apk add lm-sensors; sensors-detect` + `nct6683 force=true` em `/etc/modprobe.d/`
- [ ] CPU governor `performance` (schedutil causa spikes em LLM)
- [ ] Critério saída: `1500MHz` destravado para 2.2GHz sob governor, `llama-bench` +~30% vs sem governor

## Fase 4 — Instalação e updates (adaptada dual-boot)

Não fazer: `mkimage` gerando `.img` para `dd` no disco todo.

- [ ] Entregável: perfil Alpine normal + `setup.sh` idempotente (particiona só espaço livre, reus ESP, instala APKs, configura GRUB entry)
- [ ] `setup.sh` deve:
  - [ ] Detectar ESP existente por `PARTLABEL`/UUID, montar sem formatar
  - [ ] Instalar Alpine em partição alvo, `/boot` dentro de `/`
  - [ ] Instalar `linux-bc250-lts`, governor-smu, llama.cpp, tooling
  - [ ] Rodar `grub-mkconfig` no OS dono ou adicionar `40_custom` com UUID correto
- [ ] CI: build reprodutível de APKs (não de imagem dd); teste de boot/GPU só em runner self-hosted BC-250 real
- [ ] Rollback: manter APK anterior no cache + entrada GRUB fallback; documentar `disable/restore` 40CU
- [ ] Critério saída: reinstall do zero via script sem tocar no outro Linux

## Fase 5 — Tuning memória e desempenho

- [ ] Confirmar GTT: `dmesg | grep -i gtt; vulkaninfo` deve ver ~16.5GiB total após `ttm.pages_limit`
- [ ] Testar hipótese UMA double-cache: `mmap` vs `--no-mmap`, `vm.swappiness`, `vm.dirty_*`, THP `always/madvise/never` — medir RAM pico + tok/s
- [ ] Perfis prontos:
  - [ ] Denso Q4_K_M: `-ngl 99 -fa`
  - [ ] Contexto longo: KV `q8_0`/`q4_0`
  - [ ] MoE ex. Gemma 4 26B-A4B Q3_K_M (~70 tok/s, ~24k ctx — revalidar)
  - [ ] Comparar `llama-server` direto vs Ollama (MoE pode ser 2.4x mais rápido direto no b9265)
- [ ] Repetir térmico 10min com 40CU @1500MHz: borda <90°C média, PPT, sem throttle >10%
- [ ] Orçamento alvo: BIOS 0.5GB + idle ≤200MB + GTT 14.5-15GB; rootfs ext4 normal (não tmpfs inteiro); modelos em `/data/models`
- [ ] Critério saída: matriz modelo/quant/ctx/tok/s/GB publicada

## Fase 6 — Extras (pós-MVP)

- [ ] Cluster RPC: `GGML_RPC=ON`, `llama-server` multi-nó
- [ ] Watchdog térmico: baixa clock via D-Bus do governor se >95°C borda / 100°C CPU
- [ ] First-boot via arquivo na ESP (ex.: `/boot/efi/bc250-config.toml`): hostname, rede, modelo default, 24/40CU, curva tensão — sem expor chave

## Fase 7 — Manutenção

- [ ] Matriz fixada: `kernel-bc250 / Mesa / llama.cpp commit / governor-smu commit / firmware-amdgpu`
- [ ] `bench-regress.sh`: roda `llama-bench` pp512+tg em 2-3 modelos + checa `active_cu_number` + `vulkaninfo`; falha se queda >5% ou volta a 24CU silenciosa
- [ ] Política: bump um componente por vez, revalidar GRUB dual-boot com `os-prober` após cada troca de kernel

## Riscos / pontos em aberto

- Silício: scattered map ≠ condenação, mas exige health-test; undervolt agressivo gera erro silencioso — usar curvas conhecidas
- Térmico: 40CU@2GHz throttla em cooler stock (CPU bate 100°C TJmax, PPT 220W+); 1500MHz/900mV é o ponto sustentado
- Fontes mudam rápido (Discord); revalidar Mesa/kernel/llama.cpp na hora do build
- Não verificado: RADV sem LLVM, musl vs glibc em Vulkan, UMR no musl, VRAM ideal 512MB vs 1GB — viram issues de teste na F1/F5
- Sem placa em mãos não dá para validar F0/F5 — não avançar F2 sem baseline

## Links

- Docs: https://elektricm.github.io/amd-bc250-docs/
- Alpine: https://elektricm.github.io/amd-bc250-docs/linux/alpine/
- Governor: https://github.com/filippor/cyan-skillfish-governor + https://elektricm.github.io/amd-bc250-docs/system/governor/
- 40CU: https://github.com/duggasco/bc250-40cu-unlock + https://elektricm.github.io/amd-bc250-docs/system/40cu-unlock/
- Live UMR: https://github.com/WinnieLV/bc250-cu-live-manager
- llama fork: https://github.com/TechMakesArt/llama.cpp-bc250
- Guias/scripts: https://github.com/wdonega/bc250-llm-setup e https://github.com/akandr/bc250
