#!/bin/bash
# ============================== Summary =======================================
# Program : check_solr.sh
# Version : 2010.10.12
# Date    : July 13 2010
# Author  : Alex Simenduev - (http://www.planetit.ws)
# Summary : This is a nagios plugin that checks Apache Solr host
#
# ================================ Description =================================
# The plugin is capable of check couple aspects of Apache Solr server. Supported
# checks are ping, replication and number of documents. Check usage for info.
#
# Notice: The plugin requires 'curl' and 'xmlstarlet' utilities in order to work
# ================================ Change log ==================================
# Legend:
#                [*] Informational, [!] Bugix, [+] Added, [-] Removed
#
# Ver 2010.10.12:
#                [*] Replication check was improved a bit to avoid false alarms
#
# Ver 2010.7.29:
#                [*] Reduced number of http(s) requests in replication check
#
# Ver 2010.7.14:
#                [*] Speed improvement in 'numdocs' metric
#
# Ver 2010.7.13:
#                [*] Initial implementation.
#
# ========================== START OF PROGRAM CODE =============================
# Disable STDERR output, comment it while debugging
exec 2> /dev/null

SCRIPT_NAME=`basename $0`
SCRIPT_VERSION="2010.10.11"

# Nagios return codes
STATE_OK=0
STATE_WARNING=1
STATE_CRITICAL=2
STATE_UNKNOWN=3

# Nagios final state (OK by default)
NAGIOS_STATE=$STATE_OK

# Nagios final output
NAGIOS_OUTPUT=
NAGIOS_PERF_OUTPUT=

# Get path of requierd utilities
CURL=$(which curl)			   # curl path
XMLSTARLET=$(which xmlstarlet) # xmlstarlet path

# Command-line variables
O_SOLR_HOST="localhost"  # default solr host
O_SOLR_PORT=8983		 # default solr port
O_SOLR_METRIC=           # Check metric
O_SOLR_CORE=             # Core(s) to check
O_TIMEOUT=10			 # default check timeout in seconds
O_SSL=0					 # are we using ssl

# Maximum seconds behind Solr master
SOLR_MAX_SECONDS_BEHIND_MASTER=3600 # 1 hour

# Check that curl is exists
[ -z $CURL ] && {
	echo "Could not find 'curl' utility in the PATH."
	exit $STATE_UNKNOWN
}

# Check that curl is exists
[ -z $XMLSTARLET ] && {
	echo "Could not find 'xmlstarlet' utility in the PATH."
	exit $STATE_UNKNOWN
}

# Usage syntax
USAGE="usage: $SCRIPT_NAME [-H host] [-P <port>] -M <metric> [-C <core>...] [-T <seconds>] [-h]"

# Print help along with usage
print_help()
{
    echo "$SCRIPT_NAME - Nagios plugin to check Apache Solr"
    echo "version $SCRIPT_VERSION, by Alex Simenduev, http://www.planetit.ws"

    echo -e "\n$USAGE\n"

    echo "Parameters description:"
    echo " -H|--host <host>          # Solr host (default is localhost)"
    echo " -S|--ssl <host>           # Same as above, but connect with HTTPS"
    echo " -P|--port <port>          # Solr port number (default is 8983)"
    echo " -M|--metric <metric>      # Which metric to check (one of ping, replication, or numdocs)"
    echo " -C|--core <core>...       # Which cores to check, comma delimited (default is all cores)"
    echo " -T|--timeout              # Solr host connection timeout (used by curl)"
    echo " -h|--help                 # Print this message"
}

# Prints nagios state as string
get_nagios_state()
{
    case "$1" in
        0) RETURN_VAL="OK"
           ;;
        1) RETURN_VAL="WARNING"
           ;;
        2) RETURN_VAL="CRITICAL"
           ;;
        *) RETURN_VAL="UNKNOWN"
           ;;
    esac

    echo $RETURN_VAL
}

# Execute 'curl' command and print it's output
exec_curl() {
	local RESPONSE EXITCODE

	RESPONSE=$(curl --max-time $O_TIMEOUT --fail --silent $@)
	EXITCODE=$?

	echo $RESPONSE
	return $EXITCODE
}

# Get all solar cores (returned as space delimited)
solr_get_cores() {
	echo $(exec_curl ${URL_PREFIX}${O_SOLR_HOST}:${O_SOLR_PORT}/solr/admin/cores?wt=xml |
		xmlstarlet sel -t -m "/response/lst[@name='status']/lst" -v "@name" -o " ")
}

