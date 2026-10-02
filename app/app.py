import json
import os
import random
import socket

from flask import Flask, jsonify

from repository import build_repository

app = Flask(__name__)
VERSION = os.environ.get("APP_VERSION", "v1")

# Share of /orders requests that fail. Always 0 in a healthy release.
# The "bad release" exercise changes this default to prove the canary catches it.
FAIL_RATE = float(os.environ.get("FAIL_RATE", "0"))

repo = build_repository()


@app.get("/health")
def health():
    """For the load balancer. Never touches the database: a slow database must not
    make every task look dead and get replaced."""
    return jsonify(status="ok", version=VERSION)


@app.get("/ready")
def ready():
    """For people and smoke tests: can this task actually reach its database?"""
    ok = repo.ping()
    return jsonify(database="ok" if ok else "unreachable", version=VERSION), (200 if ok else 503)


@app.get("/")
def home():
    return jsonify(service="order-service", version=VERSION, served_by=socket.gethostname())


@app.get("/orders")
def orders():
    if random.random() < FAIL_RATE:
        print(json.dumps({"level": "ERROR", "event": "orders_failed", "version": VERSION}),
              flush=True)
        return jsonify(error="internal_error", version=VERSION), 500
    rows = repo.list_orders()
    return jsonify(version=VERSION, count=len(rows), orders=rows)


@app.get("/orders/<order_id>")
def get_order(order_id):
    order = repo.get_order(order_id)
    if order is None:
        return jsonify(error="not_found", version=VERSION), 404
    return jsonify(version=VERSION, order=order)
