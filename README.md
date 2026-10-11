# Redis Manager (Python 3.14 + Flask + Gunicorn)

Aplicação web leve em Python 3.14 para gerenciar e monitorar servidores e clusters Redis. Projetada para execução em Linux (Docker/Podman) e pronta para implantação em clusters **Red Hat OpenShift** utilizando a imagem oficial **Red Hat UBI 10 Minimal** (`registry.redhat.io/ubi10/python-314-minimal`), em total conformidade com os Security Context Constraints (SCC) e UIDs arbitrários do OpenShift.

---

## 🚀 Recursos
- **Dashboard de Métricas**: Status da conexão (PING), versão, DBSize, memória consumida, clientes conectados, hit rate de cache e uptime.
- **Suporte Multi-Servidor (SQLite3)**: Permite alternar e gerenciar diferentes conexões Redis (ex: DETRAN HML, Produção, Cache).
- **Explorador de Chaves (Keys Explorer - ARDM Style)**: Busca segura usando `SCAN` (não bloqueia o Redis em produção como o `KEYS *`), visualização de TTL, tipo de dado (String, Hash, List, Set, ZSet) e remoção segura.
- **Criação e Edição de Chaves**: Criação de chaves com TTL configurável e suporte a JSON.
- **Console Web CLI**: Execução de comandos arbitrários com camada de proteção contra comandos perigosos (`FLUSHALL`, `SHUTDOWN`, etc.).
- **OpenShift Native Probes**: Endpoints `/healthz` (liveness) e `/ready` (readiness).

---

## 🛠️ Como Executar

### Opção 1: Execução direta com Python 3.14
```bash
# 1. Instalar dependências
pip install -r requirements.txt

# 2. Iniciar a aplicação
python app.py
```
Acesse no navegador: `http://localhost:8080`

---

### Opção 2: Usando Podman ou Docker com Red Hat UBI 10
```bash
# 1. Construir a imagem localmente
podman build -t redis-manager:latest .
# (ou com docker: docker build -t redis-manager:latest .)

# 2. Executar o contêiner
podman run -d --name redis-manager -p 8080:8080 redis-manager:latest
```

---

### Opção 3: Usando Docker Compose / Podman Compose
```bash
docker compose up -d
# ou podman-compose up -d
```

---

## ☸️ Implantação no Red Hat OpenShift

A aplicação foi preparada especificamente para os padrões do OpenShift:
1. Imagem base **Red Hat UBI 10 Minimal** (`registry.redhat.io/ubi10/python-314-minimal`).
2. Roda com porta não-privilegiada (`8080`).
3. Permissões de grupo `root (gid 0)` configuradas para suportar o mecanismo de UID aleatório do OpenShift (SCC `restricted`).
4. Persistência de banco de dados SQLite com PVC de 1Gi montado em `/app/data`.
5. Manifests com `Deployment`, `Service` e `Route` TLS Edge já configurados.

### Passo a Passo no OpenShift (`oc` CLI):

1. **Faça login e selecione seu projeto:**
   ```bash
   oc project meu-namespace
   ```

2. **Crie a build direto do código ou faça push da imagem:**
   Se preferir usar o OpenShift BuildConfig (Binary build):
   ```bash
   oc new-build --strategy=docker --binary --name=redis-manager
   oc start-build redis-manager --from-dir=. --follow
   ```

   *Ou caso faça push para o Registry interno:*
   ```bash
   podman tag redis-manager:latest default-route-openshift-image-registry.apps.cluster.com/meu-namespace/redis-manager:latest
   podman push default-route-openshift-image-registry.apps.cluster.com/meu-namespace/redis-manager:latest
   ```

3. **Aplicar os manifests de PVC, Deployment, Service e Route:**
   ```bash
   oc apply -f openshift-deployment.yaml
   ```

4. **Obter a URL pública gerada pela Route:**
   ```bash
   oc get route redis-manager-route
   ```