# Check if specified core exists
solr_core_exists() {
	[ -z $(exec_curl ${URL_PREFIX}${O_SOLR_HOST}:${O_SOLR_PORT}/solr/admin/cores?wt=xml |
		xmlstarlet sel -t -m "/response/lst[@name='status']/lst" -i "@name='$1'" -v "@name") ] && return 1 || return 0
}

# Check if specified core in Solr host acts as slave
solr_core_isslave() {
	local OUTPUT=$(exec_curl "${URL_PREFIX}${O_SOLR_HOST}:${O_SOLR_PORT}/solr/$1/replication?command=details&wt=xml" |
		xmlstarlet sel -t -v "/response/lst[@name='details']/str[@name='isSlave']")

	[ "$OUTPUT" == "true" ] && return 0 || return 1
}

# Get ping status of specified core
solr_core_ping() {
    # Check if core actually exists before continuing
    solr_core_exists $1 || {
        echo "not exists => WARNING"
        return $STATE_WARNING
    }

	local RESULT=$(exec_curl ${URL_PREFIX}${O_SOLR_HOST}:${O_SOLR_PORT}/solr/$1/admin/ping?wt=xml |
		xmlstarlet sel -t -v "/response/str[@name='status']")

	if [ "$RESULT" == "OK" ]; then
	    echo "OK"
	    return $STATE_OK
    else
        echo "$RESULT => CRITICAL"
        return $STATE_CRITICAL
    fi
}

# Replication status of specified core
solr_core_replication() {
    # Check if core actually exists before continuing
    solr_core_exists $1 || {
        echo "not exists => WARNING"
        return $STATE_WARNING
    }

    # Check if core is slave
    solr_core_isslave $1 || {
        echo "not slave => UNKNOWN"
        return $STATE_UNKNOWN
    }

    local MASTER_URL MASTER_INDEXVER
    local SLAVE_DETAILS SLAVE_INDEXVER SLAVE_REPLICATING SLAVE_LASTREPLICATED

    # Get slave replication details
    SLAVE_DETAILS=$(exec_curl "${URL_PREFIX}${O_SOLR_HOST}:${O_SOLR_PORT}/solr/$1/replication?command=details&wt=xml")

    # Get master URL of specified core
    MASTER_URL=$(echo $SLAVE_DETAILS | xmlstarlet sel -t -v "/response/lst[@name='details']/lst[@name='slave']/str[@name='masterUrl']")

    # Try to connect to master
    MASTER_INDEXVER=$(exec_curl "${MASTER_URL}?command=indexversion&wt=xml") || {
	    echo "cannot reach master => UNKNOWN"
	    return $STATE_UNKNOWN
    }

    # Get index version from master
    MASTER_INDEXVER=$(echo $MASTER_INDEXVER |
        xmlstarlet sel -t -v "/response/long[@name='indexversion']")

    # Get index version from slave
    SLAVE_INDEXVER=$(echo $SLAVE_DETAILS |
        xmlstarlet sel -t -v "/response/lst[@name='details']/long[@name='indexVersion']")

    # Check if indexes match each other
    if [ $MASTER_INDEXVER -ne $SLAVE_INDEXVER ]; then
        # Check if slave currently replicating
        SLAVE_REPLICATING=$(echo $SLAVE_DETAILS |
            xmlstarlet sel -t -v "/response/lst[@name='details']/lst[@name='slave']/str[@name='isReplicating']")

        # Get last replicated date
        SLAVE_LASTREPLICATED=$(echo $SLAVE_DETAILS |
            xmlstarlet sel -t -v "/response/lst[@name='details']/lst[@name='slave']/str[@name='indexReplicatedAt']")

        # Convert the date to unix timestamp and get difference in seconds from NOW
    	SLAVE_LASTREPLICATED=$(date -d "$SLAVE_LASTREPLICATED" +%s)
    	SLAVE_LASTREPLICATED=$(date -d "now - $SLAVE_LASTREPLICATED seconds" +%s)

        # Return CRITICAL if slave isn't currently replicating
        # and it's behind master for more then 1 hour (configurable)
      	if [ "$SLAVE_REPLICATING" == "false" -a $SLAVE_LASTREPLICATED -gt $SOLR_MAX_SECONDS_BEHIND_MASTER ]; then
      	    echo "${SLAVE_LASTREPLICATED} seconds behind master => CRITICAL"
      	    return $STATE_CRITICAL
        fi
    fi

    # If we here, the replication is working ;)
    echo "OK"
    return $STATE_OK
}

