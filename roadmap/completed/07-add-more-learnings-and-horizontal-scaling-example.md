We should showcase the horizontal scaling, a good candidate is the chat app. Please add 3 backend instances with a lightweight loadbalancer in front of them that will share the load.

Also add missing learn-files for list decomposition, lambdas and more.

## Status: complete

- `example/chat/backend.tesl`: port now read from `CHAT_PORT` env var (default 8080) via `envInt`
- `example/chat/run-backend.sh`: exports `CHAT_PORT`, docs updated
- `example/chat/run-cluster.sh`: starts 3 backends (ports 3000/3002/3004) + nginx load balancer
- `example/chat/nginx-cluster.conf.template`: round-robin upstream for REST, ip_hash for WebSocket
- `example/chat/README.md`: cluster section expanded with one-command and manual instructions
- `example/learn/lesson35-list-decomposition.tesl`: List head/tail decomposition, fold, map/filter
- `example/learn/lesson36-lambdas.tesl`: lambda syntax, closures, HOF, pipeline, validation