{{/*
Common labels applied to the resources this chart owns directly (Mimir).
The subcharts label their own objects.
*/}}
{{- define "lgtm-stack.labels" -}}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/part-of: lgtm-stack
{{- end }}
