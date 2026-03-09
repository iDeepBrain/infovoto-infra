# infovoto-infra

Orquestador local de InfoVoto Perú 2026.

## Puertos

| Servicio | Puerto local | Puerto interno |
|----------|-------------|----------------|
| Gateway  | `2080`      | 8080           |
| Gradio   | `2860`      | 7860           |
| Postgres | `2432`      | 5432           |
| Redis    | `2379`      | 6379           |

## Comandos

```bash
cp .env.example .env        # configurar variables
make build                   # buildear imágenes
make up                      # levantar todo
make test                    # correr tests
make logs                    # ver logs
make down                    # bajar todo
make help                    # ver todos los comandos
```

## Estructura

```
infovoto-infra/
├── Makefile              # Todos los comandos
├── docker-compose.yml    # Orquestador
├── .env.example          # Variables de entorno
├── scripts/              # Scripts GCP
└── cloudbuild/           # Cloud Build configs
```
