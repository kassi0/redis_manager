require 'bundler/setup'
require 'sinatra/base'
require 'redis'
require 'json'
require 'erb'
require_relative 'config_store'

class RedisManagerApp < Sinatra::Base
  enable :sessions
  set :session_secret, ENV.fetch('SESSION_SECRET', 'redis_manager_secret_key_super_safe_64_bytes_long_1234567890abcdef1234567890abcdef')
  set :public_folder, File.join(__dir__, 'public')
  set :views, File.join(__dir__, 'views')

  helpers do
    def all_servers
      ConfigStore.load_servers
    end

    def current_server_config
      server_id = params[:server_id] || session[:current_server_id]
      found = ConfigStore.find(server_id) if server_id
      found ||= all_servers.first
      session[:current_server_id] = found['id'] if found
      found
    end

    def current_db_index
      if params[:db] && !params[:db].empty?
        db_num = params[:db].to_i
        session[:current_db] = db_num
        db_num
      else
        session[:current_db] || current_server_config&.dig('db') || 0
      end
    end

    def redis_client(srv = nil, db = nil)
      target = srv || current_server_config
      raise "Nenhum servidor Redis cadastrado." unless target

      target_db = db || current_db_index
      url = ConfigStore.build_redis_url(target, target_db)
      Redis.new(url: url, timeout: 4.0)
    end

    def test_connection(srv)
      client = redis_client(srv, srv['db'])
      pong = client.ping
      { success: pong == 'PONG', message: 'Conexão efetuada com sucesso (PONG)' }
    rescue => e
      { success: false, message: e.message }
    end

    def h(text)
      Rack::Utils.escape_html(text.to_s)
    end

    def format_bytes(bytes)
      bytes = bytes.to_f
      if bytes >= 1024 * 1024 * 1024
        "#{(bytes / (1024 * 1024 * 1024)).round(2)} GB"
      elsif bytes >= 1024 * 1024
        "#{(bytes / (1024 * 1024)).round(2)} MB"
      elsif bytes >= 1024
        "#{(bytes / 1024).round(2)} KB"
      else
        "#{bytes.to_i} B"
      end
    end
  end

  # Healthchecks para Liveness/Readiness no OpenShift
  get '/healthz' do
    content_type :json
    { status: 'ok', timestamp: Time.now.utc.iso8601 }.to_json
  end

  get '/ready' do
    content_type :json
    begin
      srv = current_server_config
      if srv
        redis_client(srv).ping
        { status: 'ready', server: srv['name'] }.to_json
      else
        { status: 'ready', server: 'none' }.to_json
      end
    rescue => e
      status 503
      { status: 'error', message: e.message }.to_json
    end
  end

  # ==========================================
  # PÁGINA INICIAL / GERENCIADOR (STYLE ARDM)
  # ==========================================
  get '/' do
    @servers = all_servers
    @current_server = current_server_config
    @active_db = current_db_index
    @server_statuses = {}
    @databases = []

    # Detecta estatísticas dos 16 DBs do servidor ativo
    if @current_server
      begin
        c = redis_client(@current_server, @active_db)
        info = c.info
        @server_info = info
        @db_size = c.dbsize

        # Ler chaves de keyspace (db0, db1, etc)
        # Ex: "keys=120,expires=10,avg_ttl=3600"
        (0..15).each do |i|
          db_stat = info["db#{i}"]
          keys_count = 0
          expires_count = 0
          if db_stat
            keys_count = db_stat['keys'].to_i if db_stat.is_a?(Hash)
            if db_stat.is_a?(String)
              keys_count = db_stat[/keys=(\d+)/, 1].to_i rescue 0
              expires_count = db_stat[/expires=(\d+)/, 1].to_i rescue 0
            end
          end
          @databases << {
            index: i,
            keys_count: keys_count,
            expires_count: expires_count,
            active: (i == @active_db)
          }
        end
      rescue => e
        @error = "Falha ao conectar no Redis (#{@current_server['host']}:#{@current_server['port']}): #{e.message}"
      end
    end

    erb :manager
  end

  # Trocar servidor ativo ou DB ativo
  get '/switch' do
    session[:current_server_id] = params[:server_id] if params[:server_id]
    session[:current_db] = params[:db].to_i if params[:db]
    redirect(params[:return_to] || '/')
  end

  # ==========================================
  # API AJAX PARA O ARDM EXPLORER
  # ==========================================

  # 1. Listar chaves com SCAN, busca e agrupamento
  get '/api/keys' do
    content_type :json
    pattern = params[:pattern].to_s.strip
    pattern = '*' if pattern.empty?
    cursor = params[:cursor] || '0'
    limit = 250

    begin
      client = redis_client
      next_cursor, raw_keys = client.scan(cursor, match: pattern, count: limit)

      # Pipeline para buscar tipos e ttls em lote sem lentidão
      keys_data = []
      if raw_keys.any?
        client.pipelined do |pipe|
          raw_keys.each do |k|
            pipe.type(k)
            pipe.ttl(k)
          end
        end.each_slice(2).with_index do |(type_res, ttl_res), idx|
          keys_data << {
            name: raw_keys[idx],
            type: type_res,
            ttl: ttl_res
          }
        end
      end

      # Ordena alfabeticamente
      keys_data.sort_by! { |k| k[:name] }

      {
        cursor: next_cursor,
        total_found: keys_data.size,
        keys: keys_data
      }.to_json
    rescue => e
      status 500
      { error: e.message }.to_json
    end
  end

  # 2. Obter detalhes completos da chave (Value, Type, TTL, Memory)
  get '/api/key' do
    content_type :json
    key = params[:name]
    return { error: 'Chave não informada' }.to_json unless key

    begin
      client = redis_client
      type = client.type(key)

      if type == 'none'
        return { error: 'Chave não existe ou expirou.' }.to_json
      end

      ttl = client.ttl(key)
      pttl = client.pttl(key) rescue -1
      
      # Tenta calcular memory usage se suportado pelo Redis
      memory_usage = client.call(['MEMORY', 'USAGE', key]) rescue nil

      value = nil
      length = 0

      case type
      when 'string'
        value = client.get(key)
        length = value ? value.bytesize : 0
      when 'list'
        length = client.llen(key)
        value = client.lrange(key, 0, 99) # primeiras 100
      when 'set'
        length = client.scard(key)
        value = client.smembers(key).first(100)
      when 'zset'
        length = client.zcard(key)
        value = client.zrange(key, 0, 99, withscores: true) # primeiras 100
      when 'hash'
        length = client.hlen(key)
        value = client.hgetall(key)
      end

      {
        name: key,
        type: type,
        ttl: ttl,
        pttl: pttl,
        memory_usage: memory_usage,
        length: length,
        value: value
      }.to_json
    rescue => e
      status 500
      { error: e.message }.to_json
    end
  end

  # 3. Salvar / Atualizar valor da Chave
  post '/api/key/save' do
    content_type :json
    payload = JSON.parse(request.body.read) rescue params
    key = payload['name']&.strip
    type = payload['type'] || 'string'
    val = payload['value']
    ttl = payload['ttl'] ? payload['ttl'].to_i : nil

    return { error: 'Nome da chave obrigatório' }.to_json if key.nil? || key.empty?

    begin
      client = redis_client

      case type
      when 'string'
        client.set(key, val.to_s)
      when 'hash'
        # Se for json de hash ou campo/valor
        if val.is_a?(Hash)
          client.del(key)
          client.hset(key, val) unless val.empty?
        elsif payload['field']
          client.hset(key, payload['field'], payload['field_value'])
        end
      when 'list'
        if payload['element']
          client.rpush(key, payload['element'])
        end
      when 'set'
        if payload['element']
          client.sadd(key, payload['element'])
        end
      when 'zset'
        if payload['element'] && payload['score']
          client.zadd(key, payload['score'].to_f, payload['element'])
        end
      end

      if ttl && ttl > 0
        client.expire(key, ttl)
      elsif ttl == -1
        client.persist(key)
      end

      { success: true, message: 'Chave atualizada com sucesso!' }.to_json
    rescue => e
      status 500
      { error: e.message }.to_json
    end
  end

  # 4. Atualizar somente TTL
  post '/api/key/ttl' do
    content_type :json
    payload = JSON.parse(request.body.read) rescue params
    key = payload['name']
    ttl = payload['ttl'].to_i

    begin
      client = redis_client
      if ttl > 0
        client.expire(key, ttl)
      elsif ttl == -1
        client.persist(key)
      end
      { success: true, ttl: client.ttl(key) }.to_json
    rescue => e
      status 500
      { error: e.message }.to_json
    end
  end

  # 5. Excluir Chave
  post '/api/key/delete' do
    content_type :json
    payload = JSON.parse(request.body.read) rescue params
    key = payload['name']

    begin
      client = redis_client
      deleted = client.del(key)
      { success: true, count: deleted }.to_json
    rescue => e
      status 500
      { error: e.message }.to_json
    end
  end

  # 6. Renomear Chave
  post '/api/key/rename' do
    content_type :json
    payload = JSON.parse(request.body.read) rescue params
    old_name = payload['old_name']
    new_name = payload['new_name']&.strip

    return { error: 'Novo nome inválido' }.to_json if new_name.nil? || new_name.empty?

    begin
      client = redis_client
      client.rename(old_name, new_name)
      { success: true, new_name: new_name }.to_json
    rescue => e
      status 500
      { error: e.message }.to_json
    end
  end

  # ==========================================
  # CONFIGURAÇÕES DE HOSTS E DBs
  # ==========================================
  get '/settings' do
    @servers = all_servers
    @edit_server = params[:edit_id] ? ConfigStore.find(params[:edit_id]) : nil
    @flash = session.delete(:flash)
    erb :settings
  end

  post '/settings/create' do
    ConfigStore.add_server(params)
    session[:flash] = { type: 'success', text: 'Novo servidor Redis cadastrado com sucesso!' }
    redirect '/settings'
  end

  post '/settings/update' do
    id = params[:id]
    ConfigStore.update_server(id, params)
    session[:flash] = { type: 'success', text: 'Configurações atualizadas!' }
    redirect '/settings'
  end

  post '/settings/delete' do
    id = params[:id]
    ConfigStore.delete_server(id)
    session[:flash] = { type: 'info', text: 'Servidor removido.' }
    session.delete(:current_server_id) if session[:current_server_id] == id
    redirect '/settings'
  end

  post '/settings/test' do
    content_type :json
    srv = {
      'host' => params[:host],
      'port' => params[:port],
      'password' => params[:password],
      'db' => params[:db],
      'ssl' => params[:ssl] == 'true'
    }
    result = test_connection(srv)
    result.to_json
  end

  # Terminal CLI
  get '/cli' do
    @servers = all_servers
    @current_server = current_server_config
    @active_db = current_db_index
    erb :cli
  end

  post '/cli/exec' do
    content_type :json
    command_str = params[:command].to_s.strip

    if command_str.empty?
      return { error: 'Comando vazio.' }.to_json
    end

    parts = command_str.shellsplit rescue command_str.split(' ')
    cmd = parts[0]&.downcase

    forbidden = %w[flushall flushdb shutdown config slaveof replicaof bgsave debug]
    if forbidden.include?(cmd)
      return { error: "Comando '#{cmd.upcase}' bloqueado por política de segurança web." }.to_json
    end

    begin
      client = redis_client
      res = client.call(parts)
      { output: format_redis_output(res) }.to_json
    rescue => e
      { error: e.message }.to_json
    end
  end

  private

  def format_redis_output(res)
    case res
    when Array
      res.map.with_index { |item, idx| "#{idx + 1}) #{item.inspect}" }.join("\n")
    when Hash
      res.map { |k, v| "#{k}: #{v}" }.join("\n")
    else
      res.to_s
    end
  end
end
