# Metabase — Dashboard de Analytics

Dashboard visual para visualizar métricas de usuarios, consultas y engagement en InfoVoto.

## 🚀 Quick Start

```bash
# 1. Iniciar Metabase (solo primera vez)
make metabase-up

# 2. Configurar automáticamente (dashboards predefinidos)
make metabase-setup

# 3. Acceder
→ http://localhost:2010
Email: admin@infovoto.local
Password: infovoto2026
```

## 📊 Dashboards Predefinidos

Después de ejecutar `make metabase-setup`, tendrás automáticamente:

### 1. **Analytics Overview**
   - **Usuarios únicos por día** (gráfico de línea)
   - **Total de consultas por día** (gráfico de barras)
   - **Logins por día** (gráfico de área)
   - **Top 10 usuarios más activos** (tabla)

## 🔧 Comandos Disponibles

```bash
make metabase-up        # Iniciar contenedor de Metabase
make metabase-setup     # Configurar dashboards automáticamente
make metabase-shell     # Shell interactivo en el container
make metabase-logs      # Ver logs en tiempo real
```

## 📈 Crear tus propios gráficos

1. Accede a http://localhost:2010
2. Click en **"+ New"** → **"Question"**
3. Selecciona **"Simple Question"**
4. Elige tabla `user_events`
5. Arrastra campos:
   - **X-axis:** `timestamp` (con GROUP BY date)
   - **Y-axis:** `COUNT(*)` o `COUNT(DISTINCT user_id)`
6. Click en **"Visualize"**
7. Elige tipo de gráfico (línea, barra, área, etc.)

## 📝 Ejemplos de Queries SQL

Si prefieres escribir SQL directo:

```sql
-- Usuarios únicos por día
SELECT DATE(timestamp) as fecha, COUNT(DISTINCT user_id) as usuarios
FROM user_events
WHERE event_type = 'api_call'
GROUP BY DATE(timestamp)
ORDER BY fecha DESC;

-- Top usuarios
SELECT user_id, COUNT(*) as consultas
FROM user_events
WHERE event_type = 'api_call'
GROUP BY user_id
ORDER BY consultas DESC
LIMIT 10;

-- Duración promedio de requests
SELECT DATE(timestamp) as fecha, ROUND(AVG(duration_ms), 0) as duracion_promedio
FROM user_events
WHERE event_type = 'api_call' AND duration_ms IS NOT NULL
GROUP BY DATE(timestamp)
ORDER BY fecha DESC;
```

Para usar SQL:
1. Click **"+ New"** → **"Native Query"**
2. Pega tu SQL
3. Click **"Execute"**

## 🔐 Cambiar contraseña

1. Click en tu avatar (arriba a la derecha)
2. **"Account settings"**
3. **"Password"** → ingresa contraseña nueva

## 📤 Compartir dashboards

1. Abre dashboard
2. Click **"Share"** (arriba a la derecha)
3. Elige:
   - **"Email"** → enviar a stakeholders
   - **"Public"** → generar link público (sin login)
   - **"Scheduled"** → enviar por email automáticamente

## 📱 Alerts (opcional)

Puedes configurar alertas para que Metabase te avise si:
- Usuarios caen por debajo de X
- Errores superan Y%
- Tiempo de respuesta > Z ms

Para crear:
1. En un gráfico, click **"Alert"**
2. Configura condición
3. Metabase te envía email si se cumple

## 🔄 Refresh automático

Los dashboards se refrescan cada:
- **600 segundos (10 min)** — configurado en docker-compose.yml
- Puedes cambiar: `MB_DASHBOARD_CACHING_TTL`

## 🗄️ Datos y Backups

Metabase guarda su configuración en:
- Volumen Docker: `metabase-data` (persiste aunque reinicies)
- Base de datos: La misma Postgres de InfoVoto

Para hacer backup:

```bash
# Backup de Metabase
docker compose cp metabase:/metabase-data ./backups/metabase-$(date +%Y%m%d).tar

# Restaurar
docker compose cp ./backups/metabase-YYYYMMDD.tar metabase:/metabase-data
```

## ⚙️ Configuración Avanzada

En `docker-compose.yml`:

```yaml
environment:
  MB_DB_TYPE: postgres           # BD donde guarda config
  MB_DB_DBNAME: infovoto         # Base de datos
  MB_JAVA_TOOL_OPTIONS: -Xmx512m # Memoria máxima
```

Para más opciones: https://www.metabase.com/docs/latest/installation-and-operation/environment-variables

## 🚨 Troubleshooting

### Metabase no inicia
```bash
make metabase-logs
```
Busca el error en los logs.

### Setup falla
```bash
# Espera a que Metabase esté listo (60 segundos)
sleep 30
make metabase-setup
```

### Conectar a otra base de datos
En Metabase UI:
1. Click **"⚙️ Settings"** (arriba a la derecha)
2. **"Databases"**
3. **"Add database"**
4. Ingresa credenciales

## 📚 Recursos

- Documentación oficial: https://www.metabase.com/docs/
- SQL Cheat Sheet: https://www.metabase.com/learn/databases/native-query/
- Ejemplos de queries: `infovoto-gateway/docs/analytics-queries.sql`
