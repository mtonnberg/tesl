{{- define "demo.env" -}}
DEMO_DB: {{ .root.Values.database.name | quote }}
DEMO_HOST: {{ .root.Values.database.host | quote }}
DEMO_PORT: "5432"
DEMO_USER: demo_request
DEMO_PASSWORD: {{ .root.Values.database.requestPassword | quote }}
DEMO_OWNER: demo_owner
DEMO_WORKER: demo_worker
DEMO_REQUEST: demo_request
DEMO_HTTP_PORT: "8080"
DEMO_REVISION: {{ .root.Values.revision | quote }}
GOMEMLIMIT: "256MiB"
GOMAXPROCS: "2"
{{- if or (eq .role "installer") (eq .role "worker") }}
TESL_PG_POOL_LEASE_TIMEOUT_MS: "60000"
{{- end }}
TESL_QUEUE_VISIBILITY_TIMEOUT_MS: {{ .root.Values.queueVisibilityTimeoutMs | quote }}
{{- $user := "demo_request" -}}
{{- $password := .root.Values.database.requestPassword -}}
{{- if eq .role "worker" -}}
{{- $user = "demo_worker" -}}
{{- $password = .root.Values.database.workerPassword -}}
{{- else if eq .role "installer" -}}
{{- $user = "postgres" -}}
{{- $password = .root.Values.database.installerPassword -}}
{{- end }}
DEMO_DDL: {{ printf "postgres://%s:%s@%s:5432/%s?sslmode=disable" $user ($password | urlquery) .root.Values.database.host .root.Values.database.name | quote }}
{{- if eq .root.Values.mode "migrator" }}
TESL_SCHEMA_INSTALLER_DSN: {{ printf "postgres://postgres:%s@%s:5432/%s?sslmode=disable" (.root.Values.database.installerPassword | urlquery) .root.Values.database.host .root.Values.database.name | quote }}
{{- end }}
{{- end -}}
