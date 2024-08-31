#!/bin/bash

PIPELINES_ROOT=$(pwd)
if [ -z "${PIPELINES_ROOT:-}" ]; then
	echo "root dir path not defined" >&2
	exit 1
fi

if [ -f "${PIPELINES_ROOT}/utils" ]; then
	. $PIPELINES_ROOT/utils
else
	echo "failed to load utilities" >&2
	exit 1
fi

if [ -f "${PIPELINES_ROOT}/pipelines-env" ]; then
	. $PIPELINES_ROOT/pipelines-env
else
	echo "failed to load environment" >&2
	exit 1
fi

PIPELINES_CONFIG_FILE=$1

declare -A REQUIRED_VARIABLES
REQUIRED_VARIABLES=(
	["PIPELINES_CONFIG_FILE"]="config file path not defined"
)

cfn_test_vars REQUIRED_VARIABLES
if [[ $? -ne 0 ]]; then
	exit $?
fi

cfn_info "using config $PIPELINES_CONFIG_FILE"

while read -r line
do
	cfn_info "running pipeline for $line"
	$line/main.sh "$line" "$PIPELINES_ROOT/utils"
	
	if [ $? -ne 0 ]; then
		cfn_error "error while executing ${line}/main.sh"
		exit $?
	fi

	cfn_info "sleeping for 10 seconds . . ."	
	sleep 10
done < "$PIPELINES_CONFIG_FILE"
