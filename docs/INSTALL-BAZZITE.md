# Instalação BC-250 LLM Alpine — Dual-boot com Bazzite (mesmo NVMe)

> Cenário real: Bazzite (rpm-ostree, btrfs, GRUB) já instalado no NVMe.
> Objetivo: adicionar Alpine ao lado, sem tocar no Bazzite.
>
> Fontes: docs.bazzite.gg (dual boot guide), docs BC-250, Alpine wiki.
> **Dual-boot na mesma unidade não é oficialmente suportado pelo Bazzite** —
> tem fallback de recovery na Fase 3. Leia tudo antes de executar.

## Regras de ouro

1. **Nunca formatar a ESP** (Bazzite e Alpine compartilham)
2. **Nunca reinstalar GRUB por cima de `\EFI\fedora\` ou `\EFI\BOOT\`** do Bazzite
3. **Alpine usa `--bootloader-id=alpine`** → diretório EFI separado
4. **40 CU só no Alpine** (Bazzite é imutável, não recebe kernel custom;
   se quiser 40CU no Bazzite, use o runtime UMR `bc250-cu-live-manager`)
5. **Backup antes de encolher partição** — btrfs shrink é irreversível sem backup

---

## Fase 0 — Diagnóstico no Bazzite (antes de qualquer mudança)

### 0.1 Mapear o disco

```sh
# Em execução no Bazzite
lsblk -f
sudo blkid
findmnt -o TARGET,SOURCE,FSTYPE,OPTIONS | grep -vE 'cgroup|proc|sysfs'
```

Anote:
- Dispositivo NVMe (ex: `nvme0n1`)
- ESP: provável `nvme0n1p1` montada em `/boot/efi` (vfat)
- Partição btrfs do Bazzite (pode estar sob LUKS)
- Subvolumes: `@` (root), `@var`, `@var/home`
- Espaço livre atual

### 0.2 Verificar o bootloader

```sh
# Bazzite usa GRUB?
ls /boot/efi/EFI/
# Esperado: fedora/ (ou ubuntu/), BOOT/, talvez bootloader-recovery/
sudo grub-install --version 2>/dev/null || echo "grub gerenciado pelo rpm-ostree"
```

### 0.3 Backup da ESP

```sh
sudo cp -a /boot/efi/EFI /root/backup-efi-$(date +%Y%m%d)/
# Ou para segurança externa:
sudo cp -a /boot/efi/EFI /path/to/usb/backup-efi-$(date +%Y%m%d)/
```

### 0.4 Backup do Bazzite (mínimo para shrink)

```sh
# Lista de pacotes instalados (para recovery)
rpm-ostree status > /root/rpm-ostree-status.txt
rpm-ostree list-installed > /root/pkgs.txt

# /etc (configs locais)
sudo tar czf /root/etc-backup.tgz /etc

# Se LUKS: anotar UUID da partição criptografada
sudo blkid | grep crypto_LUKS
```

### 0.5 Verificar consumo do btrfs

```sh
sudo btrfs filesystem usage /
# Anote: total, used, free — precisa de ~30GB livres para Alpine
```

### 0.6 Baseline BC-250 (se Bazzite já roda Vulkan)

```sh
vulkaninfo --summary | grep -E 'deviceName|num_cu'
# Se quiser comparar: copie scripts/baseline.sh e rode no Bazzite
```

---

## Fase 1 — Liberar espaço (partição do Bazzite)

**Ordem importa:** primeiro encolher o filesystem, depois a partição.
Pode fazer tudo pelo Bazzite para o btrfs, mas a partição é mais segura
com live USB em caso de LUKS.

### Sem LUKS (mais simples — fazer do próprio Bazzite)

```sh
# 1. Encolher o btrfs (pode rodar com sistema montado)
#    Deixe pelo menos 30GB para Alpine + 20GB para modelos
#    Exemplo: sistema usa 60GB, deixar 90GB, libertar o resto
sudo btrfs filesystem resize 90G /
# Verifique: df -h /  → btrfs mostra o novo tamanho

