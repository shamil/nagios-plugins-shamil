#!/usr/bin/perl -w
# ============================== Summary =======================================
# Program : check_snmp_cisco_asa.pl
# Version : 2010.4.18
# Date    : Apr 15 2010
# Author  : Alex Simenduev - (http://www.planetit.ws)
# Summary : This is a nagios plugin that checks PIX/ASA by using Net::SNMP
#
# ================================ Description =================================
# The plugin is capable of check couple aspects of cisco ASA/PIX firewalls.
#
# - Plugin have 2 check modes:
#   First mode, is "Global mode", in this mode you can monitor a global state of
#   the firewall, supported checks are CPU, Memory and Connections. Check usage for
#   how to use them. Second mode is "Interface mode" which gets the bandwidth speed
#   of requested interface (by 'id' or by 'name'). This is an early version of the
#   plugin, more futures will be added in the future versions ( I hope ;) )
#
# - Plugin uses SNMP protocol to get the data, currently SNMP v1 and v2 are
#   supported, I don't use SNMP v3, will add support for it upon request.
#
# - Plugin was tested on ASA-5540 and PIX-515E, it should work on other models also
#
# - Plugin uses "ifXTable" (extension of "ifTable"). Which means interface data
#   collected using 64-bit counters, and if you still desire to use 32-bit counters,
#   then use SNMPv1 (-v 1) option. More info at:
#      http://www.ciscosystemsverified.biz/en/US/tech/tk648/tk362/technologies_q_and_a_item09186a00800b69ac.shtml
#
# ================================ Change log ==================================
# Legend:
#               [*] Informational, [!] Bugix, [+] Added, [-] Removed
#
# Ver 2010.4.18:
#               [!] Fixed small bug in overflow detection.
#
# Ver 2010.4.15:
#               [+] Added 2 options to interface mode, to return data in Mbps and bps (default is Kbps).
#               [+] Added check limit to interface check, at least 5 seconds must be passed before running the check again.
#               [*] Using 64-bit counters for interface check, on SNMPv1 still using 32-bit counters.
#               [*] Made optional "crit" and "warn" options, OK status will be returned if the options were omitted.
#               [*] Improved command-line arguments parsing.
#
# Ver 2010.4.14:
#               [*] First public release.
# ========================== START OF PROGRAM CODE =============================

use strict;
use Net::SNMP;
use Getopt::Long;
use File::Basename;

# Variables Section
# -------------------------------------------------------------------------- #
my $VERSION       = "2010.4.18";
my $SCRIPT_NAME   = basename(__FILE__);
my $TIMEOUT       = 10;
my $RUN_TIMESTAMP = time();

# Nagios states
my $STATE_OK		= 0;
my $STATE_WARNING	= 1;
my $STATE_CRITICAL	= 2;
my $STATE_UNKNOWN	= 3;
my $STATE_DEPENDENT	= 4;

my @STATES = ("OK", "WARNING", "CRITICAL", "UNKNOWN", "DEPENDENT");

