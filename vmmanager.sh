#!/bin/bash


# VM Manager config
HOME_PATH='/usr/local/vmmanager/'
LOG_NAME='vmmanager'
VM_CONFIG_PATH='/etc/libvirt/qemu/'
VM_MANAGER_CONFIG_FILE='/usr/local/vmmanager/vm_config.csv'
VM_INFO_PORT='9299'
VM_LA_TRESHOLD_UP='90'
VM_LA_TRESHOLD_DOWN='30'
VM_RAM_TRESHOLD_UP='80'
VM_RAM_TRESHOLD_DOWN='40'
#VM_UPDATE_DELAY='20'
VM_TOTAL_CPU_LIMIT=16
VM_TOTAL_RAM_LIMIT=26
VM_TOTAL_RAM_KB_LIMIT=$(echo "${VM_TOTAL_RAM_LIMIT}*1024*1024" | bc)
WAIT_FOR_START_FIRST_DELAY='45'
WAIT_FOR_START_DELAY='10'
WAIT_FOR_START_TRESHOLD='120'
WAIT_FOR_STOP_FIRST_DELAY='10'
WAIT_FOR_STOP_DELAY='5'
WAIT_FOR_STOP_TRESHOLD='120'

# VM config defaults
CPU_MIN_DEF=1
CPU_MAX_DEF=8
MEM_MIN_DEF=1
MEM_MAX_DEF=8
CPU_BALANCE_LOGIC_DEF='2:1;8:2;16:4'
MEM_BALANCE_LOGIC_DEF='2:1;8:2;16:4'

# Global variables (DO NOT EDIT!!!)
VM_NAME=''
CPU_MIN=''
CPU_MAX=''
CPU_CURR=''
MEM_MIN=''
MEM_MIN_KB=''
MEM_MAX=''
MEM_MAX_KB=''
MEM_CURR_KB=''
CPU_BALANCE_LOGIC=''
MEM_BALANCE_LOGIC=''
VM_TOTAL_CPU=0
VM_TOTAL_RAM_KB=0
VM_TOTAL_RAM=''
VM_LA=''
VM_RAM=''


function log {
	
	log_file="${HOME_PATH}/logs/${LOG_NAME}-`date +%Y.%m.%d`.log"
	now=$(date "+%Y-%m-%d %H:%M:%S:%N" | cut -c1-23)
	log_data="$1"

	# log
	echo -e "${now}   ${log_data}" >> ${log_file}

}

function vm_resource_setup_total() {

	log "Get total CPU and RAM assigned to VMs..."

	while IFS=',' read VM_NAME cpu_min_conf cpu_max_conf mem_min_conf mem_max_conf cpu_balance_logic_conf mem_balance_logic_conf
	do
		if [ "${VM_NAME}" != "vm" ]
		then
			VM_TOTAL_CPU=$(echo "${VM_TOTAL_CPU}+$(vm_config_read 'cpu')" | bc)
			VM_TOTAL_RAM_KB=$(echo "${VM_TOTAL_RAM_KB}+$(vm_config_read 'ram')" | bc)
		fi
	done < ${VM_MANAGER_CONFIG_FILE}
	
	VM_TOTAL_RAM=$(echo "scale=2; ${VM_TOTAL_RAM_KB}/1024/1024" | bc)
	log "Total CPU assigned: ${VM_TOTAL_CPU}"
	log "Total RAM assigned: ${VM_TOTAL_RAM_KB}kB (${VM_TOTAL_RAM}GB)"

}


function wait_for() {

	action=$1 # start stop
	response_code='99'
	domstate='running'
	
	case ${action} in
		'start')
			
			log "Checking if VM ${VM_NAME} Apache is started..."
			log "Waiting for ${WAIT_FOR_START_FIRST_DELAY} seconds before first check..."
			sleep ${WAIT_FOR_START_FIRST_DELAY}
		
			until [ "${response_code}" == '0' ]
			do
				curl -s -m 2 http://${VM_NAME} > /dev/null
				response_code=$?
				
				if [ "${response_code}" != '0' ]
				then
					log "Apache still not listening, waiting for extra ${WAIT_FOR_START_DELAY} seconds..."
					sleep ${WAIT_FOR_START_DELAY}
				fi
			done
			
			log "Apache on VM ${VM_NAME} started"
			
		;;
		'stop')
			
			log "Checking if VM ${VM_NAME} is shut off..."
			log "Waiting for ${WAIT_FOR_STOP_FIRST_DELAY} seconds before first check..."
			sleep ${WAIT_FOR_STOP_FIRST_DELAY}
		
			until [ "${domstate}" == 'shut off' ]
			do
				domstate=$(virsh domstate ${VM_NAME})
				
				if [ "${domstate}" != 'shut off' ]
				then
					log "VM still running, waiting for extra ${WAIT_FOR_STOP_DELAY} seconds..."
					sleep ${WAIT_FOR_STOP_DELAY}
				fi
			done
			
			log "VM ${VM_NAME} is shut off"

		;;
	esac

}

