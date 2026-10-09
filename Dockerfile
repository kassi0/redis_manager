# Imagem base oficial Ruby minimalista e segura
FROM docker.io/library/ruby:3.2-alpine

# Instala dependências de build necessárias para compilar Puma e a gem sqlite3 com musl
RUN apk add --no-cache build-base tzdata sqlite-dev sqlite-libs

# Definir diretório de trabalho na aplicação
WORKDIR /app

# Forçar o bundler a compilar a gem sqlite3 a partir do código fonte (para compatibilidade com musl/Alpine)
RUN bundle config set --global force_ruby_platform true

# Copia Gemfile e instala dependências de produção
COPY Gemfile ./
RUN bundle config set --local without 'development test' && \
    bundle install --jobs 4 --retry 3

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

# OpenShift não roda como root (usar usuário não-privilegiado 1001)
USER 1001

# Variáveis padrão de execução
ENV RACK_ENV=production \
    PORT=8080 \
    PUMA_THREADS=5 \
    SQLITE_DB_PATH=/app/data/redis_manager.sqlite3

EXPOSE 8080

# Inicia o servidor web Puma
CMD ["bundle", "exec", "puma", "-C", "puma.rb"]
