# Imagem oficial Red Hat UBI 10 Minimal com Python 3.14
FROM registry.redhat.io/ubi10/python-314-minimal

# Definir diretório de trabalho na aplicação
WORKDIR /app

# Variáveis padrão de execução
ENV PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    PORT=8080 \
    SQLITE_DB_PATH=/app/data/redis_manager.sqlite3 \
    PATH="/app/.local/bin:${PATH}"

# Copia requirements e instala dependências de produção
COPY requirements.txt ./
RUN python3 -m pip install --no-cache-dir --upgrade pip && \
    python3 -m pip install --no-cache-dir -r requirements.txt

# Copia todo o código-fonte da aplicação
COPY . .

# Garante que a pasta de persistência do SQLite exista
RUN mkdir -p /app/data

# AJUSTE ESSENCIAL PARA OPENSHIFT:
# No OpenShift, contêineres rodam com um UID aleatório pertencente ao grupo root (gid 0).
# Garantimos permissão de leitura/escrita para o grupo 0 (root).
RUN chgrp -R 0 /app && \
    chmod -R g=u /app && \
    chmod -R 775 /app/data

# OpenShift não roda como root (usuário não-privilegiado 1001)
USER 1001

EXPOSE 8080

# Inicia o servidor WSGI Gunicorn (multi-worker e multi-thread)
CMD ["gunicorn", "--bind", "0.0.0.0:8080", "--workers", "2", "--threads", "4", "--access-logfile", "-", "--error-logfile", "-", "app:app"]
