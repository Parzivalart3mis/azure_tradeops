"""ASGI entrypoint: `uvicorn tradeops.main:app`."""

from tradeops.api import create_app

app = create_app()