# 2. Encolher a partição correspondente (a de baixo para cima)
#    Listar partições e identificar a do btrfs
lsblk -o NAME,SIZE,START,PARTLABEL
# Exemplo: p3 é o btrfs, p4 é /boot, p5 começa depois

# 3. Encolher a partição btrfs via parted (partição NÃO em uso na hora,
#    ou seja, use GParted de live USB se a partição for a do root em uso)
#    MUITO MAIS SEGURO: fazer passo 2 e 3 pelo live USB do Bazzite
```

### Com LUKS (fazer de live USB obrigatório)

```sh
# Bootar pelo live USB do Bazzite ou GParted
# 1. Desbloquear LUKS
sudo cryptsetup open /dev/nvme0n1pX btrfs_crypt

# 2. Encolher btrfs
sudo btrfs filesystem resize 90G /mnt

# 3. Encolher LUKS (com GParted ou cryptsetup resize + losetup)
#    cryptsetup não encolhe diretamente — use GParted com suporte a LUKS
#    ou: decrypt → resize fs → resize luks via cryptsetup resize (só expande!)
#
#    Para encolher LUKS: GParted é o caminho prático (suporta LUKS containers)

# 4. Encolher partição no GParted (arraste a borda)
```

### Criar a partição do Alpine

```sh
# No GParted (live USB) ou parted:
# Espaço livre após a partição do Bazzite → criar:
#   - Alpine / : ext4, 25-40 GB (ex: /dev/nvme0n1p7)
#   - /data/models : ext4, resto do disco (ex: /dev/nvme0n1p8)
#
# NÃO tocar na ESP (p1) nem nas partições do Bazzite
```

### Verificar que Bazzite ainda boota

```sh
# Antes de instalar qualquer coisa, reinicie no Bazzite
# e confirme que tudo funciona
sudo reboot  # escolher Bazzite no menu
df -h /
lsblk
```

> **Ponto de não-retorno:** se o Bazzite não bootar depois do shrink,
> restaure a partir do live USB com o backup da Fase 0.4.
> O live USB do Bazzite tem "Bootloader Restoring Tool" e `btrfs rescue`.

---

## Fase 2 — Instalar Alpine (live USB do Alpine)

### 2.1 Boot do live USB

- Baixar Alpine 3.24.2 x86_64 `standard` ou `extended`
- Boot com `nomodeset` se a tela não inicializar (BC-250)
- Rede: cabo Ethernet

### 2.2 Particionamento manual (setup-alpine)

```sh
setup-alpine
# ... hostname, rede, SSH, etc ...

# Discos: escolha MANUAL, não o disco automático
# Disco: /dev/nvme0n1

# Partições (NÃO formatar a ESP):
# 1. ESP existente (nvme0n1p1): MONTAR em /boot/efi, NÃO formatar
# 2. Alpine / (nvme0n1p7): ext4, formatar
# 3. /data/models (nvme0n1p8): ext4, formatar (opcional agora, pode depois)
#
# /boot FICA DENTRO de / (não é partição separada)
```

Alternativa via `apk` manual se setup-alpine não der a opção:

```sh
# Após setup-alpine parar no disco, ou manualmente:
apk add e2fsprogs dosfstools

# Formatar só a partição Alpine (NUNCA a p1!)
mkfs.ext4 -L ALPINE_BOT /dev/nvme0n1p7
mkfs.ext4 -L data /dev/nvme0n1p8

# Montar
mount /dev/nvme0n1p7 /mnt
mkdir -p /mnt/boot/efi
mount /dev/nvme0n1p1 /mnt/boot/efi    # ESP do Bazzite — SEM formatação
mkdir -p /mnt/data
mount /dev/nvme0n1p8 /mnt/data

# setup-alpine com ALPINE_DEV apontando para p7
setup-alpine  # depois escolher disco manual
```

### 2.3 Instalar bootloader do Alpine (EFI separado)

```sh
# DENTRO do Alpine instalado (chroot ou após reboot):
apk add grub-efi efibootmgr

