#!/bin/bash

#
# This file and its contents are supplied under the terms of the
# Common Development and Distribution License ("CDDL"), version 1.0.
# You may only use this file in accordance with the terms of version
# 1.0 of the CDDL.
#
# A full copy of the text of the CDDL should have accompanied this
# source.  A copy of the CDDL is also available via the Internet at
# http://www.illumos.org/license/CDDL.
#

#
# Copyright 2022 Joyent, Inc.
# Copyright 2025 MNX Cloud, Inc.
#

# shellcheck disable=1091

. /lib/sdc/usb-key.sh

eecho() {
	echo "$@" 1>&2
}

err() {
	eecho "$@"
	exit 1
}

fatal() {
	eecho
	if [[ -n "$1" ]]; then
		eecho "ERROR: $1"
	fi
	eecho
	exit 2
}

corrupt() {
	eecho "POSSIBLE CORRUPTION:" "$*"
	exit 3
}

# Only run in the global zone.
[[ "$(zonename)" == "global" ]] || err "Must run piadm in the global zone"

usage() {
	eecho ""
	eecho "Usage: piadm [-v] <command> [command-specific arguments]"
	eecho ""
	eecho "    piadm activate|assign <PI-stamp> [ZFS-pool-name]"
	eecho "    piadm avail"
	eecho "    piadm bootable [-d] [-e [-i <source>]] [-r] [ZFS-pool-name]"
	eecho "    piadm destroy|remove <PI-stamp> [ZFS-pool-name]"
	eecho "    piadm install <source> [ZFS-pool-name]"
	eecho "    piadm list <-H> [ZFS-pool-name]"
	eecho "    piadm update [ZFS-pool-name]"
	err ""
}

not_triton_CN() {
	if [[ "$TRITON_CN" == "yes" ]]; then
		err "The $1 command cannot be used on a Triton Compute Node"
	fi
}

not_triton_HN() {
	if [[ "$TRITON_HN" == "yes" ]]; then
		eecho "The $1 command cannot be used on a Triton Head Node"
		err "On a headnode, please use 'sdcadm platform'."
	fi
}

standalone_only() {
	not_triton_CN "$@"
	not_triton_HN "$@"
}

vecho() {
	if [[ $VERBOSE -eq 1 ]]; then
		# Verbose echoes invoked by -v go to stdout, not stderr.
		echo "$@"
	fi
}

declare bootfs
declare -a allbootfs
declare numbootfs

#
# Privilege check.  For now, lets just make sure we're root (user 0).
# NOTE: Global zone check was earlier, but some subcommands do NOT
# need privilege, so functionalize that check here for easy naming,
# and potential for more sophistication later.
#
privcheck() {
	[[ "$(id -u)" == 0 ]] || err "Must be root for $1"
}

