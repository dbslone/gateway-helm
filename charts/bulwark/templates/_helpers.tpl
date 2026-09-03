{{/*
Expand the name of the chart.
*/}}
{{- define "bulwark.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create a default fully qualified app name.
*/}}
{{- define "bulwark.fullname" -}}
{{- if .Values.fullnameOverride }}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- $name := default .Chart.Name .Values.nameOverride }}
{{- if contains $name .Release.Name }}
{{- .Release.Name | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}
{{- end }}

{{- define "bulwark.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "bulwark.labels" -}}
helm.sh/chart: {{ include "bulwark.chart" . }}
{{ include "bulwark.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{- define "bulwark.selectorLabels" -}}
app.kubernetes.io/name: {{ include "bulwark.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{- define "bulwark.sessionSecretName" -}}
{{- if .Values.session.existingSecret }}
{{- .Values.session.existingSecret }}
{{- else }}
{{- printf "%s-session" (include "bulwark.fullname" .) }}
{{- end }}
{{- end }}

{{- define "bulwark.httpHost" -}}
{{- printf "%s.%s.svc.cluster.local" (include "bulwark.fullname" .) .Release.Namespace }}
{{- end }}
