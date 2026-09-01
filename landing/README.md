# Лендинг Amanu

Самодостаточная статическая страница: один `index.html`, один `style.css`,
ассеты в `assets/` — без сборки, без внешних ресурсов, без сети.

Посмотреть: `open index.html` (или любой статический сервер).

Проверки: `python3 tests/check.py` — структура, локальность всех ресурсов,
честность Windows-блока, доступность, обе темы, reduced-motion.

Боевой адрес: `https://amanu.me`. Статику отдаёт nginx на `reina`
из `/var/www/amanu`; копия его конфига лежит в `deploy/nginx/`.
Просмотры считает тот же first-party GoatCounter, что у сайта
подкаста и CTOdaily; дашборд доступен на `/goatcounter`.
