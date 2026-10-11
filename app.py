import os
import shlex
from datetime import datetime, timezone
import redis
from flask import Flask, render_template, request, jsonify, redirect, session, url_for, flash
from config_store import ConfigStore

app = Flask(
    __name__,
    template_folder=os.path.join(os.path.dirname(os.path.abspath(__file__)), 'templates'),
    static_folder=os.path.join(os.path.dirname(os.path.abspath(__file__)), 'public'),
    static_url_path='/public'
)

app.secret_key = os.environ.get(
    'SECRET_KEY',
    'redis_manager_secret_key_super_safe_64_bytes_long_1234567890abcdef1234567890abcdef'
)


# --- Helpers ---

def get_all_servers():
    return ConfigStore.load_servers()


def get_current_server_config():
    server_id = request.args.get('server_id') or session.get('current_server_id')
    servers = get_all_servers()
    found = None
    if server_id:
        found = ConfigStore.find(server_id)
    if not found and servers:
        found = servers[0]
    if found:
        session['current_server_id'] = found['id']
    return found


def get_current_db_index():
    db_arg = request.args.get('db')
    if db_arg is not None and str(db_arg).strip() != '':
        try:
            db_num = int(db_arg)
            session['current_db'] = db_num
            return db_num
        except ValueError:
            pass
    if 'current_db' in session:
        return session['current_db']
    srv = get_current_server_config()
    return srv.get('db', 0) if srv else 0


def get_redis_client(srv=None, db=None):
    target = srv or get_current_server_config()
    if not target:
        raise RuntimeError("Nenhum servidor Redis cadastrado.")
    target_db = db if db is not None else get_current_db_index()
    url = ConfigStore.build_redis_url(target, target_db)
    return redis.from_url(
        url,
        socket_timeout=4.0,
        decode_responses=True,
        encoding_errors='replace'
    )


def test_connection(srv):
    try:
        client = get_redis_client(srv, srv.get('db', 0))
        pong = client.ping()
        return {'success': bool(pong), 'message': 'Conexão efetuada com sucesso (PONG)'}
    except Exception as e:
        return {'success': False, 'message': str(e)}


def format_bytes(bytes_val):
    try:
        b = float(bytes_val)
    except (TypeError, ValueError):
        return "0 B"
    if b >= 1024 * 1024 * 1024:
        return f"{b / (1024 * 1024 * 1024):.2f} GB"
    elif b >= 1024 * 1024:
        return f"{b / (1024 * 1024):.2f} MB"
    elif b >= 1024:
        return f"{b / 1024:.2f} KB"
    else:
        return f"{int(b)} B"


def format_redis_output(res):
    if isinstance(res, (list, tuple)):
        return "\n".join(f"{idx + 1}) {repr(item)}" for idx, item in enumerate(res))
    elif isinstance(res, dict):
        return "\n".join(f"{k}: {v}" for k, v in res.items())
    elif res is None:
        return "(nil)"
    else:
        return str(res)


app.jinja_env.filters['format_bytes'] = format_bytes


# --- OpenShift Health Probes ---

@app.route('/healthz', methods=['GET'])
def healthz():
    return jsonify({
        'status': 'ok',
        'timestamp': datetime.now(timezone.utc).iso8601() if hasattr(datetime.now(timezone.utc), 'iso8601') else datetime.now(timezone.utc).isoformat()
    })


@app.route('/ready', methods=['GET'])
def ready():
    try:
        # Verifica se a aplicação e a persistência SQLite estão operacionais
        ConfigStore.load_servers()
        return jsonify({'status': 'ready'})
    except Exception as e:
        return jsonify({'status': 'error', 'message': str(e)}), 503


# --- Main Manager Explorer ---

@app.route('/', methods=['GET'])
def manager():
    servers = get_all_servers()
    current_server = get_current_server_config()
    active_db = get_current_db_index()
    databases = []
    server_info = None
    db_size = 0
    error = None

    if current_server:
        try:
            client = get_redis_client(current_server, active_db)
            server_info = client.info()
            db_size = client.dbsize()

            for i in range(16):
                db_stat = server_info.get(f'db{i}')
                keys_count = 0
                expires_count = 0
                if isinstance(db_stat, dict):
                    keys_count = int(db_stat.get('keys', 0))
                    expires_count = int(db_stat.get('expires', 0))
                elif isinstance(db_stat, str):
                    import re
                    m_k = re.search(r'keys=(\d+)', db_stat)
                    m_e = re.search(r'expires=(\d+)', db_stat)
                    if m_k:
                        keys_count = int(m_k.group(1))
                    if m_e:
                        expires_count = int(m_e.group(1))
                databases.append({
                    'index': i,
                    'keys_count': keys_count,
                    'expires_count': expires_count,
                    'active': (i == active_db)
                })
        except Exception as e:
            error = f"Falha ao conectar no Redis ({current_server['host']}:{current_server['port']}): {e}"

    return render_template(
        'manager.html',
        servers=servers,
        current_server=current_server,
        active_db=active_db,
        databases=databases,
        server_info=server_info,
        db_size=db_size,
        error=error
    )