# OIDs used for the check, to get more info about those OIDs, go to:
#   http://tools.cisco.com/Support/SNMP/do/BrowseOID.do
my %OIDS = (
    'sysDescr'                  => "1.3.6.1.2.1.1.1.0",                    # Device description string
    'ifName'                    => "1.3.6.1.2.1.31.1.1.1.1",               # Interfaces name table
    'ifInOctets'                => "1.3.6.1.2.1.2.2.1.10",                 # Inbound octets table (32-bit)
    'ifOutOctets'               => "1.3.6.1.2.1.2.2.1.16",                 # Outbound octets table (32-bit)
    'ifHCInOctets'              => "1.3.6.1.2.1.31.1.1.1.6",               # Inbound octets table (64-bit)
    'ifHCOutOctets'             => "1.3.6.1.2.1.31.1.1.1.10",              # Outbound octets table (64-bit)
    'ciscoMemoryPoolUsed'       => "1.3.6.1.4.1.9.9.48.1.1.1.5.1",         # Memory in use    (in bytes)
    'ciscoMemoryPoolFree'       => "1.3.6.1.4.1.9.9.48.1.1.1.6.1",         # Memory available (in bytes)
    'cpmCPUTotal5sec'           => "1.3.6.1.4.1.9.9.109.1.1.1.1.3.1",      # CPU usage (5 sec average)
    'cpmCPUTotal1min'           => "1.3.6.1.4.1.9.9.109.1.1.1.1.4.1",      # CPU usage (1 min average)
    'cpmCPUTotal5min'           => "1.3.6.1.4.1.9.9.109.1.1.1.1.5.1",      # CPU usage (5 min average)
    'cufwConnSetupRate1min_udp' => "1.3.6.1.4.1.9.9.491.1.1.4.1.1.9.6",    # UDP connection per second (1 min. average)
    'cufwConnSetupRate1min_tcp' => "1.3.6.1.4.1.9.9.491.1.1.4.1.1.9.7",    # TCP connection per second (1 min. average)
    'cufwConnSetupRate5min_udp' => "1.3.6.1.4.1.9.9.491.1.1.4.1.1.10.6",   # UDP connection per second (5 min. average)
    'cufwConnSetupRate5min_tcp' => "1.3.6.1.4.1.9.9.491.1.1.4.1.1.10.7",   # TCP connection per second (5 min. average)
    'cfwConnectionStatValue'    => "1.3.6.1.4.1.9.9.147.1.2.2.2.1.5.40.6"  # Total number of connections currently in use
);

# Command line arguments variables
my $o_help	    = undef; # Want some help?
my $o_host	    = undef; # Hostname
my $o_global    = undef; # Global check mode
my $o_interface = undef; # Interface check mode
my $o_snmp_ver  = undef; # SNMP version to use (1 or 2c, ver 3 not supported )
my $o_snmp_com  = undef; # SNMP community string
my $o_port	    = undef; # Port
my $o_bps       = undef; # Used for interface mode to print values in bits per second
my $o_mbps      = undef; # Used for interface mode to print values in megabits per second
my $o_warn	    = undef; # Warning level
my $o_crit	    = undef; # Critical level
my $o_inverse   = undef; # Use inverse calculation of warning/critical thresholds
my $o_version	= undef; # Script version

# Entry point of the script
# -------------------------------------------------------------------------- #
check_arguments();	# First check for command line arguments

# Then connect to requested host by SNMP
my $objSNMP = snmp_connect($o_host, $o_snmp_ver, $o_snmp_com, $o_port);
my ($result, $intState, $intData, $strOutput, $strPerfData);

