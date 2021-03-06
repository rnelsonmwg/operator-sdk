#!/usr/bin/env bash

set -eux

source hack/lib/test_lib.sh
source hack/lib/image_lib.sh

DEST_IMAGE="quay.io/example/nginx-operator:v0.0.2"
ROOTDIR="$(pwd)"
TMPDIR="$(mktemp -d)"
trap_add 'rm -rf $TMPDIR' EXIT

test_namespace="test-e2e-helm"

deploy_operator() {
    kubectl create -f "$OPERATORDIR/deploy/crds/helm.example.com_nginxes_crd.yaml"
    kubectl create -f "$OPERATORDIR/deploy/service_account.yaml"
    kubectl create -f "$OPERATORDIR/deploy/cluster_role.yaml"
    kubectl create -f "$OPERATORDIR/deploy/cluster_role_binding.yaml"
    kubectl create -f "$OPERATORDIR/deploy/cluster_operator.yaml"
    kubectl create namespace ${test_namespace}
}

remove_operator() {
    kubectl delete --ignore-not-found namespace ${test_namespace}
    kubectl delete --ignore-not-found=true -f "$OPERATORDIR/deploy/service_account.yaml"
    kubectl delete --ignore-not-found=true -f "$OPERATORDIR/deploy/cluster_role.yaml"
    kubectl delete --ignore-not-found=true -f "$OPERATORDIR/deploy/cluster_role_binding.yaml"
    kubectl delete --ignore-not-found=true -f "$OPERATORDIR/deploy/crds/helm.example.com_nginxes_crd.yaml"
    kubectl delete --ignore-not-found=true -f "$OPERATORDIR/deploy/cluster_operator.yaml"
}

test_operator() {
    # kind has an issue with certain image registries (ex. redhat's), so use a
    # different test pod image.
    local metrics_test_image="fedora:latest"

    # wait for operator pod to run
    if ! timeout 1m kubectl rollout status deployment/nginx-operator;
    then
        kubectl logs deployment/nginx-operator
        exit 1
    fi

    # verify that metrics service was created
    if ! timeout 60s bash -c -- "until kubectl get service/nginx-operator-metrics > /dev/null 2>&1; do sleep 1; done";
    then
        echo "Failed to get metrics service"
        kubectl logs deployment/nginx-operator
        exit 1
    fi


    # verify that the metrics endpoint exists
    if ! timeout 1m bash -c -- "until kubectl run --attach --rm --restart=Never test-metrics --image=${metrics_test_image} -- curl -sfo /dev/null http://nginx-operator-metrics:8383/metrics; do sleep 1; done";
    then
        echo "Failed to verify that metrics endpoint exists"
        kubectl logs deployment/nginx-operator
        exit 1
    fi

    # create CR
    kubectl create --namespace=${test_namespace} -f deploy/crds/helm.example.com_v1alpha1_nginx_cr.yaml
    trap_add "kubectl delete --namespace=${test_namespace} --ignore-not-found -f ${OPERATORDIR}/deploy/crds/helm.example.com_v1alpha1_nginx_cr.yaml" EXIT
    if ! timeout 1m bash -c -- "until kubectl get --namespace=${test_namespace} nginxes.helm.example.com example-nginx -o jsonpath='{..status.deployedRelease.name}' | grep 'example-nginx'; do sleep 1; done";
    then
        kubectl logs deployment/nginx-operator
        exit 1
    fi

    # verify that the custom resource metrics endpoint exists
    if ! timeout 1m bash -c -- "until kubectl run --attach --rm --restart=Never test-cr-metrics --image=${metrics_test_image} -- curl -sfo /dev/null http://nginx-operator-metrics:8686/metrics; do sleep 1; done";
    then
        echo "Failed to verify that custom resource metrics endpoint exists"
        kubectl logs deployment/nginx-operator
        exit 1
    fi

    header_text "verify that the servicemonitor is created"
    if ! timeout 1m bash -c -- "until kubectl get servicemonitors/nginx-operator-metrics > /dev/null 2>&1; do sleep 1; done";
    then
        error_text "FAIL: Failed to get service monitor"
        operator_logs
        exit 1
    fi

    release_name=$(kubectl get --namespace=${test_namespace} nginxes.helm.example.com example-nginx -o jsonpath="{..status.deployedRelease.name}")
    nginx_deployment=$(kubectl get --namespace=${test_namespace} deployment -l "app.kubernetes.io/instance=${release_name}" -o jsonpath="{..metadata.name}")

    if ! timeout 1m kubectl rollout --namespace=${test_namespace} status deployment/${nginx_deployment};
    then
        kubectl describe --namespace=${test_namespace} pods -l "app.kubernetes.io/instance=${release_name}"
        kubectl describe --namespace=${test_namespace} deployments ${nginx_deployment}
        kubectl logs deployment/nginx-operator
        exit 1
    fi

    nginx_service=$(kubectl get --namespace=${test_namespace} service -l "app.kubernetes.io/instance=${release_name}" -o jsonpath="{..metadata.name}")
    kubectl get --namespace=${test_namespace} service ${nginx_service}

    # scale deployment replicas to 2 and verify the
    # deployment automatically scales back down to 1.
    kubectl scale --namespace=${test_namespace} deployment/${nginx_deployment} --replicas=2
    if ! timeout 1m bash -c -- "until test \$(kubectl get --namespace=${test_namespace} deployment/${nginx_deployment} -o jsonpath='{..spec.replicas}') -eq 1; do sleep 1; done";
    then
        kubectl describe --namespace=${test_namespace} pods -l "app.kubernetes.io/instance=${release_name}"
        kubectl describe --namespace=${test_namespace} deployments ${nginx_deployment}
        kubectl logs deployment/nginx-operator
        exit 1
    fi

    # update CR to replicaCount=2 and verify the deployment
    # automatically scales up to 2 replicas.
    kubectl patch --namespace=${test_namespace} nginxes.helm.example.com example-nginx -p '[{"op":"replace","path":"/spec/replicaCount","value":2}]' --type=json
    if ! timeout 1m bash -c -- "until test \$(kubectl get --namespace=${test_namespace} deployment/${nginx_deployment} -o jsonpath='{..spec.replicas}') -eq 2; do sleep 1; done";
    then
        kubectl describe --namespace=${test_namespace} pods -l "app.kubernetes.io/instance=${release_name}"
        kubectl describe --namespace=${test_namespace} deployments ${nginx_deployment}
        kubectl logs deployment/nginx-operator
        exit 1
    fi

    kubectl delete --namespace=${test_namespace} -f deploy/crds/helm.example.com_v1alpha1_nginx_cr.yaml --wait=true
    kubectl logs deployment/nginx-operator | grep "Uninstalled release" | grep "${release_name}"
}

