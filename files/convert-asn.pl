#!/usr/bin/env perl

use strict;
use warnings;
use feature ('say');
use Net::IP;

=pod

=head1 PURPOSE

This script will, after postprocessing, create two data files for rbldnsd
for ASN lookup over DNS in Cymru format, one for IPv4 and one for IPv6.

The data is put in a TXT record RDATA, which is returned for on an owner
name representing the IP address in quesion, where the address itself
is in reverse data format, e.g.

 98.158.97.176.origin.asnlookup.zonemaster.net. TXT "1921 | 176.97.158.0/24 | NA | NA | NA"

The TXT record RDATA consists of five sub fields separated by " | ", of which
only the first two are used for data for Zonemaster. The remaining three
must have the string "NA" to mean "not applicable". The second subfield is the
prefix that the IP address in question belongs. The first subfield is the ASN
or set of ASNs the prefix is announced in. Multiple ASNs are space separated.

=head1 INPUT DATA

Input, standard input, to this script is the ASN data file from
L<BGP.Tools|https://bgp.tools/> in L<text format|https://bgp.tools/table.txt>.
The data file has the following format:

<Prefix><Space><ASN>

Prefix is an IPv4 prefix or an IPv6 prefix.

The IPv4 prefix is in the usual IPv4 display format (four dot-separated octets)
plus "/" plus a prefix length 0-32 bits.

The IPv6 prefix is in the usual IPv6 display format plus a prefix length 0-64
bits

Space is an ASCII x2D space character.

ASN is a single ASN code. If the prefix is annouced in multiple ASNs then there
are multiple entries for the prefix.

=head1 OUTPUT DATA

This script will create a meta file on standard output. In the meta file every
line is prepended by "IPV4"+<TAB> or "IPV6"+<TAB>. Two data files, for IPv4
and IPv6, respectively, can be created from the meta file with the following
commands assuing that the name of the metafile is "asndata.txt":

grep "^IPV4" asndata.txt | cut -f2- > ipv4data.txt
grep "^IPV6" asndata.txt | cut -f2- > ipv6data.txt

=head1 STDERR

If prefixes /25-32 (IPv4) or /65-128 (IPv6) are found, those are ignored and
counted. At the end a warning is printed to STDERR.

If other errors are found in the input data, then an error message is printed
to standard error, the script is terminated and and a non-zero result code is
returned to the calling code.

=cut

# Headers of the files
say 'IPV6' . "\t" . '# ------------------------------------------';
say 'IPV6' . "\t" . '$DATASET dnset origin6';
say 'IPV6' . "\t" . '$TTL 14400';
say 'IPV6' . "\t" . '# ------------------------------------------';

say 'IPV4' . "\t" . '# ------------------------------------------';
say 'IPV4' . "\t" . '$DATASET ip4trie origin';
say 'IPV4' . "\t" . '$TTL 14400';
say 'IPV4' . "\t" . '# ------------------------------------------';

my ($linecnt) = 0; # Line counter

my ($ignorev4cnt) = 0; # Counting ignored IPv4 lines with prefix /25-32
my ($ignorev6cnt) = 0; # Counting ignored IPv6 lines with prefix /65-128

# Hashed temporarily store data in
my (%ipv4data, %ipv6data);

# Collect data from the data file and store by prefix
while (<>) {

    $linecnt++;

    chomp;

    my ($ip, $prefix, $asn, $rev);

    if (m!^([0-9a-f]+[0-9a-f:]+)/([0-9]+) +([0-9]+) *$!) {
	# IPv6 prefix plus ASN

	$ip = $1;      # IP address part
	$prefix = $2;  # Prefix length
	$asn = $3;     # ASN code

	# Sanitary tests
	die qq(ERROR on line $linecnt in input data: "$ip" is not an IPv6 address) unless Net::IP::ip_is_ipv6($ip);
	die qq(ERROR on line $linecnt in input data: "$prefix" is not a valid IPv6 prefix within range 0 to 128)
	    unless $prefix =~ /^\d+$/ and $prefix >= 0 and $prefix <= 128;

	# Count and ignore prefix /65-128
	if ($prefix >= 65 and $prefix <= 128) {
	    $ignorev6cnt++;
	    next;
	};

        push @{ $ipv6data{ "$ip/$prefix" } }, $asn;

    } elsif (m!^(\d+\.\d+\.\d+\.\d+)/([0-9]+) +([0-9]+) *$!) {

	$ip = $1;      # IP address part
	$prefix = $2;  # Prefix length
	$asn = $3;     # ASN code

	# Sanitary tests
	die qq(ERROR on line $linecnt in input data: "$ip" is not an IPv4 address) unless Net::IP::ip_is_ipv4($ip);
	die qq(ERROR on line $linecnt in input data: "$prefix" is not a valid IPv4 prefix within range 0 to 32)
	    unless $prefix =~ /^\d+$/ and $prefix >= 0 and $prefix <= 32;

	# Count and ignore prefix /25-32
	if ($prefix >= 25 and $prefix <= 32) {
	    $ignorev4cnt++;
	    next;
	};

        push @{ $ipv4data{ "$ip/$prefix" } }, $asn;

    } elsif (m/^\s*$/) {

	# Ignore empty line

    } else {

	die qq(ERROR on line $linecnt in input data);
    }
}

