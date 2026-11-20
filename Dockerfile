FROM python:3.12-slim

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1

WORKDIR /app
COPY requirements.txt ./
RUN python -m pip install --no-cache-dir -r requirements.txt
COPY --chmod=0644 bridge.py ./

USER 10001:10001
EXPOSE 8765
ENTRYPOINT ["python", "/app/bridge.py"]
CMD ["--bind", "0.0.0.0", "--config", "/state/bridge.json", "--cookie-file", "/run/secrets/storygraph_cookie"]
