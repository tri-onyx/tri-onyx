FROM python:3.12-slim

COPY --from=ghcr.io/astral-sh/uv:latest /uv /uvx /bin/

WORKDIR /app

COPY frontend/pyproject.toml ./
RUN --mount=type=cache,target=/root/.cache/uv \
    uv sync --no-install-project

COPY frontend/ ./

RUN DJANGO_SECRET_KEY=build-placeholder uv run python manage.py collectstatic --noinput

EXPOSE 8080

CMD ["uv", "run", "gunicorn", "trionyx_ui.wsgi:application", \
     "--bind", "0.0.0.0:8080", "--workers", "2", "--threads", "4", \
     "--timeout", "120"]
