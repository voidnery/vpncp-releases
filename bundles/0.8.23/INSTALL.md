# Установка VPN Control Plane

Краткая инструкция для развёртывания панели на своём сервере. Исходный код не нужен —
ставится из готовых Docker-образов.

## Требования
- Linux-сервер (Ubuntu 22.04/24.04 и т.п.) с правами root/sudo.
- Установленные **Docker** и **Docker Compose v2**:
  ```bash
  curl -fsSL https://get.docker.com | sudo sh
  ```
- Домен (например `panel.example.com`) с A/AAAA-записью на IP этого сервера.
- Открытые порты **80** и **443** (и **8443** для подключения агентов на узлах).

## Шаг 1. Получить установочный бандл
Скачайте папку `bundle/` из репозитория релизов (compose-файл, шаблон `.env`, конфиги
`ops/`, установщик). Например:
```bash
mkdir -p /opt/vpncp && cd /opt/vpncp
# замените на ваш URL релизного репозитория:
curl -fsSLO https://raw.githubusercontent.com/<owner>/vpncp-releases/main/bundle/docker-compose.dist.yml
curl -fsSLO https://raw.githubusercontent.com/<owner>/vpncp-releases/main/bundle/.env.example
curl -fsSLO https://raw.githubusercontent.com/<owner>/vpncp-releases/main/bundle/quick-install.sh
# (а также папку ops/ — она есть в бандле)
chmod +x quick-install.sh
```
Проще всего скачать весь бандл архивом со страницы релиза.

## Шаг 2. Установка
```bash
cd /opt/vpncp
./quick-install.sh
```
Скрипт спросит:
- **домен** панели,
- **email** для Let's Encrypt,
- **пароль** первого администратора,
- **токен лицензии** (необязательно — можно пропустить и стартовать в режиме FREE).

Он сгенерирует секреты, стянет образы и запустит панель.

## Шаг 3. DNS и TLS
1. Убедитесь, что домен указывает на сервер (A-запись).
2. Получите TLS-сертификат (Let's Encrypt, webroot) и перезапустите nginx:
   ```bash
   docker compose -f docker-compose.dist.yml restart nginx
   ```
3. Откройте `https://ВАШ-ДОМЕН`, войдите под админом.

## Лицензия
Если не вводили токен при установке — откройте страницу **License** в панели и вставьте
полученный токен. Тариф и лимиты активируются сразу (проверка офлайн).

## Обновления
Панель сама сообщит о новой версии (страница **Обновления**). Обновление:
```bash
cd /opt/vpncp
docker compose -f docker-compose.dist.yml pull
docker compose -f docker-compose.dist.yml up -d
```
Миграции БД применяются автоматически при старте новой версии.

## Резервные копии
Сохраняйте том с данными MongoDB и файл `.env` (в нём ключ шифрования `MASTER_KEY` —
без него зашифрованные данные не восстановить).
