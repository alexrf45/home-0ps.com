# Build the MkDocs site, then serve it from an unprivileged nginx.
# Build context is the repo root (so it can see _docs/, mkdocs.yml, requirements-docs.txt).

FROM python:3.13-slim AS build
WORKDIR /docs
COPY requirements-docs.txt ./
RUN pip install --no-cache-dir -r requirements-docs.txt
COPY mkdocs.yml main.py ./
COPY _docs/ ./_docs/
RUN mkdocs build --strict

# nginx-unprivileged listens on 8080 and runs as uid 101 (non-root) — satisfies
# the restricted Pod Security Standard without any extra securityContext fights.
FROM nginxinc/nginx-unprivileged:1.27-alpine
COPY --from=build /docs/site /usr/share/nginx/html
EXPOSE 8080