@app.route('/switch', methods=['GET'])
def switch():
    server_id = request.args.get('server_id')
    db_arg = request.args.get('db')
    return_to = request.args.get('return_to', '/')

    if server_id:
        session['current_server_id'] = server_id
    if db_arg is not None and str(db_arg).strip() != '':
        try:
            session['current_db'] = int(db_arg)
        except ValueError:
            pass

    return redirect(return_to)


# --- AJAX API for ARDM Explorer ---

@app.route('/api/keys', methods=['GET'])
def api_keys():
    pattern = (request.args.get('pattern') or '').strip() or '*'
    cursor = request.args.get('cursor', '0')
    limit = 250

    try:
        client = get_redis_client()
        next_cursor, raw_keys = client.scan(cursor=int(cursor), match=pattern, count=limit)

        keys_data = []
        if raw_keys:
            pipe = client.pipeline()
            for k in raw_keys:
                pipe.type(k)
                pipe.ttl(k)
            pipe_results = pipe.execute()

            for idx, k in enumerate(raw_keys):
                t = pipe_results[idx * 2]
                ttl = pipe_results[idx * 2 + 1]
                keys_data.append({
                    'name': k,
                    'type': t,
                    'ttl': ttl
                })

        keys_data.sort(key=lambda x: x['name'])

        return jsonify({
            'cursor': str(next_cursor),
            'total_found': len(keys_data),
            'keys': keys_data
        })
    except Exception as e:
        return jsonify({'error': str(e)}), 500


@app.route('/api/key', methods=['GET'])
def api_key_detail():
    key = request.args.get('name')
    if not key:
        return jsonify({'error': 'Chave não informada'}), 400

    try:
        client = get_redis_client()
        type_name = client.type(key)

        if type_name == 'none':
            return jsonify({'error': 'Chave não existe ou expirou.'})

        ttl = client.ttl(key)
        try:
            pttl = client.pttl(key)
        except Exception:
            pttl = -1

        memory_usage = None
        try:
            memory_usage = client.execute_command('MEMORY', 'USAGE', key)
        except Exception:
            pass

        value = None
        length = 0

        if type_name == 'string':
            value = client.get(key)
            length = len(value.encode('utf-8')) if value else 0
        elif type_name == 'list':
            length = client.llen(key)
            value = client.lrange(key, 0, 99)
        elif type_name == 'set':
            length = client.scard(key)
            value = list(client.smembers(key))[:100]
        elif type_name == 'zset':
            length = client.zcard(key)
            raw_zset = client.zrange(key, 0, 99, withscores=True)
            # zrange withscores returns list of tuples: [(elem, score), ...]
            value = [[elem, score] for elem, score in raw_zset]
        elif type_name == 'hash':
            length = client.hlen(key)
            value = client.hgetall(key)

        return jsonify({
            'name': key,
            'type': type_name,
            'ttl': ttl,
            'pttl': pttl,
            'memory_usage': memory_usage,
            'length': length,
            'value': value
        })
    except Exception as e:
        return jsonify({'error': str(e)}), 500


@app.route('/api/key/save', methods=['POST'])
def api_key_save():
    payload = request.get_json(silent=True) or request.form.to_dict()
    key = (payload.get('name') or '').strip()
    type_name = payload.get('type') or 'string'
    val = payload.get('value')
    ttl_raw = payload.get('ttl')
    ttl = int(ttl_raw) if ttl_raw is not None and str(ttl_raw).strip() != '' else None

    if not key:
        return jsonify({'error': 'Nome da chave obrigatório'}), 400

    try:
        client = get_redis_client()

        if type_name == 'string':
            client.set(key, str(val or ''))
        elif type_name == 'hash':
            if isinstance(val, dict):
                client.delete(key)
                if val:
                    client.hset(key, mapping=val)
            elif payload.get('field'):
                client.hset(key, payload['field'], payload.get('field_value', ''))
        elif type_name == 'list':
            if payload.get('element'):
                client.rpush(key, payload['element'])
        elif type_name == 'set':
            if payload.get('element'):
                client.sadd(key, payload['element'])
        elif type_name == 'zset':
            if payload.get('element') and payload.get('score') is not None:
                client.zadd(key, {payload['element']: float(payload['score'])})

        if ttl is not None:
            if ttl > 0:
                client.expire(key, ttl)
            elif ttl == -1:
                client.persist(key)

        return jsonify({'success': True, 'message': 'Chave atualizada com sucesso!'})
    except Exception as e:
        return jsonify({'error': str(e)}), 500


