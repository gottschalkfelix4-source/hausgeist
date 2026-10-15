FROM python:3.12-slim
LABEL org.opencontainers.image.title="Hausgeist" \
      org.opencontainers.image.description="Home-Assistant-Server für Wandtablets und Sprachassistent" \
      org.opencontainers.image.source="https://github.com/gottschalkfelix4-source/hausgeist" \
      org.opencontainers.image.licenses="MIT"
WORKDIR /srv
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY app ./app
ENV DB_PATH=/data/hausgeist.db PYTHONUNBUFFERED=1
VOLUME /data
EXPOSE 8080
HEALTHCHECK --interval=30s --timeout=5s --start-period=10s \
  CMD python -c "import urllib.request; urllib.request.urlopen('http://127.0.0.1:8080/health', timeout=4)"
CMD ["uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8080"]
