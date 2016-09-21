#!/bin/bash

# --------- License Info ---------
# Copyright (c) 2013 Emind Systems Ltd. - http://www.emind.co
# This file is part of Emind Systems DevOps Toolset.
# Emind Systems DevOps Toolset is free software: you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, either version 3 of the License, or (at your option) any later version.
# Emind Systems DevOps Toolset is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License for more details.
# You should have received a copy of the GNU General Public License along with Emind Systems DevOps Toolset. If not, see http://www.gnu.org/licenses.

SERVER_URL=""
API_KEY=""
TIME_DIFF=""
STREAM_NAME=""
INVERT="OFF"
ALARM_STATE="UNKNOWN"
SSL="ON"

function check_jq {
    jq_cmd=`which jq`
    if [ ! -e ${jq_cmd} ]; then
        echo "jq not installed"
        exit 95
    fi
}

function write_log (){
        logger -t "check_graylog_stream" "pid=$$ Msg=$*"
}

function get_streams_json()
{
    if [ ${SSL} = "OFF" ]; then
		curl -s -o ${2} ${3} ${1}
    elif [ ${SSL} = "ON" ]; then
		curl -k -s -o ${2} ${3} ${1}
    fi

	OUT=$?

    if [ ${OUT} -ne 0 ]; then
		write_log "failed to fetch json from ${1}"
        exit 97
    fi
}

function get_stream_index
{
    TARGET_STREAM_ID=$1
    STREAM_INDEX=0
    CURRENT_STREAM_ID=""
    SEARCH_STATUS=false
	  FIRST_STREAM_ID=$(cat ${GRAYLOG2_STREAMS_FILE} | jq -r ".streams[${STREAM_INDEX}].id")
    write_log "FIRST_STREAM_ID=${FIRST_STREAM_ID}"
    while true; do
		#CURRENT_STREAM_ID=$(jq -e ${STREAM_INDEX} -e "title" -u < ${GRAYLOG2_STREAMS_FILE})
    CURRENT_STREAM_ID=$(cat ${GRAYLOG2_STREAMS_FILE} | jq -r ".streams[${STREAM_INDEX}].id")
    if [ "${TARGET_STREAM_ID}" == "${CURRENT_STREAM_ID}" ]; then
			SEARCH_STATUS=true

			break
		elif [ ${STREAM_INDEX} -gt 0 ] && [ "${CURRENT_STREAM_ID}" == "${FIRST_STREAM_ID}" ]; then
			break
		fi
		STREAM_INDEX=$(( ${STREAM_INDEX} + 1 ))
    done
	write_log "TARGET_STREAM_ID=${TARGET_STREAM_ID} STREAM_INDEX=${STREAM_INDEX}"
}

function get_perf_count()
{
	VALUE=0

	OBJECT_COUNT=$(jq -r '.alerts | length' < ${1})
	if [ ${OBJECT_COUNT} -gt 0 ]; then
	    LAST_OBJECT_IDX=$(expr ${OBJECT_COUNT} - 1)
	    YOUNGEST_OBJECT_TIMESTAMP=$(jq -r '.alerts[0].triggered_at' < ${1})
	    OLDEST_OBJECT_TIMESTAMP=$(jq -r ".alerts[${LAST_OBJECT_IDX}].triggered_at" < ${1})

	    #Time difference in seconds between first and last object
      YOUNGEST_OBJECT_TIMESTAMP=$(date -d"${YOUNGEST_OBJECT_TIMESTAMP}" +%s)
      OLDEST_OBJECT_TIMESTAMP=$(date -d"${OLDEST_OBJECT_TIMESTAMP}" +%s)
	    TIME_DIFF=$(echo "scale=0; ${YOUNGEST_OBJECT_TIMESTAMP} - ${OLDEST_OBJECT_TIMESTAMP}" | bc -l)

	    #Make sure not to divide by 0
	    VALID=$(echo "${TIME_DIFF} > 0" | bc -l)
	    if [ ${VALID} -gt 0 ]; then
		#Performance value (per minute average)
		VALUE=$(echo "scale=2; ${OBJECT_COUNT} * 60 / ${TIME_DIFF}" | bc -l)
	    fi
	fi

	echo $VALUE
}

