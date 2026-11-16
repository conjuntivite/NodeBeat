# Não há imagem pronta com o Flutter 3.50.0: clona o SDK oficial na tag fixa (mesma versão do desenvolvimento).
FROM debian:bookworm-slim AS build
ARG FLUTTER_VERSION=3.50.0
RUN apt-get update && apt-get install -y --no-install-recommends git curl unzip xz-utils ca-certificates \
    && rm -rf /var/lib/apt/lists/*
RUN git clone --depth 1 --branch ${FLUTTER_VERSION} https://github.com/flutter/flutter.git /flutter
ENV PATH="/flutter/bin:${PATH}"
RUN flutter config --no-analytics --enable-web && flutter precache --web
WORKDIR /app
COPY pubspec.yaml pubspec.lock ./
RUN flutter pub get
COPY . .
# --no-web-resources-cdn: CanvasKit e fontes saem do nosso nginx, nada de gstatic/Google
RUN flutter build web --release --no-web-resources-cdn

FROM nginx:1.27-alpine
COPY --from=build /app/build/web /usr/share/nginx/html
