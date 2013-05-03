#!/usr/bin/perl -w
# ============================== Summary =======================================
# Program : check_beanstalkd.pl
# Version : 0.6
# Date    : Dec 18 2012
# Updated : May 3 2013
# Author  : Alex Simenduev
# Summary : This is a nagios plugin that checks beanstalkd server state,
#           the plugin can check any stat metric of beanstalkd server.
# ================================ Change log ==================================
# Legend:
#               [*] Informational, [!] Bugix, [+] Added, [-] Removed
#
# Ver 0.6:
#               [!] Fixed nagios state calculation
#
# Ver 0.5:
#               [+] Added support of all stats commands (stats, stats-job, stats-tube)
#               [+] Added support to just get the value of a stat (default behaviour)
#               [*] To enable delta (per interval) check, add --interval option
#
# Ver 0.1:
#               [*] Initial implementation.
# ========================== START OF PROGRAM CODE =============================
use strict;
use IO::Socket;
use Digest::MD5;
use Getopt::Long;
use File::Basename;

# Variables Section
# -------------------------------------------------------------------------- #
my $VERSION       = "0.5";
my $SCRIPT_NAME   = basename(__FILE__);
my $TIMEOUT       = 10; # timeout for the socket connection

# Nagios states
my $STATE_OK        = 0;
my $STATE_WARNING   = 1;
my $STATE_CRITICAL  = 2;
my $STATE_UNKNOWN   = 3;
my $STATE_DEPENDENT = 4;

my @STATES = ("OK", "WARNING", "CRITICAL", "UNKNOWN", "DEPENDENT");

# Command line arguments variables
my $o_help      = undef; # Want some help?
my $o_host      = undef; # Hostname
my $o_port      = undef; # Port
my $o_warn      = undef; # Warning level
my $o_crit      = undef; # Critical level
my $o_cmd       = undef; # Beanstalkd command to run
my $o_metric    = undef; # Get metric of the benatslkd command
my $o_inverse   = undef; # Use inverse calculation of warning/critical thresholds
my $o_interval  = undef; # Get delta values per run interval (calculates p/s)
my $o_version   = undef; # Script version

# Entry point of the script
# -------------------------------------------------------------------------- #
check_arguments();  # First check for command line arguments

# Connect to 'beanstalkd' server
my $SOCKET = IO::Socket::INET->new(
    PeerAddr => "$o_host:$o_port",
    Timeout  => $TIMEOUT
);

# Exit if connection failed
if (!$SOCKET) {
    print $STATES[$STATE_CRITICAL] . " - $@\n";
    exit $STATE_CRITICAL;
}

my ($strCmdStatus, $strResponse, $intState, $intData, $strOutput, $strPerfData);

(my $strActualCmd = $o_cmd) =~ s/:/ /;  # prepare the command
print $SOCKET "$strActualCmd\r\n";      # run thr command

# read the first line of the output (it contains the status ot the command)
# also trim trailing spaces & end lines (replacement for chomp).
($strCmdStatus = <$SOCKET>) =~ s/\s+$//;

unless ($strCmdStatus =~ /^OK/) {
    close($SOCKET);
    print "UNKNOWN: Error running '$o_cmd' ($strCmdStatus)\n";
    exit $STATE_UNKNOWN;
}

# get how much bytes to read, read them and save to $strResponse variable
read($SOCKET, $strResponse, substr($strCmdStatus, 3));

# close connection, we don't need it anymore
close($SOCKET);

# save the ouput into seperate lines (array)
my @lines = split("\r\n", $strResponse);

my $tmp_file = "/tmp/${SCRIPT_NAME}_" . Digest::MD5::md5_hex($o_host . $o_port . $o_cmd . $o_metric);
my $interval;

foreach my $line (@lines) {
    if ($line =~ m/$o_metric: ([0-9]+)/) {
        # get per interval deltas, if requested
        if ($o_interval) {
            ($intData, $interval) = get_delta_values($tmp_file, $1);

            # Do not continue if not enough data collected
            unless ($interval >= 1) {
                $intState  = $STATE_UNKNOWN;
                $strOutput = "Not enough data collected, rerun the check...";
                last;
            }

            $strOutput = sprintf("command='%s', metric=%s, value=%d (interval=%s, %.2f p/s)", $o_cmd, $o_metric, $intData, convert_time($interval), $intData / $interval);
        }
        else {
            $intData = $1;
            $strOutput = sprintf("command='%s', metric=%s, value=%d", $o_cmd, $o_metric, $intData);
        }

        $strPerfData = "'${o_cmd}:${o_metric}'=$intData;;;;";
        last;
    }
}

# Set state to Unknown for anything else
unless ($strOutput) {
    $intState  =  $STATE_UNKNOWN;
    $strOutput = "Couldn't get requested metric, check your input (command='$o_cmd', metric='$o_metric')";
}

# Check if state was set to UNKNOWN (3),
# if not, check if we using inverse option, then
# calculate the state according to $intData variable from the above checks
if (defined($intState) && $intState == $STATE_UNKNOWN) {
    $strPerfData  = "";
}
elsif (defined($o_inverse)) {
    if (defined($o_crit) && $intData <= $o_crit) {
        $intState = $STATE_CRITICAL;
    }
    elsif (defined($o_warn) && $intData <= $o_warn) {
        $intState = $STATE_WARNING;
    }
    else {
        $intState = $STATE_OK;
    }
}
else {
    if (defined($o_crit) && $intData >= $o_crit) {
        $intState = $STATE_CRITICAL;
    }
    elsif (defined($o_warn) && $intData >= $o_warn) {
        $intState = $STATE_WARNING;
    }
    else {
        $intState = $STATE_OK;
    }
}

