# infovoto-infra

Docker Compose + Makefile for local dev orchestration. No GCP deployment.

## Commands
```bash
make up        # start gateway + web + infovoto-mcp + postgres + redis
make down      # stop all services
make build     # rebuild all images
make health    # check all service health endpoints
make test      # gateway tests
make test-all  # gateway + scraper tests
make migrate   # run Alembic migrations
make shell-db  # psql into postgres
make shell-gw  # bash into gateway container
make scrape    # run scraper job
make help      # list all targets
```

## Local Ports (2xxx range)
| Service      | Local  | Container |
|-------------|--------|-----------|
| gateway     | 2080   | 8080      |
| web         | 2300   | 3000      |
| infovoto-mcp| 2900   | 8080      |
| postgres    | 2432   | 5432      |
| redis       | 2379   | 6379      |

## Docker Compose Profiles
- default — gateway, web, infovoto-mcp, postgres, redis
- `scraper` — adds scraper batch job container
- `dev` — adds gradio container (port 2860)

## Key Rule
NEVER commit `.env` — only `.env.example` is committed.
