#!/bin/bash
 
# Number of iterations
iterations=10
 
# Delay between iterations in seconds
delay=60
 
# Base filename for results
base_filename="k8s-calico-net-results"
 
  echo "Wait 1 min"
  sleep 60
 
# Run the command multiple times
for ((i=1; i<=$iterations; i++)); do
  # Generate a unique filename for each iteration with .txt extension
  output_filename="${base_filename}-${i}.txt"
 
  # Inform the user about the current iteration
  echo "Iteration $i started at $(date)"
 
  # Run the command and save the output to the unique filename
  ./knb -cn worker1.test.com -sn worker2.test.com -d 10 -t 60 -o json > "$output_filename"
  # strip first warning line
  (cat "$output_filename" | tail -n +2 > /tmp/tmp.txt) 2> /dev/null
  (cat /tmp/tmp.txt > "$output_filename") 2> /dev/null
  # Inform the user that the iteration is finished
  echo "Iteration $i finished at $(date)"
 
  # Wait for the specified delay
  if [ $i -lt $iterations ]; then
    echo "Wait 10 min"
    sleep $delay
  fi
done