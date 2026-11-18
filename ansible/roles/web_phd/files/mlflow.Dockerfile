FROM python:3.12-slim
# Patched from web-phd's infrastructure/mlflow.Dockerfile:
# pin sqlalchemy<2.1 because mlflow 3.4.0 imports `FallbackAsyncAdaptedQueuePool`,
# which was removed in SQLAlchemy 2.1.
RUN pip install --no-cache-dir "mlflow==3.4.0" "psycopg2-binary==2.9.10" "sqlalchemy>=2.0.38,<2.1"
RUN mkdir -p /artifacts
EXPOSE 5000