# Get number of documents in specified core
solr_core_numdocs() {
    # Check if core actually exists before continuing
    solr_core_exists $1 || {
        echo "not exists => WARNING"
        return $STATE_WARNING
    }

	local RESULT=$(exec_curl "${URL_PREFIX}${O_SOLR_HOST}:${O_SOLR_PORT}/solr/$1/admin/luke?numTerms=0&wt=xml" |
		xmlstarlet sel -t -v "/response/lst[@name='index']/int[@name='numDocs']")

	echo $RESULT
    return $STATE_OK
}

# Print help if requested
if [ "$1" == "--help" ] || [ "$1" == "-h" ]; then
    print_help
    exit $STATE_UNKNOWN
elif [ $# -lt 2 ]; then
    echo "$USAGE"
    exit $STATE_UNKNOWN
fi

# Parse parameters
while [ $# -gt 0 ]; do
    case "$1" in
        -H|--host) shift
            O_SOLR_HOST=$1
            ;;
        -S|--ssl) shift
            O_SOLR_HOST=$1
            O_SSL=1
            ;;
        -P|--port) shift
            O_SOLR_PORT=$1
            ;;
        -M|--metric) shift
            O_SOLR_METRIC=$(echo $1 | tr "[:upper:]" "[:lower:]")
            ;;
        -C|--core) shift
            O_SOLR_CORE=$(echo $1 | sed "s/,/ /g")
            ;;
        -T|--timeout) shift
            O_TIMEOUT=$1
            ;;
        *)  echo "Unknown argument: $1"
            exit $STATE_UNKNOWN
            ;;
    esac
    shift
done

# Check that required argument (metric) was specified
[ -z "$O_SOLR_METRIC" ] && {
	echo "Usage error: 'metric' parameter missing"
	exit $STATE_UNKNOWN
}

# Are we using SSL?
[ $O_SSL -gt 0 ] && URL_PREFIX="https://" || URL_PREFIX="http://"

# Check that we can connect to solr host
exec_curl ${URL_PREFIX}${O_SOLR_HOST}:${O_SOLR_PORT}/solr/admin/cores >/dev/null || {
	echo "CRITICAL: host '$O_SOLR_HOST' is not responding."
	exit $STATE_CRITICAL
}

# Get all cores if not specified manually
[ -z "$O_SOLR_CORE" ] && O_SOLR_CORE=$(solr_get_cores)

# Check the metrics
# ping
if [ "$O_SOLR_METRIC" == "ping" ]; then
    NAGIOS_OUTPUT="Ping -"

    for core in $O_SOLR_CORE; do
        RESULT=$(solr_core_ping $core)
        STATE=$?
        [ $NAGIOS_STATE -ne $STATE_CRITICAL -a $STATE -ne $STATE_OK ] && NAGIOS_STATE=$STATE
        NAGIOS_OUTPUT="$NAGIOS_OUTPUT core '$core' $RESULT,"
    done
# replication
elif [ "$O_SOLR_METRIC" == "replication" ]; then
    NAGIOS_OUTPUT="Replication -"

    for core in $O_SOLR_CORE; do
        RESULT=$(solr_core_replication $core)
        STATE=$?
        [ $NAGIOS_STATE -ne $STATE_CRITICAL -a $STATE -ne $STATE_OK ] && NAGIOS_STATE=$STATE
        NAGIOS_OUTPUT="$NAGIOS_OUTPUT core '$core' $RESULT,"
    done
# numdocs
elif [ "$O_SOLR_METRIC" == "numdocs" ]; then
    NAGIOS_OUTPUT="Number of documents -"
    NAGIOS_PERF_OUTPUT=" |"

    for core in $O_SOLR_CORE; do
        RESULT=$(solr_core_numdocs $core)
        NAGIOS_OUTPUT="$NAGIOS_OUTPUT core '$core' $RESULT,"
        NAGIOS_PERF_OUTPUT="$NAGIOS_PERF_OUTPUT 'core_$core'=$RESULT;;;;"
    done
# or warn
else
	echo "Metric '$O_SOLR_METRIC' is not supported"
	exit $STATE_UNKNOWN
fi

# Remove trailing comma if exists
NAGIOS_OUTPUT=${NAGIOS_OUTPUT%,}

# Print final output and exit
echo "$(get_nagios_state $NAGIOS_STATE): ${NAGIOS_OUTPUT}${NAGIOS_PERF_OUTPUT}"
exit $NAGIOS_STATE
