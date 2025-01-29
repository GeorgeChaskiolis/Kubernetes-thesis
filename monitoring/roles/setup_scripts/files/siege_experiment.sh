#!/bin/bash

# Usage: ./siege_experiment.sh "<concurrent_users1 concurrent_users2 ...>" "<experiment_duration1 experiment_duration2 ...>"
# Example: ./siege_experiment.sh "10 20" "30s 60s"

if [ "$#" -ne 2 ]; then
  echo "Usage: ./siege_experiment.sh \"<concurrent_users1 concurrent_users2 ...>\" \"<experiment_duration1 experiment_duration2 ...>\""
  exit 1
fi

CONCURRENT_USERS_LIST=($1)
EXPERIMENT_DURATION_LIST=($2)

if [ "${#CONCURRENT_USERS_LIST[@]}" -ne "${#EXPERIMENT_DURATION_LIST[@]}" ]; then
  echo "Error: The number of concurrent users must match the number of experiment durations."
  exit 1
fi

# Deploy Nginx if not already deployed
if ! kubectl get deployment nginx &> /dev/null; then
  echo "Nginx deployment not found. Deploying Nginx..."
  kubectl create deployment nginx --image=nginx --dry-run=client -o yaml | kubectl apply -f -
  kubectl expose deployment nginx --port=80 --target-port=80 --name=nginx-service
  echo "Nginx deployment and service created. Waiting for pods to become ready..."
  kubectl wait --for=condition=available --timeout=120s deployment/nginx
else
  echo "Nginx deployment already exists. Skipping deployment."
fi

sleep 60s

# Trap to catch CTRL+C and clean up jobs
function cleanup() {
  echo "Interrupt received. Cleaning up..."
  for JOB in "${JOBS_TO_CLEAN[@]}"; do
    echo "Deleting job ${JOB}..."
    kubectl delete job ${JOB} --ignore-not-found
  done
  exit 1
}

trap cleanup SIGINT

JOBS_TO_CLEAN=()

for i in "${!CONCURRENT_USERS_LIST[@]}"; do
  CONCURRENT_USERS=${CONCURRENT_USERS_LIST[$i]}
  EXPERIMENT_DURATION=${EXPERIMENT_DURATION_LIST[$i],,}  # Convert to lowercase to handle cases like '30S'
  JOB_NAME="siege-benchmark-${CONCURRENT_USERS}-${EXPERIMENT_DURATION}"
  LOG_FILE="siege-${CONCURRENT_USERS}-users-${EXPERIMENT_DURATION}-time.log"
  LOG_FILE_JSON="siege-${CONCURRENT_USERS}-users-${EXPERIMENT_DURATION}-time.json"
  

  JOBS_TO_CLEAN+=(${JOB_NAME})

  echo "Creating Kubernetes job for ${JOB_NAME}..."

  # Create Kubernetes Job
  cat <<EOF | kubectl apply -f -
apiVersion: batch/v1
kind: Job
metadata:
  name: ${JOB_NAME}
spec:
  template:
    spec:
      containers:
      - name: siege
        image: yokogawa/siege:latest
        command: ["/bin/sh", "-c"]
        args:
        - |
          echo "Starting Siege test...";
          siege -c${CONCURRENT_USERS} -t${EXPERIMENT_DURATION} http://nginx-service.default.svc.cluster.local;
          echo "Siege test completed.";
        resources:
          requests:
            memory: "128Mi"
            cpu: "250m"
          limits:
            memory: "256Mi"
            cpu: "500m"
      restartPolicy: Never
  backoffLimit: 1
EOF

  # Wait for the Job to Complete
  if ! kubectl wait --for=condition=complete --timeout=600s job/${JOB_NAME}; then
    echo "Error: Job ${JOB_NAME} did not complete successfully."
    cleanup
    exit 1
  fi

  # Wait for 5 seconds
  sleep 5

  # Get the Logs
  POD_NAME=$(kubectl get pods --selector=job-name=${JOB_NAME} --output=jsonpath='{.items[0].metadata.name}')
  if [ -z "$POD_NAME" ]; then
    echo "Error: No pod found for the job ${JOB_NAME}."
    cleanup
    exit 1
  fi

  echo "Creating log file: ${LOG_FILE}"
  kubectl logs ${POD_NAME} > ${LOG_FILE}
  kubectl logs ${POD_NAME} | jq -R '{"log": .}' > ${LOG_FILE_JSON}

  # Delete the Job
  kubectl delete job ${JOB_NAME}

  # Wait for 30 seconds before the next iteration
  echo "Waiting 30 seconds before the next iteration..."
  sleep 30
done

echo "All tests completed successfully."