function vm_config_set() {

	vm_set_new_cpu=$1
	vm_set_new_ram=$2
	
	if [ "${vm_set_new_cpu}" != '0' ]
	then
		log "Setting VM ${VM_NAME} CPU to ${vm_set_new_cpu} cores"
		virsh setvcpus ${VM_NAME} ${vm_set_new_cpu} --config --maximum
		virsh setvcpus ${VM_NAME} ${vm_set_new_cpu} --config
		
		VM_TOTAL_CPU=$(echo "${VM_TOTAL_CPU}-${CPU_CURR}+${vm_set_new_cpu}" | bc)
		
	fi
	
	if [ "${vm_set_new_ram}" != '0' ]
	then
		log "Setting VM ${VM_NAME} RAM to ${vm_set_new_ram}kb" 
		virsh setmaxmem ${VM_NAME} ${vm_set_new_ram} --config
		virsh setmem ${VM_NAME} ${vm_set_new_ram} --config
		
		VM_TOTAL_RAM_KB=$(echo "${VM_TOTAL_RAM_KB}-${MEM_CURR_KB}+${vm_set_new_ram}" | bc)
		VM_TOTAL_RAM=$(echo "scale=2; ${VM_TOTAL_RAM_KB}/1024/1024" | bc)
	fi

}

function vm_config_read() {

	vm_config_file=${VM_CONFIG_PATH}/${VM_NAME}.xml
	vm_property=$1 # cpu ram
	
	case "${vm_property}" in
		'cpu')
			xmlstarlet sel -t -m '//vcpu' -v . ${vm_config_file}
		;;
		'ram')
			xmlstarlet sel -t -m '//memory' -v . ${vm_config_file}
		;;
	esac

}

function vm_get_new_value() {

	vm_property=$1 # ram cpu
	vm_change=$2 # more less
	increment_apply=1
	
	if [ ${vm_change} == 'more' ] ; then operand='+'; else operand='-'; fi
	
	if [ "${vm_property}" == 'ram' ]
	then
		log "Calculating new RAM size..."
		
		#vm_current_ram_kb=$(vm_config_read 'ram')
		vm_current_ram_gb=$(echo "scale=2; ${MEM_CURR_KB}/1024/1024" | bc)
		
		for config in $(echo ${MEM_BALANCE_LOGIC} | sed 's|;| |g')
		do
			limit=$(echo ${config} | awk -F':' '{print $1}')
			increment=$(echo ${config} | awk -F':' '{print $2}')
			if (( $(echo "${vm_current_ram_gb} >= ${limit}" | bc -l)  ))
			then
				increment_apply=${increment}
			else
				
				break
			fi
		done

		ram_new_value=$(echo "${MEM_CURR_KB}${operand}${increment_apply}*1024*1024" | bc)
		
		if (( $(echo "${ram_new_value} < ${MEM_MIN_KB}" | bc -l) ))
		then
			ram_new_value=${MEM_MIN_KB}
		else
			if (( $(echo "${ram_new_value} > ${MEM_MAX_KB}" | bc -l) ))
			then
				ram_new_value=${MEM_MAX_KB}
			fi
		fi
		
		log "New RAM size: ${ram_new_value}"
		echo ${ram_new_value}
		
	else
		log "Calculating new CPU count..."
		#vm_current_cpu=$(vm_config_read 'cpu')
		
		for config in $(echo ${CPU_BALANCE_LOGIC} | sed 's|;| |g')
		do
			limit=$(echo ${config} | awk -F':' '{print $1}')
			increment=$(echo ${config} | awk -F':' '{print $2}')
			if (( $(echo "${CPU_CURR} >= ${limit}" | bc -l)  ))
			then
				increment_apply=${increment}
			else
				break
			fi
		done

		cpu_new_value=$(echo "${CPU_CURR}${operand}${increment_apply}" | bc)
		if (( $(echo "${cpu_new_value} < ${CPU_MIN}" | bc -l) ))
		then
			cpu_new_value=${CPU_MIN}
		else
			if (( $(echo "${cpu_new_value} > ${CPU_MAX}" | bc -l) ))
			then
				cpu_new_value=${CPU_MAX}
			fi
		fi
		
		log "New CPU count: ${cpu_new_value}"
		echo ${cpu_new_value}
		
	fi
	
	
}

