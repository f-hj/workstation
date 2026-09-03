{{/*
Expand the name of the chart.
*/}}
{{- define "opencode.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create a default fully qualified app name.
*/}}
{{- define "opencode.fullname" -}}
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

{{- define "opencode.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "opencode.labels" -}}
helm.sh/chart: {{ include "opencode.chart" . }}
{{ include "opencode.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{- define "opencode.selectorLabels" -}}
app.kubernetes.io/name: {{ include "opencode.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{- define "opencode.serviceAccountName" -}}
{{- if .Values.serviceAccount.create }}
{{- default (include "opencode.fullname" .) .Values.serviceAccount.name }}
{{- else }}
{{- default "default" .Values.serviceAccount.name }}
{{- end }}
{{- end }}

{{/*
Name of the Secret holding API keys / tokens.
*/}}
{{- define "opencode.secretName" -}}
{{- if .Values.secrets.existingSecret }}
{{- .Values.secrets.existingSecret }}
{{- else }}
{{- include "opencode.fullname" . }}
{{- end }}
{{- end }}

{{/*
Env var name that carries the provider API key.
*/}}
{{- define "opencode.apiKeyEnv" -}}
{{- if .Values.opencode.apiKeyEnv }}
{{- .Values.opencode.apiKeyEnv }}
{{- else }}
{{- printf "%s_API_KEY" (.Values.opencode.provider | upper | replace "-" "_") }}
{{- end }}
{{- end }}

{{/*
Registry pull secret generated from .Values.imageCredentials.
*/}}
{{- define "opencode.imagePullSecretName" -}}
{{- default (printf "%s-registry" (include "opencode.fullname" .)) .Values.imageCredentials.name }}
{{- end }}

{{- define "opencode.dockerconfigjson" -}}
{{- $c := .Values.imageCredentials }}
{{- $auth := printf "%s:%s" $c.username $c.password | b64enc }}
{{- $entry := dict "username" $c.username "password" $c.password "auth" $auth }}
{{- if $c.email }}{{- $_ := set $entry "email" $c.email }}{{- end }}
{{- dict "auths" (dict $c.registry $entry) | toJson }}
{{- end }}

{{- define "opencode.image" -}}
{{- printf "%s:%s" .Values.image.repository (default .Chart.AppVersion .Values.image.tag) }}
{{- end }}
