---
title: "Заметки Об Установке Arch Linux на Mechrevo Wujie 14 Pro (2023)"
date: 2025-01-14T02:38:50+07:00
draft: true
toc: true
description: В заметке собраны рекоминданции по установке Arch Linux на Mechrevo Wujie 14 Pro (2023).
categories:
  - Linux
  - Notes
tags:
  - Arch Linux
---

## Введение

Время от времени мне требуется установить Arch Linux на новое устройство или починить имеющуюся и эта заметка об установке, которая помогает мне это сделать.

Я вдохновлялся этими источниками при написании заметки.
- [Arch Wiki](https://wiki.archlinux.org)
- [shimeoki/dual-boot.md](https://gist.github.com/shimeoki/7f85a5af72bbd6bd0f7f6d685f01cd06)
- [orhun/arch_linux_installation.md](https://gist.github.com/orhun/02102b3af3acfdaf9a5a2164bea7c3d6)

## Ноутбук

Mechrevo Wujie 14 Pro (2023) обладает следующими характеристиками:

- AMD Ryzen 7 7840HS
- AMD Radeon 780M
- 16GB RAM
- 1TB NVME SSD
- 14" дисплей с разрешением 2880x1800 и частотой 120 Гц

### Известные проблемы

- Отсутствие драйверов для сканера отпечатков пальцев.
- Нет обновления AGESA от производителя.

## Подготовка

### Создание загрузочной флешки

1. Скачайте образ дистрибутива [Arch Linux](https://archlinux.org/download/).
2. Создайте загрузочную флешку с помощью утилит 
- Windows - [rufus](https://rufus.ie/)
- Кроссплатформенный - [ventoy](https://habr.com/ru/companies/ruvds/articles/584670/)
- Linux - [dd](https://habr.com/ru/companies/ruvds/articles/578294/)

Я предпочитаю использовать Ventoy, потому что он не повреждает флешку со временем и предоставляет больше функций.

### Подключение к сети

Для подключения к WiFi используйте [iwd](https://wiki.archlinux.org/title/Iwd):
``` bash
iwctl --passphrase <passphrase> station wlan0 connect <SSID>
```

### Выбор накопителя

Используйте команду lsblk, чтобы определить нужный накопитель, затем создайте переменную $DRIVE с расположением выбранного диска:
``` bash
export DRIVE=/dev/<DRIVE>
```

### Очистка диска

Очистите диск следующей командой:
``` bash
sgdisk --zap-all $DRIVE
```

### Создание разделов

Создайте разделы на диске:
``` bash
sgdisk --clear \
       --new=1:0:+550MiB --typecode=1:ef00 --change-name=1:EFI \
       --new=2:0:+8GiB   --typecode=2:8200 --change-name=2:cryptswap \
       --new=3:0:0       --typecode=3:8300 --change-name=3:cryptsystem $DRIVE
```
### Проверка разделов

``` bash
lsblk -o +PARTLABEL
```

### Форматирование разделов

После создания разделов выполните их форматирование.

1. Форматирование EFI-раздела:
``` bash
mkfs.fat -F32 -n EFI /dev/disk/by-partlabel/EFI
```
2. Шифрование системного раздела:
``` bash
cryptsetup luksFormat /dev/disk/by-partlabel/cryptsystem
```

3. Добавление ключа для LUKS:
``` bash
cryptsetup luksAddKey /dev/disk/by-partlabel/cryptsystem
```

4. Резервное копирование заголовка LUKS (важно для восстановления данных):
>При использовании шифрования LUKS (Linux Unified Key Setup) важно учитывать, что заголовок зашифрованного раздела является критически важным элементом для доступа к вашим данным. Потеря этого заголовка в случае его уничтожения может привести к невозможности расшифровки информации, хранящейся на диске. Проблема сопоставима по масштабам с забытым паролем или поврежденным ключевым файлом, которые также применяются для разблокировки раздела.

>Возможные причины подобного повреждения могут варьироваться от ошибок пользователя, таких как случайная переразметка диска, до некорректного обращения со стороны сторонних программ, неверно интерпретирующих таблицы разделов. Эти факторы подчёркивают уязвимость заголовка и делают задачу его сохранения крайне актуальной.

>Во избежание утраты доступа к зашифрованной информации, рекомендуется предпринять меры по созданию резервной копии заголовка раздела LUKS. Сохранение этой копии на отдельном диске может значительно обезопасить вас от потенциальных проблем, связанных с потерей критически важной информации. Создание таких резервных копий не должно быть отложено, ведь от этого может зависеть целостность и доступность ваших данных в долгосрочной перспективе.

``` bash
cryptsetup luksHeaderBackup /dev/disk/by-partlabel/cryptsystem --header-backup-file /mnt/<backup>/<file>.img
```

### Открытие зашифрованного раздела

Откройте зашифрованный раздел для дальнейшей работы:
``` bash
cryptsetup open /dev/disk/by-partlabel/cryptsystem system
```

### Шифрование раздела под swap

> Для восстановления работы после приостановки системы (гибернации или сна) важно сохранить раздел подкачки нетронутым. Для этого необходимо заранее создать раздел или файл подкачки с поддержкой LUKS, который можно будет использовать для восстановления при старте системы.
``` bash
cryptsetup luksFormat /dev/disk/by-partlabel/cryptswap
cryptsetup open /dev/disk/by-partlabel/cryptswap swap
mkswap -L swap /dev/mapper/swap
swapon -L swap
```

### Создание и монтирование системного раздела

>Я предпочитаю использовать ext4, но вы можете выбрать файловою систему которая вам больше нравится.

``` bash
mkfs.ext4 -f -L system /dev/mapper/system
mount LABEL=system /mnt
```

### Монтирование EFI раздела

``` bash
mkdir /mnt/boot
mount LABEL=EFI /mnt/boot
```

## Установка
### Правка зеркал
> Зеркала по умолчанию медленнее, чем оптимизированные серверы, которые могут находиться ближе к вашему физическому местоположению или обладать более быстрым подключением. Для ускорения загрузки пакетов рекомендуется использовать утилиту Reflector, которая автоматически обновляет и сортирует список зеркал по скорости.
``` bash
reflector --threads 100 --age 12 --protocol https --sort rate --save /etc/pacman.d/mirrorlist
pacman -Syy
```
### Установка базовых пакетов
``` bash
pacstrap /mnt base linux linux-firmware
```
### Генерация fstab
``` bash
genfstab -L /mnt >> /mnt/etc/fstab
```
Должно получиться что-то похожее на:
```
# /dev/mapper/system UUID=xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx
LABEL=system        	/         	ext4       	rw,relatime,attr2,inode64,logbufs=8,logbsize=32k,noquota	0 1

# /dev/nvme0n1p1 UUID=xxxx-xxxx
LABEL=EFI           	/boot     	vfat      	rw,relatime,fmask=0022,dmask=0022,codepage=437,iocharset=ascii,shortname=mixed,utf8,errors=remount-ro	0 2

# /dev/mapper/swap UUID=xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx
#LABEL=swap          	none      	swap      	defaults  	0 0
# add this line instead for using the mapped device as swap
/dev/mapper/swap swap swap defaults 0 0
```
### Chroot в заготовленную систему
``` bash
arch-chroot /mnt
```
### Конфигурация системы
``` bash
pacman -S amd-ucode nano reflector
```

#### Установка временной зоны
``` bash
ln -sf /usr/share/zoneinfo/<регион>/<город> /etc/localtime
```

#### Синхронизация времени
``` bash
hwclock --systohc
```

#### Выбор локалей
Раскомментируйте en_US.UTF-8 UTF-8 и ru_RU.UTF-8 UTF-8
``` bash
nano /etc/locale.gen
```

#### Генерация локалей
``` bash
locale-gen
```

#### Создание файла locale.conf
``` bash
echo 'LANG=ru_RU.UTF-8' > /etc/locale.conf
```

#### Изменение раскладки клавиатуры и шрифта
``` bash
echo 'KEYMAP=ru' > /etc/vconsole.conf
echo 'FONT=ter-c32b' >> /etc/vconsole.conf
```

#### Установка hostname
``` bash
echo '<hostname>' > /etc/hostname
```

#### Установка пароля root пользователя
``` bash
passwd
```
#### Настройка WiFi
``` bash
pacman -S networkmanager
systemctl enable NetworkManager
```
#### Настройка звука
``` bash
pacman -S pipewire lib32-pipewire
```
> [!tip]
>
> hello