# Bootloader ID separado — NÃO sobrescreve \EFI\fedora nem \EFI\BOOT\
grub-install \
  --target=x86_64-efi \
  --efi-directory=/boot/efi \
  --bootloader-id=alpine \
  --removable=no \
  --recheck

# Confirme que criou só /boot/efi/EFI/alpine/
ls /boot/efi/EFI/
# Esperado: BOOT/  fedora/  alpine/
```

### 2.4 Primeira entrada GRUB do Alpine

```sh
# /etc/default/grub — cmdline BC-250 SÓ na entrada Alpine
GRUB_CMDLINE_LINUX_DEFAULT="quiet mitigations=off ttm.pages_limit=4194304"

# Tirar nomodeset se foi usado:
# (não deixar nomodeset no GRUB depois que Mesa estiver OK)

# Gerar config
mkinitfs
grub-mkconfig -o /boot/grub/grub.cfg
```

### 2.5 Entrada EFI alternativa (fallback se o menu da placa-mãe)

```sh
# Se o firmware não listar o Alpine automaticamente:
efibootmgr --create \
  --disk /dev/nvme0n1 \
  --part 1 \
  --loader '\EFI\alpine\grubx64.efi' \
  --label "Alpine BC-250" \
  --unicode
```

---

## Fase 3 — Vincular Bazzite e Alpine (GRUB do Bazzite)

### Caminho A (recomendado): menu unificado no GRUB do Bazzite

```sh
# Boot no Bazzite
sudo nano /etc/grub.d/40_custom
```

Adicionar:

```grub
menuentry "Alpine BC-250 LLM" {
    search --no-floppy --set=root --fs-uuid UUID_DA_PARTICAO_ALPINE
    linux /boot/vmlinuz-lts root=UUID=UUID_DA_PARTICAO_ALPINE \
        mitigations=off ttm.pages_limit=4194304 quiet
    initrd /boot/initramfs-lts
}
```

```sh
# Pegar a UUID da partição Alpine:
sudo blkid /dev/nvme0n1p7

# Regenerar GRUB do Bazzite (comando oficial do Bazzite)
sudo ujust regenerate-grub

# OU se ujust não pegar o 40_custom:
sudo os-prober 2>/dev/null
sudo grub-mkconfig -o /boot/grub/grub.cfg 2>/dev/null || \
  echo "Bazzite gerencia GRUB via ujust — use ujust regenerate-grub"
```

> **Atenção:** `ujust regenerate-grub` pode sobrescrever `/etc/grub.d/40_custom`.
> Se sumir, o menu UEFI da placa-mãe (Caminho B) é o fallback garantido.

### Caminho B (fallback garantido): menu UEFI da placa-mãe

- Reiniciar e apertar F12 / F11 / ESC (varia por fabricante)
- Escolher entre `Bazzite` e `Alpine BC-250`
- **Funciona sempre**, mesmo se o GRUB do Bazzite regenerar
- Bazzite oficialmente recomenda este método para dual-boot Linux↔Linux

### Caminho C (opcional): chainload

No 40_custom, apontar para o GRUB do Alpine na ESP:

```grub
menuentry "Alpine BC-250 (via EFI)" {
    chainloader /EFI/alpine/grubx64.efi
}
```

### Teste de boot

```sh
sudo reboot
# 1. Bazzite boota normal? (entrar no Bazzite, verificar tudo OK)
# 2. Alpine boota? (escolher a entrada, verificar Vulkan)
# 3. Alterna os dois sem perder nada?
```

### Se algo deu errado — recovery do Bazzite

```sh
# Via live USB do Bazzite:
# → "Bootloader Restoring Tool" (restaura GRUB/ESP do Bazzite)
# Ou manualmente:
sudo mount /dev/nvme0n1p7 /mnt          # root Bazzite
sudo mount /dev/nvme0n1p1 /mnt/boot/efi # ESP
sudo mount /dev/nvme0n1p4 /mnt/boot      # /boot Bazzite (se separado)
sudo chroot /mnt
rpm-ostree status
grub2-mkconfig -o /boot/grub2/grub.cfg
exit
```

---

## Fase 4 — Pacotes e configuração (no Alpine)

### 4.1 Clonar o repo e compilar

```sh
# No Alpine (após login)
apk add git make
git clone <seu-repo> /opt/bc250-llm-alpine
cd /opt/bc250-llm-alpine

