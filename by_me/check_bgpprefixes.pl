#!/usr/bin/perl -w
# ============================== Summary =====================================
#
# Program : check_bgpprefixes.pl
# Version : 0.2
# Date    : Aug 13 2008
# Author  : Alex Simenduev - shamil.si@gmail.com
# Summary : This is a nagios plugin that checks number of BGP
#           prefixes by using Telnet or SSH utilities.
# Notes   : This script requires Expect.pm module.
#           on Debian/Ubuntu type as root "apt-get install libexpect-perl".
# ================================ Change log ==================================
# Ver 0.2 : First public release.
# ========================== START OF PROGRAM CODE ============================

use strict;
use Expect;
use Getopt::Long;

# Variables Section
# -------------------------------------------------------------------------- #
# Script Version 
my $VERSION	= "0.2";

# Verbose output, for debugging only
my $VERBOSE	= undef;

# Nagios states
my $STATE_OK		= 0;
my $STATE_WARNING	= 1;
my $STATE_CRITICAL	= 2;
my $STATE_UNKNOWN	= 3;
my $STATE_DEPENDENT	= 4;

my @STATES = ("OK", "WARNING", "CRITICAL", "UNKNOWN", "DEPENDENT");

# Variables used by Expect
my $TIMEOUT	    = 7;
my $BGP_COMMAND	= "show ip bgp summary";
my $PATH_SSH	= "/usr/bin/ssh";
my $PATH_TELNET	= "/usr/bin/telnet";

# Command line arguments variables
my $o_help	    = undef; # Want some help?
my $o_host	    = undef; # Hostname
my $o_port	    = undef; # Port
my $o_ssh	    = undef; # Use ssh?
my $o_user	    = undef; # Username
my $o_pass	    = undef; # Password
my $o_peer	    = undef; # BGP peer ip/ip's
my $o_warn	    = undef; # Warning level
my $o_crit	    = undef; # Critical level
my $o_version	= undef; # Script version
# -------------------------------------------------------------------------- #

# Main routine, entry point of the script
check_arguments();					                    # First check for command line arguments
my $output = runBGPcommand();				            # Save BGP summary command to $output
print $output unless (!defined($VERBOSE));		        # Will print verbose output if $VERBOSE is set.
exit parseoutput($output, $o_peer, $o_warn, $o_crit);	# Will parse the output of "runBGPcommand" sub, then exit

sub runBGPcommand {
	my $exp = new Expect();
	our $strOutput = undef; # Output of the Expect will be saved to this VAR
	my $command = undef;

	if (defined($o_ssh)) {
		if (!defined($o_port)) { $o_port = 22; }
		$command = "$PATH_SSH -o StrictHostKeyChecking=no -l $o_user -p $o_port $o_host";	
	} else {
		if (!defined($o_port)) { $o_port = 23; }
		$command = "$PATH_TELNET $o_host $o_port";
	}

	# define Expect options here
	$exp->log_stdout(0);
	$exp->log_file(\&saveoutput);
	$exp->spawn($command);
	#$exp->exp_internal(1);


	# Expect for username only for telnet.	
	if (!defined($o_ssh)) {
		$exp->expect($TIMEOUT, -re, "[Uu]sername");
		$exp->send("$o_user\n");
	}

	$exp->expect($TIMEOUT, -re, "[Pp]assword");
	$exp->send("$o_pass\n");

	$exp->expect($TIMEOUT, -re, "[#>]");
	$exp->send($BGP_COMMAND . "\n");
		   
	$exp->expect($TIMEOUT, -re, "[#>]");
	$exp->send("exit\n");
					  
	$exp->soft_close();
						  
	# This subroutine will run by Expect when it writes to log,
	# the output of the log will be saved to $output variable 
	# for later parsing.
	sub saveoutput {
		$strOutput .= shift;
		return;
	}

	return $strOutput;
}

