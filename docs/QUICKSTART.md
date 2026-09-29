# Quick Start — BC-250 LLM Alpine (dual-boot)

## 1. Pré-requisitos (antes de qualquer código)

- [ ] BIOS P3.00 modificado, IOMMU OFF, VRAM 512MB dynamic
- [ ] Cooling: repasta + airflow (fans direto na fonte)
- [ ] Secure Boot OFF
- [ ] Backup da ESP: `cp -a /boot/efi/EFI /root/backup-esp-$(date +%Y%m%d)/`

## 2. Coletar baseline

```sh
# No sistema atual (Alpine padrão ou Ubuntu temporário)
sh scripts/baseline.sh /home/tiago/Documents/vc250/bc250-llm-alpine/docs/
```

Salvar: tok/s pp512, tok/s tg, RAM livre, temperatura após 10min.

## 3. Compilar pacotes

```sh
make deps        # instala alpine-sdk, abuild, deps
make packages    # compila kernel + governor + llama.cpp
# OU individualmente:
make kernel
make governor
make llama
```

**Para o kernel:** vendor o patch 40-CU primeiro:
```sh
sh apkbuilds/linux-bc250-lts/patches/fetch-patch.sh
```

## 4. Instalar no Alpine

```sh
# Verifica ESP e disco (NÃO formata nada)
sh scripts/setup.sh --check

# Instala pacotes
sh scripts/setup.sh --install

# Configura sistema (modprobe, sysctl, serviços)
sh scripts/setup.sh --configure

# Configura GRUB (escolha um dos caminhos)
sh scripts/setup.sh --grub

# Ou tudo de uma vez:
sh scripts/setup.sh --all
```

## 5. Dual-boot GRUB

Se o **outro Linux** é dono da ESP (recomendado):

```sh
# Boot no outro Linux
sudo apt install os-prober  # ou dnf install os-prober
sudo os-prober              # detecta Alpine
sudo grub-mkconfig -o /boot/grub/grub.cfg
```

Se o **Alpine** é dono da ESP:

```sh
grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=alpine
grub-mkconfig -o /boot/grub/grub.cfg
```

Cmdline BC-250 **só na entrada Alpine**:
```
mitigations=off ttm.pages_limit=4194304 quiet
```

## 6. Verificar GPU

```sh
# Vulkan deve mostrar RADV (não llvmpipe)
vulkaninfo --summary | grep -E 'deviceName|driverName|num_cu'

# CUs: deve mostrar 40 se 40-CU habilitado
dmesg | grep active_cu_number

# Governor ativo
rc-service cyan-skillfish-governor-smu status

# Modelo carregável
llama-bench -m /data/models/model.gguf -ngl 99 -fa
```

## 7. Iniciar llama-server

```sh
# Usuário llama deve estar no grupo render
adduser llama render

# Escolher perfil
cp /etc/llama-server/profiles/dense-q4km.conf /etc/conf.d/llama-server

# Iniciar
rc-update add llama-server default
rc-service llama-server start

# Testar
curl http://localhost:8080/health
```

## 8. Teste de regressão

```sh
sh scripts/bench-regress.sh
```

Rode após cada bump de kernel/Mesa/llama.cpp/governor.

## Comandos úteis

```sh
# Status completo
sh scripts/setup.sh --status

# Logs do llama-server
tail -f /var/log/llama-server.log

# Logs do governor
tail -f /var/log/cyan-skillfish-governor-smu.log

# Temperatura em tempo real
watch -n 1 sensors

# Clock da GPU
cat /sys/class/drm/card0/device/pp_dpm_sclk

# Alternar 40CU / 24CU
echo 'options amdgpu bc250_cc_write_mode=3' > /etc/modprobe.d/bc250-40cu.conf  # 40CU
rm /etc/modprobe.d/bc250-40cu.conf  # 24CU (requer reboot)
```

## Perfis de modelo

| Perfil | Uso | Comando |
|---|---|---|
| dense-q4km | Padrão, 8-9B | `cp /etc/llama-server/profiles/dense-q4km.conf /etc/conf.d/llama-server` |
| longctx | 32k tokens | `cp /etc/llama-server/profiles/longctx.conf /etc/conf.d/llama-server` |
| moe | MoE 26B-35B | `cp /etc/llama-server/profiles/moe.conf /etc/conf.d/llama-server` |