# Now print the final output string
print $STATES[$intState] . " - $strOutput|$strPerfData\n";

# Finally exit with current state error code.
exit $intState;

# Convert time in seconds, into something that is more human readable
# e.g. 2d 6h 10m 8s
sub convert_time {
    my ($time, $days, $hours, $minutes, $seconds);

    # Get time in seconds
    $time = shift;

    # Get days
    $days = int($time / 86400);
    $time -= ($days * 86400);

    # Get hours
    $hours = int($time / 3600);
    $time -= ($hours * 3600);

    # Get minutes & seconds
    $minutes = int($time / 60);
    $seconds = $time % 60;

    $days    = $days < 1 ? "" : $days . "d ";
    $hours   = $hours < 1 ? "" : $hours ."h ";
    $minutes = $minutes < 1 ? "" : $minutes . "m ";
    $time = $days . $hours . $minutes . $seconds . "s";

    return $time;
}

# Get delta values, using temp file
# Returns list with 2 values:
#   1: Metric delta
#   2: Interval in seconds
sub get_delta_values {
    my $timestamp = time();
    my ($tmp_file, $metricval) = @_;
    my ($timestamp_diff, $metricval_diff) = (1, 0); # Minimum interval is 1 second

    # Open file to get saved data
    if (-e $tmp_file) {
        if (open(FILE, "< $tmp_file")) {
            my $saved_data = <FILE>;     # read first line from file,
            close(FILE);                 # then close the file

            $saved_data =~ /^(.*),(.*)/; # parse the "saved data" line
            $timestamp_diff = $timestamp - $1;
            $metricval_diff = $metricval - $2;
        }
        else {
            print "UNKNOWN: Unable to open '$tmp_file' file\n";
            exit $STATE_UNKNOWN;
        }
    }

    # Open/Create a temp file
    if (open(FILE, "+> $tmp_file")) {
        # then save new data to it
        print FILE "$timestamp,$metricval";
        close(FILE);
    }
    else {
        print "UNKNOWN: Unable to open '$tmp_file' file\n";
        exit $STATE_UNKNOWN;
    }

    # Return the deltas ...
    return ($metricval_diff, $timestamp_diff);
}

# This sub parses the command line arguments
sub check_arguments {
    # if no arguments specified just print usage
    if ($#ARGV + 1 == 0) {
        print_usage();
        exit $STATE_UNKNOWN;
    }

    Getopt::Long::Configure ("bundling");
    GetOptions(
        'h|help'        => \$o_help,
        'H|hostname=s'  => \$o_host,
        'P|port=i'      => \$o_port,
        'C|cmd=s'       => \$o_cmd,
        'M|metric=s'    => \$o_metric,
        'w|warn=i'      => \$o_warn,
        'c|crit=i'      => \$o_crit,
        'inverse'       => \$o_inverse,
        'interval'      => \$o_interval,
        'V|version'     => \$o_version,
    ) || exit $STATE_UNKNOWN; # exit if one of the options was not privided with required type (integer or string)

    if (defined($o_help)) {
        print_help();
        exit $STATE_UNKNOWN;
    }

    if (defined($o_version)) {
        print "$SCRIPT_NAME: $VERSION\n";
        exit $STATE_UNKNOWN;
    }

    if (!defined($o_metric)) {
        print "Usage error: Specify which metric to check, using '--metric' option!\n";
        print_usage();
        exit $STATE_UNKNOWN;
    }

    # Set default values if needed.
    $o_host = "localhost" unless defined($o_host);
    $o_port = "11300" unless defined($o_port);

    $o_cmd = "stats" unless defined($o_cmd);
    $o_cmd =~ s/^\s+|\s+$//g; # trim
    $o_cmd =~ s/\s+/ /g;       # remove double spacing

    # we support only stats[-] commands
    unless (lc($o_cmd) =~ /^stats(-.*)?$/) {
        print "UNKNOWN: Unsupported command '$o_cmd'\n";
        exit $STATE_UNKNOWN;
    }
}

sub print_usage {
    print "Usage: $SCRIPT_NAME [-H <host>] [-P <port>] -C <check> -w <warn level> -c <crit level> [-I] [-V]\n";
}

sub print_help {
    print "Beanstalkd check plugin for Nagios, version ", $VERSION, "\n";
    print "(C) 2013, Alex Simenduev - https://github.com/shamil/nagios-plugins-shamil\n\n";
    print_usage();
    print <<EOD;
-h, --help
    print this help message
-H, --hostname=STRING
    name or IP address of host to check (default: localhost)
-P, --port=INTEGER
    Beanstalkd port to use (default: 11300)
-C --cmd=STRING
    Beanstalkd stats command to run (default is stats)
-M --metric=STRING
    Get metric of the benatslkd command
-w, --warn=INTEGER
    warning level (unit depends on the check)
-c, --crit=INTEGER
    critical level (unit depends on the check)
--inverse
    Use inverse calculation of warning/critical thresholds
--interval
    Get delta values per run interval (calculates p/s)
-V, --version
    prints version number

EOD
}
