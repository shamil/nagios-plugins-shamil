#!/usr/bin/perl -w
# ============================== Summary =======================================
# Program : check_memcached.pl
# Version : 2010.7.14
# Date    : May 25 2010
# Updated : July 15 2010
# Author  : Alex Simenduev - (http://www.planetit.ws)
# Summary : This is a nagios plugin that checks memcached server state
#
# ================================ Description =================================
# The plugin is capable of check couple aspects of memcached server. Supported
# checks are Items, Connections, Memory, Uptime, and Evictions. Check usage for
# how to use them
# ================================ Change log ==================================
# Legend:
#               [*] Informational, [!] Bugix, [+] Added, [-] Removed
#
# Ver 2010.7.14:
#               [!] Corrected output message when plugin cannot connect to host
#               [+] Added 'uptime' check
#               [+] Added 'evictions' check
#               [*] Made option '-H/--host' optional, default is 'localhost'
#
# Ver 2010.5.25:
#               [*] Initial implementation.
# ========================== START OF PROGRAM CODE =============================
use strict;
use IO::Socket;
use Getopt::Long;
use File::Basename;

# Variables Section
# -------------------------------------------------------------------------- #
my $VERSION       = "2010.7.14";
my $SCRIPT_NAME   = basename(__FILE__);
my $TIMEOUT       = 10;

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

# Connect to 'memcached' server
my $SOCKET = IO::Socket::INET->new(
    PeerAddr => $o_host,
    PeerPort => $o_port,
    Proto    => "tcp",
    Type     => SOCK_STREAM,
    Timeout  =>  $TIMEOUT
);

# Exit if connection failed
if (!$SOCKET) {
    print $STATES[$STATE_CRITICAL] . " - $@\n";
    exit $STATE_CRITICAL;
}

my ($intState, $intData, $strOutput, $strPerfData);

# Run memcached 'stats' command
print $SOCKET "stats\n";

# Get number of items
if ($o_check =~ /^items$/i) {
    my $line = <$SOCKET>;
    while ($line ne "END\r\n") {
        $intData = $1 if ($line =~ m/STAT curr_items ([0-9]+)/); # Get number of items
        $line = <$SOCKET>;
    }

    $strOutput    = "$intData number of items in the server";
    $strPerfData  = "'Items'=" . $intData . ";;;;";
}
# Get number of connections
elsif ($o_check =~ /^connections$/i) {
    my $line = <$SOCKET>;
    while ($line ne "END\r\n") {
        $intData = $1 if ($line =~ m/STAT curr_connections ([0-9]+)/);  # Get number of connections
        $line = <$SOCKET>;
    }

    $strOutput    = "$intData number of connections to the server";
    $strPerfData  = "'Connections'=" . $intData . ";;;;";
}
# Get memory usage
elsif ($o_check =~ /^memory$/i) {
    my ($line, $result, $max_bytes);

    $line = <$SOCKET>;
    while ($line ne "END\r\n") {
        $result = $1 if ($line =~ m/STAT bytes ([0-9]+)/);              # Get used bytes
        $max_bytes = $1 if ($line =~ m/STAT limit_maxbytes ([0-9]+)/);  # Get maximum allowed bytes
        $line = <$SOCKET>;
    }

    $intData      =  sprintf("%d", $result / ($max_bytes * 0.01));
    $strOutput    = "$intData% memory in use by all items in the server";
    $strPerfData  = "'Used'=" . $result . "B;;;; ";
    $strPerfData .= "'Free'=" . ($max_bytes - $result) . "B;;;;";
}
# Get number evictions
elsif ($o_check =~ /^evictions$/i) {
    my $line = <$SOCKET>;
    while ($line ne "END\r\n") {
        $intData = $1 if ($line =~ m/STAT evictions ([0-9]+)/);  # Get number of evictions
        $line = <$SOCKET>;
    }

    $strOutput    = "$intData number of evictions";
    $strPerfData  = "'Evictions'=" . $intData . ";;;;";
}
# Get uptime
elsif ($o_check =~ /^uptime$/i) {
    my $line = <$SOCKET>;
    while ($line ne "END\r\n") {
        $intData = $1 if ($line =~ m/STAT uptime ([0-9]+)/);  # Get uptime seconds
        $line = <$SOCKET>;
    }

    $intData      =  sprintf("%d", $intData / 60 / 60 / 24);  # Convert seconds to days
    $strOutput    = "Up for $intData days";
    $strPerfData  = "'Uptime'=" . $intData . "d;;;;";
}
# Set state to Unknown for anything else
else {
    $intState     =  $STATE_UNKNOWN;
    $strOutput    = "Unknown check option ('$o_check') was specified";
}

# Check if state was set to UNKNOWN (3),
# if not, check if we using inverse option, then
# calculate the state according to data variable from the above checks
if (defined($intState) && $intState == $STATE_UNKNOWN) {
    $strPerfData  = "";
}
elsif (! defined($o_inverse)) {
    if ($intData > $o_crit) { $intState = $STATE_CRITICAL; }
    elsif ($intData > $o_warn) { $intState = $STATE_WARNING; }
    else { $intState = $STATE_OK; }
}
else {
    if ($intData < $o_crit) { $intState = $STATE_CRITICAL; }
    elsif ($intData < $o_warn) { $intState = $STATE_WARNING; }
    else { $intState = $STATE_OK; }
}

# Now print the final output string
print $STATES[$intState] . " - $strOutput|$strPerfData\n";

# Close connection
close($SOCKET);

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

	if (!defined($o_warn) || !defined($o_crit)) {
	    print "Usage error: Warning and critical options must be specified!\n";
	    print_usage();
	    exit $STATE_UNKNOWN;
    }

    # Set default values for some options if needed.
    $o_host = "localhost" unless defined($o_host);
    $o_port = "11211" unless defined($o_port);
}

sub print_usage {
	print "Usage: $SCRIPT_NAME [-H <host>] [-P <port>] -C <check> -w <warn level> -c <crit level> [-I] [-V]\n";
}

sub print_help {
	print "\nMemcached check plugin for Nagios, version ", $VERSION, "\n";
	print "(C) 2010, Alex Simenduev - http://www.planetit.ws\n\n";
	print_usage();
	print <<EOD;
-h, --help
    print this help message
-H, --hostname=STRING
    name or IP address of host to check (default: localhost)
-P, --port=INTEGER
    Memcached port to use (default: 11211)
-C --check=STRING
    What to check (one of: items, connections, memory, evictions, uptime)
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
