{{- define "knp.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "knp.fullname" -}}
{{- if .Values.fullnameOverride }}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- include "knp.name" . }}
{{- end }}
{{- end }}

{{- define "knp.serviceAccountName" -}}
{{- default (include "knp.fullname" .) .Values.serviceAccount.name }}
{{- end }}

{{- define "knp.selectorLabels" -}}
app.kubernetes.io/name: {{ include "knp.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{- define "knp.labels" -}}
{{ include "knp.selectorLabels" . }}
app.kubernetes.io/version: {{ .Values.image.tag | default .Chart.AppVersion | trunc 63 | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" }}
{{- end }}

{{- define "knp.image" -}}
{{- $tag := .Values.image.tag | default .Chart.AppVersion -}}
{{- if and .Values.clusterNetworkPolicy.enabled (not (hasSuffix "-npa-v1alpha2" $tag)) -}}
{{- $tag = printf "%s-npa-v1alpha2" $tag -}}
{{- end -}}
{{- if .Values.image.registry -}}
{{ trimSuffix "/" .Values.image.registry }}/{{ .Values.image.repository }}:{{ $tag }}
{{- else -}}
{{ .Values.image.repository }}:{{ $tag }}
{{- end -}}
{{- end }}
