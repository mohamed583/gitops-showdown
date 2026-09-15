{{/*
Naming and labelling helpers.
*/}}

{{- define "ticketflow.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "ticketflow.fullname" -}}
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

{{- define "ticketflow.labels" -}}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{ include "ticketflow.selectorLabels" . }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/part-of: gitops-showdown
{{- end -}}

{{- define "ticketflow.selectorLabels" -}}
app.kubernetes.io/name: {{ include "ticketflow.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}

{{- define "ticketflow.postgres.fullname" -}}
{{- printf "%s-postgres" (include "ticketflow.fullname" .) | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/*
Name of the Secret holding the database password: either one the operator
supplies, or the one this chart renders.
*/}}
{{- define "ticketflow.secretName" -}}
{{- if .Values.postgres.existingSecret -}}
{{- .Values.postgres.existingSecret -}}
{{- else -}}
{{- include "ticketflow.fullname" . -}}
{{- end -}}
{{- end -}}

{{/*
The SQLAlchemy URL, minus the password, which is injected from the Secret at
runtime. Kept in one place so the API and the migration Job cannot disagree
about which database they are talking to.
*/}}
{{- define "ticketflow.databaseHost" -}}
{{- printf "%s.%s.svc.cluster.local" (include "ticketflow.postgres.fullname" .) .Release.Namespace -}}
{{- end -}}

{{/*
Environment shared by the API container and the migration Job.
*/}}
{{- define "ticketflow.env" -}}
- name: TICKETFLOW_RELEASE
  value: {{ .Chart.AppVersion | quote }}
- name: TICKETFLOW_ENVIRONMENT
  value: {{ .Values.app.environment | quote }}
- name: POSTGRES_PASSWORD
  valueFrom:
    secretKeyRef:
      name: {{ include "ticketflow.secretName" . }}
      key: postgres-password
- name: TICKETFLOW_DATABASE_URL
  value: "postgresql+psycopg://{{ .Values.postgres.auth.username }}:$(POSTGRES_PASSWORD)@{{ include "ticketflow.databaseHost" . }}:5432/{{ .Values.postgres.auth.database }}"
{{- end -}}
