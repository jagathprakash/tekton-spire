#!/usr/bin/env bash
# Waits until all pods are running in the given namespace.
# Parameters: $1 - namespace.
function wait_until_pods_running() {
  echo -n "Waiting until all pods in namespace $1 are up"
  for i in {1..150}; do  # timeout after 5 minutes
    local pods="$(kubectl get pods --no-headers -n $1 2>/dev/null)"
    # All pods must be running
    local not_running=$(echo "${pods}" | grep -v Running | grep -v Completed | wc -l)
    if [[ -n "${pods}" && ${not_running} -eq 0 ]]; then
      local all_ready=1
      while read pod ; do
        local status=(`echo -n ${pod} | cut -f2 -d' ' | tr '/' ' '`)
        # All containers must be ready
        [[ -z ${status[0]} ]] && all_ready=0 && break
        [[ -z ${status[1]} ]] && all_ready=0 && break
        [[ ${status[0]} -lt 1 ]] && all_ready=0 && break
        [[ ${status[1]} -lt 1 ]] && all_ready=0 && break
        [[ ${status[0]} -ne ${status[1]} ]] && all_ready=0 && break
      done <<< $(echo "${pods}" | grep -v Completed)
      if (( all_ready )); then
        echo -e "\nAll pods are up:\n${pods}"
        return 0
      fi
    fi
    echo -n "."
    sleep 2
  done
  echo -e "\n\nERROR: timeout waiting for pods to come up\n${pods}"
  return 1
}

function spire_apply() {
  if [ $# -lt 2 -o "$1" != "-spiffeID" ]; then
    echo "spire_apply requires a spiffeID as the first arg" >&2
    exit 1
  fi
  show=$(kubectl exec -n spire deployment/spire-server -- \
    /opt/spire/bin/spire-server entry show $1 $2)
  if [ "$show" != "Found 0 entries" ]; then
    # delete to recreate
    entryid=$(echo "$show" | grep "^Entry ID" | cut -f2 -d:)
    kubectl exec -n spire deployment/spire-server -- \
      /opt/spire/bin/spire-server entry delete -entryID $entryid
  fi
  kubectl exec -n spire deployment/spire-server -- \
    /opt/spire/bin/spire-server entry create "$@"
}

function install_spire() {
  echo ">> Deploying Spire"
  DIR="$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"

  echo "Creating SPIRE namespace..."
  kubectl create ns spire

  echo "Applying SPIFFE CSI Driver configuration..."
  kubectl apply -f "$DIR"/spire/spiffe-csi-driver.yaml

  echo "Deploying SPIRE server"
  kubectl apply -f "$DIR"/spire/spire-server.yaml

  echo "Deploying SPIRE agent"
  kubectl apply -f "$DIR"/spire/spire-agent.yaml

  wait_until_pods_running spire || fail_test "SPIRE did not come up"

  spire_apply \
    -spiffeID spiffe://example.org/ns/spire/node/example \
    -selector k8s_psat:cluster:example-cluster \
    -selector k8s_psat:agent_ns:spire \
    -selector k8s_psat:agent_sa:spire-agent \
    -node
  spire_apply \
    -spiffeID spiffe://example.org/ns/tekton-pipelines/sa/tekton-pipelines-controller \
    -parentID spiffe://example.org/ns/spire/node/example \
    -selector k8s:ns:tekton-pipelines \
    -selector k8s:pod-label:app:tekton-pipelines-controller \
    -selector k8s:sa:tekton-pipelines-controller \
    -admin
}

function patch_pipeline_spire() {
  kubectl patch \
      deployment tekton-pipelines-controller \
      -n tekton-pipelines \
      --patch-file "$DIR"/spire/pipeline-controller-spire.json
      
  verify_pipeline_installation
}

function verify_pipeline_installation() {
  # Make sure that everything is cleaned up in the current namespace.
  delete_pipeline_resources

  # Wait for pods to be running in the namespaces we are deploying to
  wait_until_pods_running tekton-pipelines || fail_test "Tekton Pipeline did not come up"
}

function delete_pipeline_resources() {
  for res in pipelineresources tasks clustertasks pipelines taskruns pipelineruns; do
    kubectl delete --ignore-not-found=true ${res}.tekton.dev --all
  done
}

function configure_pipelines_for_spire() {
  DIR="$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"
  kubectl apply -n tekton-pipelines -f "$DIR"/spire/config-spire.yaml
  patch_pipeline_spire
  kubectl apply -n tekton-pipelines -f "$DIR"/spire/config-spire.yaml
  jsonpatch=$(printf "{\"data\": {\"enable-api-fields\": \"alpha\", \"enforce-nonfalsifiability\": \"spire\"}}")
  kubectl patch configmap feature-flags -n tekton-pipelines -p "$jsonpatch"
}

install_spire
configure_pipelines_for_spire
