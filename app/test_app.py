import app as order_service
from repository import InMemoryOrders, MySQLOrders, build_repository


def client():
    order_service.app.config["TESTING"] = True
    return order_service.app.test_client()


def test_health_is_ok_without_a_database():
    r = client().get("/health")
    assert r.status_code == 200
    assert r.get_json()["status"] == "ok"


def test_orders_returns_three():
    order_service.FAIL_RATE = 0
    r = client().get("/orders")
    assert r.status_code == 200
    assert r.get_json()["count"] == 3


def test_every_response_reports_its_version():
    for path in ("/health", "/ready", "/", "/orders"):
        assert "version" in client().get(path).get_json()


def test_ready_reports_the_database():
    r = client().get("/ready")
    assert r.status_code == 200
    assert r.get_json()["database"] == "ok"


def test_memory_is_used_when_there_is_no_database():
    assert isinstance(build_repository({}), InMemoryOrders)


def test_mysql_is_used_when_a_database_is_configured():
    repo = build_repository({"DB_HOST": "db.internal", "DB_USER": "u", "DB_PASSWORD": "p"})
    assert isinstance(repo, MySQLOrders)
