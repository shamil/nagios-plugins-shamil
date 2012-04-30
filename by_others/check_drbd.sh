#!/bin/bash

##########################################################
# Author: Rodrigo Scharlack Vian
# Email:  rodrigovian@gmail.com
# Create: 2012-04-27
#
# This script check status of DRBD Resources for nagios
#
# Checks: resource status, role and disk status
#
##########################################################

PROGNAME=${0##*/}
VERSION="1"

DRBDOVER=`which drbd-overview`
DRBDADM=`which drbdadm`
ECHO=`which echo`
CAT=`which cat`
CUT=`which cut`

# Nagios Status
OK="0"
WARNING="1"
ERROR="2"
UNKNOWN="3"

print_help () {
$CAT << EOF
============== HELP ==============
$PROGNAME version $VERSION
This script check status of DRBD Resources

Usage: $PROGNAME <RESOURCE>

Example: $PROGNAME r0
==================================

EOF
}

if [ -z $DRBDADM ] ; then
	$ECHO -e "\nERROR: command 'drbdadm' is not found.\n"
	exit $UNKNOWN
elif [ -z $DRBDOVER ] ; then
	$ECHO -e "\nERROR: command 'drbd-overview' is not found.\n"
	exit $UNKNOWN
elif [ $# -lt 1 ]; then
	$ECHO -e "\nERROR: missing Resource.\n"
	print_help
	exit $UNKNOWN
elif [ $# -gt 1 ]; then
	$ECHO -e "\nERROR: much arguments.\n"
	print_help
	exit $UNKNOWN
elif [ $1 = --help ]; then
	print_help
	exit $UNKNOWN
fi

checkDState () {
case $1 in
	UpToDate|Attaching|Negotiating)
		exit $OK
		;;
	Consistent|Inconsistent|Outdated)
		exit $WARNING
		;;
	Diskless|DUnknown|Failed)
		exit $ERROR
		;;
esac
}

RESOURCE=$1
##############################################################################################################
# drbd-overview stout:
# "  <index>:<resource>  <cstate> <role> <dstate> C r---- <mountpoint> <fstype> <size> <used> <avail> used%"
#
# Example (OUTPUT NO QUOTES):
# "  0:r0  Connected Primary/Secondary UpToDate/UpToDate C r---- /DRBD ext4 939M 227M 665M 26%"
##############################################################################################################

for res in `$DRBDOVER | $CUT -d\  -f 3 | $CUT -d : -f 2` ; do
	if [ "$res" == "$RESOURCE" ]; then
		CHK_RES=1
		break
	else
		CHK_RES=0
	fi
done

if [ $CHK_RES -eq 0 ]; then
	$ECHO "DRBD ERROR: resource '$RESOURCE' is not found."
	exit $UNKNOWN
fi

CSTATE=`$DRBDADM cstate $RESOURCE`
DSTATE=`$DRBDADM dstate $RESOURCE | $CUT -d / -f 1`
ROLE=`$DRBDADM role $RESOURCE | $CUT -d / -f 1`

case $CSTATE in
	Connected)
		$ECHO "DRBD Resource '$RESOURCE' is $CSTATE. Role: '$ROLE'. Disk State: '$DSTATE'."
		checkDState $DSTATE
		;;
	SyncSource)
		$ECHO "DRBD Resource '$RESOURCE' is synchronizing as source. Role: '$ROLE'. Disk State: '$DSTATE'."
		checkDState $DSTATE
		;;
	SyncTarget)
		$ECHO "DRBD Resource '$RESOURCE' is synchronizing as target. Role: '$ROLE'. Disk State: '$DSTATE'."
		checkDState $DSTATE
		;;
	PausedSyncS)
		$ECHO "DRBD Resource '$RESOURCE' is synchronizing as source, but is paused. Role: '$ROLE'. Disk State: '$DSTATE'."
		exit $WARNING
		;;
	PausedSyncT)
		$ECHO "DRBD Resource '$RESOURCE' is synchronizing as target, but is paused. Role: '$ROLE'. Disk State: '$DSTATE'."
		exit $WARNING
		;;
	VerifyS)
		$ECHO "Online verification is running on DRBD Resource '$RESOURCE' as verification source. Role: '$ROLE'. Disk State: '$DSTATE'."
		exit $WARNING
		;;
	VerifyT)
		$ECHO "Online verification is running on DRBD Resource '$RESOURCE' as verification target. Role: '$ROLE'. Disk State: '$DSTATE'."
		exit $WARNING
		;;
	StandAlone|Unconnected|Timeout|TearDown|ProtocolError|NetworkFailure|BrokenPipe)
		$ECHO "DRBD Resource '$RESOURCE' is $CSTATE. Role: '$ROLE'. Disk State: '$DSTATE'."
		exit $ERROR
		;;
		*)
		$ECHO "State Undefined: $CSTATE. Please, visit http://www.drbd.org/users-guide-emb/ch-admin.html#s-check-status for more explanation."
		exit $UNKNOWN
esac
