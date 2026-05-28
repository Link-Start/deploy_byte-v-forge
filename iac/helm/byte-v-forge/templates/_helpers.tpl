{{- define "byte-v-forge.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "byte-v-forge.fullname" -}}
{{- if .Values.fullnameOverride -}}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- $name := default .Chart.Name .Values.nameOverride -}}
{{- if contains $name .Release.Name -}}
{{- .Release.Name | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" -}}
{{- end -}}
{{- end -}}
{{- end -}}

{{- define "byte-v-forge.componentFullname" -}}
{{- printf "%s-%s" (include "byte-v-forge.fullname" .root) .component | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "byte-v-forge.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "byte-v-forge.labels" -}}
helm.sh/chart: {{ include "byte-v-forge.chart" . }}
app.kubernetes.io/name: {{ include "byte-v-forge.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end -}}

{{- define "byte-v-forge.componentLabels" -}}
{{ include "byte-v-forge.labels" .root }}
app.kubernetes.io/component: {{ .component }}
{{- end -}}

{{- define "byte-v-forge.selectorLabels" -}}
app.kubernetes.io/name: {{ include "byte-v-forge.name" .root }}
app.kubernetes.io/instance: {{ .root.Release.Name }}
app.kubernetes.io/component: {{ .component }}
{{- end -}}

{{- define "byte-v-forge.serviceAccountName" -}}
{{- if .Values.serviceAccount.create -}}
{{- default (include "byte-v-forge.fullname" .) .Values.serviceAccount.name -}}
{{- else -}}
{{- default "default" .Values.serviceAccount.name -}}
{{- end -}}
{{- end -}}

{{- define "byte-v-forge.appSecretName" -}}
{{- default (printf "%s-secret" (include "byte-v-forge.fullname" .)) .Values.secrets.name | trunc 63 | trimSuffix "-" -}}
{{- end -}}


{{- define "byte-v-forge.image" -}}
{{- $registry := default "" .root.Values.global.imageRegistry -}}
{{- $repository := required "image.repository is required" .image.repository -}}
{{- $tag := default "latest" .image.tag -}}
{{- $firstSegment := first (splitList "/" $repository) -}}
{{- $hasRegistry := or (contains "." $firstSegment) (contains ":" $firstSegment) (eq $firstSegment "localhost") -}}
{{- if and $registry (not $hasRegistry) -}}
{{- printf "%s/%s:%s" (trimSuffix "/" $registry) $repository $tag -}}
{{- else -}}
{{- printf "%s:%s" $repository $tag -}}
{{- end -}}
{{- end -}}

{{- define "byte-v-forge.postgresHost" -}}
{{- if .Values.postgres.enabled -}}
{{- include "byte-v-forge.componentFullname" (dict "root" . "component" "postgres") -}}
{{- else -}}
{{- required "postgres.external.host is required when postgres.enabled=false" .Values.postgres.external.host -}}
{{- end -}}
{{- end -}}

{{- define "byte-v-forge.postgresPort" -}}
{{- if .Values.postgres.enabled -}}
{{- .Values.postgres.service.port -}}
{{- else -}}
{{- .Values.postgres.external.port -}}
{{- end -}}
{{- end -}}

{{- define "byte-v-forge.pgDsn" -}}
{{- printf "host=%s user=$(POSTGRES_USER) password=$(POSTGRES_PASSWORD) dbname=$(POSTGRES_DB) port=%v sslmode=%s" (include "byte-v-forge.postgresHost" .) (include "byte-v-forge.postgresPort" .) .Values.postgres.sslMode -}}
{{- end -}}

{{- define "byte-v-forge.dashboardPathRule" -}}
{{- $parts := list -}}
{{- range . -}}
{{- $parts = append $parts (printf "PathPrefix(`%s`)" .) -}}
{{- end -}}
{{- join " || " $parts -}}
{{- end -}}

{{- define "byte-v-forge.dashboardRouteRule" -}}
{{- $pathRule := include "byte-v-forge.dashboardPathRule" .prefixes -}}
{{- if .host -}}
{{- printf "Host(`%s`) && (%s)" .host $pathRule -}}
{{- else -}}
{{- $pathRule -}}
{{- end -}}
{{- end -}}