# Required 4 arguments:
#	string	 => the string to be parsed
#	string   => the IP of BGP neighbor
#	integer  => trigger WARNING if less then spcified prefixes
#	integer  => trigger CRITICAL if less then spcified prefixes
sub parseoutput {
	if ($#_ != 3) {
		print "Subroutine 'paresoutput' accepts no more and no less then 4 parameters.";         
		return $STATE_UNKNOWN;
	}

	my @pOutput		 = split("\n", $_[0]);
	my $pBGPneighbor = $_[1];
	my $pPfxWarning	 = $_[2];
	my $pPfxCritical = $_[3];
	my $startParsing = undef;
	my $intState	 = $STATE_OK;
	my $strMessage	 = undef;

	foreach my $line (@pOutput) {
		# trim trailing spaces & end lines (replacement for chomp/chop).
		$line =~ s/\s+$//;

		# If "$line" starts with "Neighbor", this means that next lines are going to be parsed
		# So set "$startParsing" to something ("y").
		if ($line =~ /^Neighbor/) {
			$startParsing = 1;
			next;
		}

		# If "$startParsing" was set, this means we have a valid lines for parsing.
		if ($startParsing) {
			# If we have an exit in the line this means we exited from SSH/Telnet session
			# So undefine "$startParsing", as we dont wan't to parse not relevant lines.
			if ($line =~ "^.*[#>]exit") {
				$startParsing = undef;
				next;
			}

			my (
				$strBGPneighbor,	# IP address of BGP Neighbor.
				$strBGPversion,		# BGP version used.
				$intBGPas,		    # AS number.
				$intBGPmsgRcvd,		# Number of messages received by the router.
				$intBGPmgsSent,		# Number of messages sent by the router.
				$intBGPtblVer,		# Table version number, for BGP negotiations.
				$intBGPinQ,		    # Number of messages in inbound queue.
				$intBGPoutQ,		# Number of messages in outbound queue.
				$strBGPuptime,		# BGP connection uptime.
				$intBGPpfxRcd		# Number of prefixes (routes) accepted by the router.
			) = split(/\s+/, $line);

			if ($strBGPneighbor =~ /$pBGPneighbor/) {
				if ($intBGPpfxRcd < $pPfxCritical) {
					$strMessage .=  " [Neighbor $strBGPneighbor (AS $intBGPas): less then $pPfxCritical ($intBGPpfxRcd) => critical]";
					$intState = $STATE_CRITICAL;
				} elsif ($intBGPpfxRcd < $pPfxWarning) {
					$strMessage .=  " [Neighbor $strBGPneighbor (AS $intBGPas): less then $pPfxWarning ($intBGPpfxRcd) => warning]";
					$intState = $STATE_WARNING unless ($intState == $STATE_CRITICAL);
				} else {
					 $strMessage .=  " [Neighbor $strBGPneighbor (AS $intBGPas): looks OK ($intBGPpfxRcd)]";
				}

			}
		}
	}

	if (!defined($strMessage)) {
		$strMessage = " No BGP Neighbors were found!";
		$intState = $STATE_UNKNOWN;
	}

	print "$STATES[$intState] -$strMessage\n";
	return $intState;
}

sub check_arguments {
	Getopt::Long::Configure ("bundling");
	GetOptions(
		'h'		 => \$o_help,	 'help'       => \$o_help,
		'H:s'	 => \$o_host,	 'hostname:s' => \$o_host,
		'port=i' => \$o_port,	 'ssh'		  => \$o_ssh,
		'U:s'	 => \$o_user,	 'username:s' => \$o_user,
		'P:s'	 => \$o_pass,	 'password:s' => \$o_pass,
		'b:s'	 => \$o_peer,	 'bgppeer:s'  => \$o_peer,
		'w=i'	 => \$o_warn,	 'warn=i'	  => \$o_warn,
		'c=i'	 => \$o_crit,	 'crit=i'	  => \$o_crit,
		'V'		 => \$o_version, 'version'    => \$o_version,
	);
	if ( defined($o_help))		{ print_help(); exit $STATE_UNKNOWN;; }
	if ( defined($o_version))	{ print "$0: $VERSION\n"; exit $STATE_UNKNOWN; }
	if (!defined($o_host))		{ print "Usage error: No host spcified!\n"; print_usage(); exit $STATE_UNKNOWN; }
	if (!defined($o_user))		{ print "Usage error: No username specified!\n"; print_usage(); exit $STATE_UNKNOWN; }
	if (!defined($o_pass))		{ print "Usage error: No password specified!\n"; print_usage(); exit $STATE_UNKNOWN; }
	if (!defined($o_warn))		{ print "Usage error: No warning level specified!\n"; print_usage(); exit $STATE_UNKNOWN; }
	if (!defined($o_crit))		{ print "Usage error: No critical level specified!\n"; print_usage(); exit $STATE_UNKNOWN; }
	if (!defined($o_peer))		{ $o_peer = ".*"; }
}

sub print_usage {
	print "Usage: $0 -H <host> [--port <port>] [--ssh] -U <username> -P <password> [-b <peer IP>] -w <warning> -c <critical> [-V]\n";
}

sub print_help {
	print "\nBGP Prefixes check plugin for Nagios version ", $VERSION, "\n";
	print "(C) 2008, Alex Simenduev - shamil.si(at)gmail.com\n\n";
	print_usage();
	print <<EOD;
-h, --help
	print this help message
-H, --hostname=HOST
	name or IP address of host to check
--port=PORT
	SSH/Telnet port (Defaults: SSH=22, Telnet=23)
--ssh
	connect using SSH instead of Telnet
-U, --username=USERNAME
	username for connection
-P, --password=PASSWORD
	password for connection
-b, --bgppeer
	BGP peer IP address, Perl regexp supported
	If not specified all peers will be checked
-w, --warn=INTEGER
	warning level for BGP prefixes
-c, --crit=INTEGER
	critical level for BGP prefixes
-V, --version
	prints version number

EOD
	print "Examples:\n";
	print "\t$0 -H 192.168.0.100 -U user -P pass -w 180000 -c 100000\n";
	print "\tWill look for all neighbors and return CRITICAL if number of prfixes\n";
	print "\tless than 100000 and WARNING if less then 180000.\n\n";

	print "\t$0 -H 192.168.0.100 -U user -P pass -w 180000 -c 100000 --ssh\n";
	print "\tSame as above but will connect using SSH instead of Telnet.\n";
}
