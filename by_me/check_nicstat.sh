#!/bin/sh
#=========================================================================================
# ./check_nicstat -w <warning> -c <crtitical> [-I <check_item>] [-s <check_seconds>] [-i <interface>]
#
# Written by: Alex Simenduev
#
# Requires:
#  - nicstat utility (http://blogs.sun.com/timc/entry/nicstat_the_solaris_and_linux)
#  - mktemp
#  - bc
#
# Description:
#    Checks NIC statistics for specified interval, averages, and provides response.
#    uses basic shell and common utilities, just add 'nicstat' to necessary path.
# ========================================================================================
SCRIPT_NAME=`basename $0`
SCRIPT_VERSION="0.6"

# Nagios return codes
STATE_OK=0
STATE_WARNING=1
STATE_CRITICAL=2
STATE_UNKNOWN=3

# Default state
NAGIOS_STATE=$STATE_UNKNOWN

# Output data coloums (per row)
COL_READ_KB=3
COL_WRITE_KB=4
COL_READ_PACKETS=5
COL_WRITE_PACKETS=6
COL_UTILIZATION=7

# Default script options, change if needed
CHECK_SECONDS=5              # Set to default of 5
CHECK_ITEM=$COL_UTILIZATION  # Set to utilization
TEMP_FILE=`/usr/bin/mktemp /tmp/$SCRIPT_NAME.XXXXXX`
NICSTAT_PATH="/usr/local/nagios/libexec/nicstat"

USAGE="usage: $SCRIPT_NAME -w <warning> -c <crtitical> [-I <check_item>] [-s <check_seconds>] [-i <interface>]"

print_help()
{
    echo "check_nicstat - Nagios plugin to check NIC statistics by using 'nicstat' utility"
    echo "version $SCRIPT_VERSION, by Alex Simenduev, shamil.si (at) gmail.com, 24/02/2009\n"

    echo "$USAGE\n"

    echo "Parameters description:"
    echo " -w|--warning <warning>    # Warning threshold"
    echo " -c|--critical <critical>  # Warning threshold"
    echo " -I|--item <item_number>   # numerical represintation of item to check (from 3-7)"
    echo " -i|--interface            # network interface to check"
    echo " -s|--seconds              # for how long to run the check (from 3-10)"
    echo " -h|--help                 # print this message\n"

    echo "Item numbers description:"
    echo "  3 # kb/s read"
    echo "  4 # kb/s write"
    echo "  5 # packet/s read"
    echo "  6 # packet/s write"
    echo "  7 # percent of utilization"
}

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

get_item_name()
{
    case "$1" in
        3) RETURN_VAL="read kb/s"
           ;;

        4) RETURN_VAL="write kb/s"
           ;;

        5) RETURN_VAL="read pk/s"
           ;;

        6) RETURN_VAL="write pk/s"
           ;;

        7) RETURN_VAL="load %"
           ;;
    esac

    echo $RETURN_VAL
}

# Check if nicstat exists.
if [ ! -f $NICSTAT_PATH ]; then
    echo "Can't find nicstat utility.";
    exit $NAGIOS_STATE
fi

# Print usage if needed
if [ "$1" = "--help" ] || [ "$1" = "-h" ]; then
    print_help
    exit $NAGIOS_STATE
elif [ $# -lt 4 ]; then
    echo "$USAGE"
    exit $NAGIOS_STATE
fi

# Parse parameters
while [ $# -gt 0 ]; do
    case "$1" in
        -i | --interface) shift
            IFACE=$1
            ;;

        -s | --seconds) shift
            CHECK_SECONDS=$1
            ;;

        -I | --item) shift
            CHECK_ITEM=$1
            ;;

        -w | --warning) shift
            WARNING_THRESHOLD=$1
            ;;

        -c | --critical) shift
            CRITICAL_THRESHOLD=$1
            ;;

        *)  echo "Unknown argument: $1"
            exit $NAGIOS_STATE
            ;;
    esac
    shift
done

# Validate that check items is between 3 and 7
if [ $CHECK_ITEM -lt 3 ] || [ $CHECK_ITEM -gt 7 ]; then
    echo "Check item number must be between 3 and 7."
    exit $NAGIOS_STATE
fi

# Validate that check seconds is between 3 and 10
if [ $CHECK_SECONDS -lt 3 ] || [ $CHECK_SECONDS -gt 10 ]; then
    echo "Check seconds must be between 3 and 10."
    exit $NAGIOS_STATE
fi

# Check if interface was set and exists.
if [ "$IFACE" != "" ]; then
    if [ "`$NICSTAT_PATH -p -i "$IFACE" 2>&1 | grep -i "$IFACE"`" != "" ]; then
        INTERFACES=$IFACE
    else
        echo "Interface '$IFACE' doesn't exists."
        exit $NAGIOS_STATE
    fi
else
    INTERFACES=`$NICSTAT_PATH -p | grep -v lo0 | cut -f 2 -d :`
fi

# Let's save the output for further processing
`$NICSTAT_PATH -p 1 $CHECK_SECONDS > $TEMP_FILE`

# Prepare for parsing
ITEM_NAME=`get_item_name "$CHECK_ITEM"`
NAGIOS_TEXT_OUTPUT=""
NAGIOS_PERF_OUTPUT=""
for IFACE in $INTERFACES; do
    # Parse each line
    AVERAGE=0
    for LINE in `cat $TEMP_FILE | grep -i "$IFACE" | tail +2`; do
        CHECK_VALUE=`echo $LINE | cut -f $CHECK_ITEM -d :`
        AVERAGE=`echo "scale=3; $AVERAGE + $CHECK_VALUE" | /usr/bin/bc`
    done
    AVERAGE=`echo "scale=3; $AVERAGE / ($CHECK_SECONDS - 1)" | /usr/bin/bc`

    # Fix 'bc' output if needed.
    if [ "`echo $AVERAGE | cut -c 1`" = "." ]; then
	    AVERAGE="0$AVERAGE"
    elif [ $AVERAGE -eq 0 ]; then
	    AVERAGE="0.0"
	fi

    # Compare thresholds (if crit & warn equals 0, then no checking will be performed, and OK will be set).
    if [ $CRITICAL_THRESHOLD -eq 0 ] && [ $WARNING_THRESHOLD -eq 0 ]; then
     	NAGIOS_STATE=$STATE_OK
    elif [ $AVERAGE -ge $CRITICAL_THRESHOLD ]; then
	    NAGIOS_STATE=$STATE_CRITICAL
    elif [ $AVERAGE -ge $WARNING_THRESHOLD ] && [ $NAGIOS_STATE -ne $STATE_CRITICAL ]; then
	    NAGIOS_STATE=$STATE_WARNING
    elif [ $NAGIOS_STATE -ne $STATE_CRITICAL ]; then
     	NAGIOS_STATE=$STATE_OK
    fi

    # Produce nagios compliant output
    NAGIOS_TEXT_OUTPUT="$NAGIOS_TEXT_OUTPUT'$IFACE' $ITEM_NAME: $AVERAGE, "
    NAGIOS_PERF_OUTPUT="$NAGIOS_PERF_OUTPUT'$IFACE'=$AVERAGE;;;; "
done

# Finaly output the message
echo "`get_nagios_state "$NAGIOS_STATE"` (${CHECK_SECONDS}s average) - $NAGIOS_TEXT_OUTPUT|$NAGIOS_PERF_OUTPUT"

# Exit cleanly
[ -f "$TEMP_FILE" ] && rm -f $TEMP_FILE
exit $NAGIOS_STATE
