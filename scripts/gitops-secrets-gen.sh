#!/bin/bash

function usage() {
    echo "$(basename "$0") <deploy.env>" >&2
    echo "" >&2
    echo "Generates random secrets needed by the apps in this repo" >&2
    exit 1
}

if ! type -p kubeseal kubectl > /dev/null; then
    echo "You must have kubeseal & kubectl installed to use this script" >&2
    exit 1
fi

if ! $(kubectl api-resources | grep -q sealedsecrets); then
    echo "Your cluster doesn't appear to have the sealed secrets operator installed." >&2
    exit 1
fi

function secret-seal-stdin() {
    # this is meant to be piped to
    # $1 is output file, -w
    kubeseal \
        --scope cluster-wide \
        --allow-empty-data \
        -o yaml \
        -w $1
}

if [ $# -ne 1 ]; then
    usage
fi

SCRIPTS_DIR=$(dirname "$0")

if [ ! -f "$1" ]; then
    echo "Did not get a file with environment variables." >&2
    usage
fi

# set temp path so we can reset it after import
UC_REPO_PATH="$(cd "${SCRIPTS_DIR}" && git rev-parse --show-toplevel)"
export UC_REPO="${UC_REPO_PATH}"

. "$1"

# set the value again after import
export UC_REPO="${UC_REPO_PATH}"

if [ ! -d "${UC_DEPLOY}" ]; then
    echo "UC_DEPLOY not set to a path." >&2
    usage
fi

if [ "x${DEPLOY_NAME}" = "x" ]; then
    echo "DEPLOY_NAME is not set." >&2
    usage
fi

[ -f "${UC_DEPLOY}/secrets/${DEPLOY_NAME}/argocd/secret-deploy.repo.yaml" ] && \
    mv -f "${UC_DEPLOY}/secrets/${DEPLOY_NAME}/argocd/secret-deploy-repo.yaml" "${UC_DEPLOY}/secrets/${DEPLOY_NAME}/cluster/"
if [ -f "${UC_DEPLOY}/secrets/${DEPLOY_NAME}/cluster/secret-deploy-repo.yaml" ]; then
    NO_SECRET_DEPLOY=1
else
    if [ "x${UC_DEPLOY_GIT_URL}" = "x" ]; then
        echo "UC_DEPLOY_GIT_URL is not set." >&2
        usage
    fi
    if [ "x${UC_DEPLOY_SSH_FILE}" = "x" ]; then
        echo "UC_DEPLOY_SSH_FILE is not set." >&2
        usage
    fi
    if [ ! -f "${UC_DEPLOY_SSH_FILE}" ]; then
        echo "UC_DEPLOY_SSH_FILE at ${UC_DEPLOY_SSH_FILE} does not exist." >&2
        usage
    fi
fi

if [ "x${DNS_ZONE}" = "x" ]; then
    echo "DNS_ZONE is not set." >&2
    usage
fi

if [ "x${UC_DEPLOY_EMAIL}" = "x" ]; then
    echo "UC_DEPLOY_EMAIL is not set." >&2
    usage
fi

export DNS_ZONE
export DEPLOY_NAME
export DO_TMPL_VALUES=y
mkdir -p "${UC_DEPLOY}/secrets/${DEPLOY_NAME}"
"${SCRIPTS_DIR}/easy-secrets-gen.sh" "${UC_DEPLOY}/secrets/${DEPLOY_NAME}"

mkdir -p "${UC_DEPLOY}/secrets/${DEPLOY_NAME}/cluster"
echo "Creating ArgoCD ${DEPLOY_NAME} cluster"
cat << EOF > "${UC_DEPLOY}/secrets/${DEPLOY_NAME}/cluster/secret-${DEPLOY_NAME}-cluster.yaml"
apiVersion: v1
kind: Secret
data:
  config: $(printf '{"tlsClientConfig":{"insecure":false}}' | base64)
  name: $(printf "$DEPLOY_NAME" | base64)
  server: $(printf "https://kubernetes.default.svc" | base64)
metadata:
  name: ${DEPLOY_NAME}-cluster
  namespace: argocd
  labels:
    argocd.argoproj.io/secret-type: cluster
  annotations:
    uc_repo_git_url: "https://github.com/rackerlabs/understack.git"
    uc_repo_ref: "HEAD"
    uc_deploy_git_url: "$UC_DEPLOY_GIT_URL"
    uc_deploy_ref: "HEAD"
    dns_zone: "$DNS_ZONE"
EOF

if [ "x${NO_SECRET_DEPLOY}" = "x" ]; then
    echo "Creating ArgoCD repo-creds"
    cat << EOF | secret-seal-stdin "${UC_DEPLOY}/secrets/${DEPLOY_NAME}/cluster/secret-deploy-repo.yaml"
apiVersion: v1
kind: Secret
metadata:
  name: ${DEPLOY_NAME}-repo
  namespace: argocd
  labels:
    argocd.argoproj.io/secret-type: repo-creds
data:
  sshPrivateKey: $(cat "${UC_DEPLOY_SSH_FILE}" | base64 | tr -d '\n')
  type: $(printf "git" | base64)
  url: $(printf "${UC_DEPLOY_GIT_URL}" | base64)
EOF
fi

echo "Creating Cert Manager Cluster Issuer"
[ -f "${UC_DEPLOY}/secrets/${DEPLOY_NAME}/cluster-issuer.yaml" ] && \
    mv -f "${UC_DEPLOY}/secrets/${DEPLOY_NAME}/cluster-issuer.yaml" "${UC_DEPLOY}/secrets/${DEPLOY_NAME}/cluster/"
cat << EOF > "${UC_DEPLOY}/secrets/${DEPLOY_NAME}/cluster/cluster-issuer.yaml"
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: ${DEPLOY_NAME}-cluster-issuer
spec:
  acme:
    email: ${UC_DEPLOY_EMAIL}
    privateKeySecretRef:
      name: letsencrypt-prod
    server: https://acme-v02.api.letsencrypt.org/directory
    solvers:
    - http01:
        ingress:
          ingressClassName: nginx
EOF

pushd "${UC_DEPLOY}/secrets/${DEPLOY_NAME}/cluster"
rm -rf kustomization.yaml
kustomize create --autodetect
popd

# Placeholders don't need sealing
if [ ! -f "${UC_DEPLOY}/secrets/${DEPLOY_NAME}/secret-metallb.yaml" ]; then
    echo "Creating metallb secret placeholder"
    echo "---" > "${UC_DEPLOY}/secrets/${DEPLOY_NAME}/secret-metallb.yaml"
fi

if [ ! -f "${UC_DEPLOY}/secrets/${DEPLOY_NAME}/secret-nautobot-env.yaml" ]; then
    echo "Creating nautobot-env secret placeholder"
    kubectl --namespace nautobot \
        create secret generic nautobot-env \
        --dry-run=client \
        -o yaml \
        --type Opaque > "${UC_DEPLOY}/secrets/${DEPLOY_NAME}/secret-nautobot-env.yaml"
fi

exit 0
