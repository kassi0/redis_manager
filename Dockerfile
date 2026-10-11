# Imagem oficial Red Hat UBI 10 Minimal com Python 3.14
FROM registry.redhat.io/ubi10/python-314-minimal

# Alterne para root (UID 0) para criar diretórios e conceder permissões do OpenShift
USER 0

# Definir diretório de trabalho na aplicação
WORKDIR /app

# Variáveis padrão de execução
ENV PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    PORT=8080 \
    SQLITE_DB_PATH=/app/data/redis_manager.sqlite3 \
    PATH="/app/.local/bin:${PATH}"

# Cria diretório de persistência para o SQLite
RUN mkdir -p /app/data

# Copia requirements e instala dependências de produção
COPY requirements.txt ./
RUN python3 -m pip install --no-cache-dir --upgrade pip && \
    python3 -m pip install --no-cache-dir -r requirements.txt

# Copia todo o código-fonte da aplicação
COPY . .

# AJUSTE ESSENCIAL PARA OPENSHIFT:
# No OpenShift, contêineres rodam com um UID aleatório pertencente ao grupo root (gid 0).
# Concedemos permissão ao grupo 0 (root) para todos os arquivos e pastas da aplicação.
RUN chgrp -R 0 /app && \
    chmod -R g=u /app && \
    chmod -R 775 /app/data

# OpenShift não roda como root: retorna para o usuário não-privilegiado 1001
USER 1001

EXPOSE 8080

# Inicia o servidor WSGI Gunicorn (multi-worker e multi-thread)
CMD ["gunicorn", "--bind", "0.0.0.0:8080", "--workers", "2", "--threads", "4", "--access-logfile", "-", "--error-logfile", "-", "app:app"]
