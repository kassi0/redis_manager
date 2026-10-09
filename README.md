# Redis Manager (Ruby + Sinatra + Puma)

Aplicação web leve em Ruby para gerenciar e monitorar servidores e clusters Redis. Projetada para execução em Linux (Docker/Podman) e pronta para implantação em clusters **Red Hat OpenShift** (em conformidade com os Security Context Constraints - SCC e UIDs arbitrários).

---

## 🚀 Recursos
- **Dashboard de Métricas**: Status da conexão (PING), versão, DBSize, memória consumida, clientes conectados, hit rate de cache e uptime.
- **Suporte Multi-Servidor**: Permite alternar entre diferentes servidores Redis (ex: Produção, Homologação, Cache).
- **Explorador de Chaves (Keys Explorer)**: Busca usando `SCAN` (não trava o Redis em produção como o `KEYS *`), visualização de TTL, tipo de dado (String, Hash, List, Set, ZSet) e remoção segura.
- **Criação e Edição de Chaves**: Criação de chaves com TTL configurável.
- **Console Web CLI**: Execução de comandos arbitrários com camada de proteção contra comandos perigosos (`FLUSHALL`, `SHUTDOWN`, etc.).
- **OpenShift Native Probes**: Endpoints `/healthz` (liveness) e `/ready` (readiness).

---

## 🛠️ Como Executar em Linux

### Opção 1: Usando Podman ou Docker (Recomendado)
Como você está em um ambiente Linux (RHEL/Fedora/CentOS/Ubuntu), você pode rodar diretamente com container:

```bash
# 1. Construir a imagem localmente
podman build -t redis-manager:latest .
# (ou com docker: docker build -t redis-manager:latest .)

# 2. Executar o contêiner apontando para seu Redis
podman run -d --name redis-manager -p 8080:8080 \
  -e REDIS_SERVERS="Principal=redis://10.0.0.10:6379,Secundario=redis://10.0.0.11:6379" \
  redis-manager:latest
```

Acesse no navegador: `http://localhost:8080`

---

### Opção 2: Usando Docker Compose / Podman Compose (Com Redis local)
```bash
docker compose up -d
# ou podman-compose up -d
```
Isso subirá uma instância do Redis e o Redis Manager automaticamente.

---

### Opção 3: Execução direta com Ruby (Host Linux)
Requer Ruby 3.x instalado no sistema:
```bash
# Instalar dependências
gem install bundler
bundle install

# Exportar as variáveis
export REDIS_SERVERS="Local=redis://127.0.0.1:6379"
export PORT=8080

# Iniciar servidor Puma
bundle exec puma -C puma.rb
```

---

## ☸️ Implantação no OpenShift

A aplicação foi preparada especificamente para os padrões do OpenShift:
1. Roda com porta não-privilegiada (`8080`).
2. Permissões de grupo `root (gid 0)` configuradas no `Dockerfile` para suportar o mecanismo de UID aleatório do OpenShift (SCC `restricted`).
3. Manifests com `Route` TLS Edge já configurados.

### Passo a Passo no OpenShift (`oc` CLI):

1. **Faça login e selecione seu projeto:**
   ```bash
   oc project meu-namespace
   ```

2. **Crie a build direto do código ou faça push da imagem:**
   Se preferir usar o OpenShift BuildConfig (Source-to-Image / Docker build):
   ```bash
   oc new-build --strategy=docker --binary --name=redis-manager
   oc start-build redis-manager --from-dir=. --follow
   ```

   *Ou caso faça push para o Registry interno:*
   ```bash
   podman tag redis-manager:latest default-route-openshift-image-registry.apps.cluster.com/meu-namespace/redis-manager:latest
   podman push default-route-openshift-image-registry.apps.cluster.com/meu-namespace/redis-manager:latest
   ```

3. **Aplicar os manifests de Deployment, Service e Route:**
   Edite a variável `REDIS_SERVERS` no arquivo `openshift-deployment.yaml` com o endereço do seu Redis interno ou externo e execute:
   ```bash
   oc apply -f openshift-deployment.yaml
   ```

4. **Obter a URL pública gerada pela Route:**
   ```bash
   oc get route redis-manager-route
   ```
