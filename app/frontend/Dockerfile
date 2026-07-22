FROM alpine:3.20 AS builder
WORKDIR /usr/share/nginx/html
COPY index.html ./

FROM nginxinc/nginx-unprivileged:alpine-slim AS runner
# Explicitly declare non-root user identity (UID 101 = nginx)
USER 101
COPY --from=builder /usr/share/nginx/html /usr/share/nginx/html

EXPOSE 8080

CMD ["nginx", "-g", "daemon off;"]