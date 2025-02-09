#!/bin/bash

# Usage: ./wrk_experiment.sh "<threads1 threads2 ...>" "<connections1 connections2 ...>" "<duration1 duration2 ...>"
# Example: ./wrk_experiment.sh "2 4" "100 200" "30s 60s"

if [ "$#" -ne 3 ]; then
  echo "Usage: ./wrk_experiment.sh \"<threads1 threads2 ...>\" \"<connections1 connections2 ...>\" \"<duration1 duration2 ...>\""
  exit 1
fi

THREADS_LIST=($1)
CONNECTIONS_LIST=($2)
DURATION_LIST=($3)

if [ "${#THREADS_LIST[@]}" -ne "${#CONNECTIONS_LIST[@]}" ] || [ "${#THREADS_LIST[@]}" -ne "${#DURATION_LIST[@]}" ]; then
  echo "Error: The number of threads, connections, and durations must match."
  exit 1
fi

# Log the start time
echo "Script started at: $(date)"

# Deploy Nginx if not already deployed
if ! kubectl get deployment nginx &> /dev/null; then
  echo "Nginx deployment not found. Deploying Nginx..."
  kubectl create deployment nginx --image=nginx --dry-run=client -o yaml | kubectl apply -f -
  kubectl expose deployment nginx --port=80 --target-port=80 --name=nginx-service
  echo "Nginx deployment and service created. Waiting for pods to become ready..."
  kubectl wait --for=condition=available --timeout=120s deployment/nginx
  echo "Sleeping for 60 seconds after Nginx deployment..."
  sleep 60
else
  echo "Nginx deployment already exists. Skipping deployment."
fi

# Trap to catch CTRL+C and clean up jobs
function cleanup() {
  echo "Interrupt received. Cleaning up..."
  for JOB in "${JOBS_TO_CLEAN[@]}"; do
    echo "Deleting job ${JOB}..."
    kubectl delete job ${JOB}
  done
  exit 1
}

trap cleanup SIGINT

JOBS_TO_CLEAN=()

for i in "${!THREADS_LIST[@]}"; do
  THREADS=${THREADS_LIST[$i]}
  CONNECTIONS=${CONNECTIONS_LIST[$i]}
  DURATION=${DURATION_LIST[$i],,}  # Convert to lowercase to handle cases like '30S'
  JOB_NAME="wrk-benchmark-${THREADS}-${CONNECTIONS}-${DURATION}"
  LOG_FILE="wrk-${THREADS}-threads-${CONNECTIONS}-connections-${DURATION}-time.log"
  LOG_FILE_JSON="wrk-${THREADS}-threads-${CONNECTIONS}-connections-${DURATION}-time.json"

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
      - name: wrk
        image: williamyeh/wrk
        command: ["/bin/sh", "-c"]
        args:
        - |
          echo "Starting wrk test...";
          wrk -t${THREADS} -c${CONNECTIONS} -d${DURATION} http://nginx-service.default.svc.cluster.local;
          echo "wrk test completed.";
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
  kubectl wait --for=condition=complete --timeout=600s job/${JOB_NAME}

  # Wait for 5 seconds
  sleep 5

  # Get the Logs
  POD_NAME=$(kubectl get pods --selector=job-name=${JOB_NAME} --output=jsonpath='{.items[0].metadata.name}')
  if [ -z "$POD_NAME" ]; then
    echo "Error: No pod found for the job ${JOB_NAME}."
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

# Log the end time
echo "Script ended at: $(date)"