@app.route('/api/key/ttl', methods=['POST'])
def api_key_ttl():
    payload = request.get_json(silent=True) or request.form.to_dict()
    key = payload.get('name')
    ttl = int(payload.get('ttl', 0))

    try:
        client = get_redis_client()
        if ttl > 0:
            client.expire(key, ttl)
        elif ttl == -1:
            client.persist(key)
        return jsonify({'success': True, 'ttl': client.ttl(key)})
    except Exception as e:
        return jsonify({'error': str(e)}), 500


@app.route('/api/key/delete', methods=['POST'])
def api_key_delete():
    payload = request.get_json(silent=True) or request.form.to_dict()
    key = payload.get('name')

    try:
        client = get_redis_client()
        deleted = client.delete(key)
        return jsonify({'success': True, 'count': deleted})
    except Exception as e:
        return jsonify({'error': str(e)}), 500


@app.route('/api/key/rename', methods=['POST'])
def api_key_rename():
    payload = request.get_json(silent=True) or request.form.to_dict()
    old_name = payload.get('old_name')
    new_name = (payload.get('new_name') or '').strip()

    if not new_name:
        return jsonify({'error': 'Novo nome inválido'}), 400

    try:
        client = get_redis_client()
        client.rename(old_name, new_name)
        return jsonify({'success': True, 'new_name': new_name})
    except Exception as e:
        return jsonify({'error': str(e)}), 500


# --- Host Configurations (Settings) ---

@app.route('/settings', methods=['GET'])
def settings():
    servers = get_all_servers()
    edit_id = request.args.get('edit_id')
    edit_server = ConfigStore.find(edit_id) if edit_id else None
    return render_template(
        'settings.html',
        servers=servers,
        edit_server=edit_server
    )


@app.route('/settings/create', methods=['POST'])
def settings_create():
    ConfigStore.add_server(request.form)
    flash({'type': 'success', 'text': 'Novo servidor Redis cadastrado com sucesso!'})
    return redirect(url_for('settings'))


@app.route('/settings/update', methods=['POST'])
def settings_update():
    server_id = request.form.get('id')
    ConfigStore.update_server(server_id, request.form)
    flash({'type': 'success', 'text': 'Configurações atualizadas!'})
    return redirect(url_for('settings'))


@app.route('/settings/delete', methods=['POST'])
def settings_delete():
    server_id = request.form.get('id')
    ConfigStore.delete_server(server_id)
    flash({'type': 'info', 'text': 'Servidor removido.'})
    if session.get('current_server_id') == server_id:
        session.pop('current_server_id', None)
    return redirect(url_for('settings'))


@app.route('/settings/test', methods=['POST'])
def settings_test():
    srv = {
        'host': request.form.get('host'),
        'port': request.form.get('port'),
        'password': request.form.get('password'),
        'db': request.form.get('db'),
        'ssl': request.form.get('ssl') == 'true'
    }
    result = test_connection(srv)
    return jsonify(result)


# --- Web CLI Terminal ---

@app.route('/cli', methods=['GET'])
def cli():
    servers = get_all_servers()
    current_server = get_current_server_config()
    active_db = get_current_db_index()
    return render_template(
        'cli.html',
        servers=servers,
        current_server=current_server,
        active_db=active_db
    )


@app.route('/cli/exec', methods=['POST'])
def cli_exec():
    command_str = (request.form.get('command') or '').strip()
    if not command_str:
        return jsonify({'error': 'Comando vazio.'}), 400

    try:
        parts = shlex.split(command_str)
    except Exception:
        parts = command_str.split()

    if not parts:
        return jsonify({'error': 'Comando vazio.'}), 400

    cmd = parts[0].lower()
    forbidden = {'flushall', 'flushdb', 'shutdown', 'config', 'slaveof', 'replicaof', 'bgsave', 'debug'}
    if cmd in forbidden:
        return jsonify({'error': f"Comando '{cmd.upper()}' bloqueado por política de segurança web."})

    try:
        client = get_redis_client()
        res = client.execute_command(*parts)
        return jsonify({'output': format_redis_output(res)})
    except Exception as e:
        return jsonify({'error': str(e)})


if __name__ == '__main__':
    port = int(os.environ.get('PORT', 8080))
    app.run(host='0.0.0.0', port=port, debug=False)
