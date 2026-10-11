import os
import sqlite3
import uuid
from datetime import datetime
from urllib.parse import quote

class ConfigStore:
    DB_PATH = os.environ.get(
        'SQLITE_DB_PATH',
        os.path.join(os.path.dirname(os.path.abspath(__file__)), 'data', 'redis_manager.sqlite3')
    )

    @classmethod
    def get_connection(cls):
        cls.ensure_storage_exists()
        conn = sqlite3.connect(cls.DB_PATH)
        conn.row_factory = sqlite3.Row
        cls.init_schema(conn)
        return conn

    @classmethod
    def ensure_storage_exists(cls):
        directory = os.path.dirname(cls.DB_PATH)
        if directory and not os.path.exists(directory):
            os.makedirs(directory, exist_ok=True)

    @classmethod
    def init_schema(cls, conn):
        with conn:
            conn.execute("""
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
            """)

            cursor = conn.execute("SELECT COUNT(*) FROM redis_servers")
            count = cursor.fetchone()[0]
            if count == 0:
                cls.seed_default(conn)

    @classmethod
    def seed_default(cls, conn):
        # Exemplo fornecido pelo DETRAN
        server_id = uuid.uuid4().hex[:8]
        now = datetime.now().strftime('%Y-%m-%d %H:%M:%S')
        conn.execute(
            """
            INSERT INTO redis_servers (id, name, host, port, password, db, ssl, created_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            """,
            (
                server_id,
                'Redis HML (DETRAN-BA)',
                'redis-hml.apps.ocp-prod.detran.ba.gov.br',
                32380,
                '6LZ1BydZ3cok8QRm53Tk',
                0,
                0,
                now
            )
        )

    @classmethod
    def load_servers(cls):
        with cls.get_connection() as conn:
            cursor = conn.execute("SELECT * FROM redis_servers ORDER BY created_at ASC")
            rows = cursor.fetchall()
            return [cls.normalize_row(r) for r in rows]

    @classmethod
    def find(cls, server_id):
        if not server_id:
            return None
        with cls.get_connection() as conn:
            cursor = conn.execute("SELECT * FROM redis_servers WHERE id = ?", (server_id,))
            row = cursor.fetchone()
            return cls.normalize_row(row) if row else None

    @classmethod
    def add_server(cls, params):
        server_id = uuid.uuid4().hex[:8]
        name = (params.get('name') or '').strip() or f"Redis-{server_id}"
        host = (params.get('host') or '').strip()
        port_raw = params.get('port')
        port = int(port_raw) if port_raw and str(port_raw).strip() else 6379
        password = str(params.get('password') or '')
        db_raw = params.get('db')
        db_idx = int(db_raw) if db_raw and str(db_raw).strip() else 0
        ssl = 1 if str(params.get('ssl')).lower() in ('true', '1') else 0
        now = datetime.now().strftime('%Y-%m-%d %H:%M:%S')

        with cls.get_connection() as conn:
            conn.execute(
                """
                INSERT INTO redis_servers (id, name, host, port, password, db, ssl, created_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                """,
                (server_id, name, host, port, password, db_idx, ssl, now)
            )

        return cls.find(server_id)

    @classmethod
    def update_server(cls, server_id, params):
        name = (params.get('name') or '').strip()
        host = (params.get('host') or '').strip()
        port_raw = params.get('port')
        port = int(port_raw) if port_raw and str(port_raw).strip() else 6379
        password = str(params.get('password') or '')
        db_raw = params.get('db')
        db_idx = int(db_raw) if db_raw and str(db_raw).strip() else 0
        ssl = 1 if str(params.get('ssl')).lower() in ('true', '1') else 0
        now = datetime.now().strftime('%Y-%m-%d %H:%M:%S')

        with cls.get_connection() as conn:
            conn.execute(
                """
                UPDATE redis_servers
                SET name = ?, host = ?, port = ?, password = ?, db = ?, ssl = ?, updated_at = ?
                WHERE id = ?
                """,
                (name, host, port, password, db_idx, ssl, now, server_id)
            )

        return cls.find(server_id)

    @classmethod
    def delete_server(cls, server_id):
        with cls.get_connection() as conn:
            conn.execute("DELETE FROM redis_servers WHERE id = ?", (server_id,))

    @classmethod
    def build_redis_url(cls, server, db_override=None):
        if not server:
            return 'redis://127.0.0.1:6379/0'

        scheme = 'rediss' if server.get('ssl') else 'redis'
        host = server.get('host') or '127.0.0.1'
        port = server.get('port') or 6379
        db_idx = db_override if db_override is not None else (server.get('db') or 0)
        password = str(server.get('password') or '')

        if not password:
            return f"{scheme}://{host}:{port}/{db_idx}"
        else:
            encoded_pass = quote(password, safe='')
            return f"{scheme}://:{encoded_pass}@{host}:{port}/{db_idx}"

    @classmethod
    def normalize_row(cls, row):
        return {
            'id': row['id'],
            'name': row['name'],
            'host': row['host'],
            'port': int(row['port']),
            'password': str(row['password'] or ''),
            'db': int(row['db'] or 0),
            'ssl': bool(int(row['ssl'] or 0)),
            'created_at': row['created_at'],
            'updated_at': row['updated_at']
        }
