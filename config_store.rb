require 'sqlite3'
require 'fileutils'
require 'securerandom'
require 'erb'

class ConfigStore
  DB_PATH = ENV.fetch('SQLITE_DB_PATH', File.join(__dir__, 'data', 'redis_manager.sqlite3'))

  def self.db
    @db ||= begin
      ensure_storage_exists
      database = SQLite3::Database.new(DB_PATH)
      database.results_as_hash = true
      init_schema(database)
      database
    end
  end

  def self.init_schema(database)
    database.execute <<-SQL
      CREATE TABLE IF NOT EXISTS redis_servers (
        id TEXT PRIMARY KEY,
        name TEXT NOT NULL,
        host TEXT NOT NULL,
        port INTEGER NOT NULL DEFAULT 6379,
        password TEXT DEFAULT '',
        db INTEGER NOT NULL DEFAULT 0,
        ssl INTEGER NOT NULL DEFAULT 0,
        created_at TEXT NOT NULL,
        updated_at TEXT
      );
    SQL

    # Se a tabela estiver vazia, insere o servidor de exemplo solicitado
    count = database.get_first_value("SELECT COUNT(*) FROM redis_servers")
    if count == 0
      seed_default(database)
    end
  end

  def self.seed_default(database)
    # Exemplo fornecido pelo DETRAN
    id = SecureRandom.uuid[0..7]
    now = Time.now.strftime('%Y-%m-%d %H:%M:%S')
    database.execute(
      "INSERT INTO redis_servers (id, name, host, port, password, db, ssl, created_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
      [
        id,
        'Redis HML (DETRAN-BA)',
        'redis-hml.apps.ocp-prod.detran.ba.gov.br',
        32380,
        '6LZ1BydZ3cok8QRm53Tk',
        0,
        0,
        now
      ]
    )
  end

  def self.load_servers
    rows = db.execute("SELECT * FROM redis_servers ORDER BY created_at ASC")
    rows.map { |r| normalize_row(r) }
  end

  def self.find(id)
    row = db.get_first_row("SELECT * FROM redis_servers WHERE id = ?", [id])
    row ? normalize_row(row) : nil
  end

  def self.add_server(params)
    id = SecureRandom.uuid[0..7]
    name = params['name'].to_s.strip.empty? ? "Redis-#{id}" : params['name'].to_s.strip
    host = params['host'].to_s.strip
    port = params['port'].to_s.strip.empty? ? 6379 : params['port'].to_i
    password = params['password'].to_s
    db_idx = params['db'].to_s.strip.empty? ? 0 : params['db'].to_i
    ssl = (params['ssl'] == 'true' || params['ssl'] == '1') ? 1 : 0
    now = Time.now.strftime('%Y-%m-%d %H:%M:%S')

    db.execute(
      "INSERT INTO redis_servers (id, name, host, port, password, db, ssl, created_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
      [id, name, host, port, password, db_idx, ssl, now]
    )

    find(id)
  end

  def self.update_server(id, params)
    name = params['name'].to_s.strip
    host = params['host'].to_s.strip
    port = params['port'].to_s.strip.empty? ? 6379 : params['port'].to_i
    password = params['password'].to_s
    db_idx = params['db'].to_s.strip.empty? ? 0 : params['db'].to_i
    ssl = (params['ssl'] == 'true' || params['ssl'] == '1') ? 1 : 0
    now = Time.now.strftime('%Y-%m-%d %H:%M:%S')

    db.execute(
      "UPDATE redis_servers SET name = ?, host = ?, port = ?, password = ?, db = ?, ssl = ?, updated_at = ? WHERE id = ?",
      [name, host, port, password, db_idx, ssl, now, id]
    )

    find(id)
  end

  def self.delete_server(id)
    db.execute("DELETE FROM redis_servers WHERE id = ?", [id])
  end

  def self.build_redis_url(server, db_override = nil)
    return 'redis://127.0.0.1:6379' unless server

    scheme = server['ssl'] ? 'rediss' : 'redis'
    host = server['host'] || '127.0.0.1'
    port = server['port'] || 6379
    db_idx = db_override.nil? ? (server['db'] || 0) : db_override
    password = server['password'].to_s

    if password.empty?
      "#{scheme}://#{host}:#{port}/#{db_idx}"
    else
      encoded_pass = ERB::Util.url_encode(password) rescue password
      "#{scheme}://:#{encoded_pass}@#{host}:#{port}/#{db_idx}"
    end
  end

  private

  def self.normalize_row(r)
    {
      'id' => r['id'],
      'name' => r['name'],
      'host' => r['host'],
      'port' => r['port'].to_i,
      'password' => r['password'].to_s,
      'db' => r['db'].to_i,
      'ssl' => r['ssl'].to_i == 1,
      'created_at' => r['created_at'],
      'updated_at' => r['updated_at']
    }
  end

  def self.ensure_storage_exists
    dir = File.dirname(DB_PATH)
    FileUtils.mkdir_p(dir) unless Dir.exist?(dir)
  end
end
