# Python-Services Image
# Wird fuer api_poller, elevision_extended_poller, dwd_poller,
# forecast_service und anomaly_alerter verwendet.
# Jeder Container-App setzt sein eigenes CMD.

FROM python:3.12-slim

WORKDIR /app

# System-Abhaengigkeiten (psycopg2 benoetigt libpq)
RUN apt-get update && apt-get install -y --no-install-recommends \
    libpq-dev \
    gcc \
    && rm -rf /var/lib/apt/lists/*

# Python-Abhaengigkeiten zuerst (besseres Layer-Caching)
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# Anwendungscode
COPY services/*.py ./
COPY config/ ./config/

# Kein Standard-CMD: wird pro Container-App ueberschrieben
CMD ["python", "api_poller.py"]