# Vendor do patch 40-CU (obrigatório para o kernel)
sh apkbuilds/linux-bc250-lts/patches/fetch-patch.sh

# Instalar deps e compilar tudo
make deps
make packages    # kernel + governor + llama.cpp
```

### 4.2 Verificar ESP antes do setup

```sh
sh scripts/setup.sh --check
# Esperado: ESP detectada (nvme0n1p1), NÃO formatada
#           layout mostrado, espaço verificado
```

### 4.3 Instalar e configurar

```sh
sh scripts/setup.sh --install    # pacotes (firmware, Mesa, governor, llama)
sh scripts/setup.sh --configure  # modprobe, sysctl, serviços OpenRC
sh scripts/setup.sh --grub       # cmdline BC-250 no GRUB do Alpine
```

### 4.4 Habilitar 40 CUs

```sh
# O modprobe.d já foi instalado pelo --configure:
cat /etc/modprobe.d/bc250-40cu.conf
# options amdgpu bc250_cc_write_mode=3

# ANTES de confiar em 40CU, rode o health test (Fase 0 do plano):
apk add python3 libdrm
# clone duggasco/bc250-40cu-unlock para scripts/cu_map.sh e health-test

reboot
```

### 4.5 Verificar tudo

```sh
sh scripts/setup.sh --status
```

Checklist:
- [ ] `uname -r` mostra kernel `-bc250-lts`
- [ ] `vulkaninfo --summary` mostra `RADV GFX1013` (não llvmpipe)
- [ ] `dmesg | grep active_cu_number` → 40
- [ ] `rc-service cyan-skillfish-governor-smu status` → ativo
- [ ] `rc-service llama-server status` → ativo
- [ ] RAM livre idle ≤ 200MB
- [ ] Bazzite ainda boota normal

---

## Fase 5 — Baseline e tuning

```sh
# 1. Colocar modelo
mkdir -p /data/models
# copiar GGUF via scp ou partição compartilhada

# 2. Baseline
cp scripts/baseline.sh /tmp/
sh /tmp/baseline.sh /root/

# 3. Teste térmico 10min
llama-bench -m /data/models/model.gguf -ngl 99 -fa -p 512 -n 128

# 4. Serviço
cp /etc/llama-server/profiles/dense-q4km.conf /etc/conf.d/llama-server
rc-service llama-server restart
curl http://localhost:8080/health
```

---

## Mapa de responsabilidades por OS

| Item | Bazzite | Alpine |
|---|---|---|
| Bootloader | GRUB mestre (ou menu UEFI) | GRUB próprio em `\EFI\alpine\` |
| Kernel | Stock (rpm-ostree) | `linux-bc250-lts` custom |
| 40 CU | Stock 24 CU (ou UMR opcional) | Patch kernel, 40 CU |
| Governor | COPR filippor/bazzite | APK próprio SMU |
| Mesa | Repos Bazzite (25.x+) | Repos Alpine 3.24 |
| llama.cpp | Ollama ou build manual | APK `llama.cpp-bc250` |
| Modelos | — | `/data/models` (ext4 compartilhável) |
| Updates | `rpm-ostree upgrade` | `apk upgrade` |
| ESP | `\EFI\BOOT\`, `\EFI\fedora\` | `\EFI\alpine\` |

---

## Comandos de emergência

```sh
# Voltar Bazzite para 24CU stock
rm /etc/modprobe.d/bc250-40cu.conf && reboot

# Bootar no Bazzite pelo menu UEFI (F12) se GRUB quebrar
# Recovery GRUB do Bazzite: live USB → Bootloader Restoring Tool
# ESP intacta: ls /boot/efi/EFI/ deve ter fedora/ e alpine/

# Se Alpine não boota: menu UEFI → Alpine → nomodeset (linha do GRUB, pressione 'e')
# Se Vulkan caiu para CPU: adduser <usuario> render && reboot
```