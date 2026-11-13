# Tag da imagem da Cirrus Labs = versão do Flutter (3.50.0). Confira que existe antes do primeiro build.
FROM ghcr.io/cirruslabs/flutter:3.50.0 AS build
WORKDIR /app
COPY pubspec.yaml pubspec.lock ./
RUN flutter pub get
COPY . .
# --no-web-resources-cdn: CanvasKit e fontes saem do nosso nginx, nada de gstatic/Google
RUN flutter build web --release --no-web-resources-cdn

FROM nginx:1.27-alpine
COPY --from=build /app/build/web /usr/share/nginx/html
