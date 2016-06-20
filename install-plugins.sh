#!/bin/bash

# Resolve dependencies and download plugins given on the command line
#
# FROM jenkins
# RUN install-plugins.sh docker-slaves github-branch-source

REF_DIR=${REF:-/usr/share/jenkins/ref/plugins}
FAILED="$REF_DIR/failed-plugins.txt"

function getLockFile() {
	echo "$REF_DIR/${1}.lock"
}

function download() {
	local plugin originalPlugin version lock ignoreLockFile
	plugin="$1"
	version="$2"
	ignoreLockFile="$3"
	lock="$(getLockFile "$plugin")"

	if [[ $ignoreLockFile ]] || mkdir "$lock" &>/dev/null; then
		if ! doDownload "$plugin" "$version"; then
			# some plugin don't follow the rules about artifact ID
			# typically: docker-plugin
			originalPlugin="$plugin"
			plugin="${plugin}-plugin"
			if ! doDownload "$plugin" "$version"; then
				echo "Failed to download plugin: $originalPlugin or $plugin" >&2
				echo "${originalPlugin}" >> "$FAILED"
				return 1
			fi
		fi

		resolveDependencies "$plugin"
	fi
}

function doDownload() {
	local plugin version url hpi
	plugin="$1"
	version="$2"
	hpi="$REF_DIR/${plugin}.hpi"

	if [[ -f $hpi ]]; then
		echo "Using provided plugin: $plugin"
		return 0
	fi

	if [[ $version ]]; then
		url="$JENKINS_UC/download/plugins/$plugin/$version/${plugin}.hpi"
	else
		url="$JENKINS_UC/latest/${plugin}.hpi"
	fi

	echo "Downloading plugin: $plugin from $url"
	curl -s -f -L "$url" -o "$hpi"
	return $?
}

function resolveDependencies() {	
	local plugin hpi dependencies
	plugin="$1"
	hpi="$REF_DIR/${plugin}.hpi"

	# ^M below is a control character, inserted by typing ctrl+v ctrl+m
	dependencies="$(unzip -p "$hpi" META-INF/MANIFEST.MF | sed -e 's###g' | tr '\n' '|' | sed -e 's#| ##g' | tr '|' '\n' | grep "^Plugin-Dependencies: " | sed -e 's#^Plugin-Dependencies: ##')"

	if [[ ! $dependencies ]]; then
		echo " > $plugin has no dependencies"
		return
	fi

	echo " > $plugin depends on $dependencies"

	IFS=',' read -a array <<< "$dependencies"

	for d in "${array[@]}"
	do
		plugin="$(cut -d':' -f1 - <<< "$d")"
		if [[ $d == *"resolution:=optional"* ]]; then	
			echo "Skipping optional dependency $plugin"
		else
			download "$plugin" &
		fi
	done
}

main() {
	local plugin version

	mkdir -p "$REF_DIR" || exit 1

	# Create lockfile manually before first run to make sure any explicit version set is used.
	echo "Creating initial locks..."
	for plugin in "$@"; do
		mkdir "$(getLockFile "${plugin%%@*}")"
	done

	echo -e "\nDownloading plugins..."
	for plugin in "$@"; do
		version=""

		if [[ $plugin =~ .*@.* ]]; then
			version="${plugin##*@}"
			plugin="${plugin%%@*}"
		fi

		download "$plugin" "$version" "true" &
	done				  
	wait

	if [[ -f $FAILED ]]; then
		echo -e "\nSome plugins failed to download!\n$(<"$FAILED")" >&2
		exit 1
	fi

	echo -e "\nCleaning up locks..."
	rm -rv "$REF_DIR"/*.lock
}

main "$@"