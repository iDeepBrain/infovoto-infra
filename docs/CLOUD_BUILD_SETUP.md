# 🚀 Cloud Build Setup — Deploy Automático desde GitHub

Configura Cloud Build para que **automáticamente** haga build + deploy cada vez que hagas push a `main`.

---

## Paso 1: Conectar GitHub a GCP (Una vez)

```bash
# En la consola de GCP (no en terminal local):
# 1. Ve a: https://console.cloud.google.com/cloud-build/repositories
# 2. Click "Connect Repository"
# 3. Selecciona "GitHub"
# 4. Authoriza a GCP acceder a tu GitHub (cristian2023ml@gmail.com)
# 5. Selecciona: iDeepBrain organization
# 6. Selecciona repos:
#    - infovoto-web
#    - infovoto-gateway
#    - infovoto-mcp
#    - infovoto-infra (opcional)
# 7. Click "Connect"
```

---

## Paso 2: Crear Cloud Build Trigger para cada repo

### Para infovoto-web:

```bash
# En GCP Console:
# 1. Cloud Build → Triggers → Create Trigger
# 2. Llenar:
#    - Name: infovoto-web-deploy
#    - Repository: infovoto-web
#    - Branch: main
#    - Build type: Cloud Run
#    - Service name: web
#    - Region: us-central1
#    - Dockerfile location: Dockerfile (default)
# 3. Click "Create"
```

### Para infovoto-gateway:

```bash
# Igual que arriba pero:
#    - Name: infovoto-gateway-deploy
#    - Repository: infovoto-gateway
#    - Service name: gateway
```

### Para infovoto-mcp:

```bash
# Igual que arriba pero:
#    - Name: infovoto-mcp-deploy
#    - Repository: infovoto-mcp
#    - Service name: mcp-server
```

---

## Paso 3: Agregar cloudbuild.yaml a cada repo (opcional pero recomendado)

Crear archivo `cloudbuild.yaml` en la raíz de cada repo para custom logic:

### infovoto-web/cloudbuild.yaml:

```yaml
steps:
  # 1. Build image
  - name: 'gcr.io/cloud-builders/docker'
    args: ['build', '-t', 'gcr.io/$PROJECT_ID/web:latest', '.']

  # 2. Push to Container Registry
  - name: 'gcr.io/cloud-builders/docker'
    args: ['push', 'gcr.io/$PROJECT_ID/web:latest']

  # 3. Deploy to Cloud Run
  - name: 'gcr.io/cloud-builders/run'
    args:
      - 'deploy'
      - 'web'
      - '--image=gcr.io/$PROJECT_ID/web:latest'
      - '--region=us-central1'
      - '--platform=managed'
      - '--allow-unauthenticated'
      - '--port=3000'
      - '--memory=512Mi'
      - '--cpu=0.5'
      - '--max-instances=5'

  # 4. Run smoke tests (optional)
  - name: 'gcr.io/cloud-builders/npm'
    args: ['run', 'test']
    env:
      - 'NODE_ENV=test'

# Build config
images:
  - 'gcr.io/$PROJECT_ID/web:latest'

options:
  machineType: 'N1_HIGHCPU_8'

timeout: '3600s'
```

### infovoto-gateway/cloudbuild.yaml:

```yaml
steps:
  # 1. Build image
  - name: 'gcr.io/cloud-builders/docker'
    args: ['build', '-t', 'gcr.io/$PROJECT_ID/gateway:latest', '.']

  # 2. Push to Container Registry
  - name: 'gcr.io/cloud-builders/docker'
    args: ['push', 'gcr.io/$PROJECT_ID/gateway:latest']

  # 3. Deploy to Cloud Run
  - name: 'gcr.io/cloud-builders/run'
    args:
      - 'deploy'
      - 'gateway'
      - '--image=gcr.io/$PROJECT_ID/gateway:latest'
      - '--region=us-central1'
      - '--platform=managed'
      - '--allow-unauthenticated'
      - '--port=8080'
      - '--memory=512Mi'
      - '--cpu=0.5'
      - '--max-instances=5'
      - '--set-secrets=GOOGLE_CLIENT_ID=GOOGLE_CLIENT_ID:latest'
      - '--set-secrets=GOOGLE_CLIENT_SECRET=GOOGLE_CLIENT_SECRET:latest'
      - '--set-secrets=GEMINI_API_KEY=GEMINI_API_KEY:latest'
      - '--set-secrets=NEXTAUTH_SECRET=NEXTAUTH_SECRET:latest'
      - '--set-env-vars=ENVIRONMENT=production,LOG_LEVEL=INFO'

  # 4. Run smoke tests (optional)
  - name: 'gcr.io/cloud-builders/python'
    args: ['pytest', 'tests/smoke/', '-v']
    env:
      - 'PYTHONPATH=src'

images:
  - 'gcr.io/$PROJECT_ID/gateway:latest'

options:
  machineType: 'N1_HIGHCPU_8'

timeout: '3600s'
```

---

## Paso 4: Verificar que CI/CD funciona

```bash
# En tu terminal local:

# 1. Haz un cambio en el código
echo "# Test comment" >> infovoto-web/README.md

# 2. Commit y push
cd infovoto-web
git add README.md
git commit -m "test: trigger cloud build"
git push origin main

# 3. Ve a GCP Console:
# https://console.cloud.google.com/cloud-build/builds
# Deberías ver tu build en progreso

# 4. Cuando termine (5-10 min):
# https://console.cloud.google.com/run/detail/us-central1/web
# Verifica que la nueva versión está deployada
```

---

## Flujo completo (después de setup)

```
Tu código                GitHub Push              Cloud Build                    Cloud Run
   ↓                         ↓                          ↓                              ↓
[git commit]  →  [git push origin main]  →  [Trigger automático]  →  [Deploy automático]
```

Cada push a `main`:
1. ✅ Cloud Build detecta el cambio
2. ✅ Construye la imagen Docker
3. ✅ Pushea a Container Registry
4. ✅ Deploy a Cloud Run (reemplaza versión anterior)
5. ✅ Todo en ~5-10 min automáticamente

---

## Tips

- **Secrets**: Ya están en Secret Manager (`GOOGLE_CLIENT_ID`, etc), Cloud Run los conecta automáticamente
- **Network**: Cloud Run services se conectan por HTTPS automáticamente (no necesitas VPC)
- **Rollback**: Si algo falla, Cloud Run mantiene la versión anterior activa
- **Monitoring**: Todos los logs en Cloud Logging (enlace en Cloud Run dashboard)

---

## Troubleshooting

### Build falla?
```bash
# Ver logs detallados en GCP:
gcloud builds log [BUILD_ID] --region=us-central1 --limit=100
```

### Deploy no actualiza?
```bash
# Forzar redeploy
gcloud run deploy [SERVICE] --image=gcr.io/[PROJECT]/[SERVICE]:latest --region=us-central1
```

---

## Documentación

- Cloud Build: https://cloud.google.com/build/docs
- Cloud Run CI/CD: https://cloud.google.com/run/docs/continuous-deployment-with-cloud-build
