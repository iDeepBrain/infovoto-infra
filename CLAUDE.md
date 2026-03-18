# infovoto-infra

Docker Compose + Makefile para orquestación local. Scripts globales de operación. Sin deploy a GCP.

## Comandos docker-compose

```bash
make up           # gateway + web + infovoto-mcp + postgres + redis
make down         # bajar todos los servicios
make build        # rebuild todas las imágenes
make health       # check health de todos los servicios
make test         # tests del gateway
make test-all     # tests gateway + scraper
make migrate      # correr migraciones Alembic
make shell-db     # psql en postgres
make shell-gw     # bash en gateway
make help         # listar todos los targets
```

## Scripts globales de git

```bash
make git-status              # estado de todos los repos
make git-commit m="mensaje"  # commitea y pushea todos los repos con cambios
```

Scripts en `scripts/git/` — solo locales, nunca en GCP.

## Estructura de scripts

```
scripts/
├── git/
│   ├── status-all.sh
│   └── commit-all.sh
├── gcp/     # (futuro) deploy, cloud run, secrets
└── db/      # (futuro) migraciones, backups, seeds
```

## Puertos locales (rango 2xxx)

| Servicio     | Local | Container |
|-------------|-------|-----------|
| gateway     | 2080  | 8080      |
| web         | 2300  | 3000      |
| infovoto-mcp| 2900  | 8080      |
| postgres    | 2432  | 5432      |
| redis       | 2379  | 6379      |
| gradio      | 2860  | 7860      |

## Docker Compose Profiles

- default — gateway, web, infovoto-mcp, postgres, redis
- `scraper` — agrega scraper batch job
- `dev` — agrega gradio (puerto 2860)

## Git (CRÍTICO)

- SSH: `github.com-personal` (NUNCA `github.com` — esa es de marvik)
- User: `CristianLazoQuispe` / Email: `mecatronico.lazo@gmail.com`
- Org: `iDeepBrain`
- Remote: `git@github.com-personal:iDeepBrain/infovoto-infra.git`

## Reglas .gitignore

NUNCA commitear: `.env`, `*.pem`, `*.key`, `*.p12`, `*credentials*.json`, `*service_account*.json`, `*.pdf`, `*.csv`, `*.xlsx`, `*.xls`, `*.parquet`, `*.db`, `*.sqlite`.
Solo commitear `.env.example` (sin valores reales).