function vm_update() {

	change_cpu=''
	change_ram=''
	vm_cpu_new=0
	vm_ram_new=0
	local OPTIND
	
	while getopts ":c:r:v:" opt; do
		case "${opt}" in
			c)
				change_cpu="${OPTARG}"
				;;
			r)
				change_ram="${OPTARG}"
				;;
		esac
	done
	
	if [ ! -z ${change_cpu} ]
	then
		vm_cpu_new=$(vm_get_new_value 'cpu' "${change_cpu}")
	fi
	
	if [ ! -z ${change_ram} ]
	then
		vm_ram_new=$(vm_get_new_value 'ram' "${change_ram}")
	fi
	
	log "Checking host limits..."
	vm_total_cpu_new=$(echo "${VM_TOTAL_CPU}-${CPU_CURR}+${vm_cpu_new}" | bc)
	vm_total_ram_new=$(echo "${VM_TOTAL_RAM_KB}-${MEM_CURR_KB}+${vm_ram_new}" | bc)
	
	if (( $(echo "${vm_total_cpu_new}>${VM_TOTAL_CPU_LIMIT}" | bc -l) ))
	then
		log "Total VMs CPU count with new ${VM_NAME} configuration exceedes host limit (${vm_total_cpu_new}>${VM_TOTAL_CPU_LIMIT}), skipping CPU update"
		vm_cpu_new=0
	else
		log "Total VMs CPU count with new ${VM_NAME} configuration under host limit"
	fi
	
	if (( $(echo "${vm_total_ram_new}>${VM_TOTAL_RAM_KB_LIMIT}" | bc -l) ))
	then
		log "Total VMs RAM with new ${VM_NAME} configuration exceedes host limit (${vm_total_ram_new}>${VM_TOTAL_RAM_KB_LIMIT}), skipping RAM update"
		vm_ram_new=0
	else
		log "Total VMs RAM with new ${VM_NAME} configuration under host limit"
	fi

	if [[ "${vm_cpu_new}" == "0" || "${vm_cpu_new}" == "${CPU_CURR}" ]] && [[ "${vm_ram_new}" == "0" || "${vm_ram_new}" == "${MEM_CURR_KB}" ]]
	then
		log "New values same as current, skipping VM ${VM_NAME} update."
	else
	
		log "Sending shutdown comand to ${VM_NAME}..."
		virsh shutdown ${VM_NAME}
		wait_for 'stop'
		
		
		vm_config_set ${vm_cpu_new} ${vm_ram_new}
		sleep 1
		
		log "Sending start comand to ${VM_NAME}" 
		virsh start ${VM_NAME}
		wait_for 'start'
		
		log "Total CPU and RAM assigned to VMs after update..."
		log "Total CPU assigned: ${VM_TOTAL_CPU}"
		log "Total RAM assigned: ${VM_TOTAL_RAM_KB}kB (${VM_TOTAL_RAM}GB)"
		
	fi

}

function vm_info_get () {

	log "Getting VM ${VM_NAME} current RAM and CPU info..."
	response=$(curl http://${VM_NAME}:${VM_INFO_PORT})
	
	for info in $response
	do
		param=$(echo ${info} | awk -F'=' '{print $1}')
		value=$(echo ${info} | awk -F'=' '{print $2}')
		
		case ${param} in
			load_5)
				VM_LA=${value}
				log "VM ${VM_NAME} LA(5): ${VM_LA}"
			;;
			available_percentage)
				VM_RAM=${value}
				log "VM ${VM_NAME} available RAM: ${VM_RAM}"
			;;
		esac
	
	done

}

