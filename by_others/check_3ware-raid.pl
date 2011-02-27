#!/usr/bin/perl

#  -------------------------------------------------------
#             -=- <check_3ware-raid.pl> -=-
#  -------------------------------------------------------
#
#  Description : yet another plugin to check your 3ware RAID
#  controller
#
# Just want to thank Eric Schultz to help me to improve this
# little script
#
#  Version : 0.2
#  -------------------------------------------------------
#  In :
#     - see the How to use section
#
#  Out :
#     - only print on the standard output
#
#  Features :
#     - perfdata output
#
#  Fix Me/Todo :
#     - too many things ;) but let me know what do you think about it
#
# ####################################################################

# ####################################################################
# GPL v3
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.

# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.

# You should have received a copy of the GNU General Public License
# along with this program.  If not, see <http://www.gnu.org/licenses/>.
# ####################################################################

# ####################################################################
# How to use :
# ------------
#
# 1 to use this script you have to install firt tw_cli. You can find
#   the source here : http://www.3ware.com/support/download.asp
#   just follow the instructions to compile and deploy it
#
# 2 then you just have to run the following command :
#	$ ./check_3ware-raid.pl --help
#
# If you need to use this script with NRPE you just have to do the
# following steps :
#
# 1 allow your user to run the script with the sudo rights. Just add
#   something like that in your /etc/sudoers (use visudo) :
#     nagios ALL=(ALL) NOPASSWD: /<path-to>/check_3ware-raid.pl
#
# 2 then just add this kind of line in your NRPE config file :
#   command[check_3ware]=/usr/bin/sudo /<path-to>/check_3ware-raid.pl
#
# 3 don't forget to restart your NRPE daemon
#
# ####################################################################

# ####################################################################
# Changelog :
# -----------
#
# --------------------------------------------------------------------
#   Date:30/10/2010   Version:0.2     Author:Eric Schultz
#   >> added "all" option to check both units and disks
# --------------------------------------------------------------------
#   Date:28/11/2009   Version:0.1     Author:Erwan Ben Souiden
#   >> creation
# ####################################################################

# ####################################################################
#            Don't touch anything under this line!
#        You shall not pass - Gandalf is watching you
# ####################################################################

use strict;
use warnings;
use Getopt::Long qw(:config no_ignore_case);

# Generic variables
# -----------------
my $version = '0.2';
my $author = 'Erwan Labynocle Ben Souiden';
my $a_mail = 'erwan@aleikoum.net';
my $script_name = 'check_3ware-raid.pl';
my $verbose_value = 0;
my $version_value = 0;
my $more_value = 0;
my $help_value = 0;
my $perfdata_value = 0;
my %ERRORS=('OK'=>0,'WARNING'=>1,'CRITICAL'=>2,'UNKNOWN'=>3,'DEPENDENT'=>4);

# Plugin default variables
# ------------------------
my $display = 'CHECK 3ware RAID - ';
my ($critical,$warning) = (2,1);
my $tw_cli_path = '/usr/local/bin/tw_cli';
my ($id_controller,$action) = ("",'all');

GetOptions (
    'P=s' => \ $tw_cli_path,
    'path-tw_cli=s' => \ $tw_cli_path,
    'w=i' => \ $warning,
    'warning=i' => \ $warning,
    'c=i' => \ $critical,
    'critical=i' => \ $critical,
    'action=s' => \ $action,
    'a=s' => \ $action,
    'C=s' => \ $id_controller,
    'controller=s' => \ $id_controller,
    'm' => \ $more_value,
    'more' => \ $more_value,
    'V' => \ $version_value,
    'version' => \ $version_value,
    'h' => \ $help_value,
    'H' => \ $help_value,
    'help' => \ $help_value,
    'display=s' => \ $display,
    'D=s' => \ $display,
    'perfdata' => \ $perfdata_value,
    'p' => \ $perfdata_value,
    'v' => \ $verbose_value,
    'verbose' => \ $verbose_value
);

print_usage() if ($help_value);
print_version() if ($version_value);


# Syntax check of your specified options
# --------------------------------------

print "DEBUG : action : $action, path-tw_cli : $tw_cli_path\n" if ($verbose_value);
if (($action eq "") or ($tw_cli_path eq "")) {
    print $display.'one or more following arguments are missing :action/path-tw_cli'."\n";
    exit $ERRORS{"UNKNOWN"};
}

print "DEBUG : check if $tw_cli_path exists and is executable\n" if ($verbose_value);
if(! -x $tw_cli_path) {
    print $display."$tw_cli_path".' is not executable by you'."\n";
    exit $ERRORS{"UNKNOWN"};
}

print "DEBUG : warning threshold : $warning, critical threshold : $critical\n" if ($verbose_value);
if (($critical < 0) or ($warning < 0) or ($critical < $warning)) {
    print $display.'the thresholds must be integers and the critical threshold higher or equal than the warning threshold'."\n";
    exit $ERRORS{"UNKNOWN"};
}

print "DEBUG : controller : $id_controller\n" if ($verbose_value);
if ($id_controller ne "") {
	if (check_controller("$tw_cli_path",$id_controller) != 0) {
		print $display.'UNKNOWN - problem with the controller '."$id_controller ".'may be it does not exist'."\n";
		exit $ERRORS{"UNKNOWN"};
	}
}

# Core script
# -----------
my ($return,$return_more,$plugstate) = ("","","OK");

my @controller_list;
if (! $id_controller) {
	@controller_list = list_all_controller("$tw_cli_path");
	if (! @controller_list) {
		print $display.'UNKNOWN - problem to have the controllers list'."\n";
		exit $ERRORS{"UNKNOWN"};
	}
}
else {
	push(@controller_list,$id_controller);
}

print "DEBUG : action = $action\n" if ($verbose_value);

