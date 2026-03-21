#!/bin/bash
# Metabase Setup Script
# Configura Metabase automáticamente con dashboards predefinidos
# Ejecutar después de: docker-compose up -d metabase

set -e

METABASE_URL="http://localhost:2010"
ADMIN_EMAIL="admin@infovoto.local"
ADMIN_PASSWORD="infovoto2026"

echo "⏳ Esperando a Metabase..."
sleep 60

echo "🔧 Inicializando Metabase..."

# 1. Setup inicial (crear usuario admin)
echo "→ Creando usuario admin..."
SETUP_RESPONSE=$(curl -s -X POST "$METABASE_URL/api/setup" \
  -H "Content-Type: application/json" \
  -d "{
    \"token\": \"blank\",
    \"user\": {
      \"first_name\": \"InfoVoto\",
      \"last_name\": \"Admin\",
      \"email\": \"$ADMIN_EMAIL\",
      \"password\": \"$ADMIN_PASSWORD\"
    },
    \"database\": {
      \"engine\": \"postgres\",
      \"name\": \"InfoVoto\",
      \"details\": {
        \"host\": \"postgres\",
        \"port\": 5432,
        \"dbname\": \"infovoto\",
        \"user\": \"infovoto\",
        \"password\": \"localdev\"
      }
    }
  }")

echo "✓ Setup inicial completado"

# 2. Login para obtener session
echo "→ Autenticando..."
SESSION=$(curl -s -X POST "$METABASE_URL/api/session" \
  -H "Content-Type: application/json" \
  -d "{
    \"username\": \"$ADMIN_EMAIL\",
    \"password\": \"$ADMIN_PASSWORD\"
  }" | jq -r '.id')

echo "✓ Sesión iniciada: $SESSION"

# 3. Crear dashboard "Analytics Overview"
echo "→ Creando dashboard 'Analytics Overview'..."
DASHBOARD=$(curl -s -X POST "$METABASE_URL/api/dashboard" \
  -H "Content-Type: application/json" \
  -H "X-Metabase-Session: $SESSION" \
  -d "{
    \"name\": \"Analytics Overview\",
    \"description\": \"Métricas agregadas de usuarios y consultas\",
    \"caching_ttl\": null
  }" | jq -r '.id')

echo "✓ Dashboard creado: $DASHBOARD"

# 4. Get database ID
DB_ID=$(curl -s -X GET "$METABASE_URL/api/database" \
  -H "X-Metabase-Session: $SESSION" | jq -r '.[0].id')

echo "✓ Database ID: $DB_ID"

# 5. Create native questions (queries predefinidas)
echo "→ Creando preguntas (queries)..."

# Pregunta 1: Usuarios únicos por día
Q1=$(curl -s -X POST "$METABASE_URL/api/card" \
  -H "Content-Type: application/json" \
  -H "X-Metabase-Session: $SESSION" \
  -d "{
    \"name\": \"Usuarios únicos por día\",
    \"description\": \"Cuántos usuarios activos hay cada día\",
    \"database_id\": $DB_ID,
    \"dataset_query\": {
      \"type\": \"native\",
      \"native\": {
        \"query\": \"SELECT DATE(timestamp) as fecha, COUNT(DISTINCT user_id) as usuarios FROM user_events WHERE event_type='api_call' GROUP BY DATE(timestamp) ORDER BY fecha DESC\"
      },
      \"database\": $DB_ID
    },
    \"visualization_settings\": {
      \"chart.type\": \"line\",
      \"chart.colors\": [\"#4CAF50\"]
    }
  }" | jq -r '.id')

echo "  ✓ Q1 (Usuarios/día): $Q1"

