#!/bin/bash

LOAD=''
RAM=''

function response() {

	get_load
	get_ram_usage

	load_raw=$(echo -e ${LOAD})
	ram_raw=$(echo -e ${RAM})
	content_lenght="Content-Length: $((${#load_raw} + ${#ram_raw}))\r\n"

	echo -en "HTTP/1.1 200 OK\r\n"
    echo -en "Content-Type: text/plain\r\n"
    echo -en "Connection: close\r\n"
	echo -en ${content_lenght}
    echo -en "\r\n"
	echo -en ${LOAD}
	echo -en ${RAM}
	
}

function get_load() {

	load_curr_1=$(cat /proc/loadavg | awk -F" " "{print \$1}")
	load_curr_5=$(cat /proc/loadavg | awk -F" " "{print \$2}")
	load_curr_15=$(cat /proc/loadavg | awk -F" " "{print \$3}")
	
	LOAD=$(echo "load_1=${load_curr_1}\nload_5=${load_curr_5}\nload_15=${load_curr_15}")

}

function get_ram_usage() {
	
	total=$(free | awk '/Mem/ {print $2}')
	free=$(free | awk '/Mem/ {print $4}')
	available=$(free | awk '/buffers\/cache/ {print $4}')
	free_percentage=$(echo "scale=2; ${free}*100/${total}" | bc)
	available_percentage=$(echo "scale=2; ${available}*100/${total}" | bc)
	
	RAM="\ntotal=${total}\nfree=${free}\navailable=${available}\nfree_percentage=${free_percentage}\navailable_percentage=${available_percentage}"

}

#get_load
#get_ram_usage
response