function vm_monitor() {

	local vm_cpu_change
	local vm_ram_change

	log "VM check STARTED!"
	vm_resource_setup_total
	log "Start iterating trough nodes..."
	
	while IFS=',' read VM_NAME cpu_min_conf cpu_max_conf mem_min_conf mem_max_conf cpu_balance_logic_conf mem_balance_logic_conf
	do
		if [ "${VM_NAME}" != "vm" ]
		then
		
			log "START checking VM ${VM_NAME}!"
			log "VM manager setup for VM ${VM_NAME} => CPU min: ${cpu_min_conf}; CPU max: ${cpu_max_conf}; RAM min: ${mem_min_conf}; RAM max: ${mem_max_conf}; CPU balance logic: ${cpu_balance_logic_conf}; RAM balance logic: ${mem_balance_logic_conf}"
		
			if [ ! -z "${cpu_min_conf}" ] ; then CPU_MIN="${cpu_min_conf}"; else CPU_MIN="${CPU_MIN_DEF}"; fi
			if [ ! -z "${cpu_max_conf}" ] ; then CPU_MAX="${cpu_max_conf}"; else CPU_MAX="${CPU_MAX_DEF}"; fi
			if [ ! -z "${mem_min_conf}" ] ; then MEM_MIN="${mem_min_conf}"; else MEM_MIN="${MEM_MIN_DEF}"; fi
			MEM_MIN_KB=$(echo "${MEM_MIN}*1024*1024" | bc)
			if [ ! -z "${mem_max_conf}" ] ; then MEM_MAX="${mem_max_conf}"; else MEM_MAX="${MEM_MAX_DEF}"; fi
			MEM_MAX_KB=$(echo "${MEM_MAX}*1024*1024" | bc)
			if [ ! -z "${cpu_balance_logic_conf}" ] ; then CPU_BALANCE_LOGIC="${cpu_balance_logic_conf}"; else CPU_BALANCE_LOGIC="${CPU_BALANCE_LOGIC_DEF}"; fi
			if [ ! -z "${mem_balance_logic_conf}" ] ; then MEM_BALANCE_LOGIC="${mem_balance_logic_conf}"; else MEM_BALANCE_LOGIC="${MEM_BALANCE_LOGIC_DEF}"; fi
			
			log "VM manager setup after loading defaults for VM ${VM_NAME} => CPU min: ${CPU_MIN}; CPU max: ${CPU_MAX}; RAM min: ${MEM_MIN}; RAM max: ${MEM_MAX}; CPU balance logic: ${CPU_BALANCE_LOGIC}; RAM balance logic: ${MEM_BALANCE_LOGIC}"
			
			log "Getting current VM setup..."
			CPU_CURR=$(vm_config_read 'cpu')
			MEM_CURR_KB=$(vm_config_read 'ram')
			log "Current VM setup => CPU: ${CPU_CURR}; RAM: ${MEM_CURR_KB}kB"
			
			vm_info_get
			
			log "Calculating resource usage..."
			vm_cpu_usage=$(echo "scale=2; ${VM_LA}/${CPU_CURR}*100" | bc)
			vm_ram_usage=$(echo "scale=2; 100-${VM_RAM}" | bc)
			log "CPU usage: ${vm_cpu_usage}%"
			log "RAM usage: ${vm_ram_usage}%"
			
			log "Checking tresholds..."
			if (( $(echo "${vm_cpu_usage} > ${VM_LA_TRESHOLD_UP}" | bc -l) ))
			then
				log "CPU usage higher than UP treshold: ${vm_cpu_usage} > ${VM_LA_TRESHOLD_UP}"
				vm_cpu_change='-c more'
			else
				if (( $(echo "${vm_cpu_usage} < ${VM_LA_TRESHOLD_DOWN}" | bc -l) ))
				then
					log "CPU usage lower than DOWN treshold: ${vm_cpu_usage} < ${VM_LA_TRESHOLD_DOWN}"
					vm_cpu_change='-c less'
				else
					log "CPU usage within optimum range: ${VM_LA_TRESHOLD_DOWN} - ${VM_LA_TRESHOLD_UP}"
				fi
			fi
			
			if (( $(echo "${vm_ram_usage} > ${VM_RAM_TRESHOLD_UP}" | bc -l) ))
			then
				log "RAM usage higher than UP treshold: ${vm_ram_usage} > ${VM_RAM_TRESHOLD_UP}"
				vm_ram_change='-r more'
			else
				if (( $(echo "${vm_ram_usage} < ${VM_RAM_TRESHOLD_DOWN}" | bc -l) ))
				then
					log "RAM usage lower than DOWN treshold: ${vm_ram_usage} < ${VM_RAM_TRESHOLD_DOWN}"
					vm_ram_change='-r less'
				else
					log "RAM usage within optimum range: ${VM_RAM_TRESHOLD_DOWN} - ${VM_RAM_TRESHOLD_UP}"
				fi
			fi
			
			if [ ! -z "${vm_cpu_change}" ] || [ ! -z "${vm_ram_change}" ]
			then
				vm_update ${vm_cpu_change} ${vm_ram_change}
			fi
			
			log "Checking VM ${VM_NAME} FINNISHED!"
			
		fi
		
	done < ${VM_MANAGER_CONFIG_FILE}

	log "Iterating trough nodes finnished."
	log "VM check FINNISHED!"
	log "*******************"

}

vm_monitor

