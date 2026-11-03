FROM alpine:3.22
RUN apk add --no-cache ca-certificates jq
# run.py prepares a context containing this file, worker.sh and a static ./app.
COPY app /app
COPY worker.sh /worker.sh
RUN chmod 0755 /app /worker.sh
EXPOSE 8080
ENTRYPOINT ["/app"]
