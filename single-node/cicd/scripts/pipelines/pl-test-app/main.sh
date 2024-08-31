#!/bin/bash

CURRENT_DIRECTORY=$1
if [ -z "${CURRENT_DIRECTORY:-}" ]; then
        echo "Error: root dir path not defined" >&2
        exit 1
fi

UTILS_PATH=$2
if [ -f "${UTILS_PATH}" ]; then
        . $UTILS_PATH
else
        echo "Error: failed to load utilities" >&2
        exit 1
fi

cfn_info "current directory is $CURRENT_DIRECTORY"

declare -A REQUIRED_VARIABLES
REQUIRED_VARIABLES=(
	["APP_NAME"]="app name not defined"
	["CLONE_KEY_FILE"]="clone key file not defined"
	["CLONE_BRANCH"]="clone branch not defined"
	["CLONE_TO_DIR"]="target directory for cloning is not defined"
	["MAVEN_HOME"]="MAVEN_HOME not defined"
	["JAVA_HOME"]="JAVA_HOME not defined"
	["FORCE_DEPLOY"]="force deploy not defined"
)

if [[ "$FORCE_DEPLOY" == true ]]; then
	cfn_info "FORCE DEPLOY: ON"
else
	cfn_info "FORCE DEPLOY: OFF"
fi

cfn_exit_if_file_ne $CURRENT_DIRECTORY/pipeline-env
. $CURRENT_DIRECTORY/pipeline-env

cfn_test_vars REQUIRED_VARIABLES
cfn_exit_if_error $? "error while testing variables"

stage_clone () {
	cfn_info "\t--stage clone--"

	export GIT_SSH_COMMAND="ssh -i ${CURRENT_DIRECTORY}/${CLONE_KEY_FILE}"

	if [ ! -d "${CURRENT_DIRECTORY}/${CLONE_TO_DIR}" ]; then
		git clone -b ${CLONE_BRANCH} git@github.com:rd-raven/pipeline-test-app.git ${CURRENT_DIRECTORY}/${CLONE_TO_DIR}
		cfn_exit_if_error $? "error while cloning"
	else
		cfn_info "repository already cloned"
	fi

	cd $CURRENT_DIRECTORY/$CLONE_TO_DIR
	git checkout ${CLONE_BRANCH} > /dev/null 2>&1

	local CURRENT_REVISION=$(git rev-parse HEAD)
	local REMOTE_REVISION=$(git ls-remote origin ${CLONE_BRANCH} | awk '{print $1}')

	if [ "$CURRENT_REVISION" == "$REMOTE_REVISION" ]; then
		if [[ "$FORCE_DEPLOY" == true ]]; then
			cfn_info "-- FORCE DEPLOY --"
		else
			cfn_info "branch already at latest revision ${REMOTE_REVISION}, exiting current pipeline"
			exit 0
		fi
	fi
	
	if [[ "$FORCE_DEPLOY" != true ]]; then
		cfn_info "origin is ahead, fetching origin"
		git fetch origin ${CLONE_BRANCH}
	fi

	cfn_exit_if_dir_ne ${CURRENT_DIRECTORY}/${CLONE_TO_DIR}
	local LOCAL_VERSION=$(git show ${CLONE_BRANCH}:VERSION)
	local REMOTE_VERSION=$(git show origin/${CLONE_BRANCH}:VERSION)

	if [[ "$LOCAL_VERSION" == "$REMOTE_VERSION" ]]; then
		if [[ "$FORCE_DEPLOY" == true ]]; then
			cfn_info "-- FORCE DEPLOY --"
		else
			cfn_info "already at latest version ${REMOTE_VERSION}, exiting current pipeline"
			exit 0
		fi
	fi

	git merge
	cfn_exit_if_error $? "error while merging remote, cannot continue, exiting"
	cfn_info "merging successful"

	cd $CURRENT_DIRECTORY
}

stage_build () {
	cfn_info "\t--stage build--"

	cfn_exit_if_dir_ne ${CURRENT_DIRECTORY}/${CLONE_TO_DIR}
	cd ${CURRENT_DIRECTORY}/${CLONE_TO_DIR}

	${MAVEN_HOME}/bin/mvn --version
	cfn_exit_if_error $? "error while checking maven version"

	${MAVEN_HOME}/bin/mvn clean compile test package
	cfn_exit_if_error $? "error while maven build"
	
	cd ${CURRENT_DIRECTORY}
}

stage_image () {
	cfn_info "\t--stage build cri image--"

	cfn_exit_if_dir_ne ${CURRENT_DIRECTORY}/${CLONE_TO_DIR}
	cd ${CURRENT_DIRECTORY}/${CLONE_TO_DIR}

	ls
	APP_VERSION=$(cat VERSION)
	cfn_info "removing already existing image tars"
	rm ${CURRENT_DIRECTORY}/${APP_NAME}.*.tar >> /dev/null 2>&1

	docker build --tag "${APP_NAME}:v${APP_VERSION}" .
	cfn_exit_if_error $? "error while building cri image"

	cfn_info "saving cri image to tar ${CURRENT_DIRECTORY}/${APP_NAME}.${APP_VERSION}.tar"
	docker image save -o "${CURRENT_DIRECTORY}/${APP_NAME}:v${APP_VERSION}.tar" "${APP_NAME}:v${APP_VERSION}"
	cfn_info "image saved to ${CURRENT_DIRECTORY}/${APP_NAME}:v${APP_VERSION}.tar successfully"
	

	cfn_info "removing old images from containerd"
	ctr image list | grep ${APP_NAME} | awk '{print $1}' | xargs -I{} ctr image remove {}

	cfn_info "adding current new version image to containerd ${APP_NAME}:v${APP_VERSION}"
	ctr image import "${CURRENT_DIRECTORY}/${APP_NAME}:v${APP_VERSION}.tar"

	cd ${CURRENT_DIRECTORY}
}

stage_deploy () {
	cfn_info "\t--stage deploy--"

	cd ${CURRENT_DIRECTORY}/${APP_NAME}
	helm upgrade -i ${APP_NAME} charts --set appImage=${APP_NAME}:v${APP_VERSION}
	cd ${CURRENT_DIRECTORY}
}

stage_clone
stage_build
stage_image
stage_deploy
