# infovoto-infra

Orquestador local de InfoVoto Perú 2026. Docker Compose + Makefile + scripts GCP.

## Comandos
- `make up` — Levantar gateway + gradio + postgres + redis
- `make build` — Buildear todas las imágenes
- `make test` — Tests del gateway
- `make test-all` — Tests gateway + scraper
- `make down` — Bajar servicios
- `make help` — Ver todos los comandos

## Puertos locales (rango 2xxx)
- Gateway: localhost:2080
- Gradio: localhost:2860
- Postgres: localhost:2432
- Redis: localhost:2379

## Reglas
- SIEMPRE usar github.com-personal para SSH (NUNCA github.com)
- Git user: CristianLazoQuispe / mecatronico.lazo@gmail.com
- Organización: iDeepBrain
- NUNCA commitear .env (solo .env.example)
