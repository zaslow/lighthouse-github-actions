#!/bin/bash

set -euo pipefail

SERVICE_ACCOUNT_NAME=${1}
REPO_NAME=${2}
TEAM_NAME=${3}
KIND=${4:-"Component"}
NAME=${5}


export git_sync_args=''
export techdocs_generate_args=''
export techdocs_publish_args=''

check_required_environment() {
  # TODO: check for env variables
  local required_env=""

  for reqvar in $required_env; do
    if [ -z "${!reqvar:0:10}" ]; then
      raise "missing ENVIRONMENT VARIABLE ${reqvar}"
      return 1
    fi
  done
}

set_git_sync_args() {
  repo_name=${1}
  gh_user=${2}
  gh_token=${3}
  git_sync_args="[\"--repo=https://github.com/${repo_name}\", \"--branch=$branch\", \"--depth=1\", \"--one-time\", \"--username\", \"${gh_user}\", \"--password\", \"${gh_token}\"]"
}

set_techdocs_args () {
  repo=${1##*/}
  techdocs_generate_args="techdocs-cli generate --source-dir /tmp/git/${repo} --output-dir /tmp/git/techdocs/${repo} --no-docker -v --legacyCopyReadmeMdToIndexMd"
  techdocs_publish_args="techdocs-cli publish --publisher-type awsS3 --storage-name ${S3_BUCKET_NAME} --entity ${team_name}/${kind}/${name} --directory /tmp/git/techdocs/${repo}"
}

create_job() {
  service_account_name=${1}
  repo=${2##*/}
  local ghcr_secrets
  ghcr_secrets="lighthouse-techdocs-${repo}-secrets"

cat << EOF | kubectl apply -f -
apiVersion: batch/v1
kind: Job
metadata:
  name: lighthouse-techdocs-${repo}
spec:
  ttlSecondsAfterFinished: 100
  template:
    metadata:
      labels:
        app: lighthouse-techdocs-${repo}
        sidecar.istio.io/inject: "false"
    spec:
      serviceAccountName: ${service_account_name}
      initContainers:
      - name: git-sync
        image: ghcr.io/department-of-veterans-affairs/lighthouse-developer-portal/git-sync:latest
        command: ['/git-sync']
        args: ${git_sync_args}
        volumeMounts:
          - name: repo
            mountPath: /tmp/git
        resources:
          limits:
            cpu: 300m
            memory: 450Mi
      containers:
      - name: techdocs
        image: ghcr.io/department-of-veterans-affairs/lighthouse-developer-portal/techdocs:latest
        imagePullPolicy: Always
        command: ['/bin/sh']
        args:
        - -c
        - |
          cd /tmp/git/${repo} || exit 1
          sed -i 's/backstage.io\/techdocs-ref: dir:.\//backstage.io\/techdocs-ref: dir:./g' catalog-info.yaml
          ${techdocs_generate_args}
          ${techdocs_publish_args}
        volumeMounts:
          - name: repo
            mountPath: /tmp/git/
        env:
        - name: ENVOY_ADMIN_API
          value: "http://127.0.0.1:15000"
        - name: ISTIO_QUIT_API
          value: "http://127.0.0.1:15020"
        - name: SCUTTLE_LOGGING
          value: "true"
        resources:
          limits:
            cpu: 500m
            memory: 1024Mi
      imagePullSecrets:
        - name: "${ghcr_secrets}"
      restartPolicy: Never
      volumes:
      - name: repo
        emptyDir: {}
EOF
}

run_main() {
    service_account_name=${1}
    repo_name=${2}
    team_name=${3}
    kind=${4}
    name=${5}

    check_required_environment "${service_account_name}" "${repo_name}" "${team_name}" "${kind}" "${name}" || exit 1
    set_git_sync_args "${repo_name}" "${GITHUB_USER}" "${GITHUB_TOKEN}" || exit 1
    set_techdocs_args "${repo_name}" "${team_name}" "${kind}" "${name}" || exit 1
    create_job "${service_account_name}" "${repo_name}" || exit 1
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]
then
  run_main "${SERVICE_ACCOUNT_NAME}" "${REPO_NAME}" "${TEAM_NAME}" "${KIND}" "${NAME}"
fi