# Run global check
if ( defined($o_global) ) {
    # Get memory info (mem_used)
    if($o_global =~ /^mem_used$/i) {
        $result = snmp_get([
            $OIDS{'ciscoMemoryPoolUsed'},
            $OIDS{'ciscoMemoryPoolFree'}
        ]);

        # Calculate percentage
        $intData      =  ($result->{ $OIDS{'ciscoMemoryPoolUsed'} } + $result->{ $OIDS{'ciscoMemoryPoolFree'} }) / 100;
        $intData      =  sprintf("%d", $result->{ $OIDS{'ciscoMemoryPoolUsed'} } / $intData);
        $strOutput    = "$intData% memory in use by all applications in the firewall";
        $strPerfData  = "'Used'=" . $result->{ $OIDS{'ciscoMemoryPoolUsed'} } . "B;;;; ";
        $strPerfData .= "'Free'=" . $result->{ $OIDS{'ciscoMemoryPoolFree'} } . "B;;;;";
    }
    # Get CPU info (cpu_load)
    elsif($o_global =~ /^cpu_busy$/i) {
        $result = snmp_get([
            $OIDS{'cpmCPUTotal5sec'},
            $OIDS{'cpmCPUTotal1min'},
            $OIDS{'cpmCPUTotal5min'}
        ]);

        $intData      = $result->{ $OIDS{'cpmCPUTotal5sec'} };
        $strOutput    = "$intData% overall CPU busy in the last 5 seconds";
        $strPerfData  = "'5s'=" . $result->{ $OIDS{'cpmCPUTotal5sec'} } . "%;;;; ";
        $strPerfData .= "'1m'=" . $result->{ $OIDS{'cpmCPUTotal1min'} } . "%;;;; ";
        $strPerfData .= "'5m'=" . $result->{ $OIDS{'cpmCPUTotal5min'} } . "%;;;;";
    }
    # Get connections per second 1m average (con_p/s_1m)
    elsif($o_global =~ /^con_p\/s_1m$/i) {
        $result = snmp_get([
            $OIDS{'cufwConnSetupRate1min_udp'},
            $OIDS{'cufwConnSetupRate1min_tcp'}
        ]);

        my $intConUDP = $result->{ $OIDS{'cufwConnSetupRate1min_udp'} };
        my $intConTCP = $result->{ $OIDS{'cufwConnSetupRate1min_tcp'} };

        $intData      = $intConUDP + $intConTCP;
        $strOutput    = "$intData number of connections which the firewall establishing p/s (1 minute average)";
        $strPerfData  = "'udp'=$intConUDP;;;; 'tcp'=$intConTCP;;;;";
    }
    # Get connections per second 5m average (con_p/s_5m)
    elsif($o_global =~ /^con_p\/s_5m$/i) {
        $result = snmp_get([
            $OIDS{'cufwConnSetupRate5min_udp'},
            $OIDS{'cufwConnSetupRate5min_tcp'}
        ]);

        my $intConUDP = $result->{ $OIDS{'cufwConnSetupRate5min_udp'} };
        my $intConTCP = $result->{ $OIDS{'cufwConnSetupRate5min_tcp'} };

        $intData      = $intConUDP + $intConTCP;
        $strOutput    = "$intData number of connections which the firewall establishing p/s (5 minutes average)";
        $strPerfData  = "'udp'=$intConUDP;;;; 'tcp'=$intConTCP;;;;";
    }
    # Get number of connections currently in use by the entire firewall (con_total)
    elsif($o_global =~ /^con_total$/i) {
        $result = snmp_get([ $OIDS{'cfwConnectionStatValue'} ]);

        $intData      = $result->{ $OIDS{'cfwConnectionStatValue'} };
        $strOutput    = "$intData number of connections currently in use by the entire firewall";
        $strPerfData  = "'connections'=$intData;;;;";
    }
    # Set state to Unknown for anything else
    else {
        $intState     =  $STATE_UNKNOWN;
        $strOutput    = "Unknown global check option ('$o_global') was specified";
    }
}
# Run interface check
elsif ( defined($o_interface) ) {{ # '{{' used to be able to use 'last'
    # If interface was requested by name, then translate to number by using "get_interface_by_name" function
    $o_interface = get_interface_by_name($o_interface) unless $o_interface =~ /^[+-]?\d+$/;

    # Set state to Unknown if interface was not found
    if (!defined($o_interface)) {
        $intState  = $STATE_UNKNOWN;
        $strOutput = "Requested interface was not found";
        last;
    }

    if ($o_warn != 0 || $o_crit != 0) {
        $intState  = $STATE_UNKNOWN;
        $strOutput = "Interface mode doesn't support 'warn' & 'crit' options. Will be supported in future versions";
        last;
    }

    # Prepare/Define some required variables
    my ($intAvgTime, $intReceived, $intSent, $intLastRunReceived, $intLastRunSent);
    my ($oid_ifName, $oid_ifInOctets, $oid_ifOutOctets);
    my $strTempFile = "/tmp/$SCRIPT_NAME-$o_host-$o_interface";

    # Now we open file to get last run data
    if (-e $strTempFile) {
        if (open(FILE, "< $strTempFile")) {
            my $strOldData = <FILE>;            # read first line from file,
            close(FILE);                        # then close the file

            $strOldData =~ /^(.*),(.*),(.*)/i;  # parse the "last run data" line
            $intAvgTime = $RUN_TIMESTAMP - $1;
            $intLastRunReceived = $2;
            $intLastRunSent = $3;

            # Do not continue if not enough data collected
            unless ($intAvgTime > 5) {
                $intState  = $STATE_UNKNOWN;
                $strOutput = "Not enough data collected, rerun the check in at least 5 seconds";
                last;
            }
        }
        else {
            $intState  = $STATE_UNKNOWN;
            $strOutput = "Can't open '$strTempFile' file: $!";
            last;
        }
    }

    # Open/Create a temp file
    if (open(FILE, "+> $strTempFile")) {
        # now we ready to run SNMP request
        $oid_ifName = $OIDS{'ifName'} . "." . $o_interface;

        # use 32-bit counters only if SNMPv1 was used
        if ($o_snmp_ver == 1) {
            $oid_ifInOctets  = $OIDS{'ifInOctets'} . "." . $o_interface;
            $oid_ifOutOctets = $OIDS{'ifOutOctets'} . "." . $o_interface;
        }
        else {
            $oid_ifInOctets  = $OIDS{'ifHCInOctets'} . "." . $o_interface;
            $oid_ifOutOctets = $OIDS{'ifHCOutOctets'} . "." . $o_interface;
        }

        $result = snmp_get([
            $oid_ifName,
            $oid_ifInOctets,
            $oid_ifOutOctets
        ]);

        # then write last run data to it
        print FILE "$RUN_TIMESTAMP," . $result->{$oid_ifInOctets} . "," . $result->{$oid_ifOutOctets};
        close(FILE);

        # Do not continue if this is a first run
        unless (defined($intAvgTime)) {
            $intState  = $STATE_UNKNOWN;
            $strOutput = "Data collection started, rerun the check in at least 5 seconds";
            last;
        }
    }
    else {
        $intState  = $STATE_UNKNOWN;
        $strOutput = "Can't open '$strTempFile' file: $!";
        last;
    }

    # This heppens if we run out of the 64-bit (32-bit if SNMPv1 is used) number and the count starts from 0 again
    # This is not an issue, but in order to avoid negative results, I decided to skip the check.
    if ($result->{$oid_ifInOctets} <= $intLastRunReceived || $result->{$oid_ifOutOctets} <= $intLastRunSent) {
        $intState  = $STATE_UNKNOWN;
        $strOutput = "Overflow detected, skipping the check, rerun the check in at least 5 seconds";
        last;
    }

    $intData      = 0; #
    $intReceived  = sprintf("%d", ($result->{$oid_ifInOctets} - $intLastRunReceived) * 8 / $intAvgTime);
    $intSent      = sprintf("%d", ($result->{$oid_ifOutOctets} - $intLastRunSent) * 8 / $intAvgTime);
    $strPerfData  = "'input'=$intReceived;;;; 'output'=$intSent;;;;";

    # Print output text in bps or mbps or kbps (default)
    if (defined($o_bps)) {
        $intReceived .= " bps";
        $intSent     .= " bps";
    }
    elsif (defined($o_mbps)) {
        $intReceived = sprintf("%.2f Mbps", $intReceived / 1024 / 1024);
        $intSent     = sprintf("%.2f Mbps", $intSent / 1024 / 1024);
    }
    else {
        $intReceived = sprintf("%.2f Kbps", $intReceived / 1024);
        $intSent     = sprintf("%.2f Kbps", $intSent / 1024);
    }

    $strOutput = "Interface '" . $result->{$oid_ifName} . "' (${intAvgTime}s average): input $intReceived, output $intSent";
}}