# create and build the operator
pushd "$TMPDIR"
log=$(operator-sdk new nginx-operator \
  --api-version=helm.example.com/v1alpha1 \
  --kind=Nginx \
  --type=helm \
  2>&1)
echo $log
if echo $log | grep -q "failed to generate RBAC rules"; then
    echo FAIL expected successful generation of RBAC rules
    exit 1
fi

install_service_monitor_crd

pushd nginx-operator
sed -i".bak" -E -e 's/(FROM quay.io\/operator-framework\/helm-operator)(:.*)?/\1:dev/g' build/Dockerfile; rm -f build/Dockerfile.bak
operator-sdk build "$DEST_IMAGE"
# If using a kind cluster, load the image into all nodes.
load_image_if_kind "$DEST_IMAGE"
sed -i".bak" -E -e "s|REPLACE_IMAGE|$DEST_IMAGE|g" deploy/operator.yaml; rm -f deploy/operator.yaml.bak
sed -i".bak" -E -e 's|Always|Never|g' deploy/operator.yaml; rm -f deploy/operator.yaml.bak

kubectl create --dry-run -f "deploy/operator.yaml" -o json | jq '((.spec.template.spec.containers[] | select(.name == "nginx-operator").env[]) | select(.name == "WATCH_NAMESPACE")) |= {"name":"WATCH_NAMESPACE", "value":""}' | kubectl create --dry-run -f - -o yaml > deploy/cluster_operator.yaml
kubectl create --dry-run  -f "deploy/role.yaml" -o json | jq '.kind = "ClusterRole"' | kubectl create --dry-run -f - -o yaml > deploy/cluster_role.yaml
kubectl create --dry-run -f "deploy/role_binding.yaml" -o json | jq '.subjects[0].namespace= "default"' | jq '.roleRef.kind= "ClusterRole"' | jq '.kind = "ClusterRoleBinding"' | kubectl create --dry-run -f - -o yaml > deploy/cluster_role_binding.yaml

# kind has an issue with certain image registries (ex. redhat's), so use a
# different test pod image.
METRICS_TEST_IMAGE="fedora:latest"
docker pull "$METRICS_TEST_IMAGE"
# If using a kind cluster, load the metrics test image into all nodes.
load_image_if_kind "$METRICS_TEST_IMAGE"

OPERATORDIR="$(pwd)"

deploy_operator
trap_add 'remove_operator' EXIT
test_operator
remove_operator

echo "###"
echo "### Base image testing passed"
echo "### Now testing migrate to hybrid operator"
echo "###"

operator-sdk migrate --repo=github.com/example-inc/nginx-operator

if [[ ! -e build/Dockerfile.sdkold ]];
then
    echo FAIL the old Dockerfile should have been renamed to Dockerfile.sdkold
    exit 1
fi

add_go_mod_replace "github.com/operator-framework/operator-sdk" "$ROOTDIR"
# Build the project to resolve dependency versions in the modfile.
go build ./...

operator-sdk build "$DEST_IMAGE"
# If using a kind cluster, load the image into all nodes.
load_image_if_kind "$DEST_IMAGE"

deploy_operator
test_operator

popd
popd
