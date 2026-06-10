FROM python:3.12-slim

ENV PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1

WORKDIR /app

# Dependencies first (change rarely), code/common AFTER — so editing app code
# or libs/common never busts the cached pip-install layer.
COPY apps/it_agent/requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY libs/common ./common
COPY apps/it_agent/ ./it_agent

USER 10014

EXPOSE 8002

CMD ["amp-instrument", "python", "-m", "it_agent.main"]
