#!/bin/bash
 
# Function to display usage
usage() {
  echo "Usage: $0 <plugin> <num_iterations> <sleep_between_iterations> <num_pods_values>"
  echo "Example: $0 calico 5 10 '1 10 20 30'"
  echo "If no arguments are provided, default values will be used."
}
 
# Set default values
default_plugin="calico"
default_num_iterations=2
default_sleep_between_iterations=30
default_num_pods_values="1 10 20"
 
# Use provided arguments or default values
plugin=${1:-$default_plugin}
num_iterations=${2:-$default_num_iterations}
sleep_between_iterations=${3:-$default_sleep_between_iterations}
num_pods_values=${4:-$default_num_pods_values}
 
# Function to run the pod startup experiment
run_pod_startup_experiment() {
  num_pods=$1
  plugin=$2
  individual_filename="individual_pod_creation_times_${plugin}_pods${num_pods}.txt"
  total_filename="total_pod_creation_times_${plugin}_pods${num_pods}.txt"
 
  echo "Pod Creation Time Measurement for num_pods=$num_pods"
  echo "Iteration, Total Latency (milliseconds), Average Latency per pod (milliseconds), Batch Readiness Time (milliseconds)" > "$total_filename"
  echo "Pod Name, Creation Timestamp, Ready Timestamp, Latency (milliseconds)" > "$individual_filename"
 
  total_batch_readiness=0
  total_latency_accumulator=0
 
  for (( r=1; r<=num_iterations; r++ ))
  do
    echo "Starting iteration $r"
    start_times=()
    end_times=()
    latencies=()
    total_latency=0
 
    batch_start_time=$(date +%s%3N)
 
    for (( i=1; i<=$num_pods; i++ ))
    do
      pod_name="pause-pod-$r-$i"
      cat <<EOF | kubectl apply -f - &
apiVersion: v1
kind: Pod
metadata:
  name: $pod_name
spec:
  containers:
  - name: pause
    image: k8s.gcr.io/pause:3.1
  nodeSelector:
    kubernetes.io/hostname: worker2.test.com
EOF
      start_times[$i]=$(date +%s%3N)
    done
 
    wait
 
    latest_ready_time=0
    for (( i=1; i<=$num_pods; i++ ))
    do
      pod_name="pause-pod-$r-$i"
      kubectl wait --for=condition=ready pod $pod_name --timeout=300s > /dev/null 2>&1
      end_times[$i]=$(date +%s%3N)
      if [[ ${end_times[$i]} -gt $latest_ready_time ]]; then
        latest_ready_time=${end_times[$i]}
      fi
    done
 
    batch_readiness_time=$(($latest_ready_time - $batch_start_time))
    total_batch_readiness=$(($total_batch_readiness + $batch_readiness_time))
 
    for (( i=1; i<=$num_pods; i++ ))
    do
      pod_name="pause-pod-$r-$i"
      latency=$((${end_times[$i]} - ${start_times[$i]}))
      latencies[$i]=$latency
      total_latency=$(($total_latency + $latency))
      echo "$pod_name, ${start_times[$i]}, ${end_times[$i]}, $latency" >> "$individual_filename"
    done
 
    average_latency=$(($total_latency / $num_pods))
    echo "$r, $total_latency, $average_latency, $batch_readiness_time" >> "$total_filename"
    total_latency_accumulator=$(($total_latency_accumulator + $total_latency))
 
    for (( i=1; i<=$num_pods; i++ ))
    do
      pod_name="pause-pod-$r-$i"
      kubectl delete pod $pod_name > /dev/null 2>&1
    done
 
    echo "Iteration $r complete. Total latency: $total_latency milliseconds. Average latency per pod: $average_latency milliseconds. Batch readiness time: $batch_readiness_time milliseconds."
 
    echo "Sleeping for $sleep_between_iterations seconds..."
    sleep "$sleep_between_iterations"
  done
 
  average_batch_readiness=$(($total_batch_readiness / num_iterations))
  echo "Average Batch Readiness Time for all iterations: $average_batch_readiness milliseconds." >> "$total_filename"
 
  final_average_latency=$(($total_latency_accumulator / (num_iterations * $num_pods)))
  echo "Final Average Latency per pod for all iterations: $final_average_latency milliseconds." >> "$total_filename"
 
  echo "Measurement complete for num_pods=$num_pods. Data stored in $individual_filename and $total_filename"
}
 
# Function to compile the detailed results
compile_detailed_results() {
  output_file="compiled_pod_creation_times_detailed_summary.txt"
 
  echo "Plugin, Num Pods, Iteration, Total Latency (ms), Average Latency per Pod (ms), Batch Readiness Time (ms), Average Batch Readiness Time (ms), Final Average Latency per Pod for all iterations (ms)" > "$output_file"
 
  for total_file in total_pod_creation_times_*.txt
  do
    plugin=$(echo "$total_file" | sed -n 's/.*_\(.*\)_pods.*/\1/p')
    num_pods=$(echo "$total_file" | sed -n 's/.*_pods\([0-9]\+\).*/\1/p')
 
    avg_batch_readiness=$(grep "Average Batch Readiness Time for all iterations" "$total_file" | awk -F': ' '{print $2}' | awk '{print $1}')
    final_avg_latency=$(grep "Final Average Latency per pod for all iterations" "$total_file" | awk -F': ' '{print $2}' | awk '{print $1}')
 
    while read -r line
    do
      if [[ "$line" == "Iteration, Total Latency (milliseconds),"* ]] || [[ "$line" == "Average Batch Readiness Time for all iterations:"* ]] || [[ "$line" == "Final Average Latency per pod for all iterations:"* ]]; then
        continue
      fi
 
      echo "$plugin, $num_pods, $line, $avg_batch_readiness, $final_avg_latency" >> "$output_file"
    done < "$total_file"
  done
 
  echo "All data has been compiled into $output_file"
}
 
# Step 1: Run the pod startup experiments for each pod count
echo "Running experiments with the following parameters:"
echo "Plugin: $plugin"
echo "Number of Iterations: $num_iterations"
echo "Sleep Between Iterations: $sleep_between_iterations seconds"
echo "Pod Counts: $num_pods_values"
echo "-------------------------------------------"
 
for num_pods in $num_pods_values
do
  run_pod_startup_experiment "$num_pods" "$plugin"
done
 
# Step 2: Compile the detailed results
echo "Compiling results from all experiments..."
compile_detailed_results
 
echo "All experiments completed and results compiled into compiled_pod_creation_times_detailed_summary.txt"
