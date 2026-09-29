# Один образ с бинарниками api, worker, migrate и demo (демо-данные).
# Какой из них запускать, задаёт command в docker-compose.

FROM golang:1.24-alpine AS build
WORKDIR /src
COPY go.mod go.sum ./
RUN go mod download
COPY . .
RUN CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -o /out/api ./cmd/api \
 && CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -o /out/worker ./cmd/worker \
 && CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -o /out/migrate ./cmd/migrate \
 && CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -o /out/demo ./cmd/demo

FROM alpine:3.20
RUN apk add --no-cache ca-certificates tzdata && adduser -D -u 10001 app
ENV TZ=Asia/Tashkent
COPY --from=build /out/ /usr/local/bin/
USER app
EXPOSE 8080
CMD ["api"]
