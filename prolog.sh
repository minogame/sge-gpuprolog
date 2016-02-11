#!/usr/bin/env bash

# Query how many gpus to allocate.
NGPUS=$(qstat -j $JOB_ID | \
        sed -n "s/hard resource_list:.*gpu=\([[:digit:]]\+\).*/\1/p")
if [ -z $NGPUS ]
then
  exit 0
fi
if [ $NGPUS -le 0 ]
then
  exit 0
fi
NGPUS=$(expr $NGPUS \* ${NSLOTS=1})

# Check if the environment file is writable.
ENV_FILE=$SGE_JOB_SPOOL_DIR/environment
if [ ! -f $ENV_FILE -o ! -w $ENV_FILE ]
then
  exit 1
fi

device_ids=$(nvidia-smi -L | cut -f1 -d":" | cut -f2 -d" ")
device_count=$(nvidia-smi -L | wc -l)

SGE_GPU=""

#if [[ "$device_count" -lt "5" ]]
if [[ "$HOSTNAME" != "yagi08" ]]; then
	free_gpu=""
	free_gpu_count=0
	for device_id in $device_ids; do
		lockfile=/tmp/lock-gpu$device_id
		if [[ ! -d $lockfile ]]; then
			free_gpu="$free_gpu $device_id"
			let "free_gpu_count+=1"
		fi
	done

	if [[ "free_gpu_count" -lt "$NGPUS" ]]; then
		echo "NOT ENOUGH GPUS AVAILABLE. THERE ARE ONLY $free_gpu_count GPUS."
		exit 1
	fi

	SGE_GPU=$(echo $free_gpu | xargs shuf -e | tr "\n" " " | cut -d' ' -f 1-$NGPUS)

	for device_id in $SGE_GPU; do
		lockfile=/tmp/lock-gpu$device_id
		mkdir $lockfile
	done
#For yagi08
else
	free_master_gpu=""
	free_slave_gpu=""
	free_master_gpu_count=0
	free_slave_gpu_count=0

	for device_id in 2 3; do
		lockfile=/tmp/lock-gpu$device_id
		if [[ ! -d $lockfile ]]; then
			free_master_gpu="$free_master_gpu $device_id"
			let "free_master_gpu_count+=1"
		fi
	done

	for device_id in 0 1 4 5 6 7; do
		lockfile=/tmp/lock-gpu$device_id
		if [[ ! -d $lockfile ]]; then
			free_slave_gpu="$free_slave_gpu $device_id"
			let "free_slave_gpu_count+=1"
		fi
	done

	let "free_gpu_count=free_master_gpu_count+free_slave_gpu_count"
	if [[ "free_gpu_count" -lt "$NGPUS" ]]; then
		echo "NOT ENOUGH GPUS AVAILABLE. THERE ARE ONLY $free_gpu_count GPUS."
		exit 1
	fi

	case $NGPUS in
	1)
	#Single gpu job will take slave gpu prior to master gpu
		if [[ "free_slave_gpu_count" -lt "1" ]]; then
			free_gpu=$free_master_gpu
		else
			free_gpu=$free_slave_gpu
		fi
		SGE_GPU=$(echo $free_gpu | xargs shuf -e | tr "\n" " " | awk '{ print $1 }')
		lockfile=/tmp/lock-gpu$SGE_GPU
		mkdir $lockfile
		;;

	[2-7])
	#Multi gpu job will try to get a master gpu first	
		if [[ "free_master_gpu_count" -lt "1" ]]; then
			echo "NOT ENOUGH MASTER GPUS, YOU JOB CANNOT BE EXECUTE IN $HOSTNAME."
			exit 1
		fi
		master_gpu=$(echo $free_master_gpu | awk '{ print $1 }')
		let "NGPUS-=1"
		if [[ "free_slave_gpu_count" -lt "$NGPUS" ]]; then
			the_other_master_gpu=$(echo $free_master_gpu | awk '{ print $2 }')
			free_slave_gpu="$free_slave_gpu $the_other_master_gpu"
		fi
		slave_gpu=$(echo $free_slave_gpu | xargs shuf -e | tr "\n" " " | cut -d" " -f 1-$NGPUS)
		SGE_GPU="$master_gpu $slave_gpu"

		for device_id in $SGE_GPU; do
			lockfile=/tmp/lock-gpu$device_id
			mkdir $lockfile
		done
		;;

	8)
	#8 gpu job will work well with following arrangement
		SGE_GPU="2 6 1 5 0 4 3 7"
		for device_id in $SGE_GPU; do
			lockfile=/tmp/lock-gpu$device_id
			mkdir $lockfile
		done
		;;
	esac
fi

# Set the environment.
echo SGE_GPU="$(echo $SGE_GPU | sed -e 's/^ //' | sed -e 's/ /,/g')" >> $ENV_FILE
exit 0