while getopts i:g:k:t:s:c flag; do
case $flag in
    g)
        SERVER_URL=$OPTARG
        ;;
    k)
        API_KEY=$OPTARG
        ;;
    t)
        TIME_DIFF=$OPTARG
        ;;
    s)
        STREAM_NAME=$OPTARG
        ;;
    i)
        INVERT="ON"
        ;;
    c)
        SSL="ON"
        ;;
  esac
done

if [ "x${SERVER_URL}" == "x" ] || [ "x${API_KEY}" == "x" ] || [ "x${TIME_DIFF}" == "x" ] || [ "x${STREAM_NAME}" == "x" ]; then
echo "Missing input parameter"
        echo "Usage: $0 -g <graylog server url> -k <graylog api_key> -t <alarm age> -s <stream name>"
        exit 96
fi

check_jq

write_log "CMD Params: -g ${SERVER_URL} -k ${API_KEY} -t ${TIME_DIFF} -s ${STREAM_NAME}"

STREAM_URL="${SERVER_URL}/streams"
GRAYLOG2_STREAMS_FILE="/tmp/$$.json"

get_streams_json "${STREAM_URL}" "${GRAYLOG2_STREAMS_FILE}" "-u ${API_KEY}:token"
get_stream_index ${STREAM_NAME}
STREAM_ID=$(jq -r ".streams[${STREAM_INDEX}].id" < ${GRAYLOG2_STREAMS_FILE} 2> /dev/null)

LAST_ALARM=$(curl -s -k -u 11b9i6j0lteqpv30gr7l81pp51lt7d6l3ehd3jm81sahfi4be4d6:token https://an-log-v1-nd.angers.perf1.net:443/api/streams/${STREAM_ID}/alerts?since=600 | jq -r ".alerts[0].triggered_at")

rm -rf ${GRAYLOG2_STREAMS_FILE}

if [ ${SEARCH_STATUS} == false ]; then
echo "Unknown Stream:${STREAM_NAME}"
        write_log "Unknown Stream:${STREAM_NAME}"
        exit 98
fi

if [ "${LAST_ALARM}" != "" ]; then
  LAST_ALARM=$(date -d"${LAST_ALARM}" +%s)
	ALARM_AGE=$(expr $(date +%s) - ${LAST_ALARM})
  ALARM_TIME=$(date --date="${ALARM_AGE} seconds ago" -u )
else
	ALARM_AGE=""
fi

if [ "${ALARM_AGE}" != "" ] && [ ${ALARM_AGE} -lt ${TIME_DIFF} ]; then
	ALARM_STATE="ON"
else
	ALARM_STATE="OFF"
fi

if [ "${ALARM_STATE}" = "ON" ] && [ "$INVERT" = "OFF" ]; then
	EXIT_CODE=2
elif [ "${ALARM_STATE}" = "OFF" ] && [ "$INVERT" = "OFF" ]; then
	EXIT_CODE=0
elif [ "${ALARM_STATE}" = "ON" ] && [ "$INVERT" = "ON" ]; then
	EXIT_CODE=0
elif [ "${ALARM_STATE}" = "OFF" ] && [ "$INVERT" = "ON" ]; then
	EXIT_CODE=2
else
	EXIT_CODE=99
fi

#Get performance data
PERF_STREAM_URL="${SERVER_URL}/streams/${STREAM_ID}/alerts"
get_streams_json "${PERF_STREAM_URL}" "${GRAYLOG2_STREAMS_FILE}" "-u ${API_KEY}:token"
PERF_VALUE=$(get_perf_count ${GRAYLOG2_STREAMS_FILE})
rm -rf ${GRAYLOG2_STREAMS_FILE}

STREAM_NAME=$(curl -k -s -u 11b9i6j0lteqpv30gr7l81pp51lt7d6l3ehd3jm81sahfi4be4d6:token https://an-log-v1-nd.angers.perf1.net/api/streams/${STREAM_ID}/ | jq .title )
write_log "Alarm:${ALARM_STATE} - Stream:${STREAM_NAME} Last-alarm:${ALARM_TIME} Invert:$INVERT | avg-msg-min=${PERF_VALUE}"
write_log "EXIT_CODE=${EXIT_CODE}"


echo "Alarm:${ALARM_STATE} - Stream:${STREAM_NAME} Last-alarm:${ALARM_TIME} | avg-msg-min=${PERF_VALUE};"
exit ${EXIT_CODE}
