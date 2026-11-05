# iOS-сборка Blink (тест, без Mac)
1. Создать ПРИВАТНЫЙ репозиторий на GitHub (например blink-ios) и нажать Connect GitHub: https://claude.ai/connect-github
2. Залить проект с .github/workflows/ios-unsigned.yml (в .gitignore добавить !/.github/ и !/capacitor.config.json).
3. Actions -> ios-unsigned -> Run workflow -> скачать артефакт Blink-unsigned-ipa.
4. Подписать бесплатным сертификатом (Telegram-сервис) или AltStore/Sideloadly и поставить на iPhone.
Оболочка грузит https://blinkmusic.cc, обновления приходят с деплоем сайта.
