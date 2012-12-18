#!/usr/bin/perl -w
# ============================== Summary =======================================
# Program : check_beanstalkd.pl
# Version : 0.1
# Date    : Dec 18 2012
# Updated : Dec 18 2012
# Author  : Alex Simenduev
# Summary : This is a nagios plugin that checks beanstalkd server state,
#           the plugin can check any stat metric of beanstalkd server.
# ================================ Change log ==================================
# Legend:
#               [*] Informational, [!] Bugix, [+] Added, [-] Removed
#
# Ver 0.1:
#               [*] Initial implementation.
# ========================== START OF PROGRAM CODE =============================
use strict;
use IO::Socket;
use Getopt::Long;
use File::Basename;

# Variables Section
# -------------------------------------------------------------------------- #
my $VERSION       = "0.1";
my $SCRIPT_NAME   = basename(__FILE__);
my $TIMEOUT       = 10; # timeout for the socket connection

# Nagios states
my $STATE_OK		= 0;
my $STATE_WARNING	= 1;
my $STATE_CRITICAL	= 2;
my $STATE_UNKNOWN	= 3;
my $STATE_DEPENDENT	= 4;

my @STATES = ("OK", "WARNING", "CRITICAL", "UNKNOWN", "DEPENDENT");

# Command line arguments variables
my $o_help	    = undef; # Want some help?
my $o_host	    = undef; # Hostname
my $o_port	    = undef; # Port
my $o_warn	    = undef; # Warning level
my $o_crit	    = undef; # Critical level
my $o_check	    = undef; # What to check (items, connections, memory)
my $o_inverse   = undef; # Use inverse calculation of warning/critical thresholds
my $o_version	= undef; # Script version

# Entry point of the script
# -------------------------------------------------------------------------- #
check_arguments();	# First check for command line arguments

# Connect to 'redis' server
my $SOCKET = IO::Socket::INET->new(
    PeerAddr => "$o_host:$o_port",
    Timeout  => $TIMEOUT
);

# Exit if connection failed
if (!$SOCKET) {
    print $STATES[$STATE_CRITICAL] . " - $@\n";
    exit $STATE_CRITICAL;
}

my ($strInfo, $intState, $intData, $strOutput, $strPerfData);

# Run redis 'INFO' command
print $SOCKET "stats\r\n";

# get how much bytes to read, read them and save to $strInfo variable
read($SOCKET, $strInfo, substr(<$SOCKET>, 3));

# close connection, we don't need it anymore
close($SOCKET);

# save the ouput into seperate lines (array)
my @lines = split("\r\n", $strInfo);

my $tmp_file = "/tmp/$SCRIPT_NAME-$o_host-$o_port-$o_check";
my $interval;

foreach my $line (@lines) {
    if ($line =~ m/$o_check: ([0-9]+)/) {
        ($intData, $interval) = get_delta_values($tmp_file, $1);

        # Do not continue if not enough data collected
        unless ($interval >= 1) {
            $intState  = $STATE_UNKNOWN;
            $strOutput = "Not enough data collected, rerun the check...";
            last;
        }

        $strOutput = sprintf("%d number of %s in %s (%.2f p/s)", $intData, $o_check, convert_time($interval), $intData / $interval);
        $strPerfData = "'$o_check'=$intData;;;;";
        last;
    }
}

# Set state to Unknown for anything else
unless ($strOutput) {
    $intState  =  $STATE_UNKNOWN;
    $strOutput = "Unknown check option ('$o_check') was specified";
}

# Check if state was set to UNKNOWN (3),
# if not, check if we using inverse option, then
# calculate the state according to data variable from the above checks
if (defined($intState) && $intState == $STATE_UNKNOWN) {
    $strPerfData  = "";
}
elsif ($o_warn == 0 && $o_crit == 0) {
    $intState = $STATE_OK;
}
elsif (! defined($o_inverse)) {
    if ($intData >= $o_crit) { $intState = $STATE_CRITICAL; }
    elsif ($intData >= $o_warn) { $intState = $STATE_WARNING; }
    else { $intState = $STATE_OK; }
}
else {
    if ($intData <= $o_crit) { $intState = $STATE_CRITICAL; }
    elsif ($intData <= $o_warn) { $intState = $STATE_WARNING; }
    else { $intState = $STATE_OK; }
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
		'h|help'		=> \$o_help,
		'H|hostname=s'	=> \$o_host,
		'P|port=i'      => \$o_port,
		'C|check=s'     => \$o_check,
		'w|warn=i'	    => \$o_warn,
		'c|crit=i'	    => \$o_crit,
		'I|inverse'     => \$o_inverse,
		'V|version'	    => \$o_version,
	) || exit $STATE_UNKNOWN; # exit if one of the options was not privided with required type (integer or string)

	if (defined($o_help)) {
	    print_help();
	    exit $STATE_UNKNOWN;
	}

	if (defined($o_version)) {
	    print "$SCRIPT_NAME: $VERSION\n";
	    exit $STATE_UNKNOWN;
    }

	if (!defined($o_check)) {
	    print "Usage error: Specify what to check, using '--check' option!\n";
	    print_usage();
	    exit $STATE_UNKNOWN;
	}

    # Set default values if needed.
    $o_host = "localhost" unless defined($o_host);
    $o_port = "11300" unless defined($o_port);

    $o_warn = 0 unless defined($o_warn);
    $o_crit = 0 unless defined($o_crit);
}

sub print_usage {
	print "Usage: $SCRIPT_NAME [-H <host>] [-P <port>] -C <check> -w <warn level> -c <crit level> [-I] [-V]\n";
}

sub print_help {
	print "\nRedis check plugin for Nagios, version ", $VERSION, "\n";
	print "(C) 2010, Alex Simenduev - http://www.planetit.ws\n\n";
	print_usage();
	print <<EOD;
-h, --help
    print this help message
-H, --hostname=STRING
    name or IP address of host to check (default: localhost)
-P, --port=INTEGER
    Beanstalkd port to use (default: 11300)
-C --check=STRING
    What to check (any metric of 'stats' command)
-w, --warn=INTEGER
    warning level (unit depends on the check)
-c, --crit=INTEGER
    critical level (unit depends on the check)
-I, --inverse
    Use inverse calculation of warning/critical thresholds
-V, --version
    prints version number

EOD
}
