FROM python:3.12-slim

ENV PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1

WORKDIR /app

# Dependencies first (change rarely), code/common AFTER — so editing app code
# or libs/common never busts the cached pip-install layer.
COPY apps/orchestrator/requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY libs/common ./common
COPY apps/orchestrator/ ./orchestrator
# Bundle the SPA so the orchestrator serves it same-origin.
COPY apps/client/index.html apps/client/app.js apps/client/styles.css ./client_static/
RUN mkdir -p ./agent_cards

USER 10014

EXPOSE 8080

CMD ["amp-instrument", "python", "-m", "orchestrator.main"]