my @show_return;

# disk_check action
# -----------------
if(! $action =~ m/(unit_check|disk_check|all)/)  {
	$return .= "action must be unit_check|disk_check";
	$action = "";
	$plugstate = "UNKNOWN";
	}

if ($action eq 'disk_check' or $action eq 'all') {
	my ($c_ok,$c_other) = (0,0);
	foreach (@controller_list) {
		@show_return = `$tw_cli_path /$_ show`;
		foreach (@show_return) {
			if ($_=~/^(p\d+)\s+(\S+)\s/ ) {
				print "DEBUG : disk $1/status $2\n" if ($verbose_value);
				$c_ok++ if ($2 eq "OK");
				$c_other++ if (($2 ne "OK") and ($2 ne "NOT-PRESENT"));
				$return_more .= " ($1,$2)";
			}
		}
		$return .= "$c_ok disk(s) detected as OK";
		$return .= " and $c_other with potential problem" if ($c_other);
		$return .= " -$return_more" if ($more_value);
		$return .= " | disksOK=$c_ok disksNOK=$c_other" if ($perfdata_value);

	if($c_other >= $warning and $c_other ne "CRITICAL"){
	        $plugstate = "WARNING"; }
        $plugstate = "CRITICAL" if ($c_other >= $critical);
	}
}

# unit action
# -----------
if ($action eq 'unit_check' or $action eq 'all') {
	my ($c_ok,$c_rebuild,$c_other) = (0,0,0);
	foreach (@controller_list) {
		@show_return = `$tw_cli_path /$_ show`;
		foreach (@show_return) {
			if ($_=~/^(u\d+)\s+(\S+)\s+(\S+)/) {
				print "DEBUG : disk $1/type $2/status $3\n" if ($verbose_value);
				if($3 eq "OK" or $3 eq "VERIFYING"){
					$c_ok++; }
				elsif($3 eq "REBUILD"){
					$c_rebuild++; }
				else{
					$c_other++; }
				$return_more .= " ($1,$2,$3)";
			}
		}
		$return .= (($return eq '')?'':' - ');
		$return .= "$c_ok unit(s) detected as OK";
		$return .= " and $c_rebuild as REBUILD" if ($c_rebuild);
		$return .= " and $c_other with potential problem" if ($c_other);
		$return .= " -$return_more" if ($more_value);
		$return .= " | unitOK=$c_ok unitREBUILD=$c_rebuild unitNOK=$c_other" if ($perfdata_value);

		if($c_rebuild and $c_other ne "CRITICAL"){
	        	$plugstate = "WARNING"; }
		$plugstate = "CRITICAL" if ($c_other);
	}
}


print $display.$action." - ".$plugstate." - ".$return."\n";
exit $ERRORS{$plugstate};

# ####################################################################
# function 1 :  display the help
# ------------------------------
sub print_usage {
    print <<EOT;
$script_name version $version by $author

This plugin checks state of your physical disks and logical units of a 3ware RAID card.

Usage: /<path-to>/$script_name [-a unit_check|disk_check|all] [-p] [-D "$display"] [-v] [-m] [-c 2] [-w 1] [-C /c1]

Options:
 -h, --help
    Print detailed help screen
 -V, --version
    Print version information
 -D, --display=STRING
    to modify the output display...
    default is "CHECK 3ware RAID - "
 -P, --path-tw_cli=STRING
    specify the path to the tw_cli binary
    default value is /usr/local/bin/tw_cli
 -a, --action=STRING
    specify the action : unit_check|disk_check
    default is all
    all        : check both disks and units
    disk_check : display state of all physical disks
    unit_check : display state of all logical unit
 -C, --controller=STRING
    allow you to specify only one controller to check
    the default behavior is to check each time every controller
 -c, --critical=INT
    specify a critical threshold for the number of disks in a non-OK state.
    default is 2
    only for the disk_check action
 -w, --warning=INT
    specify a warning threshold for the number of disks in a non-OK state.
    default is 1
    only for the disk_check action
 -m, --more
    Print a longer output. By default, the output is not complet because
    Nagios may truncate it. This option is just for you
 -p, --perfdata
    If you want to activate the perfdata output
 -v, --verbose
    Show details for command-line debugging (Nagios may truncate the output)

Send email to $a_mail if you have questions
regarding use of this software. To submit patches or suggest improvements,
send email to $a_mail
This plugin has been created by $author

Hope you will enjoy it ;)

Remember :
    This program is free software: you can redistribute it and/or modify
    it under the terms of the GNU General Public License as published by
    the Free Software Foundation, either version 3 of the License, or
    (at your option) any later version.

    This program is distributed in the hope that it will be useful,
    but WITHOUT ANY WARRANTY; without even the implied warranty of
    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
    GNU General Public License for more details.

    You should have received a copy of the GNU General Public License
    along with this program.  If not, see <http://www.gnu.org/licenses/>.


EOT
    exit $ERRORS{"UNKNOWN"};
}

# function 2 :  display version information
# -----------------------------------------
sub print_version {
    print <<EOT;
$script_name version $version
EOT
    exit $ERRORS{"UNKNOWN"};
}

# function 3 : check if controller exists
# ---------------------------------------
sub check_controller {
    my ($tw_cli_path,$id_controller) = @_;
    system("$tw_cli_path /$id_controller show >> /dev/null 2>&1");
    return $?;
}

# function 4 : return the controllers list
# ----------------------------------------
sub list_all_controller {
    my ($tw_cli_path) = @_;
    my @controller_list;
    my @cmd_output = `$tw_cli_path show`;
    if ($? == 0) {
        foreach (@cmd_output) {
            if ($_=~/^(c\d+)\s/ ) {
                push(@controller_list,$1);
            }
        }
    }
    return @controller_list;
}