# Check if state was set to UNKNOWN (3),
# if not, check if we using inverse option, then
# calculate the state according to data variable from the above checks
if (defined($intState) && $intState == $STATE_UNKNOWN) {
    $strPerfData  = "";
}
elsif (! defined($o_inverse)) {
    if ($intData > $o_crit && $o_crit != 0) { $intState = $STATE_CRITICAL; }
    elsif ($intData > $o_warn && $o_warn != 0) { $intState = $STATE_WARNING; }
    else { $intState = $STATE_OK; }
}
else {
    if ($intData < $o_crit && $o_crit != 0) { $intState = $STATE_CRITICAL; }
    elsif ($intData < $o_warn && $o_warn != 0) { $intState = $STATE_WARNING; }
    else { $intState = $STATE_OK; }
}

# Now print the final output string
print $STATES[$intState] . " - $strOutput|$strPerfData\n";

# close SNMP session when we done
$objSNMP->close();

# Finally exit with current state error code.
exit $intState;

# Functions section
# -------------------------------------------------------------------------- #

# This function connects to host by SNMP and returns Net:SNMP object
# if connection failed, then this sub prints an error and exits the script
sub snmp_connect {
    # Create the SNMP session
    my ( $session, $error ) = Net::SNMP->session(
        -hostname   => shift,
        -version    => shift,
        -community  => shift,
        -port       => shift,
        -timeout    => $TIMEOUT,
    );

    return $session if $session;

    print $error . "\n";
    exit $STATE_UNKNOWN;
}

