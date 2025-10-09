{{/*
Expand the name of the chart.
*/}}
{{- define "gateway-helm.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "simplefbo-backend.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "gateway-helm.fullname" -}}
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

{{- define "gateway-helm.labels" -}}
helm.sh/chart: {{ include "gateway-helm.chart" . }}
{{ include "gateway-helm.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{- define "gateway-helm.selectorLabels" -}}
app.kubernetes.io/name: {{ include "gateway-helm.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{- define "gateway-helm.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create the name of the service account to use
*/}}
{{- define "gateway-helm.serviceAccountName" -}}
{{- if .Values.serviceAccount.create }}
{{- default (include "gateway-helm.fullname" .) .Values.serviceAccount.name }}
{{- else }}
{{- default "default" .Values.serviceAccount.name }}
{{- end }}
{{- end }}

{{- define "simplefbo-api-gateway.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "simplefbo-api-gateway.fullname" -}}
{{- printf "%s-%s" .Release.Name "simplefbo-api-gateway" | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "simplefbo-api-gateway.labels" -}}
app.kubernetes.io/name: {{ include "simplefbo-api-gateway.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
Create a default fully qualified app name.
We truncate at 63 chars because some Kubernetes name fields are limited to this (by the DNS naming spec).
If release name contains chart name it will be used as a full name.
*/}}
{{- define "simplefbo-backend.fullname" -}}
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

{{/*
Create chart name and version as used by the chart label.
*/}}
{{- define "simplefbo-backend.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels
*/}}
{{- define "simplefbo-backend.labels" -}}
helm.sh/chart: {{ include "simplefbo-backend.chart" . }}
{{ include "simplefbo-backend.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/*
Selector labels
*/}}
{{- define "simplefbo-backend.selectorLabels" -}}
app.kubernetes.io/name: {{ include "simplefbo-backend.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
Create the name of the service account to use
*/}}
{{- define "simplefbo-backend.serviceAccountName" -}}
{{- if .Values.serviceAccount.create }}
{{- default (include "simplefbo-backend.fullname" .) .Values.serviceAccount.name }}
{{- else }}
{{- default "default" .Values.serviceAccount.name }}
{{- end }}
{{- end }}

{{/*
Vault agent inject template
*/}}
{{- define "vault.agentInjectTemplate" -}}
{{- $ctx := . -}}
{{- $secretName := .name -}}
vault.hashicorp.com/agent-inject-secret-{{ $secretName }}: simplefbo/data/backend/{{ .Values.env }}/{{ $secretName }}
vault.hashicorp.com/agent-inject-template-{{ $secretName }}: |
  {{ "{{" }} with secret "simplefbo/data/backend/{{ .Values.env }}/{{ $secretName }}" {{ "}}" }}
  {{  "{{" }}- range $k, $v := .Data.data {{ "}}" }}
  export {{ "{{" }} $k -{{ "}}" }}="{{ "{{" }} $v -}}"
  {{ "{{" }}- end {{ "}}" }}
  {{ "{{" }} end {{ "}}" }}
{{- end -}}

{{/*
Vault agent inject annotations
*/}}
{{- define "vault.agentInjectAnnotations" -}}
{{- include "vault.agentInjectTemplate" (dict "name" "app" "Values" .Values) | nindent 0 }}
{{- include "vault.agentInjectTemplate" (dict "name" "aws-credentials" "Values" .Values) | nindent 0 }}
{{- include "vault.agentInjectTemplate" (dict "name" "oauth2-proxy" "Values" .Values) | nindent 0 }}
vault.hashicorp.com/agent-inject-template-dge-sftp-credentials: |
  {{ "{{" }} with secret "simplefbo/data/backend/{{ .Values.env }}/dge-sftp-credentials" {{ "}}" }}
  {{ "{{" }}- range $k, $v := .Data.data {{ "}}" }}
  {{ "{{" }}- if eq $k "DGE_SFTP_PRIVATE_KEY" {{ "}}" }}
  export {{ "{{" }} $k -{{ "}}" }}=$(cat << EOF
  {{ "{{" }} $v -{{ "}}" }}
  EOF
  );
  {{ "{{" }}- else {{ "}}" }}
  export {{ "{{" }} $k -{{ "}}" }}="{{ "{{" }} $v -}}"
  {{ "{{" }}- end {{ "}}" }}
  {{ "{{" }}- end {{ "}}" }}
  {{ "{{" }} end {{ "}}" }}
vault.hashicorp.com/agent-inject-secret-gcp-service-account: simplefbo/data/backend/{{ .Values.env }}/gcp-service-account
vault.hashicorp.com/agent-inject-template-gcp-service-account: |
  {{ "{{" }} with secret "simplefbo/data/backend/{{ .Values.env }}/gcp-service-account" {{ "}}" }}
  {{ "{{" }}- range $k, $v := .Data.data {{ "}}" }}
  {{ "{{" }} $v -{{ "}}" }}
  {{ "{{" }}- end {{ "}}" }}
  {{ "{{" }} end {{ "}}" }}
vault.hashicorp.com/agent-inject-secret-gcp-service-accounts: simplefbo/data/backend/{{ .Values.env }}/gcp-service-accounts
vault.hashicorp.com/agent-inject-template-gcp-service-accounts: |
  {{ "{{" }} with secret "simplefbo/data/backend/{{ .Values.env }}/gcp-service-accounts" {{ "}}" }}
  {{ "{{" }}- range $k, $v := .Data.data {{ "}}" }}
  {{ "{{" }} $v -{{ "}}" }}
  {{ "{{" }}- end {{ "}}" }}
  {{ "{{" }} end {{ "}}" }}
{{- end -}}

{{/*
Vault annotations
*/}}
{{- define "vault.annotations" -}}
vault.hashicorp.com/role: backend
vault.hashicorp.com/agent-pre-populate-only: "true"
vault.hashicorp.com/agent-init-first: "true"
vault.hashicorp.com/agent-inject: "true"
{{- include "vault.agentInjectAnnotations" . }}
vault.hashicorp.com/agent-inject-file-gcp-service-account: key.json
vault.hashicorp.com/secret-volume-path-gcp-service-account: /var/secrets/gcp-service-account
vault.hashicorp.com/agent-inject-file-gcp-service-accounts: keys.json
vault.hashicorp.com/secret-volume-path-gcp-service-accounts: /var/secrets/gcp-service-accounts
{{- end -}}