# Pregunta 2: Consultas por día
Q2=$(curl -s -X POST "$METABASE_URL/api/card" \
  -H "Content-Type: application/json" \
  -H "X-Metabase-Session: $SESSION" \
  -d "{
    \"name\": \"Total de consultas por día\",
    \"description\": \"Número de API calls por día\",
    \"database_id\": $DB_ID,
    \"dataset_query\": {
      \"type\": \"native\",
      \"native\": {
        \"query\": \"SELECT DATE(timestamp) as fecha, COUNT(*) as consultas FROM user_events WHERE event_type='api_call' GROUP BY DATE(timestamp) ORDER BY fecha DESC\"
      },
      \"database\": $DB_ID
    },
    \"visualization_settings\": {
      \"chart.type\": \"bar\",
      \"chart.colors\": [\"#2196F3\"]
    }
  }" | jq -r '.id')

echo "  ✓ Q2 (Consultas/día): $Q2"

# Pregunta 3: Usuarios más activos
Q3=$(curl -s -X POST "$METABASE_URL/api/card" \
  -H "Content-Type: application/json" \
  -H "X-Metabase-Session: $SESSION" \
  -d "{
    \"name\": \"Top 10 usuarios más activos\",
    \"description\": \"Usuarios con más consultas\",
    \"database_id\": $DB_ID,
    \"dataset_query\": {
      \"type\": \"native\",
      \"native\": {
        \"query\": \"SELECT user_id, COUNT(*) as consultas FROM user_events WHERE event_type='api_call' GROUP BY user_id ORDER BY consultas DESC LIMIT 10\"
      },
      \"database\": $DB_ID
    },
    \"visualization_settings\": {
      \"chart.type\": \"table\"
    }
  }" | jq -r '.id')

echo "  ✓ Q3 (Top usuarios): $Q3"

# Pregunta 4: Logins por día
Q4=$(curl -s -X POST "$METABASE_URL/api/card" \
  -H "Content-Type: application/json" \
  -H "X-Metabase-Session: $SESSION" \
  -d "{
    \"name\": \"Logins por día\",
    \"description\": \"Nuevos usuarios que se logean cada día\",
    \"database_id\": $DB_ID,
    \"dataset_query\": {
      \"type\": \"native\",
      \"native\": {
        \"query\": \"SELECT DATE(timestamp) as fecha, COUNT(DISTINCT user_id) as logins FROM user_events WHERE event_type='login' GROUP BY DATE(timestamp) ORDER BY fecha DESC\"
      },
      \"database\": $DB_ID
    },
    \"visualization_settings\": {
      \"chart.type\": \"area\",
      \"chart.colors\": [\"#FF9800\"]
    }
  }" | jq -r '.id')

echo "  ✓ Q4 (Logins/día): $Q4"

# 6. Agregar cards al dashboard
echo "→ Agregando gráficos al dashboard..."

curl -s -X POST "$METABASE_URL/api/dashboard/$DASHBOARD/cards" \
  -H "Content-Type: application/json" \
  -H "X-Metabase-Session: $SESSION" \
  -d "{
    \"cards\": [
      {\"id\": $Q1, \"sizeX\": 6, \"sizeY\": 3, \"row\": 0, \"col\": 0},
      {\"id\": $Q2, \"sizeX\": 6, \"sizeY\": 3, \"row\": 0, \"col\": 6},
      {\"id\": $Q4, \"sizeX\": 6, \"sizeY\": 3, \"row\": 3, \"col\": 0},
      {\"id\": $Q3, \"sizeX\": 12, \"sizeY\": 4, \"row\": 6, \"col\": 0}
    ]
  }" > /dev/null

echo "✓ Gráficos agregados al dashboard"

# 7. Hacer el dashboard público (opcional)
curl -s -X PUT "$METABASE_URL/api/dashboard/$DASHBOARD" \
  -H "Content-Type: application/json" \
  -H "X-Metabase-Session: $SESSION" \
  -d "{
    \"caching_ttl\": 600
  }" > /dev/null

echo ""
echo "=========================================="
echo "✅ METABASE SETUP COMPLETADO"
echo "=========================================="
echo ""
echo "Accede a: http://localhost:2010"
echo "Email: $ADMIN_EMAIL"
echo "Password: $ADMIN_PASSWORD"
echo ""
echo "Dashboard: Analytics Overview"
echo ""