# Create zone file data from IPv6 data
foreach my $fullprefix ( keys %ipv6data ) {

    my ($rev, $lenfulldigit, $subrev, $remainder);
    my ($ip, $prefix) = split ('/', $fullprefix);
        
    # Create a reverse name from address
    $rev = Net::IP::ip_reverse ($ip);
    $rev =~ s/\.ip6\.arpa\.?$//; # remove ".ip.arpa." from reverse name

    # Every digit in the IP address covers 4 bits. Find the number digits, with the
    # prefix that covers whole digits, e.g. both 4 and 5 bits cover one digit, but
    # 5 bits has then a remainder of 1 bit handled below.
    #
    # Before each digit in the reverse we keep the dot, i.e. "* 2".
    $lenfulldigit = int ($prefix /4) * 2; # Counted from the end of $rev below
    $subrev = substr $rev, -$lenfulldigit;
    $remainder = $prefix % 4;

    my $rdata = &create_rdata( $ipv6data{ $fullprefix }, $fullprefix);
    
    # Prefix with "IPV6\t". Print TXT information for following reverses
    say "IPV6\t:127.0.0.2:$rdata";
    
    if ($remainder == 0) {
        # Prefix length was 0, 4, 8...
        say "IPV6\t$subrev";
        
    } else {
        # Get the next digit after the substring extracted
        my $nextdigit = hex substr $rev, -$lenfulldigit-1, 1;
        # Governs how many subnets to match
        my ($addon);
        $addon = 7 if $remainder == 1; # 0-6
        $addon = 3 if $remainder == 2; # 0-2
        $addon = 1 if $remainder == 3; # 0

        for (my $i = 0; $i <= $addon; $i++) {
            my $add = $nextdigit + $i;
            die qq(ERROR: Calculated digit "$add" is greater than 15") if $add > 15;
            say 'IPV6' . "\t" . '.' . sprintf ("%x", $add) . $subrev;
        }
    }
}

# Create zone file data for IPv4 data
foreach my $fullprefix ( keys %ipv4data ) {

    my ($ip, $prefix) = split ('/', $fullprefix);
    my $rdata = &create_rdata( $ipv4data{ $fullprefix }, $fullprefix);
    
    say "IPV4\t$ip/$prefix:127.0.0.2:$rdata"
}


# Print warning to STDERR if any of the ignore counters are greater than zero.
if ($ignorev4cnt > 0 and $ignorev6cnt > 0) {
    warn qq(Ignored $ignorev4cnt lines with IPv4 prefix /25-32 and $ignorev6cnt lines with IPv6 prefix /65-128) . "\n";
} elsif ($ignorev4cnt > 0) {
    warn qq(Ignored $ignorev4cnt lines with IPv4 prefix /25-32) . "\n";
} elsif ($ignorev6cnt > 0) {
    warn qq($ignorev6cnt lines with IPv6 prefix /65-128) . "\n";
}


sub create_rdata {
    my ($aref_asn, $fullprefix) = @_;
    
    my $rdata_suffix = "| $fullprefix | NA | NA | NA"; # To put after the list of ASNs.
    my $rdata_maxlength = 250; # Should be 255, but it gives some margin. Only rare cases reach the limit.
  
    # Sort the ASNs to be able to prioritize those with low number in case there are
    # too many to include all. And give consisten output.
    my (@asn) = sort {$a <=> $b} @{ $aref_asn };

    # Create a string of ASNs up to the limit (RDATA not exeeding $rdata_maxlength bytes)
    my $asnstr = '';
    foreach my $a (@asn) {
        # Include length of one white space
        if ( length($asnstr) + length($a) + 1 + length($rdata_suffix) > $rdata_maxlength ) {
            last;
        } else {
            $asnstr .= "$a ";
        }
    }

    return "${asnstr}${rdata_suffix}";    
}
