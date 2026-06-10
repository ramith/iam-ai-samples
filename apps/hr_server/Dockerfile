FROM python:3.12-slim

ENV PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1

WORKDIR /app

# Dependencies first (change rarely), code/common AFTER — so editing app code
# or libs/common never busts the cached pip-install layer.
COPY apps/hr_server/requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY libs/common ./common
COPY apps/hr_server/ ./hr_server

USER 10014

EXPOSE 8000

CMD ["python", "-m", "hr_server.main"]
