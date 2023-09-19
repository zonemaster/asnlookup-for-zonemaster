#! /usr/bin/env bash

# Directories used in this script
basedir="/var/lib/rbldns"
datadir="$basedir/data"
logdir="$basedir/log"
scriptdir="$basedir/script"
zonedir="$basedir/zones"

# Script run from this script
convertscript="$scriptdir/convert-asn.pl"

# Files
sourcefile="table.txt" # Stored in datadir
metafile="$datadir/tablemetadata.txt"
ipv4data="$zonedir/ipv4data.txt"  # Must have the same path and names
ipv6data="$zonedir/ipv6data.txt"  # as specified for rbldnsd

# For fetching the source file
url="https://bgp.tools/$sourcefile"
wgetcommand="wget --directory-prefix=$datadir -o $logdir/wget.log --backups=30 $url"


logmessage()
{
    # For sending messages to syslog. First argument must be ERROR or INFO.
    # Second argument must be a string (the message)
    
    local level facil
    level=$1
    shift

    if [ "$level" = ERROR ]; then
	facil="daemon.err"
	
    elif [ "$level" = WARNING ]; then
	facil="daemon.warning"

    elif [ "$level" = INFO ]; then
	facil="daemon.info"

    else
	# Error in code
	exit 1
    fi
    logger --id=$$ -p $facil $@
}


set_lock_and_trap ()
{
    # Lock and set trap to delete lock files.

    local lockfile tmplockfile lockingpid

    lockfile="/tmp/rbldns-fetch.lock"

    # Create temporary lock file from template
    if ! tmplockfile=$( mktemp $lockfile.XXXXXX ) ; then
	logmessage ERROR "Cannot create temporary lock file. TERMINATING."
	return 1
    fi

    # Add message to temporary lock file
    if ! (echo "Locked at $(date) with pid"; echo "$$") > $tmplockfile ; then
	logmessage ERROR "Cannot add text to temporary lock file. TERMINATING."
	rm -f $tmplockfile
	return 1
    fi

    # Lock
    if ln $tmplockfile $lockfile 2>/dev/null; then
	rm -f $tmplockfile
    else
	rm -f $tmplockfile
	lockingpid=$(tail -1 $lockfile)
	logmessage ERROR "Process already locked by pid '$lockingpid'."
	if echo $lockingpid | egrep -q "^[0-9][0-9]*$" ; then
	    if [ -z "$(ps -h -p $lockingpid)" ] ; then
		rm -f $lockfile
		logmessage INFO "No process behind locking pid. Lock file removed."
	    fi
	fi
	return 1
    fi

    # Set traps to have lock file cleared at program termination
    trap "rm -f $lockfile; exit 0" 0 || exit 1
    trap "rm -f $lockfile; exit 1" 1 2 3 6 15 || exit 1   
} # END set_lock_and_trap ()


fetchsource()
{
    # Fetch a new source file

    local newfile newfilelength oldfile oldfilelength

    newfile="$datadir/$sourcefile"
    oldfile="$datadir/$sourcefile.1"

    if $wgetcommand ; then

	# New file has been fetch

	newfilelength=$(wc -l < $newfile) # Number of lines in the fetched file
	if ! [ -s $newfile ] ; then
	    logmessage ERROR "Fetched $sourcefile is empty. TERMINATING."
	    return 1
	fi	 
	logmessage INFO "Fetched $sourcefile with $newfilelength lines."
	
	# Old file must exist and be non-empty to be able to be compared to
	if [ -s $oldfile ] ; then
	    oldfilelength=$(wc -l < $oldfile) # Number of lines in previous file
	    if [ "$(( 10 * newfilelength / oldfilelength ))" -lt 9 ] ; then
		logmessage WARNING "Fetched $sourcefile has decrease more than 10% compared to previous version."
	    fi
	fi
    else
	logmessage ERROR "Fetching $sourcefile failed. TERMINATING."
	return 1
    fi
    return 0      
}

convertsource()
{
    # Convert the fetched soruce file to a meta format

    local scriptmessage newfile

    newfile="$datadir/$sourcefile"

    # Save if exists and is non-empty
    if [ -s $metafile ]; then
	mv $metafile $metafile.1
    fi
    
    scriptmessage=$( cat $newfile | $convertscript 2>&1 > $metafile)

    # If there was an error, send a log message and terminate
    if [ $? -ne 0 ] ; then
	logmessage ERROR "$scriptmessage"
	return 1
    fi

    # Log the message from script as a warning
    if [ -n "$scriptmessage" ] ; then
	logmessage WARNING "$scriptmessage"
    fi

    if ! [ -s $metafile ]; then
	logmessage ERROR "Created metafile is empty. TERMINATING."
	return 1
    fi
    return 0
}

createzonefiles()
{
    # Create the IPv4 and IPv6 zone files from the metafile

    local ipv4datatmp ipv6datatmp

    ipv4datatmp="$ipv4data.tmp"
    ipv6datatmp="$ipv6data.tmp"

    
    if ! grep "^IPV4" $metafile | cut -f2- > $ipv4datatmp ; then
	logmessage ERROR "Creating IPv4 zone file failed. TERMINATING."
	return 1
    fi
	
    if ! grep "^IPV6" $metafile | cut -f2- > $ipv6datatmp ; then
	logmessage ERROR "Creating IPv6 zone file failed. TERMINATING."
	return 1
    fi
	
    # Move files into place. Should not create error
    chmod 644 $ipv4datatmp
    chmod 644 $ipv6datatmp
    if ! mv $ipv4datatmp $ipv4data; then
	logmessage ERROR "Creating $(basename $ipv4data) failed. TERMINATING."
	return 1
    fi
    if ! mv $ipv6datatmp $ipv6data; then
	logmessage ERROR "Creating $(basename $ipv6data) failed. TERMINATING."
	return 1
    fi
}
    
# Start
logmessage INFO "$(basename $0) started"

if ! set_lock_and_trap ; then
    logmessage ERROR "$(basename $0) terminated unsucessfully"
    exit 1
fi

if ! fetchsource ; then
    logmessage ERROR "$(basename $0) terminated unsucessfully"
    exit 1
fi
if ! convertsource ; then
    logmessage ERROR "$(basename $0) terminated unsucessfully"
    exit 1
fi
if ! createzonefiles ; then
    logmessage ERROR "$(basename $0) terminated unsucessfully"
    exit 1
fi

logmessage INFO "$(basename $0) completed sucessfully"