# This function performs SNMP get request
# if request failed, then this sub prints an error and exits the script
sub snmp_get {
    my $result = $objSNMP->get_request(-varbindlist => @_);

    return $result if $result;

    print $objSNMP->error() . "\n";
    $objSNMP->close();
    exit $STATE_UNKNOWN;
}

# This function retrieves interface index number, by performing SNMP bulk-request
sub get_interface_by_name {
    my $strName = shift;
    my $result = $objSNMP->get_table(-baseoid => $OIDS{'ifName'});

    if (!defined($result)) {
        print $objSNMP->error() . "\n";
        $objSNMP->close();
        exit $STATE_UNKNOWN;
    }

    foreach my $key (keys %{$result}) {
        # Return Interface index number if it was matched.
        return ($key =~ /$OIDS{'ifName'}\.(\d+)$/i)[0] if ($result->{$key} =~ /$strName/);
    }

    return undef;
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
		'global=s'      => \$o_global,
		'interface=s'   => \$o_interface,
		'v=i'	        => \$o_snmp_ver,
		'C=s'           => \$o_snmp_com,
		'bps'           => \$o_bps,
		'mbps'          => \$o_mbps,
		'p|port=i'      => \$o_port,
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

	if (!defined($o_host)) {
	    print "Usage error: Hostname or IP address must be specified!\n";
	    print_usage();
	    exit $STATE_UNKNOWN;
    }

	if (!defined($o_global) && !defined($o_interface)) {
	    print "Usage error: One of '--global' or '--interface' parameter must be specified!\n";
	    print_usage();
	    exit $STATE_UNKNOWN;
	}

	if (defined($o_global) && defined($o_interface)) {
	    print "Usage error: '--global' and '--interface' parameters cannot be used together!\n";
	    print_usage();
	    exit $STATE_UNKNOWN;
	}

	if (defined($o_global) && (defined($o_bps) || defined($o_mbps))) {
	    print "Usage error: '--bps' and '--mbps' parameters cannot be used with '--global' option!\n";
	    print_usage();
	    exit $STATE_UNKNOWN;
	}

	if (defined($o_bps) && defined($o_mbps)) {
	    print "Usage error: '--bps' and '--mbps' parameters cannot be used together!\n";
	    print_usage();
	    exit $STATE_UNKNOWN;
	}

    # Set default values for some options if needed.
    $o_port     = "161"    unless defined($o_port);
    $o_snmp_ver = "2"      unless defined($o_snmp_ver);
    $o_snmp_com = "public" unless defined($o_snmp_com);
    $o_warn     = 0        unless defined($o_warn);     # 0 means: do not use.
    $o_crit     = 0        unless defined($o_crit);     # 0 means: do not use.
}

sub print_usage {
	print "Usage: $SCRIPT_NAME -H <host> --global <check>|--interface <name> [-v <snmp version>] [-C <snmp community>] [-p <port>] [--bps|--mbps] [-w <warn level>] [-c <crit level>] [-I] [-V]\n";
}

sub print_help {
	print "\nCisco ASA/PIX check plugin for Nagios, version ", $VERSION, "\n";
	print "(C) 2010, Alex Simenduev - http://www.planetit.ws\n\n";
	print_usage();
	print <<EOD;
-h, --help
    print this help message
-H, --hostname=HOST
    name or IP address of host to check
--global=CHECK
    Global mode check (one of: cpu_busy, mem_used, con_p/s_1m, con_p/s_5m, con_total)
--interface=NAME
    Interface mode check, use interface name or number
-v=VERSION
    SNMP version to use (Default: 2)
-C=COMMUNITY
    SNMP community string (Default: public)
-P, --port=PORT
    SNMP port to use (Default: 161)
--bps
    Print interface data in bits per second (default is kbps)
--mbps
    Print interface data in megabits per second (default is kbps)
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
