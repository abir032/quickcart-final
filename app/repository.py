"""Where orders come from. The rest of the app talks to this, never to MySQL directly."""
import os

import pymysql

SEED = [("keyboard", 2), ("monitor", 1), ("mouse", 5)]


class InMemoryOrders:
    """Used in tests, and on a laptop with no database."""

    def __init__(self):
        self._rows = [{"id": i + 1, "item": item, "qty": qty} for i, (item, qty) in enumerate(SEED)]

    def list_orders(self):
        return list(self._rows)

    def ping(self):
        return True


class MySQLOrders:
    """Used in AWS. ECS fills the connection details from Secrets Manager."""

    def __init__(self, host, user, password, database):
        self._params = dict(host=host, user=user, password=password, database=database,
                            connect_timeout=3, read_timeout=5,
                            cursorclass=pymysql.cursors.DictCursor)
        self._schema_ready = False

    def _connect(self):
        return pymysql.connect(**self._params)

    def _ensure_schema(self, conn):
        """Create the table and seed it once. Safe when several tasks start together:
        the named lock lets only one of them do it at a time."""
        if self._schema_ready:
            return
        with conn.cursor() as cur:
            cur.execute("SELECT GET_LOCK('quickcart_schema', 10) AS got")
            try:
                cur.execute("CREATE TABLE IF NOT EXISTS orders ("
                            "id INT AUTO_INCREMENT PRIMARY KEY, "
                            "item VARCHAR(50) NOT NULL, qty INT NOT NULL)")
                cur.execute("SELECT COUNT(*) AS n FROM orders")
                if cur.fetchone()["n"] == 0:
                    cur.executemany("INSERT INTO orders (item, qty) VALUES (%s, %s)", SEED)
                conn.commit()
            finally:
                cur.execute("SELECT RELEASE_LOCK('quickcart_schema')")
        self._schema_ready = True

    def list_orders(self):
        conn = self._connect()
        try:
            self._ensure_schema(conn)
            with conn.cursor() as cur:
                cur.execute("SELECT id, item, qty FROM orders ORDER BY id")
                return cur.fetchall()
        finally:
            conn.close()

    def ping(self):
        try:
            self._connect().close()
            return True
        except pymysql.MySQLError:
            return False


def build_repository(env=None):
    """Pick the storage from the environment: MySQL in AWS, memory everywhere else."""
    env = os.environ if env is None else env
    if env.get("DB_HOST"):
        return MySQLOrders(env["DB_HOST"], env["DB_USER"], env["DB_PASSWORD"],
                           env.get("DB_NAME", "quickcart"))
    return InMemoryOrders()