#
# Inventory pools and bootable file systems.
#
getbootable() {
	IFS=" "
	# Use `mapfile -t` so bash array constructs can work.
	mapfile -t allbootfs < <(zpool list -Ho name,bootfs | \
		awk '{if ($2 != "-") print $2 }')
	numbootfs=${#allbootfs[@]}
}

declare activestamp
activestamp=$(uname -v | sed 's/joyent_//g')
declare installstamp

poolpresent() {
	local pool_len cmd
	pool_len="${#1}"
	# This seems a bit obtuse, but we need to pass the pool specification we
	# received on the command line to zpool verbatim, but having an empty
	# variable passed to zpool won't give us any valid output.
	if (( pool_len == 0 )); then
		zp_cmd=( zpool list )
	else
		zp_cmd=( zpool list "$1" )
	fi
	if ! "${zp_cmd[@]}" > /dev/null 2>&1 ; then
		eecho "Pool $1 not present"
		usage
	fi
}

# Common-code to obtain the bootable filesystem, and setting $bootfs
# to it.  Also checks that the PI stamp or source name is not empty.
# Takes a PI name or source name (which must not be blank) AND a pool
# (which can).
piname_present_get_bootfs() {
	if [[ "$1" == "" ]]; then
		eecho "Must specify a Platform Image"
		usage
	fi

	poolpresent "$pool"

	getbootable
	if [[ $numbootfs -gt 1 && "$2" == "" ]]; then
		eecho "Multiple bootable pools are available, please specify one"
		usage
	elif [[ "$2" == "" ]]; then
		# If we reach here, no more than one bootable pool.
		bootfs=${allbootfs[0]}
		if [[ "$bootfs" == "" ]]; then
			eecho "No bootable pools available..."
			usage
		fi
		pool=$(echo "$bootfs" | awk -F/ '{print $1}')
		vecho "Selecting lone boot pool $pool by default."
	else
		# If we reach here, the CLI specifies a known-present (passes
		# poolpresent()) pool in $2 and we have at least one to check
		# against..
		pool=$2
		bootfs=""
		for check in "${allbootfs[@]}"; do
			thispool=$(echo "$check" | awk -F/ '{print $1}')
			if [[ $thispool == "$pool" ]]; then
			    bootfs=$check
			    break
			fi
		done
		if [[ "$bootfs" == "" ]]; then
			eecho "Pool $pool does not appear to be bootable."
			usage
		fi
	fi
}

# Defined as a variable in case we need to add parameters (like -s) to it.
# WARNING:  Including -k for now.
CURL=( curl -ks -f --show-error)
VCURL=( curl -k -f --progress-bar)

vcurl() {
	if [[ $VERBOSE -eq 1 ]]; then
		# Verbose curls show progress.
		"${VCURL[@]}" "$@"
	else
		# Non-verbose ones do not.
		"${CURL[@]}" "$@"
	fi
}

# Default well-known source of SmartOS Platform Images
DEFAULT_URL_PREFIX=https://us-central.manta.mnx.io/Joyent_Dev/public/SmartOS/
# Default path for piadm's configuration
PIADM_CONF=/var/piadm/piadm.conf

# fetch_csum
#
# Fetches checksums using a platform file as the key.
#
# Arguments:
#   $1 - URL from where to fetch the PI from. The name of the PI
#   	 is expected to be the last path component of the URL,
#   	 or the literal string "latest".
#
# Environment Variables:
#   PIADM_NO_SUM     - If set to 1, skips checksum validation.
#   PIADM_SUM_URL    - If set, overrides the default URL used
#                      the checksum file used for platform images.
#
# Notes:
#   - If "latest" is used, up to 1024 PIs will be listed from ${URL_PREFIX}.
#     The last one is assumed to be the latest.
#   - On error, this function exits with code 1, following piadm(8)
#     convention: the error indicates a failure, but no changes were made
#     to the system.
declare csum_platform=""
declare stamp=""
fetch_csum() {
	if [[ -z "$csum_platform" ]]; then
		local platform_file
		if [[ "$1" != "latest" ]]; then
			IFS='/' read -ra array <<< "$1"
			platform_file="${array[-1]}"
			stamp="${array[-2]}"
		else
			#latest is a special case, we need find out stamp
			stamps_url="${URL_PREFIX%/}?limit=1024"
			stamp=$("${CURL[@]}" "${stamps_url}" |\
				json -ga -c "this.name.match(/Z$/)" | json -ag name |\
				sort  | tail -1; exit "${PIPESTATUS[0]}")
			code=$?
			if [[ $code -ne 0 ]]; then
				eecho "Curl failed fetching PI data from ${stamps_url}"
				return 1
			fi
			platform_file="smartos-${stamp}.iso"
		fi
		if [[ -z ${PIADM_SUM_URL} ]];then
			local csum_url="${URL_PREFIX}${stamp}/${PIADM_DIGEST_ALGORITHM:-md5}sums.txt"
		else
			local csum_url="${PIADM_SUM_URL}"
		fi
		csum_platform=$("${CURL[@]}"  "${csum_url}" |\
			awk -v pattern="${platform_file}"\
			'$0 ~ pattern { print $1; exit}'; exit "${PIPESTATUS[0]}")
		code=$?
		if [[ $code -ne 0 ]]; then
			eecho "fetching checksums from ${csum_url}"
			#force re-calculation of checksum on the next call.
			csum_platform=""
			stamp=""
			return 1
		fi
	fi
	echo "${csum_platform}"
	return 0
}

# validate_csum
#
# $1 is the URL from where the PI was downloaded.
# $2 is the on disk PI image that was download from $1.
#
# Error code will always be 1, following the piadm(8) convention where
# a return code of 1 means: an error has occurred, but no change was made.
# Environment variable PIADM_DIGEST_ALGORITHM controls the checksum
# algorithm used by digest(1), by default md5 is used.  
validate_csum() {
	if [[ $PIADM_NO_SUM -eq 1 ]]; then
		vecho "WARNING: Not using validation checksum"
		return 0
	fi
	published_csum=$(fetch_csum "$1")
	code=$?
	if [[ $code -ne 0 ]]; then
		eecho "Could not get checksum for PI exit code: ${code}"
		return 1
	fi
	local_csum=$(digest -a "${PIADM_DIGEST_ALGORITHM:-md5}" "${2}")
	code=$?
	if [[ $code -ne 0 ]]; then
		eecho "checksum failed for $2, algorithm used: ${PIADM_DIGEST_ALGORITHM}"
		return 1
	fi
	vecho "published_checksum: ${published_csum}"
	vecho "local_checksum:     ${local_csum}"
	if [[ "${published_csum}" != "${local_csum}" ]]; then
		eecho  "local file does not match published checksum"
		return 1
	fi
	return 0
}

#
# (Re)-Configure the default URL (and potentially other things in the future)
# using the configuration file (in $PIADM_CONF).
#
config_check() {
	# Can't do standalone_only per se as it errors out, but this only
	# applies to standalone SmartOS.
	if [[ "$TRITON_CN" == "yes" || "$TRITON_HN" == "yes" ]]; then
		return
	fi

        if grep -sq us-east.manta.joyent.com $PIADM_CONF ; then
            # If they have a broken config with the stale joyent name,
            # nuke it.
            printf 'WARNING: Removing stale image server ' >&2
            printf '(us-east.manta.joyent.com)\n' >&2
            rm "${PIADM_CONF:?}"
        fi

	OLD_DEFAULT="$DEFAULT_URL_PREFIX"
	if [[ -f $PIADM_CONF ]]; then
		. $PIADM_CONF
	else
		# We're creating $PIADM_CONF.
		# NOTE: On an installation this will disappear as /var is
		# on the ramdisk.
		vecho "Creating $PIADM_CONF"
		rm -rf $PIADM_CONF
		mkdir -p /var/piadm

		PIADM_CONFIG_VERSION=1
		cat <<EOF  > $PIADM_CONF
PIADM_CONFIG_VERSION=$PIADM_CONFIG_VERSION
PIADM_DIGEST_ALGORITHM=\${PIADM_DIGEST_ALGORITHM:-md5}
PIADM_NO_SUM=\${PIADM_NO_SUM:-0}
EOF

	fi

	# Reality checks for PIADM_CONFIG_VERSION and more.
	# Currently we only have one version. In the future, we will need to
	# change that.  We will do strict string comparisons too, instead of
	# numeric ones, to harden against corrupt piadm.conf files.
	#
	if [[ "$PIADM_CONFIG_VERSION" == "1" ]]; then
		if [[ $VERBOSE -eq 1 ]]; then
			echo "Version 1 of $PIADM_CONF"
			echo "The following file contents have been configured:"
			echo ""
			cat $PIADM_CONF
			echo ""
			if [[ "$OLD_DEFAULT" != "$DEFAULT_URL_PREFIX" ]]; then
				echo "DEFAULT_URL_PREFIX was $OLD_DEFAULT ,"
				echo "but now is $DEFAULT_URL_PREFIX"
			fi
		fi
	else
		eecho "WARNING: Bad config file version: $PIADM_CONFIG_VERSION"
		err "Please fix, or delete, $PIADM_CONF and run again"
	fi

	# Can furthermore be overridden by the user's PIADM_URL_PREFIX.
	URL_PREFIX=${PIADM_URL_PREFIX:-${DEFAULT_URL_PREFIX}}
	
	# Allow environment variables to override config file values
	[[ -n "${PIADM_DIGEST_ALGORITHM}" ]] && export PIADM_DIGEST_ALGORITHM
	[[ -n "${PIADM_NO_SUM}" ]] && export PIADM_NO_SUM
	[[ -n "${PIADM_URL_PREFIX}" ]] && URL_PREFIX="${PIADM_URL_PREFIX}"
	[[ -n "${PIADM_SUM_URL}" ]] && export PIADM_SUM_URL

	source "${PIADM_CONF}"
}

avail() {
	# For now, assume that the URL_PREFIX points to a Manta
	# back-end and we use Manta methods for querying (and json(1)
	# to help us out).  If the user overrides with
	# PIADM_URL_PREFIX, the behavior is undefined, and we issue a
	# warning.

	if [[ "$URL_PREFIX" != "$DEFAULT_URL_PREFIX" ]]; then
		eecho "WARNING: $URL_PREFIX is being queried for available"
		eecho "platform images. Output may be empty, or unusual."
		eecho ""
	fi

	# We need to get a list of all installed PIs to exclude them from
	# the list of available. By definition, a PI is available only if it is:
	# * newer than the current PI
	# * not already installed
	getbootable
	tmp=$(mktemp)
	for bootfs in "${allbootfs[@]}"; do
		cat /"${bootfs}"/platform-*/etc/version/platform > "$tmp"
	done

	# The aforementioned Manta method, parsed by json(1).
	# Don't print ones old enough to NOT contain piadm(8) itself.
	# Always be silent (i.e. use ${CURL[@]}).
	"${CURL[@]}" "${URL_PREFIX}/?limit=1000" | json -ga -c \
		"this.name.match(/Z$/) && this.name>=\"$activestamp\"" name | \
		grep -v -f "$tmp"
	rm -f "${tmp:?}"
}

# Scan for available installation media and mount it.
mount_installmedia() {
	tfile=$(mktemp)
	tfile2=$(mktemp)

	mntdir=$1

	# Try the USB key first, quietly and without $mntdir/.joyentusb check
	if ! mount_usb_key "$mntdir" skip > "$tfile" 2>&1 ; then
		# If the USB key fails, try mounting the ISO.
		if ! mount_ISO "$mntdir" > "$tfile2" 2>&1; then
			if [[ $VERBOSE -eq 1 ]]; then
			    eecho "Can't find install media: USB stick errors:"
			    eecho ""
			    cat "$tfile" 1>&2
			    eecho ""
			    eecho "ISO errors"
			    eecho ""
			    cat "$tfile2" 1>&2
			fi
			rm -f "$tfile" "$tfile2"
			return 1
		fi
	fi

	rm -f "$tfile" "$tfile2"
	return 0
}

# Install a Platform Image.
#
# XXX WARNING - there is a security discussion to be had about the integrity
# of the source.
install() {
	piname_present_get_bootfs "$1" "$2"
	tdir=$(mktemp -d)
	mkdir "${tdir}/mnt"

	# $1 contains a "source".  Deal with it correctly in the big
	# if/elif/else block.  Once done, we can copy over bits into $tdir or
	# ${tdir}/mnt.
	#

	# Special-case of "latest"
	if [[ "$1" == "latest" ]]; then
		# Well-known URL for the latest PI using conventions from
		# URL_PREFIX.  Grab the latest-version ISO. Before proceeding,
		# make sure it's the current one.
		iso=yes
		vecho "Downloading latest SmartOS ISO"
		vcurl -o "${tdir}/smartos.iso" "${URL_PREFIX}/smartos-latest.iso"
		code=$?
		if [[ $code -ne 0 ]]; then
			/bin/rm -rf "${tdir}"
			fatal "Curl exit code $code"
		fi
		validate_csum "$1" "${tdir}/smartos.iso"
		code=$?
		if [[ $code -ne 0 ]]; then
			/bin/rm -rf "${tdir}"
			err "Cannot validate checksum for $1"
		fi
		mount -F hsfs "${tdir}/smartos.iso" "${tdir}/mnt"
		# if user disabled checksums, we don't have a stamp.
		if [[ -z "${stamp}" ]]; then
			# For now, assume boot stamp and PI stamp are the same on an ISO...
			stamp=$(cat "${tdir}/mnt/etc/version/boot")
		fi
	elif [[ "$1" == "media" ]]; then
		# Scan the available media to find what we seek.  Same advice
		# about making sure it's the current one.
		iso=yes
		if ! mount_installmedia "${tdir}/mnt" ; then
			/bin/rm -rf "${tdir}"
			err "Cannot find install media"
		fi

		# if user disabled checksums, we don't have a stamp.
		if [[ -z "${stamp}" ]]; then
			# For now, assume boot stamp and PI stamp are the same on
			# install media.
			stamp=$(cat "${tdir}/mnt/etc/version/boot")
		fi
	elif [[ -f $1 ]]; then
		# File input!  Check for what kind, etc. etc.

		# WARNING:  Depends GREATLY on the output of file(1)
		filetype=$(file "$1" | awk '{print $2}')
		if [[ "$filetype" == "ISO" ]]; then
			# Assume .iso file.
			vecho "Treating $1 as an ISO file."
			iso=yes
			mount -F hsfs "$1" "${tdir}/mnt"
			# if user disabled checksums, we don't have a stamp.
			if [[ -z "${stamp}" ]]; then
				stamp=$(cat "${tdir}/mnt/etc/version/boot")
			fi
		elif [[ "$filetype" == "gzip" ]]; then
			# SmartOS PI.  Let's confirm it's actually a .tgz...

			if ! gtar -xzOf "$1" > /dev/null 2>&1; then
				/bin/rm -rf "${tdir:?}"
				err "File $1 is not an ISO or a .tgz file."
			fi
			# We're most-likely good here.  NOTE: SmartOS/Triton
			# PI files expand to platform-$STAMP.  Fix it here
			# before proceeding.
			vecho "Treating $1 as an .tgz Platform Image file."
			gtar -xzf "$1" -C "${tdir}/mnt"
			mv "${tdir}"/mnt/platform-* "${tdir}/mnt/platform"
			iso=no
			# if user disabled checksums, we don't have a stamp.
			if [[ -z "${stamp}" ]]; then
				stamp=$(cat "${tdir}/mnt/platform/etc/version/platform")
			fi
		else
			/bin/rm -rf "${tdir:?}"
			err "Unknown file type for $1"
		fi
	else
		# Explicit boot stamp or URL.

		# Check if URL exists first
		# We believe max-time 30s to fetch headers
		# is more than enough.
		vecho "Checking if URL $1 exists (30s) timeout"
		if ! "${CURL[@]}" --max-time 30 --connect-timeout \
				10 --head "$1" -w "%{http_code}" 2> /dev/null |\
				tail -1 > /var/run/piadm.http.$$; then
			# Get HTTP status code for error reporting
			http_code=$(cat /var/run/piadm.http.$$)
			/bin/rm -f /var/run/piadm.http.$$
			if [[ -n "$http_code" && "$http_code" != "000" ]]; then
				vecho "URL $1 returned HTTP Status: $http_code"
			fi
			# Fall through to treat as boot stamp
		else
		    /bin/rm -f /var/run/piadm.http.$$
			vecho "Downloading from URL $1"
			if vcurl -o "${tdir}/download" "$1"; then
				# Recurse with the downloaded file.
				dload=$(mktemp)
				mv -f "${tdir}/download" "$dload"
				/bin/rm -rf "${tdir}"
				# in case `install` exits out early...
				( pwait $$ ; rm -f "$dload" ) &
				vecho "Installing $1"
				vecho "	   (downloaded to $dload)"
				install "$dload" "$2"
				return 0
			else
				vecho "Failed to download from URL $1"
				# Fall through to treat as boot stamp
			fi
		fi
		# Else we treat it like a boot stamp.

		# Now that we think it's a boot stamp, check if it's the
		# current one or if it exists.
		if [[ -d ${bootfs}/platform-${1} ]]; then
			/bin/rm -rf "${tdir}"
			eecho "PI-stamp $1 appears to be already on /${bootfs}"
			err "Use  piadm remove $1  to remove any old copies."
		fi

		# Confirm this is a legitimate build stamp.
		# Use conventions from site hosted in URL_PREFIX.
		vecho "Downloading ISO for Platform Image $1"
		checkurl=${URL_PREFIX}/$1/index.html
		# Always be silent, use ${CURL[@]}.
		if ! "${CURL[@]}" "$checkurl" | head | grep -qv "not found" ; then
			eecho "PI-stamp $1" \
				"is invalid for download from $URL_PREFIX"
			usage
		fi
		vcurl -o "${tdir}/smartos.iso" "${URL_PREFIX}/$1/smartos-${1}.iso"
		code=$?
		if [[ $code -ne 0 ]]; then
			/bin/rm -rf "${tdir}"
			fatal "PI-stamp $1 -- curl exit code $code"
		fi
		validate_csum "${URL_PREFIX}/$1/smartos-${1}.iso" "${tdir}/smartos.iso"
 		code=$?
		if [[ $code -ne 0 ]]; then
			/bin/rm -rf "${tdir}"
			err "validate_csum exit code  $code"
		fi
		mount -F hsfs "${tdir}/smartos.iso" "${tdir}/mnt"
		code=$?
		if [[ $code -ne 0 ]]; then
			/bin/rm -rf "${tdir}"
			fatal "PI-stamp $1 -- mount exit code $code"
		fi
		iso=yes
		stamp=$1
		# Reality-check boot stamp.
		bstamp=$(cat "${tdir}/mnt/etc/version/boot")
		if [[ $stamp != "$bstamp" ]]; then
			umount "${tdir}/mnt"
			/bin/rm -rf "${tdir}"
			err "Boot bits stamp says $bstamp," \
			    "vs. argument stamp $stamp"
		fi
	fi

	vecho "Installing PI $stamp"

	# At this point we have ${tdir}/mnt which contains at least
	# "platform".  If "iso" is yes, it also contains "boot",
	# "boot.catalog" and "etc", but we only really care about boot.catalog
	# and boot. These may be mounted as read-only, so we can't do mv.

	if [[ "$iso" == "yes" ]]; then
		# Match-check boot stamp and platform stamp.
		pstamp=$(cat "${tdir}/mnt/platform/etc/version/platform")
		if [[ "$stamp" != "$pstamp" ]];	then
			umount "${tdir}/mnt"
			/bin/rm -rf "${tdir}"
			err "Boot stamp $stamp mismatches platform stamp" \
				"$pstamp"
		fi

		if [[ -e "/${bootfs}/boot-${stamp}" ]]; then
			umount "${tdir}/mnt"
			/bin/rm -rf "${tdir}"
			eecho "PI-stamp $stamp has boot bits already" \
				"on /${bootfs}"
			err "Use  piadm remove $stamp " \
				"to remove any old copies."
		fi
		mkdir "/${bootfs}/boot-${stamp}" || \
			eecho "Can't mkdir /${bootfs}/boot-${stamp}"
		tar -cf - -C "${tdir}/mnt/boot" . | \
			tar -xf - -C "/${bootfs}/boot-${stamp}" || \
			eecho "Problem in tar of boot bits"

		[[ -e "/${bootfs}/custom/loader.conf.local" ]] && \
			ln -sf "../custom/loader.conf.local" \
				"/${bootfs}/boot-${stamp}/loader.conf.local"
		[[ -e "/${bootfs}/custom/loader.rc.local" ]] && \
			ln -sf "../custom/loader.rc.local" \
				"/${bootfs}/boot-${stamp}/loader.rc.local"
	fi

	if [[ -e /${bootfs}/platform-${stamp} ]]; then
		if [[ $iso == "yes" ]]; then
			umount "${tdir}/mnt"
		fi
		/bin/rm -rf "${tdir}"
		eecho "PI-stamp $stamp appears to be already on /${bootfs}"
		err "Use   piadm remove $stamp	 to remove any old copies."
	fi
	mkdir "/${bootfs}/platform-${stamp}" || \
		eecho "Can't mkdir /${bootfs}/platform-${stamp}"
	tar -cf - -C "${tdir}/mnt/platform" . | \
		tar -xf - -C "/${bootfs}/platform-${stamp}" || \
		eecho "Problem in tar of platform bits"

	if [[ "$iso" == "yes" ]]; then
		umount "${tdir}/mnt"
	fi
	/bin/rm -rf "${tdir:?}"

	if [[ ! -d /${bootfs}/platform-${stamp} ]]; then
		fatal "Installation problem (no ${bootfs}/platform-${stamp})"
	fi
	if [[ ! -d /${bootfs}/boot-${stamp} && "$iso" == "yes" ]]; then
		fatal "Installation problem (no ${bootfs}/boot-${stamp}" \
			"from ISO)"
	fi

	# Global variable for enablepool() usage...
	installstamp=$stamp
	return 0
}

list() {
	if [[ $1 == "-H" ]]; then
		pool=$2
	else
		printf "%-22s %-30s %-10s %-4s %-4s \n" "PI STAMP" \
			"BOOTABLE FILESYSTEM" "BOOT IMAGE" "NOW" "NEXT"
		pool=$1
	fi

	poolpresent "$pool"

	getbootable
	for bootfs in "${allbootfs[@]}"; do
		bfspool=$(echo "$bootfs" | awk -F/ '{print $1}')
		if [[ "$pool" != "" && "$bfspool" != "$pool" ]]; then
			# If we specify a pool for listing, skip ones not in
			# the pool.
			continue
		fi
		cd "/$bootfs" || fatal "Could not chdir to /$bootfs"
		bootbitsstamp=$(cat etc/version/boot)
		# Triton Head Nodes are special.
		if [[ "$TRITON_HN" != "yes" ]]; then
			# Regular standalone SmartOS case.
			if [[ ! -L /$bootfs/platform ]]; then
				corrupt "WARNING: Bootable filesystem" \
					"$bootfs has non-symlink platform"
			fi
			bootstamp=$(cat platform/etc/version/platform)
			mapfile -t pis \
				< <(cat platform-*/etc/version/platform)
		else
			# Triton Head Node case.
			if [[ ! -d /$bootfs/os ]]; then
				corrupt "WARNING: Headnode boot filesystem" \
					"$bootfs has no os/ directory."
			fi
			bootstamp=$(awk -F= '/^platform-version=/ {print $2}' \
				< boot/loader.conf | sed 's/"//g')
			mapfile -t pis < <(cat os/*/platform/etc/version/platform)
		fi
		for pi in "${pis[@]}"; do
			if [[ $activestamp == "$pi" ]]; then
				active="yes"
			else
				active="no"
			fi
			if [[ $bootstamp == "$pi" ]]; then
				booting="yes"
			else
				booting="no"
			fi
			if [[ $bootbitsstamp == "$pi" ]]; then
				bootbits="next"
			elif [[ -d "boot-$pi" ]]; then
				bootbits="available"
				# Special-case of ipxe booting next needs "next"
				if [[ $pi == "ipxe" ]]
				then
					if [[ $VERBOSE -eq 1 ]]; then
						pi="ipxe($(cat etc/version/ipxe))"
					else
						pi="ipxe"
					fi
					if [[ $booting == "yes" ]]; then
						bootbits="next"
					fi
				fi
			else
				bootbits="none"
			fi
			printf "%-22s %-30s %-10s %-4s %-4s\n" \
				"$pi" "$bootfs" "$bootbits" "$active" "$booting"
		done
	done
}

update_boot_sectors() {
	pool=$1
	bootfs=$2
	flag=$3

	# XXX WARNING -- illumos#12894 will allow slogs.  We will need to
	# alter the generation of boot_devices accordingly.  Generate the
	# pool's boot devices now, in case we did something hyper-clever for
	# the pool.  s1 may be created, but not yet PCFS...
	mapfile -t boot_devices < <(zpool list -vHP "$pool" | \
		grep -E 'c[0-9]+' | awk '{print $1}' | sed -E 's/s[0-9]+//g')

	# Reality check the pool was created with -B.
	# First way to do this is to check for the `bootsize` property not
	# its default, which is NO bootsize.
	if [[ $(zpool list -Ho bootsize "$pool") == "-" ]]; then
		# No bootsize is a first-cut test.  It passes if the pool was
		# created with `zpool create -B`. There's one other that needs
		# to be performed, because some bootable pools are manually
		# configured to share slices with other functions (slog,
		# l2arc, dedup):

		# Use fstyp to confirm if this is a manually created EFI
		# System Partition (ESP)
		type=$(fstyp "/dev/dsk/${boot_devices[0]}s0" 2>/dev/null)
		if [[ "$type" == "pcfs" ]]; then
			# If we detect PCFS on s0, it's LIKELY an EFI System
			# Partition that was crafted manually.  Use s1 if it's
			# ZFS, or bail if it's not.

			s1type=$(
			    fstyp "/dev/dsk/${boot_devices[0]}s1" 2>/dev/null
			)
			if [[ "$s1type" != "zfs" ]]; then
				fatal "Unusual configuration," \
					"${boot_devices[0]}s1 not ZFS"
			fi
			suffix=s1
		else
			suffix=s0
		fi
	else
		# Guaranteed that s0 is EFI System Partition, ZFS lives on s1.
		suffix=s1
	fi

	some=0
	for a in "${boot_devices[@]}"; do
		if [[ "$flag" == "-d" ]]; then
			if [[ "$suffix" == "s0" ]]; then
				# BIOS boot, we don't care.
				some=1
				continue
			fi
			# otherwise mount the ESP and trash it.
			tdir=$(mktemp -d)
			if ! mount -F pcfs "/dev/dsk/${a}s0" "${tdir:?}" ; then
				# Wrong filesystem, so skip the rest of this loop
				eecho "disk $a has no PCFS ESP, it seems"
				continue
			fi
			# Just take out the EFI directory, in case someone
			# is using it for something ELSE also.
			/bin/rm -rf "${tdir}/EFI"
			umount "$tdir" && rmdir "$tdir"
			some=1
			# If we make it here, at least some disks had
			# ESP and we managed to clean them out.  "some" below
			# will get set.
		else
			# Plow through devices, even if some fail.
			# installboot also does
			# loader-into-EFI-System-Partition this way.
			# Trailing / is important in the -b argument
			# because boot is actually a symlink.
			if installboot -m -b "/${bootfs}/boot/" \
				"/${bootfs}/boot/pmbr" \
				"/${bootfs}/boot/gptzfsboot" \
				"/dev/rdsk/${a}${suffix}" > /dev/null 2>&1 ; then
				some=1
			else
				eecho "WARNING: Can't installboot on ${a}${suffix}"
			fi
		fi
	done

	# Partial success (altering some of the pool's disks) is good
	# enough for command success.
	if [[ $some -eq 0 ]]; then
		fatal "Could not modify ANY vdevs of pool $2"
	fi
}

#
# Emit a select-a-Platform-Image page header.  Set the menuset prefix!
#
# PWD is /${bootfs} at this point.
#
emit_pageheader() {
	pagenum=$1
	totalpages=$2
	defaultpi=$3

	if [[ "$pagenum" == "$totalpages" ]]; then
		nextpage=3
	else
		nextpage=$((pagenum + 3))
	fi
	menusetnum=$((pagenum + 2))
	menusetprefix="pi${pagenum}menu_"
	cat >> ./os/pi.rc <<EOF
set menuset_name${menusetnum}="pi${pagenum}"
set ${menusetprefix}init[1]="init_pi"

set ${menusetprefix}caption[1]="Back to Main Menu [Backspace]"
set ${menusetprefix}command[1]="pi_draw_screen drop 1 goto_menu"
set ${menusetprefix}keycode[1]=8
set pi${pagenum}ansi_caption[1]="Back to Main Menu ^[1m[Backspace]^[m"

set ${menusetprefix}caption[2]="[P]age: ${pagenum} of ${totalpages}"
set ${menusetprefix}command[2]="${nextpage} goto_menu"
set ${menusetprefix}keycode[2]=112
set pi${pagenum}ansi_caption[2]="^[1mP^[mage: ${pagenum} of ${totalpages}"

set ${menusetprefix}options=3
EOF
	# Need printf(1) so the shell doesn't attempt expansion...
	printf 'set %soptionstext="${pimenu_optionstext}"\n' \
		$menusetprefix >> ./os/pi.rc
	cat >> ./os/pi.rc <<EOF

set ${menusetprefix}caption[3]="[D]efault (${defaultpi})"
set ${menusetprefix}command[3]="s\" set bootpi=default\" evaluate pi_unload pi_draw_screen"
set ${menusetprefix}keycode[3]=100
set pi${pagenum}ansi_caption[3]="^[1mD^[mefault (${defaultpi})"

EOF



	echo $menusetprefix
}

#
# Create the /$bootfs/os/ directory from scratch.  This includes a
# /bin/rm -rf of the old /$bootfs/os/ directory if it exists.
#
# The os/ directory, inspired by the Triton Head Node, allows a
# selection of specific platform images that aren't the "default" as
# symlinked into /$bootfs/platform/.  It is comprised of:
#
# os/pi.rc --> Generated by this function, it is a list of up to three
# menu pages of alternate platform images, NOT INCLUDING the "default"
# one per above.  If $bootfs has too many PIs, this function should
# take the most recent as sorted by stamp date.
#
# os/$STAMP/platform --> symbolic links to ../../platform-$STAMP/.
# Because "platform" is the last path component this way, the kernel
# will not seek a boot archive in the default /$bootfs/platform directory.
# NOTE that the default one wll not have a os/$DEFAULTSTAMP/platform entry.
#
# PWD is /${bootfs} at this point.
#
regenerate_os() {
	# Clobber old one now, generate a new one, and setup the extra
	# main-menu item..
	vecho "Removing old ./os/ directory"
	/bin/rm -rf ./os

	# Only use "maxpis" newest PI stamps, which must be 15 or fewer.
	# Note that the default PI is not counted amongst the 15.
	maxpis=15
	pisperpage=5

	defaultpi=$(cat ./platform/etc/version/platform)
	mapfile -t pis < <(cat platform-*/etc/version/platform | \
		grep -v ${defaultpi} | sort -r | head -${maxpis})
	totalpis=${#pis[@]}
	if [[ "$totalpis" == "0" ]]; then
		vecho "No need for the ./os/ directory, only one PI"
		return
	fi

	vecho "Creating new ./os/ directory"
	mkdir ./os
	cat > ./os/pi.rc <<EOF
\\
\\ Generated by piadm(8).
\\

\\ Assume mainmenu_options=4 for now.

set mainmenu_caption[5]="Alternate [P]latform Images..."
set mainmenu_command[5]="3 goto_menu"
set mainmenu_keycode[5]=112
set mainansi_caption[5]="Alternate ^[1mP^[mlatform Images..."

\\ Will be reset by init_pi (see below and in menu-commands.4th).
set pimenu_optionstext="Platform Image: (UNINIT)"
\\ For feeding init_pi.
set pitext="Platform Image: "

EOF

	# Make sure maxpis is evenly divisible by pisperpage.  maxpages
	# should not exceed 3 (loader limits 8 total pages, before this we've
	# eaten 4, so eat 3 more, and save one for later).
	maxpages=$(((maxpis + 1) / pisperpage))
	totalpages=$((((totalpis - 1) / pisperpage) + 1))

	pinum=0
	menusetprefix=""

	for pi in "${pis[@]}"; do
		vecho "Including Platform Image ${pi}"
		mkdir ./os/${pi}
		ln -s ../../platform-${pi} ./os/${pi}/platform

		pagenum=$((((pinum) / pisperpage) + 1))
		itemnum=$(((pinum % pisperpage) + 1))
		if [[ "$itemnum" == "1" ]]; then
			menusetprefix=$(emit_pageheader $pagenum $totalpages \
				$defaultpi)
		fi
		# else menusetprefix is already set for this round!

		# Emit the entry.
		cat >> ./os/pi.rc <<EOF

set ${menusetprefix}caption[$((itemnum + 3))]="${pi}"
set ${menusetprefix}command[$((itemnum + 3))]="pi_unload s\" set bootpi=${pi}\" evaluate s\" load /os/${pi}/platform/i86pc/kernel/amd64/unix\" evaluate s\" load -t rootfs /os/${pi}/platform/i86pc/amd64/boot_archive\" evaluate pi_draw_screen"
set pi${pagenum}ansi_caption[$((itemnum + 3))]="${pi}"

EOF
		pinum=$((pinum + 1))
	done
}

activate() {
	pistamp=$1
	piname_present_get_bootfs "$pistamp" "$2"
	pool=$(echo "$bootfs" | awk -F/ '{print $1}')

	cd "/$bootfs" || fatal "Could not chdir to /$bootfs"
	if [[ -d "platform-$pistamp" ]]; then
		if [[ -f platform/etc/version/platform ]]; then
			bootstamp=$(cat platform/etc/version/platform)
		else
			bootstamp=""
		fi
		if [[ $bootstamp == "$pistamp" ]]; then
			vecho "NOTE: $pistamp is the current active PI."
			regenerate_os
			return
		fi
	else
		eecho "$pistamp is not a stamp for a PI on pool $pool"
		usage
	fi

	vecho "Platform Image $pistamp will be loaded on next boot,"

	# Okay, at this point we have the platform sorted out.  Let's see if
	# we can do the same with the boot.
	if [[ -d boot-$pistamp ]]; then
		rm -f boot
		ln -s ./boot-"$pistamp" boot
		mkdir -p etc/version
		echo "$pistamp" > etc/version/boot
		update_boot_sectors "$pool" "$bootfs"

		# Fix the loader.conf for keep-the-ramdisk booting.
		grep -q 'fstype="ufs"' ./boot/loader.conf || \
			echo 'fstype="ufs"' >> ./boot/loader.conf

		vecho "    with a new boot image,"
	else
		vecho "	   WARNING: $pistamp has no matching boot image, using"
		if [[ ! -f etc/version/boot ]]; then
			fatal "No boot version available on /$bootfs"
		elif [[ ! -d boot/. ]]; then
			fatal "No boot bits directory on /$bootfs"
		fi
	fi

	vecho "    boot image " "$(cat etc/version/boot)"

	rm -f platform
	ln -s "./platform-$pistamp" platform
	regenerate_os
}

remove() {
	pistamp=$1
	piname_present_get_bootfs "$pistamp" "$2"
	cd "/$bootfs" || fatal "Could not chdir to /$bootfs"
	bootstamp=$(cat platform/etc/version/platform)

	if [[ -d platform-$pistamp ]]; then
		if [[ $bootstamp == "$pistamp" ]]; then
			eecho "$pistamp is the next-booting PI." \
		    		"Please activate another PI"
			eecho "using 'piadm activate <other-PI-stamp>' first."
			usage
		fi

		# Boot image processing.
		if [[ -d "boot-$pistamp" ]]; then
			# Boot bits may be older than the current PI, and the
			# current PI may not have matching boot bits for some
			# reason. Guard against shooting yourself in the foot.
			if grep -q "$pistamp" etc/version/boot; then
				eecho "$pistamp is the current set of boot" \
					"binaries.  Please"
				eecho "activate another pi using" \
					"'piadm activate <other-PI-stamp>'" \
					"first."
				usage
			fi
			/bin/rm -rf "boot-$pistamp"
		fi

		/bin/rm -rf "platform-$pistamp"
		regenerate_os
	else
		eecho "$pistamp is not a stamp for a PI on pool $pool"
		usage
	fi
}

ispoolenabled() {
	pool=$1
	poolpresent "$pool"

	# SmartOS convention is $POOL/boot.
	currbootfs=$(zpool list -Ho bootfs "$pool")
	if [[ $currbootfs == "${pool}/boot" ]]; then
		# We're bootable (at least bootable enough)
		zfs list -H "$currbootfs" > /dev/null 2>&1  && return 0
		# else drop out to not-bootable, but this shouldn't happen.
		vecho ".... odd, ${pool}/boot is pool's bootfs," \
			"but isn't a filesystem"
	elif [[ $currbootfs != "-" ]]; then
		eecho "It appears pool $pool has a different boot filesystem" \
			"than the"
		eecho "standard SmartOS filesystem of ${pool}/boot. It will" \
			"need manual"
		corrupt "intervention."
	fi

	# Not bootable.
	return 1
}

# Routines and variables related specifically to Triton Compute Nodes.

# Data for Triton Compute Node (CN) iPXE.
TRITON_IPXE_PATH=/opt/smartdc/share/usbkey/contents
TRITON_IPXE_ETC=${TRITON_IPXE_PATH}/etc
TRITON_IPXE_BOOT=${TRITON_IPXE_PATH}/boot

initialize_as_CN() {
	TRITON_CN="yes"

	source /lib/sdc/config.sh
	load_sdc_config

	# Establish the CNAPI default boot Platform Image
	# Always be silent, use ${CURL[@]}.
	cnapi_domain=$("${CURL[@]}" http://"${CONFIG_sapi_domain:?}"/applications?name=sdc | json -Ha metadata.cnapi_domain)
	CNAPI_DEFAULT_PI=$("${CURL[@]}" http://"${cnapi_domain}"/boot/default | json platform)
}

initialize_as_HN() {
	#
	# For the Triton Head Node, we only really want piadm doing one of
	# four things:
	#
	# 1.) Enabling a bootable pool, which will involve a bunch of
	#     Triton-savvy maneuvers.
	# 2.) Updating the boot sector and/or EFI boot.
	# 3.) Disabling a bootable pool, which will ALSO involved a bunch of
	#     Triton-savvy maneuvers.
	# 4.) List the pools available that are Triton-savvy and bootable.
	#
	# For right now, we merely need to indicate we're a headnode and
	# if we're booted off of a pool, which one.

	TRITON_HN="yes"
	TRITON_HN_BOOTPOOL=$(bootparams | awk -F= '/^triton_bootpool=/ {print $2}')
}

# README file for /${bootfs}/platform-ipxe/README.
cat_readme() {
	cat <<EOF
For iPXE boots, the platform/ directory is empty.  This README, and
the word "ipxe" in platform/etc/version/platform, are here so there's
something in the platform/ directory to prevent piadm (especially
older versions) from thinking something is wrong.
EOF
}

# Given a bootstamp, install a Platform Image as a backup for the compute node.
# PWD is /${bootfs} at this point.
install_pi_CN() {
	vecho "Installing as a backup Platform image PI stamp $1"

	if [[ -d ./platform-$1 ]]; then
		vecho "PI stamp $1 already installed."
		installstamp=$1
		return 0
	fi

	# Obtain at least unix and boot archive.

	# For now, use bootparams to get the URL needed, and pull
	# files from there.  If there's a better way to obtain things, use it.
	unix_path=$(bootparams | awk -F= '/^boot-file=/ {print $2}')
	if [[ "$1" == "$CNAPI_DEFAULT_PI" ]]; then
		# We need to edit out the bootstamp part.  Count on path
		# having "os/STAMP/" in it.
		unix_path=$(sed "s/os\/[0-9TZ]*\//os\/$CNAPI_DEFAULT_PI\//g" <<< "$unix_path")
	fi
	archive_prefix=$(sed 's/kernel\/amd64\/unix/amd64/g' <<< "$unix_path")

	# Reality check the buildstamp passed, which will become installstamp,
	# is in the unix_path.
	echo "$unix_path" | grep -q "$1" || return 1

	installstamp=$1
	vecho "making platform-$installstamp directories"
	mkdir -p platform-"$installstamp"/etc/version
	echo "$installstamp" > platform-"$installstamp"/etc/version/platform
	mkdir -p platform-"$installstamp"/i86pc/kernel/amd64
	mkdir -p platform-"$installstamp"/i86pc/amd64
	# To enable a platform/ component in the boot file pathname to confirm
	# "unix" is also in the boot archive (as /platform/..../unix).
	ln -s . platform-"$installstamp"/platform

	vecho "Pulling unix"
	vcurl "$unix_path" > \
		platform-"$installstamp"/i86pc/kernel/amd64/unix || return 1
	for file in boot_archive boot_archive.hash boot_archive.manifest \
		boot_archive.gitstatus; do
		vecho "Pulling" "$file"
		vcurl "${archive_prefix}"/"${file}" > \
			platform-"$installstamp"/i86pc/amd64/"${file}" || \
			return 1
	done

	return 0
}

# Enabling a bootable pool, specifically for a Triton Compute Node.
bringup_CN() {
	# Bootfs is already set at this point.

	if [[ "$CNAPI_DEFAULT_PI" != "$activestamp" ]]; then
		vecho "Current booted PI $activestamp is not default PI" \
			"$CNAPI_DEFAULT_PI"
	fi

	# First install ipxe in $bootfs.
	cd "/${bootfs}" || fatal "Could not chdir to /$bootfs"
	# Clobber everything in $bootfs.  We do not care about dot-files.
	rm -rf ./*

	# The "platform-ipxe" directory for on-disk iPXE is a placeholder.
	# We put a README (see cat_readme() above) and the string "ipxe"
	# for the PI-stamp.
	mkdir -p ./platform-ipxe/etc/version
	cat_readme > ./platform-ipxe/README
	echo "ipxe" > ./platform-ipxe/etc/version/platform

	# Now we set up the "etc" directory, which contains versions of
	# both loader ("boot") and iPXE ("ipxe").
	mkdir -p etc/version
	cp -f ${TRITON_IPXE_ETC}/version/* etc/version/.
	vecho "installing ipxe version: " "$(cat etc/version/ipxe)"

	# Now we set up the "boot-ipxe" directory.
	mkdir boot-ipxe
	# Use tar here because it's the first time.
	tar -cf - -C ${TRITON_IPXE_BOOT} . | tar -xf - -C boot-ipxe
	# Preserve versions in boot-ipxe too in case we need them later.
	cp -f etc/version/boot boot-ipxe/bootversion
	cp -f etc/version/ipxe boot-ipxe/ipxeversion

	# Symlinks for loader default and `piadm list` consistency.
	ln -s platform-ipxe platform
	ln -s boot-ipxe boot

	# Install a PI for backup booting purposes.
	if ! install_pi_CN "$activestamp" && \
		[[ "$CNAPI_DEFAULT_PI" != "$activestamp" ]]; then
		/bin/rm -rf platform-"$activestamp"
		if ! install_pi_CN "$CNAPI_DEFAULT_PI"; then
			/bin/rm -rf platform-"$CNAPI_DEFAULT_PI"
			err "No PIs available"
		fi
	fi
	# installstamp will be set by the successful install_pi_CN()

	# Populate loader.conf.
	# NOTE: One could uncomment the sed below and replace the cp if one
	# wished to have the CN backup-boot not go into the Triton HN
	# installer but act in a different kind of weird way.
	# sed 's/headnode="true"/headnode="false"/g' \ <
	#	boot-ipxe/loader.conf.tmpl > boot-ipxe/loader.conf
	cp boot-ipxe/loader.conf.tmpl boot-ipxe/loader.conf
	{
		echo 'ipxe="true"'
		echo 'smt_enabled="true"'
		echo 'console="ttyb,ttya,ttyc,ttyd,text"'
		echo 'os_console="ttyb"'
		echo 'fstype="ufs"'
		# use $installstamp to help!
		echo "platform-version=$installstamp"
		# Need an extra "platform" in here to satisfy the illumos
		# load-time that looks for a unix in the boot archive.  The
		# boot file path MUST have /platform/i86pc/kernel/amd64/unix
		# as its trailing components.  See install_pi_CN() for the
		# insertion of a symlink to help out.
		echo bootfile=\"/platform-"$installstamp"/platform/i86pc/kernel/amd64/unix\"
		echo boot_archive_name=\"/platform-"$installstamp"/i86pc/amd64/boot_archive\"
		echo boot_archive.hash_name=\"/platform-"$installstamp"/i86pc/amd64/boot_archive.hash\"
	} >> boot-ipxe/loader.conf

	# Caller will invoke update_boot_sectors.
}

update_CN() {
	declare -a pdirs

	if [[ "$TRITON_CN" != "yes" ]]; then
		err "The update command may only be used on a Triton Compute Node"
	fi

	piname_present_get_bootfs "ipxe" "$1"
	cd "/${bootfs}" || fatal "Could not chdir to /$bootfs"

	# First check if the backup PI is in need of update.
	# The standard iPXE/CN deployment has exactly one platform-STAMP.
	mapfile -t pdirs < <(ls -d platform-[0-9]*T*Z)
	if [[ ${#pdirs[@]} -gt 1 ]]; then
		corrupt "Multiple platform-STAMP in CN bootfs /${bootfs}/."
	elif [[ ${#pdirs[@]} -lt 1 ]]; then
		corrupt "No platform-STAMP in CN bootfs /${bootfs}/."
	fi

	pdir=${pdirs[0]}

	pstamp=$(cat "${pdir}"/etc/version/platform)
	if [[ "$pstamp" != "$activestamp" ]]; then
		vecho "Updating backup PI to" "$activestamp"
		if ! install_pi_CN "$activestamp" && \
			[[ "$CNAPI_DEFAULT_PI" != "$activestamp" ]]; then
			vecho "...trying" "$CNAPI_DEFAULT_PI" "instead"
			if ! install_pi_CN "$CNAPI_DEFAULT_PI" ; then
				/bin/rm -rf platform-"$activestamp"
				/bin/rm -rf platform-"$CNAPI_DEFAULT_PI"
				err "No PIs available, keeping" "$pstamp"
			fi
		fi

		# Success, don't keep the old one!
		# $installstamp will have new PI stamp, will inform below.
		vecho "...success installing $installstamp"
		/bin/rm -rf "$pdir"
		tfile=$(mktemp)
		# Alter loader.conf's backup PI stamp.
		# NOTE: If loader.conf has a flag day, we really need to
		# Do Better here.
		cp ./boot-ipxe/loader.conf "${tfile}"
		sed s/"${pstamp}"/"${installstamp}"/g < "${tfile}" \
			> ./boot-ipxe/loader.conf
		rm -f "${tfile}"
	fi

	# THEN check to see if we need to update iPXE...
	diskipxe=$(cat etc/version/ipxe)
	diskboot=$(cat etc/version/boot)
	newipxe=$(cat ${TRITON_IPXE_ETC}/version/ipxe)
	newboot=$(cat ${TRITON_IPXE_ETC}/version/boot)
	if [[ "$diskipxe" == "$newipxe" && "$diskboot" == "$newboot" ]]; then
		vecho "No updates needed for iPXE and its loader."
		vecho "If you think there should be an update, run"
		vecho "'sdcadm experimental update-gz-tools' on your"\
			"Triton Head Node"
		exit 0
	fi

	[[ "$diskipxe" != "$newipxe" ]] && \
		vecho "Updating iPXE provided by headnode (ver: $newipxe)"
	[[ "$diskboot" != "$newboot" ]] && \
		vecho "Updating boot loader provided by headnode (ver: $newboot)"
	cp -f ${TRITON_IPXE_ETC}/version/* etc/version/.

	# NOTE:  If there is an illumos loader flag day, one may have to
	# perform more than simple rsync to update ./boot/.
	rsync -r ${TRITON_IPXE_BOOT}/. ./boot/.

	# Preserve versions in boot-ipxe too in case we need them later.
	cp -f etc/version/boot boot-ipxe/bootversion
	cp -f etc/version/ipxe boot-ipxe/ipxeversion

	# And make sure we update the boot sectors.
	update_boot_sectors "$pool" "$bootfs"
}

bringup_HN() {
	# One last reality check...
	# 1.) Check if we're trying to enable our currently booting pool.
	if [[ "$pool" == "$TRITON_HN_BOOTPOOL" ]]; then
		err "Pool $pool is already bootable, and we just booted it."
	fi

	# If we reach here, we've checked for the already-bootable
	# case, checked for the can-be-bootable case, and have a
	# $bootfs ready to go.  For the head node, we will be extra
	# cautious and remove all of its contents first.  NOTE: rm(1)
	# will complain because you'll get EBUSY for the mountpoint
	# itself.
	vecho "Cleaning up $bootfs"
	/bin/rm -rf /"$bootfs" >& /dev/null
	cd /"$bootfs"

	# Mount the Triton USB key (even if it's a virtual one...).
	if [[ $(sdc-usbkey status) == "mounted" ]]; then
		stick_premounted=yes
	fi
	stickmount=$(sdc-usbkey mount)
	vecho "Mounted USB key on $stickmount"

	# NOTE:  BAIL ON VERSION 1 STICKS FOR NOW
	version=$(sdc-usbkey status -j | json version)
	if [[ "$version" != "2" ]]; then
		# Unmount on version-mismatch...
		if [[ "$stick_premounted" != "yes" ]]; then
			sdc-usbkey unmount
		fi
		err "USB key must be Version 2 (loader) to install on a pool."
	fi

	# Copy over the whole thing to ${bootfs}
	vecho "Copying over USB key contents to /$bootfs"

	# NOTE: If failed here, USB key will still be mounted for debugging
	# reasons, regardless of $stick_premounted.
	tar -cf - -C "$stickmount" . | tar -xf - || \
		err "Problem copying USB key on $stickmount (still mounted)" \
			"to /$bootfs"

	# Add both fstype="ufs" to loader.conf.
	vecho "Modifying loader.conf for pool-based Triton Head Node boot"
	grep -q 'fstype="ufs"' ./boot/loader.conf || \
		echo 'fstype="ufs"' >> ./boot/loader.conf
	# Filter out any old triton_ bootparams (either old bootpool OR
	# installer properties) and replace them with JUST the new bootpool.
	# Let's be cautious and use a temp file instead of sed's -i or -I.
	tfile=$(mktemp)
	grep -v '^triton_' ./boot/loader.conf > $tfile
	mv -f $tfile ./boot/loader.conf
	echo "triton_bootpool=\"$pool\"" >> ./boot/loader.conf

	# (OPTIONAL) Add "from-pool" indicator to boot.4th.

	# 4.) Properly capitalize ${bootfs}/os/ entries.
	vecho "Case-correcting os/ entries."
	cd ./os
	for a in *; do
		# If our "usb key" is already a ZFS bootfs, don't mv
		# identically-named things.
		if [[ "$a" != "${a^^}" ]]; then
			mv "$a" "${a^^}"
		fi
	done
	cd ..

	if [[ "$stick_premounted" != "yes" ]]; then
		sdc-usbkey unmount
	fi
}

enablepool() {
	if [[ $1 == "-i" ]]; then
		if [[ "$2" == "" || "$3" == "" ]]; then
			eecho "-i must take an option," \
				"and then a pool must be specified."
			usage
		fi
		standalone_only "'bootable -e' with '-i'"
		installsource=$2
		pool=$3
	elif [[ -z $1 ]]; then
		eecho "To enable a pool for booting, please specify at least" \
			"a pool"
		usage
	else
		installsource="media"
		pool=$1
	fi

	# SmartOS standard bootable filesystem is POOL/boot.
	bootfs=${pool}/boot

	# If we're a head node, bail early if we don't have a sufficiently
	# advanced set of gz-tools.
	if [[ "$TRITON_HN" == "yes" && ! -f /opt/smartdc/lib/bootpool.js ]]
	then
		eecho ""
		eecho "To activate a pool for Triton head node booting, newer"
		eecho "global-zone tools (namely support for sdc-usbkey to"
		eecho "treat $bootfs as a USB key equivalent) are required."
		eecho ""
		eecho "Please update your headnode global-zone tools by"
		err "using 'sdcadm experimental update-gz-tools' and try again."
	fi

	if ispoolenabled "$pool" ; then
		# NOTE: Different actions depending on standalone, CN, or HN.
		if [[ -d /${bootfs}/platform/. && -d /${bootfs}/boot/. ]]; then
			echo "Pool $pool appears to be bootable."
			if [[ "$TRITON_CN" == "yes" ]]; then
				echo "Use 'piadm update' to update the CN's" \
					"iPXE and backup PI."
			elif [[ "$TRITON_HN" == "yes" ]]; then
				echo "Use 'sdcadm platform' to change PIs."
			else
				echo "Use 'piadm install' and" \
					"'piadm activate' to change PIs."
			fi
			return 0
		fi
		# One or both of "platform" or "boot" aren't there.
		# For now, proceed clobber-style.
	fi

	if ! zfs list -H "$bootfs" > /dev/null 2>&1; then
		# Create a new bootfs and set it.
		# NOTE:	 Encryption should be turned off for this dataset.
		zfs create -o encryption=off "$bootfs" || \
			fatal "Cannot create $bootfs dataset"
	fi
	# We MAY need to do some reality checking if the `zfs list` shows
	# $bootfs. For now, just wing it. and plow forward.

	# At this point we have an existing SmartOS-standard boot filesystem,
	# but it's not specified as bootfs in the pool.  Test if bootfs can be
	# set...
	zpool set "bootfs=${bootfs}" "${pool}" || \
		fatal "Cannot set bootfs for $pool"
	# Reset our view of available bootable pools.
	getbootable

	if [[ "$TRITON_CN" == "yes" ]]; then
		bringup_CN
		update_boot_sectors "$pool" "$bootfs"
	elif [[ "$TRITON_HN" == "yes" ]]; then
		bringup_HN
		update_boot_sectors "$pool" "$bootfs"
		echo "NOTE:  Directory $bootfs on pool $pool is now able to be"
		echo "this head node's virtual bootable USB key."
		echo ""
		echo "If this isn't a replacement pool for an existing bootable"
		echo "pool, you should remove the USB key from this headnode"
		echo "and then reboot this headnode from a disk in $pool"
		echo ""
		echo "The USB key (even if it's another pool's bootfs) is"
		echo "now" $(sdc-usbkey status) "because that is what it was"
		echo "before piadm ran."
		echo ""
	else
		install "$installsource" "$pool"
		# install set 'installstamp' on our behalf.
		activate "$installstamp" "$pool"
	fi
}

refresh_or_disable_pool() {
	flag=$1
	pool=$2

	if [[ -z $pool ]]; then
		eecho "Must specify a pool for disabling or refresh"
		usage
	fi

	currbootfs=""
	# ispoolenabled sets currbootfs as a side-effect.
	ispoolenabled "$pool" || \
		err "Pool $pool is not bootable, and cannot be disabled or refreshed"

	if [[ "$flag" == "-d" ]]; then
		if [[ "$TRITON_HN" == "yes" ]]; then
			if [[ "$pool" == "$TRITON_HN_BOOTPOOL" ]]; then
				# The warning says it all.
				eecho "WARNING: Disabling currently-booting" \
					"pool"

				# For now, just bail in this case.
				err "Please boot from a USB key or other pool"

				# TODO? -- Check to see if there
				# are alternatives before disabling?
				#
				# First, use this tool to find other
				# bootable pools.
				#
				# echo "Other available pools:"
				# echo ""
				# bootable | grep -v "$pool"
				# echo ""
				#
				# Then check to see if there's an
				# actual USB key available.
				#
				# tdir=$(mktemp -d)
				# ... use new -u (force USB key search) option
				# sdc-usbkey mount -u $tdir
				# ... if tdir has a usb key, mention it
				# sdc-usbkey unmount $tdir
			else
				vecho "Disabling Triton Head Node inactive" \
					"bootable pool."
			fi
		fi
		vecho "Disabling bootfs on pool $pool"
		zpool set bootfs="" "$pool"
	else
		vecho "Refreshing boot sectors and/or ESP on pool $pool"
		# Refreshing works the same for all of standalone, compute
		# node, or head node.
	fi

	update_boot_sectors "$pool" "$currbootfs" "$flag"

	return 0
}

bootable() {
	if [[ $1 == "-d" || "$1" == "-r" ]]; then
		refresh_or_disable_pool "$1" "$2"
		return
	elif [[ $1 == "-e" ]]; then
		shift 1
		enablepool "$@"
		return
	fi

	# If we reach here, we're querying about a pool.

	if [[ "$1" == "" ]]; then
		mapfile -t allpools < <(zpool list -Ho name)
	else
		# Reality check for bad pool name.
		poolpresent "$1"
		# Or have a list of one pool...
		allpools=( "$1" )
	fi

	# We're guaranteed that, modulo background processes, $allpools has a
	# list of actual pools, even if it's a list-of-one.

	for pool in "${allpools[@]}"; do
		if zpool list -Ho bootfs "$pool" | grep -q "${pool}/boot" ; then
			bootable="BIOS"
			# Check for pcfs partition on pool disks.
			mapfile -t boot_devices < \
				<(zpool list -vHP "${pool}" | \
				grep -E 'c[0-9]+' | awk '{print $1}')
			for a in "${boot_devices[@]}"; do
				noslice=$(echo "$a" | sed -E 's/s[0-9]+//g')
				tdir=$(mktemp -d)
				# Assume that s0 on the physical disk would be
				# where the EFI System Partition (ESP) lives.
				# A pcfs mount, ALONG WITH a check for a
				# bootx64.efi executable, can confirm/deny
				# it. Do this instead of just checking for
				# bootsize because we can further
				# integrity-check here if need be.

				if mount -F pcfs "/dev/dsk/${noslice}s0" "$tdir" \
					> /dev/null 2>&1 && \
					[[ -f "$tdir/EFI/Boot/bootx64.efi" ]]; then
					efi="and UEFI"
				else
					efi=""
				fi
				umount -f "$tdir" > /dev/null 2>&1 && rmdir "$tdir"
			done
		else
			bootable="non-bootable"
			efi=""
		fi

		printf "%-30s ==> %s %s\n" "$pool" "$bootable" "$efi"
	done
}

if [[ "$1" == "-v" ]]; then
	VERBOSE=1
	shift 1
elif [[ "$1" == "-vv" ]]; then
	set -x
	VERBOSE=1
	shift 1
else
	VERBOSE=0
fi

# Determine if we're running on a Triton Compute Node (CN) or not:
bootparams | grep -E -q 'smartos=|headnode=' || initialize_as_CN
bootparams | grep -q 'headnode=' && initialize_as_HN

# Check the configuration file out.
config_check

cmd=$1
shift 1

case $cmd in
	activate | assign )
		privcheck "$cmd"
		standalone_only "$cmd"
		activate "$@"
		;;

	avail )
		standalone_only avail
		avail
		;;

	bootable )
		privcheck bootable
		bootable "$@"
		;;

	install )
		privcheck install
		standalone_only install
		install "$@"
		cd /${bootfs}
		regenerate_os
		;;

	list )
		list "$@"
		;;

	destroy | remove )
		privcheck "$cmd"
		standalone_only "$cmd"
		remove "$@"
		;;

	update )
		privcheck update
		update_CN "$@"
		;;

	*)
		usage
		;;

esac

exit 0
