#!/bin/bash

set -x

# Inputs
readonly SHEPHERD_NAMESPACE=spring-cloud-dataflow
readonly SHEPHERD_POOL=tkg-nimbus-1_4
readonly LOCK_FILE_DIR=$(dirname $0)/shepherd-pool
readonly LOCK_FILE=${LOCK_FILE_DIR}/lock.json

readonly DATAFLOW_NAME=springsource-docker-private-local.jfrog.io/scdf-pro-server
readonly DATAFLOW_TAG=1.4.2-SNAPSHOT
readonly SKIPPER_TAG=2.8.2-SNAPSHOT
readonly BROKER=rabbitmq

readonly JFROG_USERNAME=xxxx
readonly JFROG_PASSWORD=xxxx

readonly DOCKER_HUB_USERNAME=xxxx
readonly DOCKER_HUB_PASSWORD=xxxx

export KUBECONFIG=`mktemp -d`/kubeconfig

lock() {
  mkdir -p ${LOCK_FILE_DIR}
  sheepctl -n ${SHEPHERD_NAMESPACE} pool lock ${SHEPHERD_POOL} --output ${LOCK_FILE} --lifetime 24h
}

config_cluster() {
  jq .access -r ${LOCK_FILE} | jq -r .tkg[].kubeconfig | tee ${KUBECONFIG}
  # Create default storage engine
  kubectl create -f - <<EOF
kind: StorageClass
apiVersion: storage.k8s.io/v1
metadata:
  name: default
  annotations:
    storageclass.kubernetes.io/is-default-class: "true"
provisioner: csi.vsphere.vmware.com
reclaimPolicy: Retain
EOF

  # Scale works in control cluster
  readonly jumper_hostname=$(jq .outputs.vm.jumper.hostname -r ${LOCK_FILE})
  readonly jumper_username=$(jq .outputs.vm.jumper.username -r ${LOCK_FILE})
  readonly jumper_password=$(jq .outputs.vm.jumper.password -r ${LOCK_FILE})

  expect <<EOF
    spawn ssh -o StrictHostKeyChecking=no ${jumper_username}@${jumper_hostname}
    expect "password:"
    send "${jumper_password}\r"
    expect "$ "
    send "source env.sh\r"
    send "tanzu cluster scale tkg-mgmt-vc -w 6\r"
    expect "Workload cluster 'tkg-mgmt-vc' is being scaled"
EOF
}

wait_for_cluster_nodes() {
  # TODO Add timeout
  while [ $(kubectl get Node -A | grep -v control-plane | grep Ready | wc -l) -le 5 ]; do
    kubectl get Node -A
    echo "Waiting on cluster worker nodes to scale..."
    sleep 5
  done
}

deploy_dataflow() {
  kubectl create secret docker-registry scdf-image-regcred \
          --docker-server=springsource-docker-private-local.jfrog.io \
          --docker-username=${JFROG_USERNAME} \
          --docker-password=${JFROG_PASSWORD}
  kubectl create secret docker-registry scdf-metadata-default \
          --docker-username=${DOCKER_HUB_USERNAME} \
          --docker-password=${DOCKER_HUB_PASSWORD}
  ytt \
    -f scdf-pro/.github/tmc/kustomize/values.yaml \
    -f scdf-pro/.github/tmc/kustomize/template \
    --data-value dataflow_name=$DATAFLOW_NAME \
    --data-value dataflow_tag=$DATAFLOW_TAG \
    --data-value skipper_name=harbor-repo.vmware.com/dockerhub-proxy-cache/springcloud/spring-cloud-skipper-server \
    --data-value skipper_tag=$SKIPPER_TAG \
    --dangerous-emptied-output-directory scdf-pro/.github/tmc/kustomize/tweak
  cp -r scdf-pro/.github/tmc/kustomize/tweak/ scdf-k8s-packaging/
  scdf-k8s-packaging/bin/install-dev.sh --broker $BROKER
  export DATAFLOW_IP=$(kubectl get svc | grep scdf-server | awk '{print $4}')

  while [ -z $(wget -qO- http://$DATAFLOW_IP/) ]; do
    echo "Waiting for Data Flow to start"
    sleep 5
  done
}

register_apps() {
  if [ "$BROKER" = "rabbitmq" ]
  then
    BROKERNAME=rabbit
  else
    BROKERNAME=$BROKER
  fi
  wget -O- http://$DATAFLOW_IP/apps --post-data="uri=https://dataflow.spring.io/$BROKER-docker-latest"
  wget -O- http://$DATAFLOW_IP/apps --post-data="uri=https://dataflow.spring.io/task-docker-latest"
  wget -O- http://$DATAFLOW_IP/apps/task/scenario/0.0.1-SNAPSHOT --post-data="uri=docker:springcloudtask/scenario-task:0.0.1-SNAPSHOT"
  wget -O- http://$DATAFLOW_IP/apps/task/batch-remote-partition/0.0.2-SNAPSHOT --post-data="uri=docker://springcloud/batch-remote-partition:0.0.2-SNAPSHOT"
  wget -O- http://$DATAFLOW_IP/apps/sink/ver-log/3.0.1 --post-data="uri=docker:springcloudstream/log-sink-$BROKERNAME:3.0.1"
  wget -O- http://$DATAFLOW_IP/apps/sink/ver-log/2.1.5.RELEASE --post-data="uri=docker:springcloudstream/log-sink-$BROKERNAME:2.1.5.RELEASE"
  wget -O- http://$DATAFLOW_IP/apps/task/task-demo-metrics-prometheus/0.0.4-SNAPSHOT --post-data="uri=docker://springcloudtask/task-demo-metrics-prometheus:0.0.4-SNAPSHOT"
}

run_tests() {
  cd spring-cloud-dataflow-acceptance-tests
  ./mvnw \
    -Dspring.profiles.active=blah \
    -DPLATFORM_TYPE=kubernetes \
    -DNAMESPACE=default \
    -DSKIP_CLOUD_CONFIG=true \
    -Dtest.docker.compose.disable.extension=true \
    -Dspring.cloud.dataflow.client.serverUri=http://$DATAFLOW_IP \
    -Dspring.cloud.dataflow.client.skipSslValidation=true \
    -Dtest=!DataFlowAT#streamAppCrossVersion \
    clean test
}

lock
config_cluster
wait_for_cluster_nodes
deploy_dataflow
register_apps
run_tests
