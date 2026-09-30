# Сборка двух панелей и nginx, который их раздаёт и проксирует API.
FROM node:22-alpine AS build
WORKDIR /web
COPY package.json package-lock.json ./
COPY shared/package.json shared/
COPY admin/package.json admin/
COPY store/package.json store/
RUN npm ci --no-audit --no-fund
COPY . .
# Ключ Яндекс Карт (JavaScript API) — вшивается в панели при сборке.
ARG VITE_YANDEX_MAPS_KEY=""
ENV VITE_YANDEX_MAPS_KEY=$VITE_YANDEX_MAPS_KEY
RUN npm run build

FROM nginx:1.27-alpine
COPY --from=build /web/store/dist /usr/share/nginx/html
COPY --from=build /web/admin/dist /usr/share/nginx/html/admin
